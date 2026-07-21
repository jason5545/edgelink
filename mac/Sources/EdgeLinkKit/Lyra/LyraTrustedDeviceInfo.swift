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
        osVersion: String?
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
}
