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
    public static let phoneAction = "phone.action"
    public static let phoneActionResult = "phone.action.result"
    public static let phoneRelayStart = "phone.relay.start"
    public static let phoneRelayEndpoint = "phone.relay.endpoint"
    public static let phoneCallStatus = "phone.call.status"
    public static let miLinkStatus = "milink.status"
    public static let miLinkFrame = "milink.frame"
    public static let miLinkCommand = "milink.command"
    public static let miLinkCommandResult = "milink.command.result"
    public static let androidMicStatus = "android.mic.status"
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
    public let iconPngBase64: String?
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
        iconPngBase64: String? = nil,
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
        self.iconPngBase64 = iconPngBase64
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

public struct PhoneActionBody: Codable, Equatable, Sendable {
    public let requestId: String
    public let action: String
    public let number: String?
    public let relayHost: String?
    public let relayPort: Int?
    public let relaySessionId: String?
    public let relayControlPort: Int?

    public init(
        requestId: String,
        action: String,
        number: String? = nil,
        relayHost: String? = nil,
        relayPort: Int? = nil,
        relaySessionId: String? = nil,
        relayControlPort: Int? = nil
    ) {
        self.requestId = requestId
        self.action = action
        self.number = number
        self.relayHost = relayHost
        self.relayPort = relayPort
        self.relaySessionId = relaySessionId
        self.relayControlPort = relayControlPort
    }
}

public struct PhoneActionResultBody: Codable, Equatable, Sendable {
    public let requestId: String
    public let action: String
    public let success: Bool
    public let error: String?
    public let ts: Int64

    public init(requestId: String, action: String, success: Bool, error: String? = nil, ts: Int64) {
        self.requestId = requestId
        self.action = action
        self.success = success
        self.error = error
        self.ts = ts
    }
}

public struct PhoneRelayStartRequestBody: Codable, Equatable, Sendable {
    public let requestId: String
    public let reason: String
    public let ts: Int64

    public init(requestId: String, reason: String, ts: Int64) {
        self.requestId = requestId
        self.reason = reason
        self.ts = ts
    }
}

public struct PhoneRelayEndpointBody: Codable, Equatable, Sendable {
    public let requestId: String
    public let relayHost: String?
    public let relayPort: Int?
    public let relaySessionId: String?
    public let relayControlPort: Int?
    public let success: Bool
    public let error: String?
    public let ts: Int64

    public init(
        requestId: String,
        relayHost: String? = nil,
        relayPort: Int? = nil,
        relaySessionId: String? = nil,
        relayControlPort: Int? = nil,
        success: Bool = true,
        error: String? = nil,
        ts: Int64
    ) {
        self.requestId = requestId
        self.relayHost = relayHost
        self.relayPort = relayPort
        self.relaySessionId = relaySessionId
        self.relayControlPort = relayControlPort
        self.success = success
        self.error = error
        self.ts = ts
    }
}

public struct PhoneCallStatusBody: Codable, Equatable, Sendable {
    public let callId: String
    public let state: String
    public let handle: String?
    public let displayName: String?
    public let direction: String?
    public let canAnswer: Bool
    public let canHangUp: Bool
    public let isActive: Bool
    public let reason: String
    public let ts: Int64

    public init(
        callId: String,
        state: String,
        handle: String? = nil,
        displayName: String? = nil,
        direction: String? = nil,
        canAnswer: Bool = false,
        canHangUp: Bool = false,
        isActive: Bool = false,
        reason: String,
        ts: Int64
    ) {
        self.callId = callId
        self.state = state
        self.handle = handle
        self.displayName = displayName
        self.direction = direction
        self.canAnswer = canAnswer
        self.canHangUp = canHangUp
        self.isActive = isActive
        self.reason = reason
        self.ts = ts
    }
}

public struct AndroidMicStatusBody: Codable, Equatable, Sendable {
    public let active: Bool
    public let source: Int?
    public let sourceName: String?
    public let sessionId: Int?
    public let silenced: Bool?
    public let activeRecordingCount: Int
    public let reason: String
    public let ts: Int64

    public init(
        active: Bool,
        source: Int? = nil,
        sourceName: String? = nil,
        sessionId: Int? = nil,
        silenced: Bool? = nil,
        activeRecordingCount: Int = 0,
        reason: String,
        ts: Int64
    ) {
        self.active = active
        self.source = source
        self.sourceName = sourceName
        self.sessionId = sessionId
        self.silenced = silenced
        self.activeRecordingCount = activeRecordingCount
        self.reason = reason
        self.ts = ts
    }
}

public struct MiLinkServiceCapabilityBody: Codable, Equatable, Sendable {
    public let id: String
    public let packageName: String
    public let appName: String
    public let serviceName: String
    public let category: String
    public let route: String
    public let available: Bool
    public let preferred: Bool
    public let bindAction: String?
    public let evidence: String

    public init(
        id: String,
        packageName: String,
        appName: String,
        serviceName: String,
        category: String,
        route: String,
        available: Bool,
        preferred: Bool = false,
        bindAction: String? = nil,
        evidence: String
    ) {
        self.id = id
        self.packageName = packageName
        self.appName = appName
        self.serviceName = serviceName
        self.category = category
        self.route = route
        self.available = available
        self.preferred = preferred
        self.bindAction = bindAction
        self.evidence = evidence
    }
}

public struct MiLinkStatusBody: Codable, Equatable, Sendable {
    public let sourceDeviceId: String?
    public let sourcePlatform: String
    public let route: String
    public let officialDiscoveryRequired: Bool
    public let available: Bool
    public let rootProbeOk: Bool
    public let attributionProbeOk: Bool
    public let messengerTransportOk: Bool
    public let castServiceOk: Bool
    public let phoneContinuityOk: Bool?
    public let phoneCallRelayServiceOk: Bool?
    public let phoneMediaRelayCallbackOk: Bool?
    public let phoneRemoteDeviceCount: Int?
    public let phoneMediaRelayCandidateCount: Int?
    public let services: [MiLinkServiceCapabilityBody]?
    public let preferredRoutes: [String: String]?
    public let summary: String
    public let ts: Int64

    public init(
        sourceDeviceId: String? = nil,
        sourcePlatform: String = "android",
        route: String = "edgelink.secure",
        officialDiscoveryRequired: Bool = false,
        available: Bool,
        rootProbeOk: Bool,
        attributionProbeOk: Bool,
        messengerTransportOk: Bool,
        castServiceOk: Bool,
        phoneContinuityOk: Bool? = nil,
        phoneCallRelayServiceOk: Bool? = nil,
        phoneMediaRelayCallbackOk: Bool? = nil,
        phoneRemoteDeviceCount: Int? = nil,
        phoneMediaRelayCandidateCount: Int? = nil,
        services: [MiLinkServiceCapabilityBody]? = nil,
        preferredRoutes: [String: String]? = nil,
        summary: String,
        ts: Int64
    ) {
        self.sourceDeviceId = sourceDeviceId
        self.sourcePlatform = sourcePlatform
        self.route = route
        self.officialDiscoveryRequired = officialDiscoveryRequired
        self.available = available
        self.rootProbeOk = rootProbeOk
        self.attributionProbeOk = attributionProbeOk
        self.messengerTransportOk = messengerTransportOk
        self.castServiceOk = castServiceOk
        self.phoneContinuityOk = phoneContinuityOk
        self.phoneCallRelayServiceOk = phoneCallRelayServiceOk
        self.phoneMediaRelayCallbackOk = phoneMediaRelayCallbackOk
        self.phoneRemoteDeviceCount = phoneRemoteDeviceCount
        self.phoneMediaRelayCandidateCount = phoneMediaRelayCandidateCount
        self.services = services
        self.preferredRoutes = preferredRoutes
        self.summary = summary
        self.ts = ts
    }
}

public struct MiLinkFrameBody: Codable, Equatable, Sendable {
    public let sourceDeviceId: String?
    public let sourcePlatform: String
    public let route: String
    public let clientNo: String
    public let sequence: Int
    public let dataBase64: String
    public let bytes: Int
    public let hasNext: Bool
    public let ts: Int64

    public init(
        sourceDeviceId: String? = nil,
        sourcePlatform: String = "android",
        route: String = "edgelink.secure",
        clientNo: String,
        sequence: Int,
        dataBase64: String,
        bytes: Int,
        hasNext: Bool,
        ts: Int64
    ) {
        self.sourceDeviceId = sourceDeviceId
        self.sourcePlatform = sourcePlatform
        self.route = route
        self.clientNo = clientNo
        self.sequence = sequence
        self.dataBase64 = dataBase64
        self.bytes = bytes
        self.hasNext = hasNext
        self.ts = ts
    }
}

public struct MiLinkCommandBody: Codable, Equatable, Sendable {
    public let requestId: String
    public let command: String
    public let args: [String: String]
    public let ts: Int64

    public init(
        requestId: String,
        command: String,
        args: [String: String] = [:],
        ts: Int64
    ) {
        self.requestId = requestId
        self.command = command
        self.args = args
        self.ts = ts
    }
}

public struct MiLinkCommandResultBody: Codable, Equatable, Sendable {
    public let requestId: String
    public let command: String
    public let success: Bool
    public let route: String
    public let message: String
    public let data: [String: String]
    public let ts: Int64

    public init(
        requestId: String,
        command: String,
        success: Bool,
        route: String,
        message: String,
        data: [String: String] = [:],
        ts: Int64
    ) {
        self.requestId = requestId
        self.command = command
        self.success = success
        self.route = route
        self.message = message
        self.data = data
        self.ts = ts
    }
}
