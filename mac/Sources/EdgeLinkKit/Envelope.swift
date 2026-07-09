import Foundation

public struct Envelope<Body: Codable & Sendable>: Codable, Sendable {
    public let t: String
    public let b: Body

    public init(t: String, b: Body) {
        self.t = t
        self.b = b
    }
}

public struct EmptyBody: Codable, Sendable {
    public init() {}
}

public enum EnvelopeType {
    public static let statusPing = "status.ping"
    public static let statusPong = "status.pong"
    public static let inputPointer = "input.pointer"
    public static let inputKey = "input.key"
    public static let inputText = "input.text"
    public static let screenStart = "screen.start"
    public static let screenStop = "screen.stop"
    public static let screenMeta = "screen.meta"
    public static let screenViewerVisibility = "screen.viewerVisibility"
    public static let ctrlPointer = "ctrl.pointer"
    public static let ctrlKey = "ctrl.key"
    public static let ctrlText = "ctrl.text"
    public static let ctrlGlobal = "ctrl.global"
    public static let rtcOffer = "rtc.offer"
    public static let rtcAnswer = "rtc.answer"
    public static let rtcIce = "rtc.ice"
    public static let clipboardSet = "clipboard.set"
    public static let notificationPost = "notification.post"
    public static let notificationRemove = "notification.remove"
    public static let smsMessage = "sms.message"
    public static let smsSend = "sms.send"
    public static let smsSendResult = "sms.send.result"
}

public struct InputPointerBody: Codable, Equatable, Sendable {
    public let dx: Double
    public let dy: Double
    public let scrollX: Double?
    public let scrollY: Double?
    public let btn: String?

    public init(dx: Double = 0, dy: Double = 0, scrollX: Double? = nil, scrollY: Double? = nil, btn: String? = nil) {
        self.dx = dx
        self.dy = dy
        self.scrollX = scrollX
        self.scrollY = scrollY
        self.btn = btn
    }
}

public struct InputKeyBody: Codable, Equatable, Sendable {
    public let key: String
    public let mods: [String]

    public init(key: String, mods: [String] = []) {
        self.key = key
        self.mods = mods
    }
}

public struct InputTextBody: Codable, Equatable, Sendable {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

public struct ScreenMetaBody: Codable, Equatable, Sendable {
    public let w: Int
    public let h: Int
    public let scale: Double
    public let dpi: Int

    public init(w: Int, h: Int, scale: Double, dpi: Int) {
        self.w = w
        self.h = h
        self.scale = scale
        self.dpi = dpi
    }
}

public struct ScreenViewerVisibilityBody: Codable, Equatable, Sendable {
    public let visible: Bool

    public init(visible: Bool) {
        self.visible = visible
    }
}

public struct CtrlPointerBody: Codable, Equatable, Sendable {
    public let x: Int
    public let y: Int
    public let action: String
    public let wheelDy: Int?

    public init(x: Int, y: Int, action: String, wheelDy: Int? = nil) {
        self.x = x
        self.y = y
        self.action = action
        self.wheelDy = wheelDy
    }
}

public struct CtrlKeyBody: Codable, Equatable, Sendable {
    public let key: String
    public let down: Bool
    public let mods: [String]

    public init(key: String, down: Bool, mods: [String] = []) {
        self.key = key
        self.down = down
        self.mods = mods
    }
}

public struct CtrlTextBody: Codable, Equatable, Sendable {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

public struct CtrlGlobalBody: Codable, Equatable, Sendable {
    public let action: String

    public init(action: String) {
        self.action = action
    }
}

public struct RtcSdpBody: Codable, Equatable, Sendable {
    public let sdp: String

    public init(sdp: String) {
        self.sdp = sdp
    }
}

public struct RtcIceBody: Codable, Equatable, Sendable {
    public let mid: String
    public let index: Int
    public let candidate: String

    public init(mid: String, index: Int, candidate: String) {
        self.mid = mid
        self.index = index
        self.candidate = candidate
    }
}

public struct ClipboardSetBody: Codable, Equatable, Sendable {
    public let text: String
    public let ts: Int64
    public let hash: String

    public init(text: String, ts: Int64, hash: String) {
        self.text = text
        self.ts = ts
        self.hash = hash
    }
}

public struct NotificationPostBody: Codable, Equatable, Sendable {
    public let id: String
    public let sourceDeviceId: String?
    public let sourcePlatform: String?
    public let app: String
    public let bundle: String?
    public let title: String
    public let text: String
    public let subtitle: String?
    public let ts: Int64

    public init(
        id: String,
        sourceDeviceId: String? = nil,
        sourcePlatform: String? = nil,
        app: String,
        bundle: String? = nil,
        title: String,
        text: String,
        subtitle: String? = nil,
        ts: Int64
    ) {
        self.id = id
        self.sourceDeviceId = sourceDeviceId
        self.sourcePlatform = sourcePlatform
        self.app = app
        self.bundle = bundle
        self.title = title
        self.text = text
        self.subtitle = subtitle
        self.ts = ts
    }
}

public struct NotificationRemoveBody: Codable, Equatable, Sendable {
    public let id: String
    public let sourceDeviceId: String?

    public init(id: String, sourceDeviceId: String? = nil) {
        self.id = id
        self.sourceDeviceId = sourceDeviceId
    }
}

public struct SmsMessageBody: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let sourceDeviceId: String?
    public let sourcePlatform: String?
    public let address: String
    public let text: String
    public let direction: String
    public let isBackfill: Bool
    public let ts: Int64

    public init(
        id: String,
        sourceDeviceId: String? = nil,
        sourcePlatform: String? = nil,
        address: String,
        text: String,
        direction: String,
        isBackfill: Bool = false,
        ts: Int64
    ) {
        self.id = id
        self.sourceDeviceId = sourceDeviceId
        self.sourcePlatform = sourcePlatform
        self.address = address
        self.text = text
        self.direction = direction
        self.isBackfill = isBackfill
        self.ts = ts
    }
}

public struct SmsSendBody: Codable, Equatable, Sendable {
    public let requestId: String
    public let to: String
    public let text: String

    public init(requestId: String, to: String, text: String) {
        self.requestId = requestId
        self.to = to
        self.text = text
    }
}

public struct SmsSendResultBody: Codable, Equatable, Sendable {
    public let requestId: String
    public let to: String
    public let success: Bool
    public let error: String?
    public let ts: Int64

    public init(requestId: String, to: String, success: Bool, error: String? = nil, ts: Int64) {
        self.requestId = requestId
        self.to = to
        self.success = success
        self.error = error
        self.ts = ts
    }
}
