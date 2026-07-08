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
    const val CLIPBOARD_SET = "clipboard.set"
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
data class ClipboardSetBody(
    val text: String,
    val ts: Long,
    val hash: String
)
