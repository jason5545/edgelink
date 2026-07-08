package com.edgelink.core

import com.goterl.lazysodium.LazySodiumAndroid
import com.goterl.lazysodium.SodiumAndroid
import com.goterl.lazysodium.interfaces.AEAD
import com.goterl.lazysodium.interfaces.DiffieHellman
import com.goterl.lazysodium.interfaces.Sign
import java.security.SecureRandom

data class Ed25519KeyPair(
    val publicKey: ByteArray,
    val secretKey: ByteArray
) {
    init {
        require(publicKey.size == Sign.ED25519_PUBLICKEYBYTES)
        require(secretKey.size == Sign.ED25519_SECRETKEYBYTES)
    }
}

data class X25519KeyPair(
    val publicKey: ByteArray,
    val secretKey: ByteArray
) {
    init {
        require(publicKey.size == DiffieHellman.SCALARMULT_BYTES)
        require(secretKey.size == DiffieHellman.SCALARMULT_SCALARBYTES)
    }
}

class SodiumHandshakeCrypto(
    private val sodium: LazySodiumAndroid = LazySodiumAndroid(SodiumAndroid()),
    private val random: SecureRandom = SecureRandom()
) : HandshakeCrypto {
    init {
        sodium.sodiumInit()
    }

    override fun randomBytes(size: Int): ByteArray =
        ByteArray(size).also(random::nextBytes)

    fun randomSeed(): ByteArray =
        ByteArray(Sign.ED25519_SEEDBYTES).also(random::nextBytes)

    fun ed25519KeyPairFromSeed(seed: ByteArray): Ed25519KeyPair {
        require(seed.size == Sign.ED25519_SEEDBYTES) { "Ed25519 seed must be 32 bytes." }
        val publicKey = ByteArray(Sign.ED25519_PUBLICKEYBYTES)
        val secretKey = ByteArray(Sign.ED25519_SECRETKEYBYTES)
        check(sodium.cryptoSignSeedKeypair(publicKey, secretKey, seed)) {
            "libsodium failed to derive Ed25519 keypair."
        }
        return Ed25519KeyPair(publicKey = publicKey, secretKey = secretKey)
    }

    fun signDetached(message: ByteArray, secretKey: ByteArray): ByteArray {
        require(secretKey.size == Sign.ED25519_SECRETKEYBYTES) { "Ed25519 secret key must be 64 bytes." }
        val signature = ByteArray(Sign.ED25519_BYTES)
        check(sodium.cryptoSignDetached(signature, message, message.size.toLong(), secretKey)) {
            "libsodium failed to sign message."
        }
        return signature
    }

    override fun signIdentity(message: ByteArray, identity: LocalIdentity): ByteArray =
        signDetachedWithSeed(message, identity.privateKeySeed)

    fun signDetachedWithSeed(message: ByteArray, seed: ByteArray): ByteArray =
        signDetached(message, ed25519KeyPairFromSeed(seed).secretKey)

    override fun verifyIdentity(signature: ByteArray, message: ByteArray, publicKey: ByteArray): Boolean {
        return verifyDetached(signature, message, publicKey)
    }

    fun verifyDetached(signature: ByteArray, message: ByteArray, publicKey: ByteArray): Boolean {
        require(signature.size == Sign.ED25519_BYTES) { "Ed25519 signature must be 64 bytes." }
        require(publicKey.size == Sign.ED25519_PUBLICKEYBYTES) { "Ed25519 public key must be 32 bytes." }
        return sodium.cryptoSignVerifyDetached(signature, message, message.size, publicKey)
    }

    override fun x25519KeyPair(): X25519KeyPair {
        val secretKey = ByteArray(DiffieHellman.SCALARMULT_SCALARBYTES).also(random::nextBytes)
        return X25519KeyPair(
            publicKey = x25519PublicKey(secretKey),
            secretKey = secretKey
        )
    }

    fun x25519PublicKey(secretKey: ByteArray): ByteArray {
        require(secretKey.size == DiffieHellman.SCALARMULT_SCALARBYTES) { "X25519 secret key must be 32 bytes." }
        val publicKey = ByteArray(DiffieHellman.SCALARMULT_BYTES)
        check(sodium.cryptoScalarMultBase(publicKey, secretKey)) {
            "libsodium failed to derive X25519 public key."
        }
        return publicKey
    }

    override fun x25519SharedSecret(secretKey: ByteArray, publicKey: ByteArray): ByteArray {
        require(secretKey.size == DiffieHellman.SCALARMULT_SCALARBYTES) { "X25519 secret key must be 32 bytes." }
        require(publicKey.size == DiffieHellman.SCALARMULT_BYTES) { "X25519 public key must be 32 bytes." }
        val shared = ByteArray(DiffieHellman.SCALARMULT_BYTES)
        check(sodium.cryptoScalarMult(shared, secretKey, publicKey)) {
            "libsodium failed to compute X25519 shared secret."
        }
        return shared
    }
}

class SodiumSecureFrameAead(
    private val sodium: LazySodiumAndroid = LazySodiumAndroid(SodiumAndroid())
) : SecureFrameAead {
    init {
        sodium.sodiumInit()
    }

    override fun seal(plaintext: ByteArray, key: ByteArray, nonce: ByteArray, aad: ByteArray): ByteArray {
        require(key.size == AEAD.CHACHA20POLY1305_IETF_KEYBYTES) { "ChaCha20-Poly1305 key must be 32 bytes." }
        require(nonce.size == AEAD.CHACHA20POLY1305_IETF_NPUBBYTES) { "ChaCha20-Poly1305 nonce must be 12 bytes." }
        val ciphertextAndTag = ByteArray(plaintext.size + AEAD.CHACHA20POLY1305_IETF_ABYTES)
        val ciphertextLength = LongArray(1)
        check(
            sodium.cryptoAeadChaCha20Poly1305IetfEncrypt(
                ciphertextAndTag,
                ciphertextLength,
                plaintext,
                plaintext.size.toLong(),
                aad,
                aad.size.toLong(),
                null,
                nonce,
                key
            )
        ) {
            "libsodium failed to seal secure frame."
        }
        return ciphertextAndTag.copyOf(ciphertextLength[0].toInt())
    }

    override fun open(ciphertextAndTag: ByteArray, key: ByteArray, nonce: ByteArray, aad: ByteArray): ByteArray {
        require(key.size == AEAD.CHACHA20POLY1305_IETF_KEYBYTES) { "ChaCha20-Poly1305 key must be 32 bytes." }
        require(nonce.size == AEAD.CHACHA20POLY1305_IETF_NPUBBYTES) { "ChaCha20-Poly1305 nonce must be 12 bytes." }
        require(ciphertextAndTag.size >= AEAD.CHACHA20POLY1305_IETF_ABYTES) { "Ciphertext is truncated." }
        val plaintext = ByteArray(ciphertextAndTag.size - AEAD.CHACHA20POLY1305_IETF_ABYTES)
        val plaintextLength = LongArray(1)
        check(
            sodium.cryptoAeadChaCha20Poly1305IetfDecrypt(
                plaintext,
                plaintextLength,
                null,
                ciphertextAndTag,
                ciphertextAndTag.size.toLong(),
                aad,
                aad.size.toLong(),
                nonce,
                key
            )
        ) {
            "libsodium failed to open secure frame."
        }
        return plaintext.copyOf(plaintextLength[0].toInt())
    }
}
