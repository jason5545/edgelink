import Foundation

// MARK: - micont TCP Tunnel Protocol (Route a)
// Clean-room implementation based on binary evidence from captures/xiaomi-hyperconnect.
// Protobuf package: lyra.netbus.conn.tunnel
// Field numbers are best-guess sequential; probe-mode logging verifies against real device.

// MARK: - TransDataType

public enum LyraTransDataType {
    public static let physical: UInt8 = 1
    public static let logical: UInt8 = 2
    public static let auth: UInt8 = 3
    public static let payload: UInt8 = 4
    public static let payloadV2: UInt8 = 5
    public static let tunnel: UInt8 = 6
}

// MARK: - Tunnel Action Frame Types

public enum TunnelActionFrameType: UInt32, Sendable, CaseIterable {
    case connect = 1
    case accept = 2
    case reject = 3
    case pushData = 4
    case ackData = 5
    case finish = 6
    case error = 7
    case pause = 8
    case resume = 9
}

// MARK: - Tunnel Feature

public struct TunnelFeature: Equatable, Sendable {
    public var version: UInt32
    public var maxConnections: UInt32
    public var maxPayloadSize: UInt32

    public init(version: UInt32 = 1, maxConnections: UInt32 = 16, maxPayloadSize: UInt32 = 65536) {
        self.version = version
        self.maxConnections = maxConnections
        self.maxPayloadSize = maxPayloadSize
    }

    public func serialized() -> Data {
        var data = Data()
        LyraProtoWriter.appendVarintField(1, value: UInt64(version), to: &data)
        LyraProtoWriter.appendVarintField(2, value: UInt64(maxConnections), to: &data)
        LyraProtoWriter.appendVarintField(3, value: UInt64(maxPayloadSize), to: &data)
        return data
    }

    public init?(parsing data: Data) {
        guard let fields = try? LyraProtoReader.readFields(from: data) else { return nil }
        var version: UInt32 = 1
        var maxConnections: UInt32 = 16
        var maxPayloadSize: UInt32 = 65536
        for field in fields {
            switch (field.number, field.wireType) {
            case (1, 0): version = UInt32(field.varintValue ?? 1)
            case (2, 0): maxConnections = UInt32(field.varintValue ?? 16)
            case (3, 0): maxPayloadSize = UInt32(field.varintValue ?? 65536)
            default: continue
            }
        }
        self.init(version: version, maxConnections: maxConnections, maxPayloadSize: maxPayloadSize)
    }
}

// MARK: - Tunnel Action Frames

public struct TunnelActionFrameConnect: Equatable, Sendable {
    public var tunnelHandle: UInt32
    public var destinationAddress: String
    public var feature: TunnelFeature?

    public init(tunnelHandle: UInt32, destinationAddress: String, feature: TunnelFeature? = nil) {
        self.tunnelHandle = tunnelHandle
        self.destinationAddress = destinationAddress
        self.feature = feature
    }

    public func serialized() -> Data {
        var data = Data()
        LyraProtoWriter.appendVarintField(1, value: UInt64(tunnelHandle), to: &data)
        LyraProtoWriter.appendLengthDelimitedField(2, value: Data(destinationAddress.utf8), to: &data)
        if let feature {
            LyraProtoWriter.appendLengthDelimitedField(3, value: feature.serialized(), to: &data)
        }
        return data
    }

    public init?(parsing data: Data) {
        guard let fields = try? LyraProtoReader.readFields(from: data) else { return nil }
        var tunnelHandle: UInt32 = 0
        var destinationAddress = ""
        var feature: TunnelFeature?
        for field in fields {
            switch (field.number, field.wireType) {
            case (1, 0): tunnelHandle = UInt32(field.varintValue ?? 0)
            case (2, 2):
                if let value = field.lengthDelimitedValue {
                    destinationAddress = String(data: value, encoding: .utf8) ?? ""
                }
            case (3, 2):
                if let value = field.lengthDelimitedValue {
                    feature = TunnelFeature(parsing: value)
                }
            default: continue
            }
        }
        self.init(tunnelHandle: tunnelHandle, destinationAddress: destinationAddress, feature: feature)
    }
}

public struct TunnelActionFrameAccept: Equatable, Sendable {
    public var tunnelHandle: UInt32

    public init(tunnelHandle: UInt32) {
        self.tunnelHandle = tunnelHandle
    }

    public func serialized() -> Data {
        var data = Data()
        LyraProtoWriter.appendVarintField(1, value: UInt64(tunnelHandle), to: &data)
        return data
    }

    public init?(parsing data: Data) {
        guard let fields = try? LyraProtoReader.readFields(from: data) else { return nil }
        var tunnelHandle: UInt32 = 0
        for field in fields {
            if field.number == 1, field.wireType == 0 {
                tunnelHandle = UInt32(field.varintValue ?? 0)
            }
        }
        self.init(tunnelHandle: tunnelHandle)
    }
}

public struct TunnelActionFrameReject: Equatable, Sendable {
    public var tunnelHandle: UInt32
    public var reason: UInt32

    public init(tunnelHandle: UInt32, reason: UInt32 = 0) {
        self.tunnelHandle = tunnelHandle
        self.reason = reason
    }

    public func serialized() -> Data {
        var data = Data()
        LyraProtoWriter.appendVarintField(1, value: UInt64(tunnelHandle), to: &data)
        if reason != 0 {
            LyraProtoWriter.appendVarintField(2, value: UInt64(reason), to: &data)
        }
        return data
    }

    public init?(parsing data: Data) {
        guard let fields = try? LyraProtoReader.readFields(from: data) else { return nil }
        var tunnelHandle: UInt32 = 0
        var reason: UInt32 = 0
        for field in fields {
            switch (field.number, field.wireType) {
            case (1, 0): tunnelHandle = UInt32(field.varintValue ?? 0)
            case (2, 0): reason = UInt32(field.varintValue ?? 0)
            default: continue
            }
        }
        self.init(tunnelHandle: tunnelHandle, reason: reason)
    }
}

public struct TunnelActionFramePushData: Equatable, Sendable {
    public var tunnelHandle: UInt32
    public var payload: Data
    public var seq: UInt32

    public init(tunnelHandle: UInt32, payload: Data, seq: UInt32 = 0) {
        self.tunnelHandle = tunnelHandle
        self.payload = payload
        self.seq = seq
    }

    public func serialized() -> Data {
        var data = Data()
        LyraProtoWriter.appendVarintField(1, value: UInt64(tunnelHandle), to: &data)
        LyraProtoWriter.appendLengthDelimitedField(2, value: payload, to: &data)
        if seq != 0 {
            LyraProtoWriter.appendVarintField(3, value: UInt64(seq), to: &data)
        }
        return data
    }

    public init?(parsing data: Data) {
        guard let fields = try? LyraProtoReader.readFields(from: data) else { return nil }
        var tunnelHandle: UInt32 = 0
        var payload = Data()
        var seq: UInt32 = 0
        for field in fields {
            switch (field.number, field.wireType) {
            case (1, 0): tunnelHandle = UInt32(field.varintValue ?? 0)
            case (2, 2): payload = field.lengthDelimitedValue ?? Data()
            case (3, 0): seq = UInt32(field.varintValue ?? 0)
            default: continue
            }
        }
        self.init(tunnelHandle: tunnelHandle, payload: payload, seq: seq)
    }
}

public struct TunnelActionFrameAckData: Equatable, Sendable {
    public var tunnelHandle: UInt32
    public var ackedBytes: UInt32

    public init(tunnelHandle: UInt32, ackedBytes: UInt32) {
        self.tunnelHandle = tunnelHandle
        self.ackedBytes = ackedBytes
    }

    public func serialized() -> Data {
        var data = Data()
        LyraProtoWriter.appendVarintField(1, value: UInt64(tunnelHandle), to: &data)
        LyraProtoWriter.appendVarintField(2, value: UInt64(ackedBytes), to: &data)
        return data
    }

    public init?(parsing data: Data) {
        guard let fields = try? LyraProtoReader.readFields(from: data) else { return nil }
        var tunnelHandle: UInt32 = 0
        var ackedBytes: UInt32 = 0
        for field in fields {
            switch (field.number, field.wireType) {
            case (1, 0): tunnelHandle = UInt32(field.varintValue ?? 0)
            case (2, 0): ackedBytes = UInt32(field.varintValue ?? 0)
            default: continue
            }
        }
        self.init(tunnelHandle: tunnelHandle, ackedBytes: ackedBytes)
    }
}

public struct TunnelActionFrameFinish: Equatable, Sendable {
    public var tunnelHandle: UInt32

    public init(tunnelHandle: UInt32) {
        self.tunnelHandle = tunnelHandle
    }

    public func serialized() -> Data {
        var data = Data()
        LyraProtoWriter.appendVarintField(1, value: UInt64(tunnelHandle), to: &data)
        return data
    }

    public init?(parsing data: Data) {
        guard let fields = try? LyraProtoReader.readFields(from: data) else { return nil }
        var tunnelHandle: UInt32 = 0
        for field in fields {
            if field.number == 1, field.wireType == 0 {
                tunnelHandle = UInt32(field.varintValue ?? 0)
            }
        }
        self.init(tunnelHandle: tunnelHandle)
    }
}

public struct TunnelActionFrameError: Equatable, Sendable {
    public var tunnelHandle: UInt32
    public var code: UInt32
    public var message: String?

    public init(tunnelHandle: UInt32, code: UInt32, message: String? = nil) {
        self.tunnelHandle = tunnelHandle
        self.code = code
        self.message = message
    }

    public func serialized() -> Data {
        var data = Data()
        LyraProtoWriter.appendVarintField(1, value: UInt64(tunnelHandle), to: &data)
        LyraProtoWriter.appendVarintField(2, value: UInt64(code), to: &data)
        if let message {
            LyraProtoWriter.appendLengthDelimitedField(3, value: Data(message.utf8), to: &data)
        }
        return data
    }

    public init?(parsing data: Data) {
        guard let fields = try? LyraProtoReader.readFields(from: data) else { return nil }
        var tunnelHandle: UInt32 = 0
        var code: UInt32 = 0
        var message: String?
        for field in fields {
            switch (field.number, field.wireType) {
            case (1, 0): tunnelHandle = UInt32(field.varintValue ?? 0)
            case (2, 0): code = UInt32(field.varintValue ?? 0)
            case (3, 2):
                if let value = field.lengthDelimitedValue {
                    message = String(data: value, encoding: .utf8)
                }
            default: continue
            }
        }
        self.init(tunnelHandle: tunnelHandle, code: code, message: message)
    }
}

public struct TunnelActionFramePause: Equatable, Sendable {
    public var tunnelHandle: UInt32

    public init(tunnelHandle: UInt32) {
        self.tunnelHandle = tunnelHandle
    }

    public func serialized() -> Data {
        var data = Data()
        LyraProtoWriter.appendVarintField(1, value: UInt64(tunnelHandle), to: &data)
        return data
    }

    public init?(parsing data: Data) {
        guard let fields = try? LyraProtoReader.readFields(from: data) else { return nil }
        var tunnelHandle: UInt32 = 0
        for field in fields {
            if field.number == 1, field.wireType == 0 {
                tunnelHandle = UInt32(field.varintValue ?? 0)
            }
        }
        self.init(tunnelHandle: tunnelHandle)
    }
}

public struct TunnelActionFrameResume: Equatable, Sendable {
    public var tunnelHandle: UInt32

    public init(tunnelHandle: UInt32) {
        self.tunnelHandle = tunnelHandle
    }

    public func serialized() -> Data {
        var data = Data()
        LyraProtoWriter.appendVarintField(1, value: UInt64(tunnelHandle), to: &data)
        return data
    }

    public init?(parsing data: Data) {
        guard let fields = try? LyraProtoReader.readFields(from: data) else { return nil }
        var tunnelHandle: UInt32 = 0
        for field in fields {
            if field.number == 1, field.wireType == 0 {
                tunnelHandle = UInt32(field.varintValue ?? 0)
            }
        }
        self.init(tunnelHandle: tunnelHandle)
    }
}

// MARK: - TunnelActionFrame (oneof wrapper)

public enum TunnelActionFrame: Equatable, Sendable {
    case connect(TunnelActionFrameConnect)
    case accept(TunnelActionFrameAccept)
    case reject(TunnelActionFrameReject)
    case pushData(TunnelActionFramePushData)
    case ackData(TunnelActionFrameAckData)
    case finish(TunnelActionFrameFinish)
    case error(TunnelActionFrameError)
    case pause(TunnelActionFramePause)
    case resume(TunnelActionFrameResume)

    public var tunnelHandle: UInt32 {
        switch self {
        case .connect(let f): return f.tunnelHandle
        case .accept(let f): return f.tunnelHandle
        case .reject(let f): return f.tunnelHandle
        case .pushData(let f): return f.tunnelHandle
        case .ackData(let f): return f.tunnelHandle
        case .finish(let f): return f.tunnelHandle
        case .error(let f): return f.tunnelHandle
        case .pause(let f): return f.tunnelHandle
        case .resume(let f): return f.tunnelHandle
        }
    }

    public func serialized() -> Data {
        var data = Data()
        switch self {
        case .connect(let f):
            LyraProtoWriter.appendLengthDelimitedField(1, value: f.serialized(), to: &data)
        case .accept(let f):
            LyraProtoWriter.appendLengthDelimitedField(2, value: f.serialized(), to: &data)
        case .reject(let f):
            LyraProtoWriter.appendLengthDelimitedField(3, value: f.serialized(), to: &data)
        case .pushData(let f):
            LyraProtoWriter.appendLengthDelimitedField(4, value: f.serialized(), to: &data)
        case .ackData(let f):
            LyraProtoWriter.appendLengthDelimitedField(5, value: f.serialized(), to: &data)
        case .finish(let f):
            LyraProtoWriter.appendLengthDelimitedField(6, value: f.serialized(), to: &data)
        case .error(let f):
            LyraProtoWriter.appendLengthDelimitedField(7, value: f.serialized(), to: &data)
        case .pause(let f):
            LyraProtoWriter.appendLengthDelimitedField(8, value: f.serialized(), to: &data)
        case .resume(let f):
            LyraProtoWriter.appendLengthDelimitedField(9, value: f.serialized(), to: &data)
        }
        return data
    }

    public init?(parsing data: Data) {
        guard let fields = try? LyraProtoReader.readFields(from: data) else { return nil }
        for field in fields where field.wireType == 2 {
            guard let value = field.lengthDelimitedValue else { continue }
            switch field.number {
            case 1:
                if let f = TunnelActionFrameConnect(parsing: value) { self = .connect(f); return }
            case 2:
                if let f = TunnelActionFrameAccept(parsing: value) { self = .accept(f); return }
            case 3:
                if let f = TunnelActionFrameReject(parsing: value) { self = .reject(f); return }
            case 4:
                if let f = TunnelActionFramePushData(parsing: value) { self = .pushData(f); return }
            case 5:
                if let f = TunnelActionFrameAckData(parsing: value) { self = .ackData(f); return }
            case 6:
                if let f = TunnelActionFrameFinish(parsing: value) { self = .finish(f); return }
            case 7:
                if let f = TunnelActionFrameError(parsing: value) { self = .error(f); return }
            case 8:
                if let f = TunnelActionFramePause(parsing: value) { self = .pause(f); return }
            case 9:
                if let f = TunnelActionFrameResume(parsing: value) { self = .resume(f); return }
            default:
                continue
            }
        }
        return nil
    }
}

// MARK: - TunnelActionFramePack (batch)

public struct TunnelActionFramePack: Equatable, Sendable {
    public var frames: [TunnelActionFrame]

    public init(frames: [TunnelActionFrame]) {
        self.frames = frames
    }

    public func serialized() -> Data {
        var data = Data()
        for frame in frames {
            LyraProtoWriter.appendLengthDelimitedField(1, value: frame.serialized(), to: &data)
        }
        return data
    }

    public init?(parsing data: Data) {
        guard let fields = try? LyraProtoReader.readFields(from: data) else { return nil }
        var frames: [TunnelActionFrame] = []
        for field in fields where field.number == 1 && field.wireType == 2 {
            guard let value = field.lengthDelimitedValue else { continue }
            if let frame = TunnelActionFrame(parsing: value) {
                frames.append(frame)
            }
        }
        self.init(frames: frames)
    }
}

// MARK: - TcpTunnelProfile (MiConnectProto)

public struct TcpTunnelProfile: Equatable, Sendable {
    public var sourceAddress: String
    public var destinationAddress: String
    public var proxyAddress: String

    public init(sourceAddress: String = "", destinationAddress: String = "", proxyAddress: String = "") {
        self.sourceAddress = sourceAddress
        self.destinationAddress = destinationAddress
        self.proxyAddress = proxyAddress
    }

    public func serialized() -> Data {
        var data = Data()
        if !sourceAddress.isEmpty {
            LyraProtoWriter.appendLengthDelimitedField(1, value: Data(sourceAddress.utf8), to: &data)
        }
        if !destinationAddress.isEmpty {
            LyraProtoWriter.appendLengthDelimitedField(2, value: Data(destinationAddress.utf8), to: &data)
        }
        if !proxyAddress.isEmpty {
            LyraProtoWriter.appendLengthDelimitedField(3, value: Data(proxyAddress.utf8), to: &data)
        }
        return data
    }

    public init?(parsing data: Data) {
        guard let fields = try? LyraProtoReader.readFields(from: data) else { return nil }
        var sourceAddress = ""
        var destinationAddress = ""
        var proxyAddress = ""
        for field in fields {
            switch (field.number, field.wireType) {
            case (1, 2):
                if let v = field.lengthDelimitedValue { sourceAddress = String(data: v, encoding: .utf8) ?? "" }
            case (2, 2):
                if let v = field.lengthDelimitedValue { destinationAddress = String(data: v, encoding: .utf8) ?? "" }
            case (3, 2):
                if let v = field.lengthDelimitedValue { proxyAddress = String(data: v, encoding: .utf8) ?? "" }
            default: continue
            }
        }
        self.init(sourceAddress: sourceAddress, destinationAddress: destinationAddress, proxyAddress: proxyAddress)
    }
}

// MARK: - TunnelCapacity (MiConnectProto)

public struct TunnelCapacity: Equatable, Sendable {
    public var maxTunnels: UInt32
    public var supported: Bool

    public init(maxTunnels: UInt32 = 16, supported: Bool = true) {
        self.maxTunnels = maxTunnels
        self.supported = supported
    }

    public func serialized() -> Data {
        var data = Data()
        LyraProtoWriter.appendVarintField(1, value: UInt64(maxTunnels), to: &data)
        LyraProtoWriter.appendBoolField(2, value: supported, to: &data)
        return data
    }

    public init?(parsing data: Data) {
        guard let fields = try? LyraProtoReader.readFields(from: data) else { return nil }
        var maxTunnels: UInt32 = 16
        var supported = true
        for field in fields {
            switch (field.number, field.wireType) {
            case (1, 0): maxTunnels = UInt32(field.varintValue ?? 16)
            case (2, 0): supported = (field.varintValue ?? 1) != 0
            default: continue
            }
        }
        self.init(maxTunnels: maxTunnels, supported: supported)
    }
}

// MARK: - TunnelPortPairInfoFrame

public struct TunnelPortPairInfoFrame: Equatable, Sendable {
    public var localPort: UInt32
    public var remotePort: UInt32

    public init(localPort: UInt32, remotePort: UInt32) {
        self.localPort = localPort
        self.remotePort = remotePort
    }

    public func serialized() -> Data {
        var data = Data()
        LyraProtoWriter.appendVarintField(1, value: UInt64(localPort), to: &data)
        LyraProtoWriter.appendVarintField(2, value: UInt64(remotePort), to: &data)
        return data
    }

    public init?(parsing data: Data) {
        guard let fields = try? LyraProtoReader.readFields(from: data) else { return nil }
        var localPort: UInt32 = 0
        var remotePort: UInt32 = 0
        for field in fields {
            switch (field.number, field.wireType) {
            case (1, 0): localPort = UInt32(field.varintValue ?? 0)
            case (2, 0): remotePort = UInt32(field.varintValue ?? 0)
            default: continue
            }
        }
        self.init(localPort: localPort, remotePort: remotePort)
    }
}
