package com.edgelink.core

import java.security.MessageDigest
import java.util.Locale

data class SasCode(
    val numeric: String,
    val display: String = "${numeric.substring(0, 3)} ${numeric.substring(3, 6)}"
)

object Pairing {
    fun commitment(hostPublicKey: ByteArray, hostNonce: ByteArray): ByteArray =
        sha256(hostPublicKey, hostNonce)

    fun sas(
        hostPublicKey: ByteArray,
        clientPublicKey: ByteArray,
        hostNonce: ByteArray,
        clientNonce: ByteArray
    ): SasCode {
        val digest = sha256(hostPublicKey, clientPublicKey, hostNonce, clientNonce)
        var remainder = 0
        for (byte in digest) {
            remainder = (remainder * 256 + (byte.toInt() and 0xff)) % 1_000_000
        }
        return SasCode(String.format(Locale.US, "%06d", remainder))
    }

    private fun sha256(vararg parts: ByteArray): ByteArray {
        val digest = MessageDigest.getInstance("SHA-256")
        parts.forEach(digest::update)
        return digest.digest()
    }
}
