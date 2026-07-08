package com.edgelink.core

import java.nio.ByteBuffer
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

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

enum class SecureChannelRole {
    INITIATOR,
    RESPONDER
}

interface SecureFrameAead {
    fun seal(plaintext: ByteArray, key: ByteArray, nonce: ByteArray, aad: ByteArray): ByteArray
    fun open(ciphertextAndTag: ByteArray, key: ByteArray, nonce: ByteArray, aad: ByteArray): ByteArray
}

object JcaSecureFrameAead : SecureFrameAead {
    override fun seal(plaintext: ByteArray, key: ByteArray, nonce: ByteArray, aad: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("ChaCha20-Poly1305")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "ChaCha20"), IvParameterSpec(nonce))
        cipher.updateAAD(aad)
        return cipher.doFinal(plaintext)
    }

    override fun open(ciphertextAndTag: ByteArray, key: ByteArray, nonce: ByteArray, aad: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("ChaCha20-Poly1305")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "ChaCha20"), IvParameterSpec(nonce))
        cipher.updateAAD(aad)
        return cipher.doFinal(ciphertextAndTag)
    }
}

class SecureChannel(
    keys: SecureChannelKeys,
    role: SecureChannelRole,
    private val aead: SecureFrameAead = JcaSecureFrameAead
) {
    private val sendKey: ByteArray
    private val receiveKey: ByteArray
    private val sendDirection: SecureChannelDirection
    private val receiveDirection: SecureChannelDirection
    private val sendCounter = FrameCounter()
    private val receiveCounter = FrameCounter()

    init {
        when (role) {
            SecureChannelRole.INITIATOR -> {
                sendKey = keys.initiatorToResponder
                receiveKey = keys.responderToInitiator
                sendDirection = SecureChannelDirection.INITIATOR_TO_RESPONDER
                receiveDirection = SecureChannelDirection.RESPONDER_TO_INITIATOR
            }
            SecureChannelRole.RESPONDER -> {
                sendKey = keys.responderToInitiator
                receiveKey = keys.initiatorToResponder
                sendDirection = SecureChannelDirection.RESPONDER_TO_INITIATOR
                receiveDirection = SecureChannelDirection.INITIATOR_TO_RESPONDER
            }
        }
    }

    fun seal(plaintext: ByteArray): ByteArray =
        SecureFrame.seal(plaintext, sendKey, sendDirection, sendCounter.next(), aead)

    fun open(frame: ByteArray): ByteArray =
        SecureFrame.open(frame, receiveKey, receiveDirection, receiveCounter.next(), aead)
}

object SecureFrame {
    const val MAX_CIPHERTEXT_AND_TAG_LENGTH = 64 * 1024

    fun nonce(counter: Long): ByteArray {
        val out = ByteArray(12)
        ByteBuffer.wrap(out, 4, 8).putLong(counter)
        return out
    }

    fun seal(
        plaintext: ByteArray,
        key: ByteArray,
        direction: SecureChannelDirection,
        counter: Long,
        aead: SecureFrameAead = JcaSecureFrameAead
    ): ByteArray {
        require(key.size == 32) { "ChaCha20-Poly1305 key must be 32 bytes." }
        val ciphertextAndTag = aead.seal(plaintext, key, nonce(counter), direction.aad)
        require(ciphertextAndTag.size <= MAX_CIPHERTEXT_AND_TAG_LENGTH) { "Frame too large." }
        return ByteBuffer.allocate(4 + ciphertextAndTag.size)
            .putInt(ciphertextAndTag.size)
            .put(ciphertextAndTag)
            .array()
    }

    fun open(
        frame: ByteArray,
        key: ByteArray,
        direction: SecureChannelDirection,
        counter: Long,
        aead: SecureFrameAead = JcaSecureFrameAead
    ): ByteArray {
        require(key.size == 32) { "ChaCha20-Poly1305 key must be 32 bytes." }
        require(frame.size >= 4) { "Frame is truncated." }
        val length = ByteBuffer.wrap(frame, 0, 4).int
        require(length in 16..MAX_CIPHERTEXT_AND_TAG_LENGTH) { "Invalid frame length." }
        require(frame.size == 4 + length) { "Frame length mismatch." }

        return aead.open(frame.copyOfRange(4, frame.size), key, nonce(counter), direction.aad)
    }
}
