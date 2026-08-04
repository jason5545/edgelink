import CryptoKit
import EdgeLinkKit
import Foundation

// Builds the PAYLOAD_V2 plaintext for the phone's reverse sync task: the full
// TrustedDeviceInfo (64-hex full device id, relayCall service, mesh port) in
// the type-0x00 sync frame the phone's FrameParse accepts, so DevRepo can
// store networking_trusted_device_<fullId> and TeleService finds our relay.
enum LyraSyncReply {
    private static let syncUuidDefaultsKey = "xiaomiSyncReplyUuid"
    private static let meshPortDefaultsKey = "xiaomiMiShareMeshPort"

    // The clone's short id stays stable (xiaomiTrustCloneDeviceId); the full
    // 64-hex id extends it deterministically from our identity pubkey so the
    // phone's store key is stable across restarts.
    static func fullDeviceIdHex(shortDeviceIdHex: String) -> String {
        let pub = MiTrustTicketStore.current().identityPubKey
        let digest = SHA256.hash(data: pub)
            .map { String(format: "%02X", $0) }.joined()
        guard shortDeviceIdHex.count == 8, digest.count == 64 else {
            return shortDeviceIdHex
        }
        return shortDeviceIdHex + digest.dropFirst(8)
    }

    static var syncUuid: String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: syncUuidDefaultsKey), !existing.isEmpty {
            return existing
        }
        let generated = UUID().uuidString.lowercased()
        defaults.set(generated, forKey: syncUuidDefaultsKey)
        return generated
    }

    static var meshPort: UInt16? {
        let saved = UserDefaults.standard.integer(forKey: meshPortDefaultsKey)
        return saved > 0 ? UInt16(saved) : nil
    }

    static func services(relayCallEnabled: Bool) -> [LyraTrustedDeviceInfo.Service] {
        var services = [
            LyraTrustedDeviceInfo.Service(name: "miLyraShare", package: "com.edgelink.mac"),
            LyraTrustedDeviceInfo.Service(name: "miShareBasic", package: "com.edgelink.mac"),
            LyraTrustedDeviceInfo.Service(name: "miLyraShareTransfer", package: "com.edgelink.mac"),
            LyraTrustedDeviceInfo.Service(
                name: "PairService", package: "com.milink.service",
                data: Data([0x09, 0x59, 0xa0, 0x44])
            ),
            LyraTrustedDeviceInfo.Service(
                name: "universalClipboard", package: "com.milink.service", data: Data([0x00])
            ),
            LyraTrustedDeviceInfo.Service(
                name: "NotificationTrans", package: "com.milink.service",
                data: Data([0x09, 0x59, 0xa0, 0x44])
            ),
            LyraTrustedDeviceInfo.Service(
                name: "synergy", package: "pcmanager", data: Data([0x09, 0x59, 0xa0, 0x44])
            ),
            LyraTrustedDeviceInfo.Service(
                name: "cast", package: "com.xiaomi.mirror", data: Data([0x09, 0x59, 0xa0, 0x44])
            ),
            LyraTrustedDeviceInfo.Service(
                name: "distributedHardware", package: "com.milink.service", data: Data("1".utf8)
            ),
        ]
        if relayCallEnabled {
            services.append(
                LyraTrustedDeviceInfo.Service(
                    name: "relayCall", package: "com.ios.phone",
                    data: Data([0x03, 0x01, 0x01, 0x01])
                )
            )
        }
        return services
    }

    static func payload(deviceIdHex: String, displayName: String) -> Data {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let relayCallEnabled = UserDefaults.standard.object(forKey: "xiaomiRelayCallAdvertise") as? Bool ?? false
        let deviceTypeOverride = UserDefaults.standard.integer(forKey: "xiaomiDeviceTypeOverride")
        let deviceInfo = LyraTrustedDeviceInfo.syncReplyDeviceInfoFrame(
            deviceName: displayName,
            deviceType: deviceTypeOverride > 0 ? UInt32(deviceTypeOverride) : 4,
            fullDeviceIdHex: fullDeviceIdHex(shortDeviceIdHex: deviceIdHex),
            shortDeviceIdHex: deviceIdHex,
            uidHash: "61F250B63BE702E35785999767C221163AF7238995757F598034B753E3AF0733",
            hwModel: hardwareModel(),
            lyraVersion: "5.1.208.10.fullCnRelease.0512164",
            services: services(relayCallEnabled: relayCallEnabled),
            meshPort: meshPort,
            ipAddress: primaryIPv4Address(),
            osVersion: "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)",
            accountNumericId: "32717118",
            syncUuid: syncUuid,
            region: UserDefaults.standard.string(forKey: "xiaomiMeshRegion") ?? "cn"
        )
        return LyraTrustedDeviceInfo.syncReplyPayload(deviceInfo: deviceInfo)
    }

    private static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }

    private static func primaryIPv4Address() -> String? {
        var address: String?
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return nil }
        defer { freeifaddrs(interfaces) }
        var current = interfaces
        while let interface = current {
            let flags = Int32(interface.pointee.ifa_flags)
            let name = String(cString: interface.pointee.ifa_name)
            if name == "en0", flags & IFF_UP != 0, interface.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(
                    interface.pointee.ifa_addr,
                    socklen_t(interface.pointee.ifa_addr.pointee.sa_len),
                    &host,
                    socklen_t(host.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                ) == 0 {
                    address = String(cString: host)
                }
            }
            current = interface.pointee.ifa_next
        }
        return address
    }
}
