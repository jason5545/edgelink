package com.edgelink.core

data class Envelope<T>(
    val t: String,
    val b: T
)

object EnvelopeTypes {
    const val STATUS_PING = "status.ping"
    const val STATUS_PONG = "status.pong"
    const val INPUT_POINTER = "input.pointer"
    const val INPUT_KEY = "input.key"
    const val INPUT_TEXT = "input.text"
    const val CLIPBOARD_SET = "clipboard.set"
}

data class InputPointerBody(
    val dx: Double = 0.0,
    val dy: Double = 0.0,
    val scrollX: Double? = null,
    val scrollY: Double? = null,
    val btn: String? = null
)

data class InputKeyBody(
    val key: String,
    val mods: List<String> = emptyList()
)

data class InputTextBody(
    val text: String
)

data class ClipboardSetBody(
    val text: String,
    val ts: Long,
    val hash: String
)
