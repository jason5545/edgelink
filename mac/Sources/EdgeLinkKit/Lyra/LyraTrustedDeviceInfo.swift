import Foundation

public enum LyraTrustedDeviceInfo {
    public struct Service: Equatable, Sendable {
        public var name: String
        public var package: String
        public var data: Data?

        public init(name: String, package: String, data: Data? = nil) {
            self.name = name
            self.package = package
            self.data = data
        }
    }

    public static func serviceInfoFrame(_ service: Service) -> Data {
        var data = Data()
        LyraProtoWriter.appendLengthDelimitedField(1, value: Data(service.name.utf8), to: &data)
        LyraProtoWriter.appendLengthDelimitedField(2, value: Data(service.package.utf8), to: &data)
        if let extra = service.data {
            LyraProtoWriter.appendLengthDelimitedField(3, value: extra, to: &data)
        }
        return data
    }

    public static func deviceInfoFrame(
        deviceName: String,
        deviceType: UInt32,
        deviceId: String,
        uidHash: String,
        hwModel: String,
        lyraVersion: String,
        services: [Service],
        ipAddress: String?,
        osVersion: String?,
        region: String = "cn"
    ) -> Data {
        var data = Data()
        LyraProtoWriter.appendLengthDelimitedField(1, value: Data(deviceName.utf8), to: &data)
        LyraProtoWriter.appendVarintField(2, value: UInt64(deviceType), to: &data)
        LyraProtoWriter.appendLengthDelimitedField(3, value: Data(deviceId.utf8), to: &data)
        LyraProtoWriter.appendLengthDelimitedField(4, value: Data(uidHash.utf8), to: &data)
        LyraProtoWriter.appendVarintField(10, value: 1, to: &data)
        LyraProtoWriter.appendLengthDelimitedField(11, value: Data(hwModel.utf8), to: &data)
        LyraProtoWriter.appendLengthDelimitedField(12, value: Data(lyraVersion.utf8), to: &data)
        for service in services {
            LyraProtoWriter.appendLengthDelimitedField(14, value: serviceInfoFrame(service), to: &data)
        }
        LyraProtoWriter.appendVarintField(18, value: 0x3FFF, to: &data)
        LyraProtoWriter.appendLengthDelimitedField(19, value: Data(region.utf8), to: &data)
        LyraProtoWriter.appendLengthDelimitedField(20, value: Data(deviceName.utf8), to: &data)
        if let osVersion {
            LyraProtoWriter.appendLengthDelimitedField(34, value: Data(osVersion.utf8), to: &data)
        }
        if let ipAddress {
            LyraProtoWriter.appendLengthDelimitedField(35, value: Data(ipAddress.utf8), to: &data)
        }
        LyraProtoWriter.appendLengthDelimitedField(37, value: Data(deviceName.utf8), to: &data)
        return data
    }

    public static func syncInner(deviceInfo: Data) -> Data {
        var sync = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &sync)
        LyraProtoWriter.appendLengthDelimitedField(2, value: deviceInfo, to: &sync)
        return sync
    }

    public static func syncFrame(deviceInfo: Data) -> Data {
        let sync = syncInner(deviceInfo: deviceInfo)
        var frame = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &frame)
        LyraProtoWriter.appendLengthDelimitedField(5, value: sync, to: &frame)
        return frame
    }

    public static func plaintextAnnounce(deviceInfo: Data, netId: UInt8 = 1) -> Data {
        var payload = Data()
        payload.append(netId)
        payload.append(0)
        payload.append(0)
        payload.append(syncFrame(deviceInfo: deviceInfo))
        return payload
    }

    // Full device-info frame for the reverse sync payload exchange, mirroring
    // the officially paired Mac's networking_trusted_device entry in the
    // phone's DevRepo (fields the thin announce frame omits, including the
    // 64-hex full device id that keys the store).
    public static func syncReplyDeviceInfoFrame(
        deviceName: String,
        deviceType: UInt32,
        fullDeviceIdHex: String,
        shortDeviceIdHex: String,
        uidHash: String,
        hwModel: String,
        lyraVersion: String,
        services: [Service],
        meshPort: UInt16?,
        ipAddress: String?,
        osVersion: String?,
        accountNumericId: String,
        syncUuid: String,
        region: String = "cn"
    ) -> Data {
        var data = Data()
        LyraProtoWriter.appendLengthDelimitedField(1, value: Data(deviceName.utf8), to: &data)
        LyraProtoWriter.appendVarintField(2, value: UInt64(deviceType), to: &data)
        LyraProtoWriter.appendLengthDelimitedField(3, value: Data(fullDeviceIdHex.utf8), to: &data)
        LyraProtoWriter.appendLengthDelimitedField(4, value: Data(uidHash.utf8), to: &data)
        LyraProtoWriter.appendVarintField(7, value: 15879, to: &data)
        LyraProtoWriter.appendVarintField(8, value: 4294963213, to: &data)
        LyraProtoWriter.appendVarintField(9, value: 14619, to: &data)
        LyraProtoWriter.appendVarintField(10, value: 5, to: &data)
        LyraProtoWriter.appendLengthDelimitedField(11, value: Data(hwModel.utf8), to: &data)
        LyraProtoWriter.appendLengthDelimitedField(12, value: Data(lyraVersion.utf8), to: &data)
        for service in services {
            LyraProtoWriter.appendLengthDelimitedField(14, value: serviceInfoFrame(service), to: &data)
        }
        LyraProtoWriter.appendVarintField(16, value: 1, to: &data)
        LyraProtoWriter.appendVarintField(18, value: 0x3FFF, to: &data)
        LyraProtoWriter.appendLengthDelimitedField(19, value: Data(region.utf8), to: &data)
        LyraProtoWriter.appendLengthDelimitedField(20, value: Data("Mac".utf8), to: &data)
        LyraProtoWriter.appendLengthDelimitedField(23, value: Data(shortDeviceIdHex.utf8), to: &data)
        LyraProtoWriter.appendLengthDelimitedField(24, value: Data(hwModel.utf8), to: &data)
        if let meshPort {
            LyraProtoWriter.appendVarintField(25, value: UInt64(meshPort), to: &data)
        }
        LyraProtoWriter.appendVarintField(26, value: 1, to: &data)
        LyraProtoWriter.appendVarintField(27, value: 1, to: &data)
        LyraProtoWriter.appendVarintField(28, value: 1, to: &data)
        LyraProtoWriter.appendVarintField(29, value: 1, to: &data)
        LyraProtoWriter.appendLengthDelimitedField(
            31, value: Data("\(accountNumericId)_\(fullDeviceIdHex.lowercased())".utf8), to: &data
        )
        LyraProtoWriter.appendLengthDelimitedField(32, value: Data(syncUuid.utf8), to: &data)
        if let osVersion {
            LyraProtoWriter.appendLengthDelimitedField(34, value: Data(osVersion.utf8), to: &data)
        }
        if let ipAddress {
            LyraProtoWriter.appendLengthDelimitedField(35, value: Data(ipAddress.utf8), to: &data)
        }
        LyraProtoWriter.appendLengthDelimitedField(37, value: Data(deviceName.utf8), to: &data)
        LyraProtoWriter.appendLengthDelimitedField(39, value: Data(accountNumericId.utf8), to: &data)
        LyraProtoWriter.appendVarintField(40, value: 1, to: &data)
        return data
    }

    // The sync-task payload frame: a single 0x00 type byte followed by the
    // sync frame. The announce's 01 00 00 header is rejected by the phone's
    // FrameParse ("bad frame") on the sync path. The response variant carries
    // the trusted-type wrapper (frame f1=2, f6={f2:trustedType, f3:deviceInfo})
    // — the type-1 announce frame parses but AddOnlineDevice rejects it with
    // "trusted_type 0".
    public static func syncReplyPayload(deviceInfo: Data, trustedType: UInt64 = 1) -> Data {
        var wrapper = Data()
        LyraProtoWriter.appendVarintField(2, value: trustedType, to: &wrapper)
        LyraProtoWriter.appendLengthDelimitedField(3, value: deviceInfo, to: &wrapper)
        var frame = Data()
        LyraProtoWriter.appendVarintField(1, value: 2, to: &frame)
        LyraProtoWriter.appendLengthDelimitedField(6, value: wrapper, to: &frame)
        var payload = Data()
        payload.append(0)
        payload.append(frame)
        return payload
    }
}
