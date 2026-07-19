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

    fun advanceTo(nextValue: Long) {
        require(nextValue >= value) { "Frame counter cannot move backwards." }
        value = nextValue
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
        SecureFrame.sealVersioned(plaintext, sendKey, sendDirection, sendCounter.next(), aead)

    fun open(frame: ByteArray): ByteArray {
        val opened = SecureFrame.openVersioned(
            frame = frame,
            key = receiveKey,
            direction = receiveDirection,
            minimumCounter = receiveCounter.value,
            aead = aead
        )
        receiveCounter.advanceTo(opened.counter + 1)
        return opened.plaintext
    }
}

data class OpenedSecureFrame(
    val counter: Long,
    val plaintext: ByteArray
)

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

    fun sealVersioned(
        plaintext: ByteArray,
        key: ByteArray,
        direction: SecureChannelDirection,
        counter: Long,
        aead: SecureFrameAead = JcaSecureFrameAead
    ): ByteArray {
        val legacyFrame = seal(plaintext, key, direction, counter, aead)
        val ciphertextLength = ByteBuffer.wrap(legacyFrame, 0, 4).int
        return ByteBuffer.allocate(12 + ciphertextLength)
            .putInt(ciphertextLength)
            .putLong(counter)
            .put(legacyFrame, 4, ciphertextLength)
            .array()
    }

    fun openVersioned(
        frame: ByteArray,
        key: ByteArray,
        direction: SecureChannelDirection,
        minimumCounter: Long,
        aead: SecureFrameAead = JcaSecureFrameAead
    ): OpenedSecureFrame {
        require(frame.size >= 12) { "Frame is truncated." }
        val header = ByteBuffer.wrap(frame)
        val ciphertextLength = header.int
        require(ciphertextLength in 16..MAX_CIPHERTEXT_AND_TAG_LENGTH) { "Invalid frame length." }
        require(frame.size == 12 + ciphertextLength) { "Frame length mismatch." }
        val counter = header.long
        require(counter >= minimumCounter) { "Frame counter was replayed." }
        val legacyFrame = ByteBuffer.allocate(4 + ciphertextLength)
            .putInt(ciphertextLength)
            .put(frame, 12, ciphertextLength)
            .array()
        return OpenedSecureFrame(
            counter = counter,
            plaintext = open(legacyFrame, key, direction, counter, aead)
        )
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
