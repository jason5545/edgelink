import EdgeLinkKit
import Foundation

// Parsed view of a TrustedDeviceInfo device-info frame, mirroring the
// writers in EdgeLinkKit's LyraTrustedDeviceInfo (thin announce frame and
// the full syncReplyDeviceInfoFrame share the same field map):
//   f1 name, f2 type, f3 fullDeviceId, f4 uidHash, f11 hwModel,
//   f12 lyraVersion, f13 deviceKey, f14 service (repeated), f15 credBlock,
//   f19 region, f23 shortId, f25 meshPort, f34 osVersion, f35 ip, f39 account
public struct LyraTrustedDevice: Sendable, Equatable {
    public struct Service: Sendable, Equatable {
        public var name: String
        public var package: String
        public var data: Data?

        public init(name: String, package: String, data: Data? = nil) {
            self.name = name
            self.package = package
            self.data = data
        }
    }

    public var deviceName: String = ""
    public var deviceType: UInt64 = 0
    public var fullDeviceIdHex: String = ""
    public var shortDeviceIdHex: String = ""
    public var uidHash: String = ""
    public var accountNumericId: String = ""
    public var meshPort: UInt64 = 0
    public var ipAddress: String?
    public var hwModel: String = ""
    public var lyraVersion: String = ""
    public var deviceKey: Data?
    public var services: [Service] = []
    public var credBlock: Data?
    public var region: String = ""
    public var osVersion: String?

    public init() {}

    public func hasService(_ name: String) -> Bool {
        services.contains { $0.name == name }
    }
}

public enum LyraTrustedDeviceParser {
    public enum PayloadKind: Sendable, Equatable {
        // Mesh announce (3-byte netId/0/0 header): parses into DevRepo but
        // the phone's AddOnlineDevice rejects it with trusted_type 0 — the
        // cred checks never run on this path.
        case announce
        // Device-initiated type-1 sync push: routes through HandleSyncDevMsg
        // and its cred checks (binary-confirmed 2026-08-04).
        case push
        // Type-2 reply (trusted-type wrapper f6): HandleReplyDevMsg ALSO runs
        // the cred checks and stamps trusted type (0731 ground truth) — the
        // earlier "reply never stamps" note was wrong.
        case reply
    }

    public struct Payload: Sendable {
        public var kind: PayloadKind
        public var device: LyraTrustedDevice
        public var groupInfo: Data?
        public var trustedType: UInt64?
    }

    // Parses the post-decryption plaintext of a packType-5 payload. Handles
    // all three observed shapes:
    //   announce:     netId 0x00 0x00 | frame{f1:1, f5:sync{f1:1, f2:info}}
    //   sync push:    0x00 | frame{f1:1, f5:sync{f1:1, f2:info(f15:groupInfo)}}
    //   sync reply:   0x00 | frame{f1:2, f6:{f2:trustedType, f3:info(f15:groupInfo)}}
    // The group cred carrier is tdi.f15 on BOTH sync paths (binary-proven):
    // SyncFrame's f2(dev)/f3(adv_key) are a oneof, so anything in sync.f3
    // makes the phone delete the whole dev frame on parse.
    public static func parsePayload(_ plaintext: Data) -> Payload? {
        var frameData = Data(plaintext)
        var isAnnounce = false
        // Strip the announce's 3-byte netId/0/0 header or the sync path's
        // single 0x00 type byte.
        if plaintext.count > 3, plaintext[plaintext.startIndex + 1] == 0,
           plaintext[plaintext.startIndex + 2] == 0
        {
            frameData = Data(plaintext.dropFirst(3))
            isAnnounce = true
        } else if plaintext.first == 0x00 {
            frameData = Data(plaintext.dropFirst())
        } else {
            return nil
        }
        if let sync = lengthDelimited(5, in: frameData),
           let deviceInfo = lengthDelimited(2, in: sync),
           let device = parseDeviceInfo(deviceInfo)
        {
            return Payload(
                kind: isAnnounce ? .announce : .push,
                device: device,
                groupInfo: isAnnounce ? nil : lengthDelimited(15, in: deviceInfo),
                trustedType: nil
            )
        }
        if let wrapper = lengthDelimited(6, in: frameData),
           let deviceInfo = lengthDelimited(3, in: wrapper),
           let device = parseDeviceInfo(deviceInfo)
        {
            return Payload(
                kind: .reply,
                device: device,
                groupInfo: lengthDelimited(15, in: deviceInfo),
                trustedType: varint(2, in: wrapper)
            )
        }
        return nil
    }

    public static func parseDeviceInfo(_ data: Data) -> LyraTrustedDevice? {
        guard let fields = try? LyraProtoReader.readFields(from: data) else { return nil }
        var device = LyraTrustedDevice()
        for field in fields {
            switch (field.number, field.wireType) {
            case (1, 2):
                device.deviceName = string(field)
            case (2, 0):
                device.deviceType = field.varintValue ?? 0
            case (3, 2):
                device.fullDeviceIdHex = string(field)
            case (4, 2):
                device.uidHash = string(field)
            case (11, 2):
                device.hwModel = string(field)
            case (12, 2):
                device.lyraVersion = string(field)
            case (13, 2):
                device.deviceKey = field.lengthDelimitedValue
            case (14, 2):
                if let raw = field.lengthDelimitedValue, let service = parseService(raw) {
                    device.services.append(service)
                }
            case (15, 2):
                device.credBlock = field.lengthDelimitedValue
            case (19, 2):
                device.region = string(field)
            case (23, 2):
                device.shortDeviceIdHex = string(field)
            case (25, 0):
                device.meshPort = field.varintValue ?? 0
            case (34, 2):
                device.osVersion = string(field)
            case (35, 2):
                device.ipAddress = string(field)
            case (39, 2):
                device.accountNumericId = string(field)
            default:
                continue
            }
        }
        return device
    }

    private static func string(_ field: LyraProtoReader.Field) -> String {
        field.lengthDelimitedValue.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    private static func parseService(_ data: Data) -> LyraTrustedDevice.Service? {
        guard let name = lengthDelimited(1, in: data).flatMap({ String(data: $0, encoding: .utf8) })
        else { return nil }
        let package = lengthDelimited(2, in: data).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return LyraTrustedDevice.Service(name: name, package: package, data: lengthDelimited(3, in: data))
    }

    static func lengthDelimited(_ fieldNumber: Int, in data: Data) -> Data? {
        guard let fields = try? LyraProtoReader.readFields(from: data) else { return nil }
        return fields.first { $0.number == fieldNumber && $0.wireType == 2 }?.lengthDelimitedValue
    }

    static func varint(_ fieldNumber: Int, in data: Data) -> UInt64? {
        guard let fields = try? LyraProtoReader.readFields(from: data) else { return nil }
        return fields.first { $0.number == fieldNumber && $0.wireType == 0 }?.varintValue
    }
}
