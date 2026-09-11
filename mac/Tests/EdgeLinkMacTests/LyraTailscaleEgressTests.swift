import EdgeLinkKit
import Foundation
import Network
import XCTest

// Recreates the 2026-09-11 Tailscale-exit-node outage — every phone-bound
// flow following the route table into utun and black-holing while Mac and
// phone share the same WiFi — and pins the fix end to end:
//
// 1. RECREATE: forcing dial egress onto the wrong interface (what the
//    hijacked route table effectively does) kills loopback mesh traffic.
// 2. FIX: with the policy active, a dial into the phone's LAN subnet binds
//    the subnet-owning interface (bypassing the hijacked route) while
//    loopback, internet and tailnet destinations keep system routing.
// 3. INBOUND: a TCP listener pinned via the phone's LAN hint completes
//    handshakes the wildcard listener loses into the tunnel.
final class LyraTailscaleEgressTests: XCTestCase {
    private var sender: LyraMeshSocket?
    private var receiver: LyraMeshSocket?
    private var liveInterfacesByName: [String: NWInterface] = [:]

    private let lock = NSLock()
    private var decisions: [(context: String, interface: String?)] = []
    private var received: [LyraMeshPack.Frame] = []

    override func setUp() {
        super.setUp()
        LANEgressInterface.resetTestOverrides()
        liveInterfacesByName = Self.snapshotInterfaces()
        LANEgressInterface.nwInterfaceProviderOverride = { [weak self] name in
            self?.liveInterfacesByName[name]
        }
        LANEgressInterface.onBindDecision = { [weak self] context, interface in
            self?.lock.lock()
            self?.decisions.append((context, interface))
            self?.lock.unlock()
        }
    }

    override func tearDown() {
        LANEgressInterface.resetTestOverrides()
        sender?.stop()
        receiver?.stop()
        sender = nil
        receiver = nil
        liveInterfacesByName = [:]
        super.tearDown()
    }

    private static func snapshotInterfaces() -> [String: NWInterface] {
        let semaphore = DispatchSemaphore(value: 0)
        var map: [String: NWInterface] = [:]
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            for interface in path.availableInterfaces {
                map[interface.name] = interface
            }
            semaphore.signal()
        }
        monitor.start(queue: .global())
        _ = semaphore.wait(timeout: .now() + 5)
        monitor.cancel()
        return map
    }

    private func en0Interface() throws -> LANEgressInterface.LocalInterface {
        guard let en0 = LANEgressInterface.currentLocalInterfaces().first(where: { $0.name == "en0" }) else {
            throw XCTSkip("en0 has no IPv4 on this machine")
        }
        return en0
    }

    // The live en0 plus a Tailscale utun owning the tailnet /32 — the
    // interface set of the 2026-09-11 outage machine.
    private func tailscaleSet(en0: LANEgressInterface.LocalInterface) -> [LANEgressInterface.LocalInterface] {
        [
            en0,
            LANEgressInterface.LocalInterface(name: "utun4", address: "100.89.162.36", netmask: "255.255.255.255"),
        ]
    }

    private func waitFor(
        _ description: String, timeout: TimeInterval = 10,
        _ predicate: @escaping () -> Bool
    ) {
        let expectation = XCTestExpectation(description: description)
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now(), repeating: .milliseconds(20))
        timer.setEventHandler {
            if predicate() {
                expectation.fulfill()
                timer.cancel()
            }
        }
        timer.resume()
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        timer.cancel()
        XCTAssertEqual(result, .completed, "timed out waiting for: \(description)")
    }

    private func startSocketPair() throws -> (sender: LyraMeshSocket, receiverPort: UInt16) {
        let sender = LyraMeshSocket()
        let receiver = LyraMeshSocket()
        self.sender = sender
        self.receiver = receiver
        receiver.onFrame = { [weak self] frame, _, _ in
            self?.lock.lock()
            self?.received.append(frame)
            self?.lock.unlock()
        }
        try receiver.start()
        try sender.start()
        waitFor("both sockets bound") {
            receiver.boundPort != nil && sender.boundPort != nil
        }
        return (sender, try XCTUnwrap(receiver.boundPort))
    }

    private func receivedCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return received.count
    }

    private func decision(for context: String) -> String?? {
        lock.lock()
        defer { lock.unlock() }
        return decisions.last(where: { $0.context == context })?.interface
    }

    // MARK: - Recreate

    func testTunnelHijackedEgressRecreatesOutageOnLoopback() throws {
        let (sender, receiverPort) = try startSocketPair()

        // What the hijacked route table effectively does to every phone
        // dial: egress forced onto the wrong pipe. Live 2026-09-11 this was
        // utun4 swallowing the whole LAN /22; on loopback, en0 plays utun.
        LANEgressInterface.forcedBindInterfaceName = "en0"
        try sender.send(frame: LyraMeshPack.Frame(packType: 5, payload: Data("hijacked".utf8)), to: "127.0.0.1", port: receiverPort)
        let hijackDeadline = Date().addingTimeInterval(1.5)
        while Date() < hijackDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(receivedCount(), 0, "egress forced into the wrong pipe must black-hole (the outage)")

        // The fix: policy-driven binding leaves loopback unbound → normal
        // routing → delivery resumes. For LAN destinations it binds the
        // subnet-owning interface instead (pinned by the next test).
        LANEgressInterface.forcedBindInterfaceName = nil
        LANEgressInterface.localInterfacesOverride = tailscaleSet(en0: try en0Interface())
        // Fresh sender: the phase-A dial cached an en0-bound connection for
        // this endpoint key, and reusing it would keep black-holing.
        sender.stop()
        let fixedSender = LyraMeshSocket()
        self.sender = fixedSender
        try fixedSender.start()
        waitFor("fixed sender bound") {
            fixedSender.boundPort != nil
        }
        try fixedSender.send(frame: LyraMeshPack.Frame(packType: 5, payload: Data("fixed".utf8)), to: "127.0.0.1", port: receiverPort)
        waitFor("frame delivered once egress policy is correct") {
            self.receivedCount() == 1
        }
        XCTAssertNil(try XCTUnwrap(decision(for: "dial:127.0.0.1")), "loopback must keep system routing")
    }

    // MARK: - Fix: dial binding

    func testDialToPhoneLANSubnetBindsLANInterfaceUnderTailscaleInterfaces() throws {
        let en0 = try en0Interface()
        LANEgressInterface.localInterfacesOverride = tailscaleSet(en0: en0)
        let (sender, receiverPort) = try startSocketPair()

        // The phone's position: an address inside en0's subnet (here the
        // Mac's own en0 address, delivered hairpin through en0).
        try sender.send(
            frame: LyraMeshPack.Frame(packType: 5, payload: Data("lan".utf8)),
            to: en0.address,
            port: receiverPort
        )
        waitFor("LAN-bound frame delivered hairpin") {
            self.receivedCount() == 1
        }
        XCTAssertEqual(try XCTUnwrap(decision(for: "dial:\(en0.address)")), "en0")
    }

    func testOffLANDestinationsKeepSystemRouting() throws {
        let en0 = try en0Interface()
        LANEgressInterface.localInterfacesOverride = tailscaleSet(en0: en0)
        let (sender, _) = try startSocketPair()

        // TURN/relay traffic must follow the (tunnel) default route, and
        // tailnet peers must not get en0-bound either. Fire-and-forget UDP;
        // the assertion is on the binding decision, not delivery.
        try sender.send(frame: LyraMeshPack.Frame(packType: 5, payload: Data("x".utf8)), to: "192.0.2.1", port: 9)
        try sender.send(frame: LyraMeshPack.Frame(packType: 5, payload: Data("x".utf8)), to: "100.64.10.131", port: 9)
        XCTAssertNil(try XCTUnwrap(decision(for: "dial:192.0.2.1")))
        XCTAssertNil(try XCTUnwrap(decision(for: "dial:100.64.10.131")))
    }

    // MARK: - Fix: raw-BSD-socket binding (MPT media sink / timesync)

    // The MPT sink's KCP ACKs and the timesync client bypass Network
    // framework — under the hijack their sendto egress died in the tunnel
    // and the phone retransmitted its window forever (live una=128 wedge).
    func testRawSocketBindingSetsIPBoundIFForLANDestination() throws {
        let en0 = try en0Interface()
        LANEgressInterface.localInterfacesOverride = tailscaleSet(en0: en0)

        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        defer { close(fd) }
        XCTAssertTrue(LANEgressInterface.bindToLANInterface(socketFD: fd, destinationHost: en0.address))
        var boundIf: UInt32 = 0
        var length = socklen_t(MemoryLayout<UInt32>.size)
        XCTAssertEqual(getsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &boundIf, &length), 0)
        XCTAssertEqual(boundIf, if_nametoindex("en0"), "ACK socket must be nailed to the LAN interface")
        XCTAssertEqual(try XCTUnwrap(decision(for: "dial-fd:\(en0.address)")), "en0")

        let offLAN = socket(AF_INET, SOCK_DGRAM, 0)
        defer { close(offLAN) }
        XCTAssertFalse(LANEgressInterface.bindToLANInterface(socketFD: offLAN, destinationHost: "192.0.2.1"))
        var offLANBoundIf: UInt32 = 0
        XCTAssertEqual(getsockopt(offLAN, IPPROTO_IP, IP_BOUND_IF, &offLANBoundIf, &length), 0)
        XCTAssertEqual(offLANBoundIf, 0, "off-LAN sockets keep system routing")
        XCTAssertNil(try XCTUnwrap(decision(for: "dial-fd:192.0.2.1")))
    }

    // Loopback recreation is impossible for the raw path: the kernel
    // short-circuits 127/8 to lo0 even on an IP_BOUND_IF socket (unlike the
    // NWConnection path used above), so the wedge's wire-level evidence is
    // the live log (una pinned at 128, ~100% duplicates). What must hold
    // here: the policy never binds loopback destinations, so relay-fed
    // loopback flows keep working.
    func testRawSocketLoopbackStaysUnbound() throws {
        let receiver = LyraMeshSocket()
        self.receiver = receiver
        try receiver.start()
        waitFor("receiver bound") { receiver.boundPort != nil }
        let receiverPort = try XCTUnwrap(receiver.boundPort)
        var rawReceived = 0
        receiver.onRawDatagram = { _, _ in
            self.lock.lock()
            rawReceived += 1
            self.lock.unlock()
        }

        LANEgressInterface.localInterfacesOverride = tailscaleSet(en0: try en0Interface())
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        defer { close(fd) }
        XCTAssertFalse(LANEgressInterface.bindToLANInterface(socketFD: fd, destinationHost: "127.0.0.1"))
        var boundIf: UInt32 = 0
        var length = socklen_t(MemoryLayout<UInt32>.size)
        XCTAssertEqual(getsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &boundIf, &length), 0)
        XCTAssertEqual(boundIf, 0, "loopback destinations must stay unbound")

        var destination = sockaddr_in()
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = receiverPort.bigEndian
        XCTAssertEqual(inet_pton(AF_INET, "127.0.0.1", &destination.sin_addr), 1)
        let data = Data("relay-fed".utf8)
        let sent = data.withUnsafeBytes { buffer -> Int in
            withUnsafePointer(to: &destination) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    Darwin.sendto(fd, buffer.baseAddress, data.count, 0, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        XCTAssertEqual(sent, data.count)
        waitFor("loopback raw datagram delivered unbound") {
            self.lock.lock()
            defer { self.lock.unlock() }
            return rawReceived == 1
        }
    }

    // MARK: - Fix: inbound TCP listener binding

    func testListenerPinsToPhoneLANInterface() throws {
        let en0 = try en0Interface()
        LANEgressInterface.localInterfacesOverride = tailscaleSet(en0: en0)

        let parameters = NWParameters.tcp
        let binding = LANEgressInterface.lanBoundListenerParameters(
            parameters,
            port: .any,
            peerHostHint: en0.address
        )
        XCTAssertEqual(try XCTUnwrap(decision(for: "listen:\(en0.address)")), "en0")
        XCTAssertEqual(binding.listenPort, .any, "the port moves into the required local endpoint")
        let reservedPort = try XCTUnwrap(binding.effectivePort, "ephemeral port must be reserved up front")
        XCTAssertNotEqual(reservedPort, 0)

        let listener = try NWListener(using: parameters, on: binding.listenPort)
        defer { listener.cancel() }
        let accepted = XCTestExpectation(description: "phone-side dial accepted on the pinned listener")
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            accepted.fulfill()
        }
        listener.start(queue: .global())

        // The phone's dial: a TCP connection into the pinned listener must
        // complete the handshake (the wildcard version's SYN-ACK died in the
        // tunnel on the live machine).
        let dial = NWConnection(
            host: NWEndpoint.Host(en0.address),
            port: NWEndpoint.Port(rawValue: reservedPort)!,
            using: .tcp
        )
        defer { dial.cancel() }
        let dialReady = XCTestExpectation(description: "dial reaches ready")
        dial.stateUpdateHandler = { state in
            if case .ready = state {
                dialReady.fulfill()
            }
        }
        dial.start(queue: .global())
        let result = XCTWaiter.wait(for: [accepted, dialReady], timeout: 5)
        XCTAssertEqual(result, .completed)
    }

    func testListenerWithLoopbackOrUnknownHintStaysUnbound() throws {
        let en0 = try en0Interface()
        LANEgressInterface.localInterfacesOverride = tailscaleSet(en0: en0)
        let explicitPort = NWEndpoint.Port(rawValue: 41_999)!

        let loopbackParams = NWParameters.tcp
        let loopbackBinding = LANEgressInterface.lanBoundListenerParameters(
            loopbackParams,
            port: explicitPort,
            peerHostHint: "127.0.0.1"
        )
        XCTAssertNil(try XCTUnwrap(decision(for: "listen:127.0.0.1")))
        XCTAssertEqual(loopbackBinding.listenPort, explicitPort)
        XCTAssertEqual(loopbackBinding.effectivePort, explicitPort.rawValue)
        XCTAssertNil(loopbackParams.requiredInterface)

        let noHintParams = NWParameters.tcp
        let noHintBinding = LANEgressInterface.lanBoundListenerParameters(
            noHintParams,
            port: explicitPort,
            peerHostHint: nil
        )
        XCTAssertEqual(noHintBinding.listenPort, explicitPort)
        XCTAssertNil(noHintParams.requiredInterface)
    }
}
