package com.edgelink.core

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject

@Serializable
data class Envelope<T>(
    val t: String,
    val b: T
)

@Serializable
object EmptyBody

object EnvelopeTypes {
    const val STATUS_PING = "status.ping"
    const val STATUS_PONG = "status.pong"
    const val STATUS_CAPS = "status.caps"
    const val INPUT_POINTER = "input.pointer"
    const val INPUT_KEY = "input.key"
    const val INPUT_TEXT = "input.text"
    const val SCREEN_START = "screen.start"
    const val SCREEN_STOP = "screen.stop"
    const val SCREEN_META = "screen.meta"
    const val SCREEN_VIEWER_VISIBILITY = "screen.viewerVisibility"
    const val CTRL_POINTER = "ctrl.pointer"
    const val CTRL_KEY = "ctrl.key"
    const val CTRL_TEXT = "ctrl.text"
    const val CTRL_GLOBAL = "ctrl.global"
    const val RTC_OFFER = "rtc.offer"
    const val RTC_ANSWER = "rtc.answer"
    const val RTC_ICE = "rtc.ice"
    const val CLIPBOARD_SET = "clipboard.set"
    const val CLIPBOARD_HISTORY_REQUEST = "clipboard.history.request"
    const val CLIPBOARD_HISTORY_RESPONSE = "clipboard.history.response"
    const val NOTIFICATION_POST = "notification.post"
    const val NOTIFICATION_REMOVE = "notification.remove"
    const val SMS_MESSAGE = "sms.message"
    const val SMS_SEND = "sms.send"
    const val SMS_SEND_RESULT = "sms.send.result"
    const val PHONE_ACTION = "phone.action"
    const val PHONE_ACTION_RESULT = "phone.action.result"
    const val PHONE_RELAY_START = "phone.relay.start"
    const val PHONE_RELAY_ENDPOINT = "phone.relay.endpoint"
    const val PHONE_RELAY_MEDIA = "phone.relay.media"
    const val PHONE_CALL_STATUS = "phone.call.status"
    const val MILINK_STATUS = "milink.status"
    const val MILINK_FRAME = "milink.frame"
    const val MILINK_MIRROR_MEDIA = "milink.mirror.media"
    const val MILINK_COMMAND = "milink.command"
    const val MILINK_COMMAND_RESULT = "milink.command.result"
    const val ANDROID_MIC_STATUS = "android.mic.status"
    const val MAC_SLEEP = "mac.sleep"
    const val MAC_AWAKE = "mac.awake"
    const val TUNNEL_OPEN = "tunnel.open"
    const val TUNNEL_OPEN_RESULT = "tunnel.open.result"
    const val TUNNEL_DATA = "tunnel.data"
    const val TUNNEL_CLOSE = "tunnel.close"
    const val TUNNEL_ERROR = "tunnel.error"
    const val TUNNEL_FLOW = "tunnel.flow"
    const val BATTERY_STATUS = "battery.status"
}

object EnvelopeCodec {
    val json: Json = Json {
        encodeDefaults = true
        ignoreUnknownKeys = true
    }

    inline fun <reified T> encode(type: String, body: T): ByteArray =
        json.encodeToString(Envelope(type, body)).encodeToByteArray()

    inline fun <reified T> decode(bytes: ByteArray): Envelope<T> =
        json.decodeFromString(bytes.decodeToString())

    fun type(bytes: ByteArray): String =
        json.decodeFromString<Envelope<JsonObject>>(bytes.decodeToString()).t
}

@Serializable
data class InputPointerBody(
    val dx: Double = 0.0,
    val dy: Double = 0.0,
    val scrollX: Double? = null,
    val scrollY: Double? = null,
    val btn: String? = null
)

@Serializable
data class InputKeyBody(
    val key: String,
    val mods: List<String> = emptyList()
)

@Serializable
data class InputTextBody(
    val text: String
)

@Serializable
data class ScreenMetaBody(
    val w: Int,
    val h: Int,
    val scale: Double,
    val dpi: Int
)

@Serializable
data class ScreenViewerVisibilityBody(
    val visible: Boolean
)

@Serializable
data class CtrlPointerBody(
    val x: Int,
    val y: Int,
    val action: String,
    val wheelDy: Int? = null
)

@Serializable
data class CtrlKeyBody(
    val key: String,
    val down: Boolean,
    val mods: List<String> = emptyList()
)

@Serializable
data class CtrlTextBody(
    val text: String
)

@Serializable
data class CtrlGlobalBody(
    val action: String
)

@Serializable
data class RtcSdpBody(
    val sdp: String
)

@Serializable
data class RtcIceBody(
    val mid: String,
    val index: Int,
    val candidate: String
)

@Serializable
data class ClipboardSetBody(
    val text: String,
    val ts: Long,
    val hash: String,
    val kind: String? = null,
    val thumbnailBase64: String? = null,
    val sourceDeviceId: String? = null
)

enum class ClipboardKind(val intValue: Int) {
    TEXT(0),
    IMAGE(1),
    HTML(2),
    FILE(3);

    val wireName: String get() = name.lowercase()

    companion object {
        fun fromInt(value: Int): ClipboardKind? =
            entries.firstOrNull { it.intValue == value }

        fun fromWire(name: String?): ClipboardKind? =
            name?.let { needle -> entries.firstOrNull { it.wireName == needle } }
    }
}

@Serializable
data class StatusCapsBody(
    val clipboardHistory: Boolean = true,
    val clipboardThumbnail: Boolean = true
)

@Serializable
data class ClipboardHistoryRequestBody(
    val sinceTs: Long? = null,
    val limit: Int? = null
)

@Serializable
data class ClipboardHistoryItemBody(
    val id: String,
    val kind: String,
    val ts: Long,
    val hash: String,
    val text: String? = null,
    val thumbnailBase64: String? = null,
    val sourceDeviceId: String? = null
)

@Serializable
data class ClipboardHistoryResponseBody(
    val items: List<ClipboardHistoryItemBody> = emptyList()
)

@Serializable
data class NotificationPostBody(
    val id: String,
    val sourceDeviceId: String? = null,
    val sourcePlatform: String? = null,
    val app: String,
    val bundle: String? = null,
    val iconPngBase64: String? = null,
    val title: String,
    val text: String,
    val subtitle: String? = null,
    val ts: Long
)

@Serializable
data class NotificationRemoveBody(
    val id: String,
    val sourceDeviceId: String? = null
)

@Serializable
data class SmsMessageBody(
    val id: String,
    val sourceDeviceId: String? = null,
    val sourcePlatform: String? = null,
    val address: String,
    val text: String,
    val direction: String,
    val isBackfill: Boolean = false,
    val ts: Long
)

@Serializable
data class SmsSendBody(
    val requestId: String,
    val to: String,
    val text: String
)

@Serializable
data class SmsSendResultBody(
    val requestId: String,
    val to: String,
    val success: Boolean,
    val error: String? = null,
    val ts: Long
)

@Serializable
data class PhoneActionBody(
    val requestId: String,
    val action: String,
    val number: String? = null,
    val relayHost: String? = null,
    val relayPort: Int? = null,
    val relaySessionId: String? = null,
    val relayControlPort: Int? = null,
    val lanHost: String? = null,
    val lanPort: Int? = null,
    val lanProbePort: Int? = null
)

@Serializable
data class PhoneActionResultBody(
    val requestId: String,
    val action: String,
    val success: Boolean,
    val error: String? = null,
    val ts: Long
)

@Serializable
data class PhoneRelayStartRequestBody(
    val requestId: String,
    val reason: String,
    val ts: Long
)

@Serializable
data class PhoneRelayEndpointBody(
    val requestId: String,
    val relayHost: String? = null,
    val relayPort: Int? = null,
    val relaySessionId: String? = null,
    val relayControlPort: Int? = null,
    val lanHost: String? = null,
    val lanPort: Int? = null,
    val lanProbePort: Int? = null,
    val success: Boolean = true,
    val error: String? = null,
    val ts: Long
)

@Serializable
data class PhoneRelayMediaBody(
    val sessionId: String,
    val direction: String,
    val kind: String,
    val dataBase64: String? = null,
    val bytes: Int? = null,
    val sequence: Int? = null,
    val event: String? = null,
    val ts: Long
)

@Serializable
data class MiLinkMirrorMediaBody(
    val sessionId: String,
    val direction: String,
    val kind: String,
    val dataBase64: String? = null,
    val bytes: Int? = null,
    val sequence: Int? = null,
    val event: String? = null,
    val ts: Long
)

@Serializable
data class PhoneCallStatusBody(
    val callId: String,
    val state: String,
    val handle: String? = null,
    val displayName: String? = null,
    val direction: String? = null,
    val canAnswer: Boolean = false,
    val canHangUp: Boolean = false,
    val isActive: Boolean = false,
    val reason: String,
    val ts: Long
)

@Serializable
data class AndroidMicStatusBody(
    val active: Boolean,
    val source: Int? = null,
    val sourceName: String? = null,
    val sessionId: Int? = null,
    val silenced: Boolean? = null,
    val activeRecordingCount: Int = 0,
    val reason: String,
    val ts: Long
)

@Serializable
data class MiLinkServiceCapabilityBody(
    val id: String,
    val packageName: String,
    val appName: String,
    val serviceName: String,
    val category: String,
    val route: String,
    val available: Boolean,
    val preferred: Boolean = false,
    val bindAction: String? = null,
    val evidence: String
)

@Serializable
data class MiLinkStatusBody(
    val sourceDeviceId: String? = null,
    val sourcePlatform: String = "android",
    val route: String = "edgelink.secure",
    val officialDiscoveryRequired: Boolean = false,
    val available: Boolean,
    val rootProbeOk: Boolean,
    val attributionProbeOk: Boolean,
    val messengerTransportOk: Boolean,
    val castServiceOk: Boolean,
    val phoneContinuityOk: Boolean = false,
    val phoneCallRelayServiceOk: Boolean = false,
    val phoneMediaRelayCallbackOk: Boolean = false,
    val phoneRemoteDeviceCount: Int = 0,
    val phoneMediaRelayCandidateCount: Int = 0,
    val services: List<MiLinkServiceCapabilityBody> = emptyList(),
    val preferredRoutes: Map<String, String> = emptyMap(),
    val summary: String,
    val ts: Long
)

@Serializable
data class MiLinkFrameBody(
    val sourceDeviceId: String? = null,
    val sourcePlatform: String = "android",
    val route: String = "edgelink.secure",
    val clientNo: String,
    val sequence: Int,
    val dataBase64: String,
    val bytes: Int,
    val hasNext: Boolean,
    val ts: Long
)

@Serializable
data class MiLinkCommandBody(
    val requestId: String,
    val command: String,
    val args: Map<String, String> = emptyMap(),
    val ts: Long
)

@Serializable
data class MiLinkCommandResultBody(
    val requestId: String,
    val command: String,
    val success: Boolean,
    val route: String,
    val message: String,
    val data: Map<String, String> = emptyMap(),
    val ts: Long
)

@Serializable
data class BatteryStatusBody(
    val level: Int,
    val charging: Boolean,
    val plugged: String? = null,
    val temperature: Double? = null,
    val ts: Long
)
