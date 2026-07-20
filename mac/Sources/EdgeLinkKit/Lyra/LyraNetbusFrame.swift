import Foundation

public enum LyraMeshPack {
    public static let headerLength = 4
    public static let maxFrameLength = 0x10000

    public enum PackError: Error, Equatable, Sendable {
        case frameTooLarge(Int)
        case truncated
        case invalidHeaderLength(Int)
    }

    public struct Frame: Equatable, Sendable {
        public var packType: UInt8
        public var extendedHeader: Data
        public var payload: Data

        public init(packType: UInt8, extendedHeader: Data = Data(), payload: Data) {
            self.packType = packType
            self.extendedHeader = extendedHeader
            self.payload = payload
        }
    }

    public static func encode(_ frame: Frame) throws -> Data {
        let headerLength = headerLength + frame.extendedHeader.count
        let totalLength = headerLength + frame.payload.count
        guard totalLength <= maxFrameLength else {
            throw PackError.frameTooLarge(totalLength)
        }
        guard frame.packType <= 0x1F, headerLength <= 0x0F else {
            throw PackError.invalidHeaderLength(headerLength)
        }

        var data = Data(capacity: totalLength)
        data.append(0x01 | (frame.packType << 3))
        data.append(UInt8(headerLength))
        data.append(UInt8((totalLength >> 8) & 0xFF))
        data.append(UInt8(totalLength & 0xFF))
        data.append(frame.extendedHeader)
        data.append(frame.payload)
        return data
    }

    public struct DecodeResult: Equatable, Sendable {
        public let frame: Frame
        public let consumedBytes: Int
    }

    public static func decode(_ data: Data) throws -> DecodeResult {
        let bytes = Array(data)
        guard bytes.count >= headerLength else {
            throw PackError.truncated
        }
        let packType = bytes[0] >> 3
        let headerLength = Int(bytes[1] & 0x0F)
        guard headerLength >= self.headerLength else {
            throw PackError.invalidHeaderLength(headerLength)
        }
        let totalLength = (Int(bytes[2]) << 8) | Int(bytes[3])
        guard totalLength >= headerLength, bytes.count >= totalLength else {
            throw PackError.truncated
        }
        let extendedHeader = Data(bytes[self.headerLength..<headerLength])
        let payload = Data(bytes[headerLength..<totalLength])
        return DecodeResult(
            frame: Frame(packType: packType, extendedHeader: extendedHeader, payload: payload),
            consumedBytes: totalLength
        )
    }
}

public enum LyraProtoWriter {
    public static func appendVarint(_ value: UInt64, to data: inout Data) {
        var remaining = value
        while remaining > 0x7F {
            data.append(UInt8(remaining & 0x7F) | 0x80)
            remaining >>= 7
        }
        data.append(UInt8(remaining & 0x7F))
    }

    public static func appendTag(field: Int, wireType: Int, to data: inout Data) {
        appendVarint(UInt64((field << 3) | wireType), to: &data)
    }

    public static func appendVarintField(_ field: Int, value: UInt64, to data: inout Data) {
        appendTag(field: field, wireType: 0, to: &data)
        appendVarint(value, to: &data)
    }

    public static func appendBoolField(_ field: Int, value: Bool, to data: inout Data) {
        appendVarintField(field, value: value ? 1 : 0, to: &data)
    }

    public static func appendLengthDelimitedField(_ field: Int, value: Data, to data: inout Data) {
        appendTag(field: field, wireType: 2, to: &data)
        appendVarint(UInt64(value.count), to: &data)
        data.append(value)
    }
}

public struct LyraProtoReader {
    public enum ReadError: Error, Equatable, Sendable {
        case truncated
        case malformedVarint
        case unsupportedWireType(Int)
    }

    public struct Field: Equatable, Sendable {
        public let number: Int
        public let wireType: Int
        public let varintValue: UInt64?
        public let lengthDelimitedValue: Data?
    }

    public static func readFields(from data: Data) throws -> [Field] {
        var fields: [Field] = []
        var index = data.startIndex
        while index < data.endIndex {
            let tag = try readVarint(from: data, index: &index)
            let fieldNumber = Int(tag >> 3)
            let wireType = Int(tag & 0x7)
            switch wireType {
            case 0:
                let value = try readVarint(from: data, index: &index)
                fields.append(Field(number: fieldNumber, wireType: wireType, varintValue: value, lengthDelimitedValue: nil))
            case 2:
                let length = try readVarint(from: data, index: &index)
                let end = index + Int(length)
                guard end <= data.endIndex else {
                    throw ReadError.truncated
                }
                fields.append(Field(number: fieldNumber, wireType: wireType, varintValue: nil, lengthDelimitedValue: Data(data[index..<end])))
                index = end
            default:
                throw ReadError.unsupportedWireType(wireType)
            }
        }
        return fields
    }

    public static func readVarint(from data: Data, index: inout Data.Index) throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < data.endIndex {
            let byte = data[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 {
                return result
            }
            shift += 7
            guard shift < 64 else {
                throw ReadError.malformedVarint
            }
        }
        throw ReadError.truncated
    }
}

public struct MiConnectFrame: Equatable, Sendable {
    public var version: UInt32
    public var logiConnFrames: [LogiConnFrame]
    public var physConnFrame: PhysConnFrame?

    public init(version: UInt32 = 0, logiConnFrames: [LogiConnFrame] = [], physConnFrame: PhysConnFrame? = nil) {
        self.version = version
        self.logiConnFrames = logiConnFrames
        self.physConnFrame = physConnFrame
    }

    public func serialized() -> Data {
        var v0 = Data()
        for frame in logiConnFrames {
            LyraProtoWriter.appendLengthDelimitedField(1, value: frame.serialized(), to: &v0)
        }
        if let physConnFrame {
            LyraProtoWriter.appendLengthDelimitedField(2, value: physConnFrame.serialized(), to: &v0)
        }
        var data = Data()
        LyraProtoWriter.appendVarintField(1, value: UInt64(version), to: &data)
        LyraProtoWriter.appendLengthDelimitedField(2, value: v0, to: &data)
        return data
    }

    public init?(parsing data: Data) {
        guard let fields = try? LyraProtoReader.readFields(from: data) else {
            return nil
        }
        var version: UInt32 = 0
        var logiConnFrames: [LogiConnFrame] = []
        var physConnFrame: PhysConnFrame?
        for field in fields {
            switch (field.number, field.wireType) {
            case (1, 0):
                version = UInt32(field.varintValue ?? 0)
            case (2, 2):
                guard let v0Data = field.lengthDelimitedValue,
                      let v0Fields = try? LyraProtoReader.readFields(from: v0Data)
                else { continue }
                for v0Field in v0Fields {
                    switch (v0Field.number, v0Field.wireType) {
                    case (1, 2):
                        if let payload = v0Field.lengthDelimitedValue, let frame = LogiConnFrame(parsing: payload) {
                            logiConnFrames.append(frame)
                        }
                    case (2, 2):
                        if let payload = v0Field.lengthDelimitedValue {
                            physConnFrame = PhysConnFrame(parsing: payload)
                        }
                    default:
                        continue
                    }
                }
            default:
                continue
            }
        }
        self.init(version: version, logiConnFrames: logiConnFrames, physConnFrame: physConnFrame)
    }
}

public struct LogiConnFrame: Equatable, Sendable {
    public var logiConnId: UInt32
    public var localNetId: UInt32
    public var remoteNetId: UInt32
    public var flag: Bool
    public var inner: Data

    public init(logiConnId: UInt32, localNetId: UInt32 = 0, remoteNetId: UInt32 = 0, flag: Bool = false, inner: Data = Data()) {
        self.logiConnId = logiConnId
        self.localNetId = localNetId
        self.remoteNetId = remoteNetId
        self.flag = flag
        self.inner = inner
    }

    public func serialized() -> Data {
        var data = Data()
        LyraProtoWriter.appendVarintField(1, value: UInt64(logiConnId), to: &data)
        LyraProtoWriter.appendVarintField(2, value: UInt64(localNetId), to: &data)
        LyraProtoWriter.appendVarintField(3, value: UInt64(remoteNetId), to: &data)
        if flag {
            LyraProtoWriter.appendBoolField(4, value: true, to: &data)
        }
        if !inner.isEmpty {
            LyraProtoWriter.appendLengthDelimitedField(5, value: inner, to: &data)
        }
        return data
    }

    public init?(parsing data: Data) {
        guard let fields = try? LyraProtoReader.readFields(from: data) else {
            return nil
        }
        var logiConnId: UInt32 = 0
        var localNetId: UInt32 = 0
        var remoteNetId: UInt32 = 0
        var flag = false
        var inner = Data()
        for field in fields {
            switch (field.number, field.wireType) {
            case (1, 0): logiConnId = UInt32(field.varintValue ?? 0)
            case (2, 0): localNetId = UInt32(field.varintValue ?? 0)
            case (3, 0): remoteNetId = UInt32(field.varintValue ?? 0)
            case (4, 0): flag = (field.varintValue ?? 0) != 0
            case (5, 2): inner = field.lengthDelimitedValue ?? Data()
            default: continue
            }
        }
        self.init(logiConnId: logiConnId, localNetId: localNetId, remoteNetId: remoteNetId, flag: flag, inner: inner)
    }
}

public enum PhysConnPayload: Equatable, Sendable {
    case syncDeviceInfoRequest(Data)
    case syncDeviceInfoResponse(Data)
    case updateDeviceInfo(Data)
    case updateNetworkInfo(Data)
    case keepAliveRequest(Data)
    case keepAliveResponse(Data)
    case disconnectRequest(Data)
    case disconnectResponse(Data)

    var fieldNumber: Int {
        switch self {
        case .syncDeviceInfoRequest: return 3
        case .syncDeviceInfoResponse: return 4
        case .updateDeviceInfo: return 5
        case .updateNetworkInfo: return 6
        case .keepAliveRequest: return 7
        case .keepAliveResponse: return 8
        case .disconnectRequest: return 9
        case .disconnectResponse: return 10
        }
    }

    var data: Data {
        switch self {
        case .syncDeviceInfoRequest(let data), .syncDeviceInfoResponse(let data),
             .updateDeviceInfo(let data), .updateNetworkInfo(let data),
             .keepAliveRequest(let data), .keepAliveResponse(let data),
             .disconnectRequest(let data), .disconnectResponse(let data):
            return data
        }
    }

    init?(fieldNumber: Int, data: Data) {
        switch fieldNumber {
        case 3: self = .syncDeviceInfoRequest(data)
        case 4: self = .syncDeviceInfoResponse(data)
        case 5: self = .updateDeviceInfo(data)
        case 6: self = .updateNetworkInfo(data)
        case 7: self = .keepAliveRequest(data)
        case 8: self = .keepAliveResponse(data)
        case 9: self = .disconnectRequest(data)
        case 10: self = .disconnectResponse(data)
        default: return nil
        }
    }
}

public struct PhysConnFrame: Equatable, Sendable {
    public var field1: UInt32
    public var field2: UInt32
    public var payload: PhysConnPayload?

    public init(field1: UInt32 = 0, field2: UInt32 = 0, payload: PhysConnPayload? = nil) {
        self.field1 = field1
        self.field2 = field2
        self.payload = payload
    }

    public func serialized() -> Data {
        var data = Data()
        LyraProtoWriter.appendVarintField(1, value: UInt64(field1), to: &data)
        LyraProtoWriter.appendVarintField(2, value: UInt64(field2), to: &data)
        if let payload {
            LyraProtoWriter.appendLengthDelimitedField(payload.fieldNumber, value: payload.data, to: &data)
        }
        return data
    }

    public init?(parsing data: Data) {
        guard let fields = try? LyraProtoReader.readFields(from: data) else {
            return nil
        }
        var field1: UInt32 = 0
        var field2: UInt32 = 0
        var payload: PhysConnPayload?
        for field in fields {
            switch (field.number, field.wireType) {
            case (1, 0): field1 = UInt32(field.varintValue ?? 0)
            case (2, 0): field2 = UInt32(field.varintValue ?? 0)
            case (3...10, 2):
                if let value = field.lengthDelimitedValue {
                    payload = PhysConnPayload(fieldNumber: field.number, data: value)
                }
            default: continue
            }
        }
        self.init(field1: field1, field2: field2, payload: payload)
    }
}

public enum LogiConnInnerPayload: Equatable, Sendable {
    case request(Data)
    case response(Data)
    case responseAck(Data)
    case disconnect(Data)
    case syncInfo(Data)
    case upgrade(Data)
    case authHandshake(Data)

    var fieldNumber: Int {
        switch self {
        case .request: return 2
        case .response: return 3
        case .responseAck: return 4
        case .disconnect: return 5
        case .syncInfo: return 6
        case .upgrade: return 7
        case .authHandshake: return 8
        }
    }

    var data: Data {
        switch self {
        case .request(let data), .response(let data), .responseAck(let data),
             .disconnect(let data), .syncInfo(let data), .upgrade(let data),
             .authHandshake(let data):
            return data
        }
    }

    init?(fieldNumber: Int, data: Data) {
        switch fieldNumber {
        case 2: self = .request(data)
        case 3: self = .response(data)
        case 4: self = .responseAck(data)
        case 5: self = .disconnect(data)
        case 6: self = .syncInfo(data)
        case 7: self = .upgrade(data)
        case 8: self = .authHandshake(data)
        default: return nil
        }
    }
}

public struct LogiConnInnerFrame: Equatable, Sendable {
    public var frameType: UInt32
    public var payload: LogiConnInnerPayload?

    public init(frameType: UInt32 = 0, payload: LogiConnInnerPayload? = nil) {
        self.frameType = frameType
        self.payload = payload
    }

    public func serialized() -> Data {
        var data = Data()
        LyraProtoWriter.appendVarintField(1, value: UInt64(frameType), to: &data)
        if let payload {
            LyraProtoWriter.appendLengthDelimitedField(payload.fieldNumber, value: payload.data, to: &data)
        }
        return data
    }

    public init?(parsing data: Data) {
        guard let fields = try? LyraProtoReader.readFields(from: data) else {
            return nil
        }
        var frameType: UInt32 = 0
        var payload: LogiConnInnerPayload?
        for field in fields {
            switch (field.number, field.wireType) {
            case (1, 0): frameType = UInt32(field.varintValue ?? 0)
            case (2...8, 2):
                if let value = field.lengthDelimitedValue {
                    payload = LogiConnInnerPayload(fieldNumber: field.number, data: value)
                }
            default: continue
            }
        }
        self.init(frameType: frameType, payload: payload)
    }
}

public enum LyraMeshDatagram {
    public static let magic: UInt32 = 0x12345678
    public static let headerWord: UInt32 = 0x10000051
    public static let headerLength = 24

    public enum DatagramError: Error, Equatable, Sendable {
        case truncated
        case badMagic
    }

    public static func encode(tick: UInt32, payload: Data) -> Data {
        var data = Data(capacity: headerLength + payload.count)
        data.append(contentsOf: [0x78, 0x56, 0x34, 0x12])
        data.append(contentsOf: [0x51, 0x00, 0x00, 0x10])
        data.append(contentsOf: [
            UInt8(tick & 0xFF),
            UInt8((tick >> 8) & 0xFF),
            UInt8((tick >> 16) & 0xFF),
            UInt8((tick >> 24) & 0xFF)
        ])
        data.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0])
        let length = UInt32(payload.count)
        data.append(contentsOf: [
            UInt8(length & 0xFF),
            UInt8((length >> 8) & 0xFF),
            UInt8((length >> 16) & 0xFF),
            UInt8((length >> 24) & 0xFF)
        ])
        data.append(payload)
        return data
    }

    public static func decode(_ data: Data) throws -> Data {
        let bytes = Array(data)
        guard bytes.count >= headerLength else {
            throw DatagramError.truncated
        }
        guard bytes[0] == 0x78, bytes[1] == 0x56, bytes[2] == 0x34, bytes[3] == 0x12 else {
            throw DatagramError.badMagic
        }
        let length = Int(bytes[20]) | (Int(bytes[21]) << 8) | (Int(bytes[22]) << 16) | (Int(bytes[23]) << 24)
        guard bytes.count >= headerLength + length else {
            throw DatagramError.truncated
        }
        return Data(bytes[headerLength..<(headerLength + length)])
    }
}

public struct LyraDeviceInfo: Equatable, Sendable {
    public var deviceId: String
    public var deviceType: UInt32
    public var uidHash: String
    public var displayName: String
    public var osVersion: String
    public var connMediumTypes: UInt32
    public var romVersion: String

    public init(
        deviceId: String,
        deviceType: UInt32,
        uidHash: String,
        displayName: String,
        osVersion: String,
        connMediumTypes: UInt32,
        romVersion: String
    ) {
        self.deviceId = deviceId
        self.deviceType = deviceType
        self.uidHash = uidHash
        self.displayName = displayName
        self.osVersion = osVersion
        self.connMediumTypes = connMediumTypes
        self.romVersion = romVersion
    }

    public func serialized() -> Data {
        var data = Data()
        LyraProtoWriter.appendLengthDelimitedField(2, value: Data(deviceId.utf8), to: &data)
        LyraProtoWriter.appendVarintField(3, value: UInt64(deviceType), to: &data)
        LyraProtoWriter.appendLengthDelimitedField(4, value: Data(uidHash.utf8), to: &data)
        LyraProtoWriter.appendVarintField(5, value: 1, to: &data)
        LyraProtoWriter.appendLengthDelimitedField(6, value: Data(displayName.utf8), to: &data)
        LyraProtoWriter.appendLengthDelimitedField(8, value: Data(osVersion.utf8), to: &data)
        LyraProtoWriter.appendVarintField(9, value: UInt64(connMediumTypes), to: &data)
        LyraProtoWriter.appendLengthDelimitedField(11, value: Data(romVersion.utf8), to: &data)
        var wifiCapabilities = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &wifiCapabilities)
        LyraProtoWriter.appendLengthDelimitedField(12, value: wifiCapabilities, to: &data)
        return data
    }
}

public struct PhysConnSyncDeviceInfoResponse: Equatable, Sendable {
    public var timestampMs: UInt64
    public var deviceInfo: LyraDeviceInfo
    public var field3: UInt32
    public var field5: UInt32
    public var networkInfo: Data?

    public init(timestampMs: UInt64, deviceInfo: LyraDeviceInfo, field3: UInt32 = 256, field5: UInt32 = 128, networkInfo: Data? = nil) {
        self.timestampMs = timestampMs
        self.deviceInfo = deviceInfo
        self.field3 = field3
        self.field5 = field5
        self.networkInfo = networkInfo
    }

    public func serialized() -> Data {
        var data = Data()
        LyraProtoWriter.appendVarintField(1, value: timestampMs, to: &data)
        LyraProtoWriter.appendLengthDelimitedField(2, value: deviceInfo.serialized(), to: &data)
        LyraProtoWriter.appendVarintField(3, value: UInt64(field3), to: &data)
        LyraProtoWriter.appendVarintField(5, value: UInt64(field5), to: &data)
        if let networkInfo {
            LyraProtoWriter.appendLengthDelimitedField(6, value: networkInfo, to: &data)
        }
        return data
    }
}

public struct PhysConnSyncDeviceInfoRequest: Equatable, Sendable {
    public let timestampMs: UInt64
    public let deviceId: String?
    public let deviceType: UInt32?
    public let connMediumTypes: UInt32?
    public let rawDeviceInfo: Data
    public let trailingFields: [LyraProtoReader.Field]

    public init?(parsing data: Data) {
        guard let fields = try? LyraProtoReader.readFields(from: data) else {
            return nil
        }
        var timestampMs: UInt64 = 0
        var deviceId: String?
        var deviceType: UInt32?
        var connMediumTypes: UInt32?
        var rawDeviceInfo = Data()
        var trailing: [LyraProtoReader.Field] = []
        for field in fields {
            switch (field.number, field.wireType) {
            case (1, 0):
                timestampMs = field.varintValue ?? 0
            case (2, 2):
                rawDeviceInfo = field.lengthDelimitedValue ?? Data()
                if let deviceFields = try? LyraProtoReader.readFields(from: rawDeviceInfo) {
                    for deviceField in deviceFields {
                        switch (deviceField.number, deviceField.wireType) {
                        case (2, 2):
                            deviceId = deviceField.lengthDelimitedValue.flatMap { String(data: $0, encoding: .utf8) }
                        case (3, 0):
                            deviceType = UInt32(deviceField.varintValue ?? 0)
                        case (9, 0):
                            connMediumTypes = UInt32(deviceField.varintValue ?? 0)
                        default:
                            continue
                        }
                    }
                }
            default:
                trailing.append(field)
            }
        }
        self.timestampMs = timestampMs
        self.deviceId = deviceId
        self.deviceType = deviceType
        self.connMediumTypes = connMediumTypes
        self.rawDeviceInfo = rawDeviceInfo
        self.trailingFields = trailing
    }
}
