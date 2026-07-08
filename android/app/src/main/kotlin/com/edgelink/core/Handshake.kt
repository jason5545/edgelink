package com.edgelink.core

import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

data class HandshakePeer(
    val deviceId: String,
    val ephemeralPublicKey: ByteArray,
    val nonce: ByteArray
)

object HandshakeEncoding {
    private val helloPrefix = "EdgeLink hs.v1 hello\n".encodeToByteArray()
    private val ackPrefix = "EdgeLink hs.v1 ack\n".encodeToByteArray()
    private val confirmPrefix = "EdgeLink hs.v1 confirm\n".encodeToByteArray()
    private val transcriptPrefix = "EdgeLink hs.v1 transcript\n".encodeToByteArray()
    val hkdfInfo: ByteArray = "EdgeLink secure channel v1".encodeToByteArray()

    fun peerRecord(peer: HandshakePeer): ByteArray {
        val out = ByteArrayOutputStream()
        out.writeLengthPrefixed(peer.deviceId.encodeToByteArray())
        out.writeLengthPrefixed(peer.ephemeralPublicKey)
        out.writeLengthPrefixed(peer.nonce)
        return out.toByteArray()
    }

    fun helloInput(clientPeer: HandshakePeer): ByteArray =
        helloPrefix + peerRecord(clientPeer)

    fun ackInput(clientPeer: HandshakePeer, hostPeer: HandshakePeer): ByteArray =
        ackPrefix + peerRecord(clientPeer) + peerRecord(hostPeer)

    fun confirmInput(
        clientPeer: HandshakePeer,
        hostPeer: HandshakePeer,
        helloSignature: ByteArray,
        ackSignature: ByteArray
    ): ByteArray =
        confirmPrefix + peerRecord(clientPeer) + peerRecord(hostPeer) + helloSignature + ackSignature

    fun transcriptHash(
        clientPeer: HandshakePeer,
        helloSignature: ByteArray,
        hostPeer: HandshakePeer,
        ackSignature: ByteArray,
        confirmSignature: ByteArray
    ): ByteArray =
        sha256(transcriptPrefix + peerRecord(clientPeer) + helloSignature + peerRecord(hostPeer) + ackSignature + confirmSignature)

    private fun ByteArrayOutputStream.writeLengthPrefixed(value: ByteArray) {
        require(value.size <= UShort.MAX_VALUE.toInt())
        write((value.size ushr 8) and 0xff)
        write(value.size and 0xff)
        write(value)
    }

    private fun sha256(value: ByteArray): ByteArray =
        MessageDigest.getInstance("SHA-256").digest(value)
}

data class HandshakeTranscript(
    val clientPeer: HandshakePeer,
    val hostPeer: HandshakePeer,
    val helloSignature: ByteArray,
    val ackSignature: ByteArray,
    val confirmSignature: ByteArray
) {
    val transcriptHash: ByteArray
        get() = HandshakeEncoding.transcriptHash(
            clientPeer = clientPeer,
            helloSignature = helloSignature,
            hostPeer = hostPeer,
            ackSignature = ackSignature,
            confirmSignature = confirmSignature
        )
}

data class SecureChannelKeys(
    val initiatorToResponder: ByteArray,
    val responderToInitiator: ByteArray
) {
    init {
        require(initiatorToResponder.size == 32)
        require(responderToInitiator.size == 32)
    }
}

object HandshakeKeySchedule {
    fun deriveKeys(sharedSecret: ByteArray, transcriptHash: ByteArray): SecureChannelKeys {
        val okm = hkdfSha256(
            ikm = sharedSecret,
            salt = transcriptHash,
            info = HandshakeEncoding.hkdfInfo,
            length = 64
        )
        return SecureChannelKeys(
            initiatorToResponder = okm.copyOfRange(0, 32),
            responderToInitiator = okm.copyOfRange(32, 64)
        )
    }

    fun hkdfSha256(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
        val prk = hmacSha256(salt, ikm)
        val out = ByteArrayOutputStream()
        var previous = ByteArray(0)
        var counter = 1
        while (out.size() < length) {
            previous = hmacSha256(prk, previous + info + byteArrayOf(counter.toByte()))
            out.write(previous)
            counter += 1
        }
        return out.toByteArray().copyOfRange(0, length)
    }

    private fun hmacSha256(key: ByteArray, value: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return mac.doFinal(value)
    }
}
