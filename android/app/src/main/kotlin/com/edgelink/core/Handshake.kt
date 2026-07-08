package com.edgelink.core

import java.io.ByteArrayOutputStream

data class HandshakePeer(
    val deviceId: String,
    val ephemeralPublicKey: ByteArray,
    val nonce: ByteArray
)

object HandshakeEncoding {
    fun peerRecord(peer: HandshakePeer): ByteArray {
        val out = ByteArrayOutputStream()
        out.writeLengthPrefixed(peer.deviceId.encodeToByteArray())
        out.writeLengthPrefixed(peer.ephemeralPublicKey)
        out.writeLengthPrefixed(peer.nonce)
        return out.toByteArray()
    }

    private fun ByteArrayOutputStream.writeLengthPrefixed(value: ByteArray) {
        require(value.size <= UShort.MAX_VALUE.toInt())
        write((value.size ushr 8) and 0xff)
        write(value.size and 0xff)
        write(value)
    }
}
