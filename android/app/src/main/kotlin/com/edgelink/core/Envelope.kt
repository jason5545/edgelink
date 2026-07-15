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
    const val NOTIFICATION_POST = "notification.post"
    const val NOTIFICATION_REMOVE = "notification.remove"
    const val SMS_MESSAGE = "sms.message"
    const val SMS_SEND = "sms.send"
    const val SMS_SEND_RESULT = "sms.send.result"
    const val PHONE_ACTION = "phone.action"
    const val PHONE_ACTION_RESULT = "phone.action.result"
    const val MILINK_STATUS = "milink.status"
    const val MILINK_FRAME = "milink.frame"
    const val ANDROID_MIC_STATUS = "android.mic.status"
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
    val hash: String
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
    val relayPort: Int? = null
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
