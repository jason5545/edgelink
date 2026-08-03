import Foundation

public enum DuoScreenTrustType: UInt32, Sendable {
    case statusAction = 0
    case statusEvent = 1
    case bindAction = 2
    case bindEvent = 3
    case authAction = 4
    case authEvent = 5
    case verifyAction = 6
    case verifyEvent = 7
    case passwordAction = 8
    case passwordEvent = 9
    case misc = 10
}

public enum DuoScreenTrustFeature {
    public static let unlockDevice: UInt32 = 1
}

public enum DuoScreenTrustEventMode {
    public static let authSettingFirst: Int32 = 1
}

public enum DuoScreenTrustCode {
    public static let success: Int32 = 0
    public static let terminalAlt: Int32 = 1
    public static let userCancel: Int32 = 3
    public static let timeoutCancel: Int32 = 20
    public static let retryWithFingerprint: Int32 = 21
    public static let serviceNotReady: Int32 = 256
    // Phone-side quick auth refused because the shared-auth TA demands one
    // on-phone lock-screen password verification first (phone logcat:
    // quickAuthEventHandle "device reboot, need risk auth" → returnErrorCode
    // 11, mrmd/misauth "first boot, please auth!"). The TA can re-arm this
    // flag hours after boot even while quick auth worked earlier.
    public static let riskAuthRequired: Int32 = 11
    public static let disabledBySetting: Int32 = -2000
}

public enum DuoScreenTrustRisk: Int32, Sendable {
    case none = 0
    case healthAbnormal = 1
    case passwordLongTimeNotUsed = 2
    case deviceReboot = 3
    case deviceLocked = 4
}

public enum DuoScreenTrustVerifyReason: Int32, Sendable {
    case passwordUpdated = 1
    case recentUnused = 2
    case recentRebooted = 3
    case healthAbnormal = 4
    case longtimeUnused = 5
    case authFailedFallback = 6
}

public enum DuoScreenTrustBindStatus: Int32, Sendable {
    case bound = 0
    case notBound = 1
    case keyError = 2
    case passwordChanged = 3
    case certExpired = 4
}

public enum DuoScreenTrustEnableStatus: Int32, Sendable {
    case unknown = -2
    case disabled = -1
    case unset = 0
    case enabled = 1
}

public enum DuoScreenTrustAuthMethod {
    public static let anyByStrength: Int32 = -1
    public static let password: Int32 = 4
    public static let fingerprint: Int32 = 5
}

public enum DuoScreenKeyguardStatus {
    public static let valid: Int32 = 0
}

public struct TrustAuthMethod: Equatable, Sendable {
    public var method: UInt32 = 0
    public var strength: UInt32 = 0

    public init() {}
}

public struct TrustAuthStatus: Equatable, Sendable {
    public var features: [UInt32] = []
    public var supportVersion: UInt32 = 0
    public var compatibility: Int32 = 0
    public var enableStatus: Int32 = 0
    public var bindStatus: Int32 = 0
    public var localRisk: Int32 = 0
    public var remoteRisk: Int32 = 0
    public var methods: [TrustAuthMethod] = []
    public var supportUnbind: Int32 = 0

    public init() {}
}

public struct TrustPasswordStatus: Equatable, Sendable {
    public var features: [UInt32] = []
    public var supportVersion: UInt32 = 0
    public var compatibility: Int32 = 0
    public var method: Int32 = 0
    public var length: UInt32 = 0

    public init() {}
}

public struct TrustStatusAction: Equatable, Sendable {
    public var authFeatures: [UInt32] = []
    public var passwordFeatures: [UInt32] = []
    public var eventMode: Int32 = 0
    public var authMethods: [UInt32] = []

    public init() {}
}

public struct TrustStatusEvent: Equatable, Sendable {
    public var code: Int32 = 0
    public var localKeyguardStatus: Int32 = 0
    public var remoteKeyguardStatus: Int32 = 0
    public var auth: TrustAuthStatus?
    public var password: TrustPasswordStatus?

    public init() {}
}

public struct TrustBindAction: Equatable, Sendable {
    public var unbind: Bool = false
    public var cancel: Bool = false
    public var feature: UInt32 = 0
    public var reason: Int32 = 0
    public var unlockUi: Bool = false
    public var notCheckSetting: Bool = false

    public init() {}
}

public struct TrustBindEvent: Equatable, Sendable {
    public var unbind: Bool = false
    public var code: Int32 = 0
    public var feature: UInt32 = 0

    public init() {}
}

public struct TrustAuthAction: Equatable, Sendable {
    public var feature: UInt32 = 0
    public var cancel: Bool = false
    public var method: Int32 = 0
    public var minStrength: UInt32 = 0
    public var unlockUi: Bool = false
    public var extras: String = ""
    public var notCheckSetting: Bool = false

    public init() {}
}

public struct TrustAuthEvent: Equatable, Sendable {
    public var feature: UInt32 = 0
    public var code: Int32 = 0

    public init() {}

    public init(feature: UInt32, code: Int32) {
        self.feature = feature
        self.code = code
    }
}

public struct TrustVerifyAction: Equatable, Sendable {
    public var feature: UInt32 = 0
    public var cancel: Bool = false
    public var unlockUi: Bool = false
    public var risk: Int32 = 0
    public var notCheckSetting: Bool = false

    public init() {}
}

public struct TrustVerifyEvent: Equatable, Sendable {
    public var feature: UInt32 = 0
    public var code: Int32 = 0

    public init() {}

    public init(feature: UInt32, code: Int32) {
        self.feature = feature
        self.code = code
    }
}

public struct TrustPasswordAction: Equatable, Sendable {
    public var feature: UInt32 = 0
    public var cancel: Bool = false
    public var unlockUi: Bool = false

    public init() {}
}

public struct TrustPasswordEvent: Equatable, Sendable {
    public var feature: UInt32 = 0
    public var code: Int32 = 0

    public init() {}

    public init(feature: UInt32, code: Int32) {
        self.feature = feature
        self.code = code
    }
}

public struct TrustMisc: Equatable, Sendable {
    public var type: UInt32 = 0

    public init() {}
}

public enum DuoScreenTrustMessage: Equatable, Sendable {
    case statusAction(TrustStatusAction)
    case statusEvent(TrustStatusEvent)
    case bindAction(TrustBindAction)
    case bindEvent(TrustBindEvent)
    case authAction(TrustAuthAction)
    case authEvent(TrustAuthEvent)
    case verifyAction(TrustVerifyAction)
    case verifyEvent(TrustVerifyEvent)
    case passwordAction(TrustPasswordAction)
    case passwordEvent(TrustPasswordEvent)
    case misc(TrustMisc)
}

public struct DuoScreenTrust: Equatable, Sendable {
    public var type: UInt32 = 0
    public var sessionID: UInt64 = 0
    public var msg: DuoScreenTrustMessage?

    public init() {}

    public init(sessionID: UInt64, msg: DuoScreenTrustMessage) {
        self.sessionID = sessionID
        self.msg = msg
        switch msg {
        case .statusAction: type = DuoScreenTrustType.statusAction.rawValue
        case .statusEvent: type = DuoScreenTrustType.statusEvent.rawValue
        case .bindAction: type = DuoScreenTrustType.bindAction.rawValue
        case .bindEvent: type = DuoScreenTrustType.bindEvent.rawValue
        case .authAction: type = DuoScreenTrustType.authAction.rawValue
        case .authEvent: type = DuoScreenTrustType.authEvent.rawValue
        case .verifyAction: type = DuoScreenTrustType.verifyAction.rawValue
        case .verifyEvent: type = DuoScreenTrustType.verifyEvent.rawValue
        case .passwordAction: type = DuoScreenTrustType.passwordAction.rawValue
        case .passwordEvent: type = DuoScreenTrustType.passwordEvent.rawValue
        case .misc: type = DuoScreenTrustType.misc.rawValue
        }
    }
}

public enum DuoScreenTrustProto {
    public enum ProtoError: Error, Equatable, Sendable {
        case truncated
        case malformed
    }

    public static func encode(_ trust: DuoScreenTrust) -> Data {
        var data = Data()
        if trust.type != 0 {
            LyraProtoWriter.appendVarintField(1, value: UInt64(trust.type), to: &data)
        }
        if trust.sessionID != 0 {
            LyraProtoWriter.appendVarintField(2, value: trust.sessionID, to: &data)
        }
        if let msg = trust.msg {
            let (field, body): (Int, Data) = {
                switch msg {
                case .statusAction(let m): return (3, encodeStatusAction(m))
                case .statusEvent(let m): return (4, encodeStatusEvent(m))
                case .bindAction(let m): return (5, encodeBindAction(m))
                case .bindEvent(let m): return (6, encodeBindEvent(m))
                case .authAction(let m): return (7, encodeAuthAction(m))
                case .authEvent(let m): return (8, encodeAuthEvent(m))
                case .verifyAction(let m): return (9, encodeVerifyAction(m))
                case .verifyEvent(let m): return (10, encodeVerifyEvent(m))
                case .passwordAction(let m): return (11, encodePasswordAction(m))
                case .passwordEvent(let m): return (12, encodePasswordEvent(m))
                case .misc(let m): return (13, encodeMisc(m))
                }
            }()
            LyraProtoWriter.appendLengthDelimitedField(field, value: body, to: &data)
        }
        return data
    }

    public static func decode(_ data: Data) throws -> DuoScreenTrust {
        var trust = DuoScreenTrust()
        for field in try LyraProtoReader.readFields(from: data) {
            switch field.number {
            case 1:
                trust.type = UInt32(field.varintValue ?? 0)
            case 2:
                trust.sessionID = field.varintValue ?? 0
            case 3:
                trust.msg = .statusAction(try decodeStatusAction(try payload(field)))
            case 4:
                trust.msg = .statusEvent(try decodeStatusEvent(try payload(field)))
            case 5:
                trust.msg = .bindAction(try decodeBindAction(try payload(field)))
            case 6:
                trust.msg = .bindEvent(try decodeBindEvent(try payload(field)))
            case 7:
                trust.msg = .authAction(try decodeAuthAction(try payload(field)))
            case 8:
                trust.msg = .authEvent(try decodeAuthEvent(try payload(field)))
            case 9:
                trust.msg = .verifyAction(try decodeVerifyAction(try payload(field)))
            case 10:
                trust.msg = .verifyEvent(try decodeVerifyEvent(try payload(field)))
            case 11:
                trust.msg = .passwordAction(try decodePasswordAction(try payload(field)))
            case 12:
                trust.msg = .passwordEvent(try decodePasswordEvent(try payload(field)))
            case 13:
                trust.msg = .misc(try decodeMisc(try payload(field)))
            default:
                continue
            }
        }
        return trust
    }

    private static func payload(_ field: LyraProtoReader.Field) throws -> Data {
        guard let value = field.lengthDelimitedValue else {
            throw ProtoError.malformed
        }
        return value
    }

    private static func appendInt32Field(_ field: Int, value: Int32, to data: inout Data) {
        guard value != 0 else { return }
        LyraProtoWriter.appendVarintField(field, value: UInt64(bitPattern: Int64(value)), to: &data)
    }

    private static func appendUInt32Field(_ field: Int, value: UInt32, to data: inout Data) {
        guard value != 0 else { return }
        LyraProtoWriter.appendVarintField(field, value: UInt64(value), to: &data)
    }

    private static func appendBoolField(_ field: Int, value: Bool, to data: inout Data) {
        guard value else { return }
        LyraProtoWriter.appendBoolField(field, value: value, to: &data)
    }

    private static func appendPackedUInt32Field(_ field: Int, values: [UInt32], to data: inout Data) {
        guard !values.isEmpty else { return }
        var packed = Data()
        for value in values {
            LyraProtoWriter.appendVarint(UInt64(value), to: &packed)
        }
        LyraProtoWriter.appendLengthDelimitedField(field, value: packed, to: &data)
    }

    private static func int32Value(_ field: LyraProtoReader.Field) -> Int32 {
        Int32(truncatingIfNeeded: field.varintValue ?? 0)
    }

    private static func packedUInt32Values(_ field: LyraProtoReader.Field) -> [UInt32] {
        if let packed = field.lengthDelimitedValue {
            var values: [UInt32] = []
            var index = packed.startIndex
            while index < packed.endIndex {
                guard let value = try? LyraProtoReader.readVarint(from: packed, index: &index) else {
                    break
                }
                values.append(UInt32(truncatingIfNeeded: value))
            }
            return values
        }
        if let value = field.varintValue {
            return [UInt32(truncatingIfNeeded: value)]
        }
        return []
    }

    public static func encodeStatusAction(_ m: TrustStatusAction) -> Data {
        var data = Data()
        appendPackedUInt32Field(1, values: m.authFeatures, to: &data)
        appendPackedUInt32Field(2, values: m.passwordFeatures, to: &data)
        appendInt32Field(3, value: m.eventMode, to: &data)
        appendPackedUInt32Field(4, values: m.authMethods, to: &data)
        return data
    }

    public static func decodeStatusAction(_ data: Data) throws -> TrustStatusAction {
        var m = TrustStatusAction()
        for field in try LyraProtoReader.readFields(from: data) {
            switch field.number {
            case 1: m.authFeatures.append(contentsOf: packedUInt32Values(field))
            case 2: m.passwordFeatures.append(contentsOf: packedUInt32Values(field))
            case 3: m.eventMode = int32Value(field)
            case 4: m.authMethods.append(contentsOf: packedUInt32Values(field))
            default: continue
            }
        }
        return m
    }

    public static func encodeStatusEvent(_ m: TrustStatusEvent) -> Data {
        var data = Data()
        appendInt32Field(1, value: m.code, to: &data)
        appendInt32Field(2, value: m.localKeyguardStatus, to: &data)
        appendInt32Field(3, value: m.remoteKeyguardStatus, to: &data)
        if let auth = m.auth {
            LyraProtoWriter.appendLengthDelimitedField(4, value: encodeAuthStatus(auth), to: &data)
        }
        if let password = m.password {
            LyraProtoWriter.appendLengthDelimitedField(5, value: encodePasswordStatus(password), to: &data)
        }
        return data
    }

    public static func decodeStatusEvent(_ data: Data) throws -> TrustStatusEvent {
        var m = TrustStatusEvent()
        for field in try LyraProtoReader.readFields(from: data) {
            switch field.number {
            case 1: m.code = int32Value(field)
            case 2: m.localKeyguardStatus = int32Value(field)
            case 3: m.remoteKeyguardStatus = int32Value(field)
            case 4: m.auth = try decodeAuthStatus(try payload(field))
            case 5: m.password = try decodePasswordStatus(try payload(field))
            default: continue
            }
        }
        return m
    }

    public static func encodeAuthStatus(_ m: TrustAuthStatus) -> Data {
        var data = Data()
        appendPackedUInt32Field(1, values: m.features, to: &data)
        appendUInt32Field(2, value: m.supportVersion, to: &data)
        appendInt32Field(3, value: m.compatibility, to: &data)
        appendInt32Field(4, value: m.enableStatus, to: &data)
        appendInt32Field(5, value: m.bindStatus, to: &data)
        appendInt32Field(6, value: m.localRisk, to: &data)
        appendInt32Field(7, value: m.remoteRisk, to: &data)
        for method in m.methods {
            LyraProtoWriter.appendLengthDelimitedField(8, value: encodeAuthMethod(method), to: &data)
        }
        appendInt32Field(9, value: m.supportUnbind, to: &data)
        return data
    }

    public static func decodeAuthStatus(_ data: Data) throws -> TrustAuthStatus {
        var m = TrustAuthStatus()
        for field in try LyraProtoReader.readFields(from: data) {
            switch field.number {
            case 1: m.features.append(contentsOf: packedUInt32Values(field))
            case 2: m.supportVersion = UInt32(field.varintValue ?? 0)
            case 3: m.compatibility = int32Value(field)
            case 4: m.enableStatus = int32Value(field)
            case 5: m.bindStatus = int32Value(field)
            case 6: m.localRisk = int32Value(field)
            case 7: m.remoteRisk = int32Value(field)
            case 8: m.methods.append(try decodeAuthMethod(try payload(field)))
            case 9: m.supportUnbind = int32Value(field)
            default: continue
            }
        }
        return m
    }

    public static func encodeAuthMethod(_ m: TrustAuthMethod) -> Data {
        var data = Data()
        appendUInt32Field(1, value: m.method, to: &data)
        appendUInt32Field(2, value: m.strength, to: &data)
        return data
    }

    public static func decodeAuthMethod(_ data: Data) throws -> TrustAuthMethod {
        var m = TrustAuthMethod()
        for field in try LyraProtoReader.readFields(from: data) {
            switch field.number {
            case 1: m.method = UInt32(field.varintValue ?? 0)
            case 2: m.strength = UInt32(field.varintValue ?? 0)
            default: continue
            }
        }
        return m
    }

    public static func encodePasswordStatus(_ m: TrustPasswordStatus) -> Data {
        var data = Data()
        appendPackedUInt32Field(1, values: m.features, to: &data)
        appendUInt32Field(2, value: m.supportVersion, to: &data)
        appendInt32Field(3, value: m.compatibility, to: &data)
        appendInt32Field(4, value: m.method, to: &data)
        appendUInt32Field(5, value: m.length, to: &data)
        return data
    }

    public static func decodePasswordStatus(_ data: Data) throws -> TrustPasswordStatus {
        var m = TrustPasswordStatus()
        for field in try LyraProtoReader.readFields(from: data) {
            switch field.number {
            case 1: m.features.append(contentsOf: packedUInt32Values(field))
            case 2: m.supportVersion = UInt32(field.varintValue ?? 0)
            case 3: m.compatibility = int32Value(field)
            case 4: m.method = int32Value(field)
            case 5: m.length = UInt32(field.varintValue ?? 0)
            default: continue
            }
        }
        return m
    }

    public static func encodeBindAction(_ m: TrustBindAction) -> Data {
        var data = Data()
        appendBoolField(1, value: m.unbind, to: &data)
        appendBoolField(2, value: m.cancel, to: &data)
        appendUInt32Field(3, value: m.feature, to: &data)
        appendInt32Field(4, value: m.reason, to: &data)
        appendBoolField(5, value: m.unlockUi, to: &data)
        appendBoolField(6, value: m.notCheckSetting, to: &data)
        return data
    }

    public static func decodeBindAction(_ data: Data) throws -> TrustBindAction {
        var m = TrustBindAction()
        for field in try LyraProtoReader.readFields(from: data) {
            switch field.number {
            case 1: m.unbind = (field.varintValue ?? 0) != 0
            case 2: m.cancel = (field.varintValue ?? 0) != 0
            case 3: m.feature = UInt32(field.varintValue ?? 0)
            case 4: m.reason = int32Value(field)
            case 5: m.unlockUi = (field.varintValue ?? 0) != 0
            case 6: m.notCheckSetting = (field.varintValue ?? 0) != 0
            default: continue
            }
        }
        return m
    }

    public static func encodeBindEvent(_ m: TrustBindEvent) -> Data {
        var data = Data()
        appendBoolField(1, value: m.unbind, to: &data)
        appendInt32Field(2, value: m.code, to: &data)
        appendUInt32Field(3, value: m.feature, to: &data)
        return data
    }

    public static func decodeBindEvent(_ data: Data) throws -> TrustBindEvent {
        var m = TrustBindEvent()
        for field in try LyraProtoReader.readFields(from: data) {
            switch field.number {
            case 1: m.unbind = (field.varintValue ?? 0) != 0
            case 2: m.code = int32Value(field)
            case 3: m.feature = UInt32(field.varintValue ?? 0)
            default: continue
            }
        }
        return m
    }

    public static func encodeAuthAction(_ m: TrustAuthAction) -> Data {
        var data = Data()
        appendUInt32Field(1, value: m.feature, to: &data)
        appendBoolField(2, value: m.cancel, to: &data)
        appendInt32Field(3, value: m.method, to: &data)
        appendUInt32Field(4, value: m.minStrength, to: &data)
        appendBoolField(5, value: m.unlockUi, to: &data)
        if !m.extras.isEmpty {
            LyraProtoWriter.appendLengthDelimitedField(6, value: Data(m.extras.utf8), to: &data)
        }
        appendBoolField(7, value: m.notCheckSetting, to: &data)
        return data
    }

    public static func decodeAuthAction(_ data: Data) throws -> TrustAuthAction {
        var m = TrustAuthAction()
        for field in try LyraProtoReader.readFields(from: data) {
            switch field.number {
            case 1: m.feature = UInt32(field.varintValue ?? 0)
            case 2: m.cancel = (field.varintValue ?? 0) != 0
            case 3: m.method = int32Value(field)
            case 4: m.minStrength = UInt32(field.varintValue ?? 0)
            case 5: m.unlockUi = (field.varintValue ?? 0) != 0
            case 6:
                if let raw = field.lengthDelimitedValue {
                    m.extras = String(decoding: raw, as: UTF8.self)
                }
            case 7: m.notCheckSetting = (field.varintValue ?? 0) != 0
            default: continue
            }
        }
        return m
    }

    public static func encodeAuthEvent(_ m: TrustAuthEvent) -> Data {
        var data = Data()
        appendUInt32Field(1, value: m.feature, to: &data)
        appendInt32Field(2, value: m.code, to: &data)
        return data
    }

    public static func decodeAuthEvent(_ data: Data) throws -> TrustAuthEvent {
        var m = TrustAuthEvent()
        for field in try LyraProtoReader.readFields(from: data) {
            switch field.number {
            case 1: m.feature = UInt32(field.varintValue ?? 0)
            case 2: m.code = int32Value(field)
            default: continue
            }
        }
        return m
    }

    public static func encodeVerifyAction(_ m: TrustVerifyAction) -> Data {
        var data = Data()
        appendUInt32Field(1, value: m.feature, to: &data)
        appendBoolField(2, value: m.cancel, to: &data)
        appendBoolField(3, value: m.unlockUi, to: &data)
        appendInt32Field(4, value: m.risk, to: &data)
        appendBoolField(5, value: m.notCheckSetting, to: &data)
        return data
    }

    public static func decodeVerifyAction(_ data: Data) throws -> TrustVerifyAction {
        var m = TrustVerifyAction()
        for field in try LyraProtoReader.readFields(from: data) {
            switch field.number {
            case 1: m.feature = UInt32(field.varintValue ?? 0)
            case 2: m.cancel = (field.varintValue ?? 0) != 0
            case 3: m.unlockUi = (field.varintValue ?? 0) != 0
            case 4: m.risk = int32Value(field)
            case 5: m.notCheckSetting = (field.varintValue ?? 0) != 0
            default: continue
            }
        }
        return m
    }

    public static func encodeVerifyEvent(_ m: TrustVerifyEvent) -> Data {
        encodeAuthEvent(TrustAuthEvent(feature: m.feature, code: m.code))
    }

    public static func decodeVerifyEvent(_ data: Data) throws -> TrustVerifyEvent {
        let event = try decodeAuthEvent(data)
        return TrustVerifyEvent(feature: event.feature, code: event.code)
    }

    public static func encodePasswordAction(_ m: TrustPasswordAction) -> Data {
        var data = Data()
        appendUInt32Field(1, value: m.feature, to: &data)
        appendBoolField(2, value: m.cancel, to: &data)
        appendBoolField(3, value: m.unlockUi, to: &data)
        return data
    }

    public static func decodePasswordAction(_ data: Data) throws -> TrustPasswordAction {
        var m = TrustPasswordAction()
        for field in try LyraProtoReader.readFields(from: data) {
            switch field.number {
            case 1: m.feature = UInt32(field.varintValue ?? 0)
            case 2: m.cancel = (field.varintValue ?? 0) != 0
            case 3: m.unlockUi = (field.varintValue ?? 0) != 0
            default: continue
            }
        }
        return m
    }

    public static func encodePasswordEvent(_ m: TrustPasswordEvent) -> Data {
        encodeAuthEvent(TrustAuthEvent(feature: m.feature, code: m.code))
    }

    public static func decodePasswordEvent(_ data: Data) throws -> TrustPasswordEvent {
        let event = try decodeAuthEvent(data)
        return TrustPasswordEvent(feature: event.feature, code: event.code)
    }

    public static func encodeMisc(_ m: TrustMisc) -> Data {
        var data = Data()
        appendUInt32Field(1, value: m.type, to: &data)
        return data
    }

    public static func decodeMisc(_ data: Data) throws -> TrustMisc {
        var m = TrustMisc()
        for field in try LyraProtoReader.readFields(from: data) {
            if field.number == 1 {
                m.type = UInt32(field.varintValue ?? 0)
            }
        }
        return m
    }
}

public enum DuoScreenProtocolV1 {
    public static let typeTrust: UInt8 = 68

    public enum FrameError: Error, Equatable, Sendable {
        case truncated
        case lengthMismatch
    }

    public static func encodeFrame(type: UInt8, payload: Data) -> Data {
        var frame = Data(capacity: payload.count + 5)
        frame.append(type)
        let length = UInt32(payload.count)
        frame.append(UInt8(length & 0xFF))
        frame.append(UInt8((length >> 8) & 0xFF))
        frame.append(UInt8((length >> 16) & 0xFF))
        frame.append(UInt8((length >> 24) & 0xFF))
        frame.append(payload)
        return frame
    }

    public static func decodeFrame(_ data: Data) throws -> (type: UInt8, payload: Data) {
        guard data.count >= 5 else {
            throw FrameError.truncated
        }
        let type = data[data.startIndex]
        let i = data.startIndex
        let length = Int(data[i + 1]) | (Int(data[i + 2]) << 8) | (Int(data[i + 3]) << 16) | (Int(data[i + 4]) << 24)
        guard data.count - 5 >= length else {
            throw FrameError.truncated
        }
        guard data.count - 5 == length else {
            throw FrameError.lengthMismatch
        }
        return (type, Data(data[(i + 5)...]))
    }
}
