import Foundation

enum LANPinnedPhoneIP {
    static let defaultsKey = "lanLastPhoneIP"
    static let timeDefaultsKey = "lanLastPhoneIPTime"
    static let maxAge: TimeInterval = 86_400

    struct InterfaceAddress: Equatable {
        let address: String
        let netmask: String
    }

    static func record(_ ip: String, defaults: UserDefaults = .standard, now: Date = Date()) {
        defaults.set(ip, forKey: defaultsKey)
        defaults.set(now.timeIntervalSince1970, forKey: timeDefaultsKey)
    }

    static func current(
        defaults: UserDefaults = .standard,
        interfaces: [InterfaceAddress]? = nil,
        now: Date = Date()
    ) -> String? {
        guard let pinned = defaults.string(forKey: defaultsKey), !pinned.isEmpty else {
            return nil
        }
        let pinnedAt = defaults.double(forKey: timeDefaultsKey)
        guard pinnedAt > 0, now.timeIntervalSince1970 - pinnedAt < maxAge else {
            return nil
        }
        let activeInterfaces = interfaces ?? localIPv4Interfaces()
        guard isOnLocalNetwork(pinned, interfaces: activeInterfaces) else {
            return nil
        }
        return pinned
    }

    static func isOnLocalNetwork(_ ip: String, interfaces: [InterfaceAddress]) -> Bool {
        guard interfaces.isEmpty == false else {
            return true
        }
        guard let target = ipv4ToUInt32(ip) else {
            return false
        }
        for interface in interfaces {
            guard let address = ipv4ToUInt32(interface.address),
                  let netmask = ipv4ToUInt32(interface.netmask)
            else {
                continue
            }
            if target & netmask == address & netmask {
                return true
            }
        }
        return false
    }

    static func localIPv4Interfaces() -> [InterfaceAddress] {
        var result: [InterfaceAddress] = []
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
            guard let address = numericHost(addressPointer),
                  !address.hasPrefix("127.")
            else {
                continue
            }
            let netmask = interface.pointee.ifa_netmask.flatMap { numericHost($0) } ?? "255.255.255.0"
            result.append(InterfaceAddress(address: address, netmask: netmask))
        }
        return result
    }

    static func ipv4ToUInt32(_ string: String) -> UInt32? {
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
