import Foundation
import Network

// Tailscale exit-node survival (live root cause 2026-09-11): with an exit
// node connected, Tailscale installs its own default route AND a route for
// the connected LAN subnet via utun4 (netstat showed "10.5.48/22 utun4"
// shadowing en0's ifscoped clone). Every phone-bound flow then follows the
// routing table into the tunnel and black-holes: mirror cast dial, RTSP
// dial, file-transfer dials and inbound TCP handshakes all die while Mac
// and phone share the same WiFi (default-route ping to the phone: 100%
// loss; en0-bound ping: 0% loss).
//
// The escape is interface scoping (IP_BOUND_IF semantics): a flow bound to
// the LAN interface ignores the hijacked route lookup entirely. Verified
// live: an en0-bound UDP/TCP dial reaches the phone, and a TCP listener
// with requiredInterface + requiredLocalEndpoint(en0 IP) completes
// handshakes that the wildcard listener times out on (SYN-ACKs otherwise
// egress utun4). Inbound UDP needs nothing: Network framework pins accepted
// datagram flows to the ingress interface, so replies already work.
//
// Selection policy: only destinations inside a NON-tunnel interface's
// subnet get bound — internet destinations (TURN/relay) and tailnet
// addresses (100.64.0.0/10 lives on a utun) must keep following the system
// routing table, and loopback destinations are never bound so tests are
// unaffected.
public enum LANEgressInterface {
    public struct LocalInterface: Equatable, Sendable {
        public let name: String
        public let address: String
        public let netmask: String

        public init(name: String, address: String, netmask: String) {
            self.name = name
            self.address = address
            self.netmask = netmask
        }
    }

    private static let tunnelNamePrefixes = ["utun", "ipsec", "ppp", "tun", "tap", "wg"]

    public static func isTunnelInterfaceName(_ name: String) -> Bool {
        tunnelNamePrefixes.contains { name.hasPrefix($0) }
    }

    // MARK: - Test seams

    // Replaces the live getifaddrs snapshot (Tailscale scenarios in tests).
    public static var localInterfacesOverride: [LocalInterface]?
    // Forces EVERY dial to bind this interface name, including loopback
    // destinations — recreates the "all egress disappears into the wrong
    // pipe" hijack on loopback without touching the routing table.
    public static var forcedBindInterfaceName: String?
    // Supplies NWInterface objects when the live directory must not be used.
    public static var nwInterfaceProviderOverride: ((String) -> NWInterface?)?
    // Observes binding decisions: (context, chosenInterfaceName).
    public static var onBindDecision: ((String, String?) -> Void)?

    public static func resetTestOverrides() {
        localInterfacesOverride = nil
        forcedBindInterfaceName = nil
        nwInterfaceProviderOverride = nil
        onBindDecision = nil
    }

    private static func recordDecision(_ context: String, _ interfaceName: String?) {
        onBindDecision?(context, interfaceName)
    }

    // MARK: - NWInterface directory

    // NWInterface has no name-based initializer; the only source is a path
    // snapshot. Kept warm from app start so dial sites stay synchronous.
    private final class Directory {
        static let shared = Directory()

        private let lock = NSLock()
        private var monitor: NWPathMonitor?
        private var interfacesByName: [String: NWInterface] = [:]

        func warmUp() {
            lock.lock()
            defer { lock.unlock() }
            guard monitor == nil else { return }
            let monitor = NWPathMonitor()
            self.monitor = monitor
            monitor.pathUpdateHandler = { [weak self] path in
                var map: [String: NWInterface] = [:]
                for interface in path.availableInterfaces {
                    map[interface.name] = interface
                }
                self?.lock.lock()
                self?.interfacesByName = map
                self?.lock.unlock()
            }
            monitor.start(queue: DispatchQueue(label: "edgelink.lan-egress.directory", qos: .utility))
        }

        func interface(named name: String) -> NWInterface? {
            lock.lock()
            defer { lock.unlock() }
            return interfacesByName[name]
        }
    }

    public static func warmUp() {
        Directory.shared.warmUp()
    }

    private static func nwInterface(named name: String) -> NWInterface? {
        if let nwInterfaceProviderOverride {
            return nwInterfaceProviderOverride(name)
        }
        return Directory.shared.interface(named: name)
    }

    // MARK: - Local interface enumeration

    public static func currentLocalInterfaces() -> [LocalInterface] {
        if let localInterfacesOverride {
            return localInterfacesOverride
        }
        var result: [LocalInterface] = []
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else {
            return result
        }
        defer { freeifaddrs(interfaces) }
        var current = interfaces
        while let interface = current {
            defer { current = interface.pointee.ifa_next }
            let flags = Int32(interface.pointee.ifa_flags)
            guard flags & IFF_UP != 0,
                  flags & IFF_LOOPBACK == 0,
                  let addressPointer = interface.pointee.ifa_addr,
                  addressPointer.pointee.sa_family == UInt8(AF_INET)
            else {
                continue
            }
            let name = String(cString: interface.pointee.ifa_name)
            guard let address = numericHost(addressPointer), !address.hasPrefix("127.") else {
                continue
            }
            let netmask = interface.pointee.ifa_netmask.flatMap { numericHost($0) } ?? "255.255.255.0"
            result.append(LocalInterface(name: name, address: address, netmask: netmask))
        }
        return result
    }

    // MARK: - Selection policy

    // The non-tunnel interface whose subnet contains the destination (longest
    // prefix wins). nil for non-IPv4, loopback, tunnel-owned (tailnet) and
    // off-LAN destinations — those keep system routing.
    public static func lanInterface(
        forDestination host: String,
        interfaces: [LocalInterface]
    ) -> LocalInterface? {
        guard let target = ipv4ToUInt32(host) else {
            return nil
        }
        if target & 0xFF00_0000 == 0x7F00_0000 {
            return nil
        }
        var best: (interface: LocalInterface, prefixBits: Int)?
        for interface in interfaces where !isTunnelInterfaceName(interface.name) {
            guard let address = ipv4ToUInt32(interface.address),
                  let netmask = ipv4ToUInt32(interface.netmask),
                  address & netmask == target & netmask
            else {
                continue
            }
            let prefixBits = netmask.nonzeroBitCount
            if best == nil || prefixBits > best!.prefixBits {
                best = (interface, prefixBits)
            }
        }
        return best?.interface
    }

    // MARK: - Dial binding

    // Binds an outbound connection's parameters to the LAN interface owning
    // the destination's subnet. No-op for anything that must follow system
    // routing (internet, tailnet, loopback, hostnames).
    @discardableResult
    public static func bindToLANInterface(
        _ parameters: NWParameters,
        destinationHost: String
    ) -> Bool {
        let context = "dial:\(destinationHost)"
        if let forcedBindInterfaceName {
            let applied = applyBinding(forcedBindInterfaceName, to: parameters)
            recordDecision(context, applied ? forcedBindInterfaceName : nil)
            return applied
        }
        guard let match = lanInterface(
            forDestination: destinationHost,
            interfaces: currentLocalInterfaces()
        ) else {
            recordDecision(context, nil)
            return false
        }
        let applied = applyBinding(match.name, to: parameters)
        recordDecision(context, applied ? match.name : nil)
        return applied
    }

    // MARK: - Listener binding

    // MARK: - Raw-socket binding

    // Raw-BSD-socket variant (the MPT media sink/source, the mirror timesync
    // client, and the local-IP-toward-peer probes all bypass Network
    // framework): same policy, applied as IP_BOUND_IF. Without this the MPT
    // sink's KCP ACKs egress the tunnel and the phone retransmits its window
    // forever — receive stuck at the first window boundary, video frozen
    // (live 2026-09-11: una pinned at 128, ~100% duplicates).
    @discardableResult
    public static func bindToLANInterface(socketFD fd: Int32, destinationHost: String) -> Bool {
        let context = "dial-fd:\(destinationHost)"
        let interfaceName: String?
        if let forcedBindInterfaceName {
            interfaceName = forcedBindInterfaceName
        } else {
            interfaceName = lanInterface(
                forDestination: destinationHost,
                interfaces: currentLocalInterfaces()
            )?.name
        }
        guard let interfaceName else {
            recordDecision(context, nil)
            return false
        }
        var index = if_nametoindex(interfaceName)
        guard index != 0,
              setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size)) == 0
        else {
            recordDecision(context, nil)
            return false
        }
        recordDecision(context, interfaceName)
        return true
    }

    public struct LANListenerParameters {
        // Pass to NWListener's on: (the real port moved into the required
        // local endpoint; combining requiredLocalEndpoint with an explicit
        // on: port is EINVAL).
        public let listenPort: NWEndpoint.Port
        // The port the listener actually occupies. NWListener.port reports
        // 0/nil once the port lives in requiredLocalEndpoint, so callers
        // that advertise the port must read this instead.
        public let effectivePort: UInt16?
        public let boundInterfaceName: String?
    }

    // Inbound TCP needs BOTH the interface scope and a local-endpoint pin to
    // the LAN address — requiredInterface alone still lets the kernel route
    // SYN-ACKs into the tunnel (verified live 2026-09-11). When the peer
    // hint (the phone's known LAN IP) sits in a non-tunnel interface's
    // subnet, returns parameters bound to that interface; otherwise returns
    // the inputs unchanged.
    public static func lanBoundListenerParameters(
        _ parameters: NWParameters,
        port: NWEndpoint.Port,
        peerHostHint: String?
    ) -> LANListenerParameters {
        let context = "listen:\(peerHostHint ?? "none")"
        if let forcedBindInterfaceName {
            if applyListenerBinding(
                interfaceName: forcedBindInterfaceName,
                localAddress: nil,
                port: port,
                to: parameters
            ) {
                recordDecision(context, forcedBindInterfaceName)
                return LANListenerParameters(
                    listenPort: .any,
                    effectivePort: port.rawValue == 0 ? nil : port.rawValue,
                    boundInterfaceName: forcedBindInterfaceName
                )
            }
            recordDecision(context, nil)
            return LANListenerParameters(listenPort: port, effectivePort: port.rawValue == 0 ? nil : port.rawValue, boundInterfaceName: nil)
        }
        guard let peerHostHint,
              let match = lanInterface(
                  forDestination: peerHostHint,
                  interfaces: currentLocalInterfaces()
              )
        else {
            recordDecision(context, nil)
            return LANListenerParameters(listenPort: port, effectivePort: port.rawValue == 0 ? nil : port.rawValue, boundInterfaceName: nil)
        }
        // An ephemeral request (.any) cannot go into the required local
        // endpoint as-is: NWListener then reports port 0 and callers that
        // read the port back (to advertise it to the phone) break. Reserve
        // a real port on the LAN address first; the listener rebinds it a
        // moment later (a failed rebind surfaces as a normal listener error).
        let effectivePort: NWEndpoint.Port
        if port == .any {
            guard let reserved = reserveEphemeralPort(address: match.address, interfaceName: match.name),
                  let reservedPort = NWEndpoint.Port(rawValue: reserved)
            else {
                recordDecision(context, nil)
                return LANListenerParameters(listenPort: port, effectivePort: port.rawValue == 0 ? nil : port.rawValue, boundInterfaceName: nil)
            }
            effectivePort = reservedPort
        } else {
            effectivePort = port
        }
        guard applyListenerBinding(
            interfaceName: match.name,
            localAddress: match.address,
            port: effectivePort,
            to: parameters
        ) else {
            recordDecision(context, nil)
            return LANListenerParameters(listenPort: port, effectivePort: port.rawValue == 0 ? nil : port.rawValue, boundInterfaceName: nil)
        }
        recordDecision(context, match.name)
        return LANListenerParameters(
            listenPort: .any,
            effectivePort: effectivePort.rawValue,
            boundInterfaceName: match.name
        )
    }

    // MARK: - Internals

    private static func applyBinding(_ interfaceName: String, to parameters: NWParameters) -> Bool {
        guard let interface = nwInterface(named: interfaceName) else {
            return false
        }
        parameters.requiredInterface = interface
        return true
    }

    private static func applyListenerBinding(
        interfaceName: String,
        localAddress: String?,
        port: NWEndpoint.Port,
        to parameters: NWParameters
    ) -> Bool {
        guard let interface = nwInterface(named: interfaceName) else {
            return false
        }
        parameters.requiredInterface = interface
        if let localAddress, let ipv4 = IPv4Address(localAddress) {
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(ipv4), port: port)
        }
        return true
    }

    private static func reserveEphemeralPort(address: String, interfaceName: String) -> UInt16? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var boundInterface = if_nametoindex(interfaceName)
        guard boundInterface != 0 else { return nil }
        guard setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &boundInterface, socklen_t(MemoryLayout<UInt32>.size)) == 0 else {
            return nil
        }
        var reuse: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var ipv4 = in_addr()
        guard address.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 else { return nil }
        var socketAddress = sockaddr_in()
        socketAddress.sin_family = sa_family_t(AF_INET)
        socketAddress.sin_port = 0
        socketAddress.sin_addr = ipv4
        socketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        let bindResult = withUnsafePointer(to: &socketAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { return nil }
        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(fd, sockaddrPointer, &length)
            }
        }
        guard nameResult == 0 else { return nil }
        return UInt16(bigEndian: assigned.sin_port)
    }

    public static func ipv4ToUInt32(_ string: String) -> UInt32? {
        var address = in_addr()
        guard string.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else {
            return nil
        }
        return UInt32(bigEndian: address.s_addr)
    }

    private static func numericHost(_ address: UnsafePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(
            address,
            socklen_t(address.pointee.sa_len),
            &host,
            socklen_t(host.count),
            nil,
            0,
            NI_NUMERICHOST
        )
        guard result == 0 else {
            return nil
        }
        return String(cString: host)
    }
}
