package com.edgelink.core

data class Envelope<T>(
    val t: String,
    val b: T
)

object EnvelopeTypes {
    const val STATUS_PING = "status.ping"
    const val INPUT_POINTER = "input.pointer"
    const val INPUT_KEY = "input.key"
    const val INPUT_TEXT = "input.text"
    const val CLIPBOARD_SET = "clipboard.set"
}
