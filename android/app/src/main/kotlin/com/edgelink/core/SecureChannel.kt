package com.edgelink.core

enum class SecureChannelDirection(val aad: ByteArray) {
    INITIATOR_TO_RESPONDER("EdgeLink frame v1 i2r".encodeToByteArray()),
    RESPONDER_TO_INITIATOR("EdgeLink frame v1 r2i".encodeToByteArray())
}

class FrameCounter(initialValue: Long = 0) {
    var value: Long = initialValue
        private set

    fun next(): Long = value.also {
        value += 1
    }
}
