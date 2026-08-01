import Foundation

public enum LyraCastMessageType {
    public static let screenConfigurationChanged: UInt8 = 5
    public static let screenAction: UInt8 = 12
    public static let simpleEvent: UInt8 = 18
    public static let capabilities: UInt8 = 64
    public static let trust: UInt8 = 68
}

public enum LyraCastMessageCodec {
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

public struct LyraCastScreenAction: Equatable, Sendable {
    public enum Action: UInt32, Sendable {
        case closeScreen = 0
        case switchTaskToNewScreen = 1
        case resize = 2
        case openOutboundApp = 3
        case openMirrorScreen = 4
        case destroyScreen = 5
        case syncScreenInfo = 6
        case syncScreenshot = 7
        case syncSubscreenApps = 8
        case lockSubscreen = 9
        case unlockSubscreen = 10
        case updateMainMode = 11
        case prepareResult = 12
        case switchSubscreenBack = 13
        case setTheme = 14
    }

    public var sessionId: UInt64 = 0
    public var screenId: UInt32 = 0
    public var action: UInt32 = 0
    public var width: UInt32 = 0
    public var height: UInt32 = 0
    public var appId: String = ""
    public var openMirrorScreenFrom: UInt32 = 0
    public var density: UInt32 = 0
    public var statusBarHeight: UInt32 = 0
    public var navBarHeight: UInt32 = 0
    public var backgroundMode: Bool = false
    public var prepareResult: UInt32 = 0
    public var supportFlipType: UInt32 = 0
    public var isSupportDisplayAdjust: Bool = false
    public var theme: UInt32 = 0
    public var closeScreenReason: UInt32 = 0
    public var preferShowImeInSubscreen: Bool = false

    public init() {}

    public static func openMirrorScreen(sessionId: UInt64, screenId: UInt32 = 0) -> LyraCastScreenAction {
        var message = LyraCastScreenAction()
        message.sessionId = sessionId
        message.screenId = screenId
        message.action = Action.openMirrorScreen.rawValue
        return message
    }

    public static func closeScreen(sessionId: UInt64 = 0, screenId: UInt32 = 0) -> LyraCastScreenAction {
        var message = LyraCastScreenAction()
        message.sessionId = sessionId
        message.screenId = screenId
        message.action = Action.closeScreen.rawValue
        return message
    }

    public func encode() -> Data {
        var data = Data()
        if sessionId != 0 { LyraProtoWriter.appendVarintField(1, value: sessionId, to: &data) }
        if screenId != 0 { LyraProtoWriter.appendVarintField(2, value: UInt64(screenId), to: &data) }
        if action != 0 { LyraProtoWriter.appendVarintField(3, value: UInt64(action), to: &data) }
        if width != 0 { LyraProtoWriter.appendVarintField(4, value: UInt64(width), to: &data) }
        if height != 0 { LyraProtoWriter.appendVarintField(5, value: UInt64(height), to: &data) }
        if !appId.isEmpty { LyraProtoWriter.appendLengthDelimitedField(6, value: Data(appId.utf8), to: &data) }
        if openMirrorScreenFrom != 0 { LyraProtoWriter.appendVarintField(7, value: UInt64(openMirrorScreenFrom), to: &data) }
        if density != 0 { LyraProtoWriter.appendVarintField(8, value: UInt64(density), to: &data) }
        if statusBarHeight != 0 { LyraProtoWriter.appendVarintField(9, value: UInt64(statusBarHeight), to: &data) }
        if navBarHeight != 0 { LyraProtoWriter.appendVarintField(10, value: UInt64(navBarHeight), to: &data) }
        if backgroundMode { LyraProtoWriter.appendBoolField(11, value: true, to: &data) }
        if prepareResult != 0 { LyraProtoWriter.appendVarintField(12, value: UInt64(prepareResult), to: &data) }
        if supportFlipType != 0 { LyraProtoWriter.appendVarintField(14, value: UInt64(supportFlipType), to: &data) }
        if isSupportDisplayAdjust { LyraProtoWriter.appendBoolField(15, value: true, to: &data) }
        if theme != 0 { LyraProtoWriter.appendVarintField(16, value: UInt64(theme), to: &data) }
        if closeScreenReason != 0 { LyraProtoWriter.appendVarintField(17, value: UInt64(closeScreenReason), to: &data) }
        if preferShowImeInSubscreen { LyraProtoWriter.appendBoolField(18, value: true, to: &data) }
        return data
    }

    public static func decode(_ data: Data) throws -> LyraCastScreenAction {
        var message = LyraCastScreenAction()
        for field in try LyraProtoReader.readFields(from: data) {
            switch field.number {
            case 1: message.sessionId = field.varintValue ?? 0
            case 2: message.screenId = UInt32(field.varintValue ?? 0)
            case 3: message.action = UInt32(field.varintValue ?? 0)
            case 4: message.width = UInt32(field.varintValue ?? 0)
            case 5: message.height = UInt32(field.varintValue ?? 0)
            case 6: message.appId = field.lengthDelimitedValue.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            case 7: message.openMirrorScreenFrom = UInt32(field.varintValue ?? 0)
            case 8: message.density = UInt32(field.varintValue ?? 0)
            case 9: message.statusBarHeight = UInt32(field.varintValue ?? 0)
            case 10: message.navBarHeight = UInt32(field.varintValue ?? 0)
            case 11: message.backgroundMode = (field.varintValue ?? 0) != 0
            case 12: message.prepareResult = UInt32(field.varintValue ?? 0)
            case 14: message.supportFlipType = UInt32(field.varintValue ?? 0)
            case 15: message.isSupportDisplayAdjust = (field.varintValue ?? 0) != 0
            case 16: message.theme = UInt32(field.varintValue ?? 0)
            case 17: message.closeScreenReason = UInt32(field.varintValue ?? 0)
            case 18: message.preferShowImeInSubscreen = (field.varintValue ?? 0) != 0
            default: break
            }
        }
        return message
    }
}

public struct LyraCastSimpleEvent: Equatable, Sendable {
    public static let eventMirrorCallKey: UInt32 = 23
    public static let eventMirrorCallStop: UInt32 = 25
    public static let eventDeviceInfo: UInt32 = 38

    public var sessionId: UInt64?
    public var event: UInt32 = 0
    public var stringValue: String?
    public var uint32Value: UInt32?
    public var uint64Value: UInt64?
    public var boolValue: Bool?

    public init() {}

    public func encode() -> Data {
        var data = Data()
        if let sessionId { LyraProtoWriter.appendVarintField(1, value: sessionId, to: &data) }
        if event != 0 { LyraProtoWriter.appendVarintField(2, value: UInt64(event), to: &data) }
        if let stringValue { LyraProtoWriter.appendLengthDelimitedField(3, value: Data(stringValue.utf8), to: &data) }
        if let uint32Value { LyraProtoWriter.appendVarintField(4, value: UInt64(uint32Value), to: &data) }
        if let uint64Value { LyraProtoWriter.appendVarintField(5, value: uint64Value, to: &data) }
        if let boolValue { LyraProtoWriter.appendBoolField(6, value: boolValue, to: &data) }
        return data
    }

    public static func decode(_ data: Data) throws -> LyraCastSimpleEvent {
        var message = LyraCastSimpleEvent()
        for field in try LyraProtoReader.readFields(from: data) {
            switch field.number {
            case 1: message.sessionId = field.varintValue
            case 2: message.event = UInt32(field.varintValue ?? 0)
            case 3: message.stringValue = field.lengthDelimitedValue.flatMap { String(data: $0, encoding: .utf8) }
            case 4: message.uint32Value = field.varintValue.map { UInt32($0) }
            case 5: message.uint64Value = field.varintValue
            case 6: message.boolValue = field.varintValue.map { $0 != 0 }
            default: break
            }
        }
        return message
    }
}

public struct LyraCastCapabilities: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var key: String
        public var value: String

        public init(key: String, value: String) {
            self.key = key
            self.value = value
        }
    }

    public var entries: [Entry] = []
    public var isHandshake: Bool = false

    public init() {}

    public func encode() -> Data {
        var data = Data()
        for entry in entries {
            var node = Data()
            LyraProtoWriter.appendLengthDelimitedField(1, value: Data(entry.key.utf8), to: &node)
            LyraProtoWriter.appendLengthDelimitedField(2, value: Data(entry.value.utf8), to: &node)
            LyraProtoWriter.appendLengthDelimitedField(1, value: node, to: &data)
        }
        if isHandshake { LyraProtoWriter.appendBoolField(2, value: true, to: &data) }
        return data
    }

    public static func decode(_ data: Data) throws -> LyraCastCapabilities {
        var message = LyraCastCapabilities()
        for field in try LyraProtoReader.readFields(from: data) {
            switch field.number {
            case 1:
                guard let node = field.lengthDelimitedValue else { break }
                var entry = Entry(key: "", value: "")
                for sub in try LyraProtoReader.readFields(from: node) {
                    if sub.number == 1 {
                        entry.key = sub.lengthDelimitedValue.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    } else if sub.number == 2 {
                        entry.value = sub.lengthDelimitedValue.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    }
                }
                message.entries.append(entry)
            case 2:
                message.isHandshake = (field.varintValue ?? 0) != 0
            default: break
            }
        }
        return message
    }
}
