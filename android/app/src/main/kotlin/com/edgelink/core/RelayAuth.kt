package com.edgelink.core

import kotlinx.serialization.Serializable
import java.util.Base64

@Serializable
data class RelayAuthEnvelope(
    val t: String = "relay.auth",
    val b: Body
) {
    @Serializable
    data class Body(
        val hostId: String,
        val deviceId: String,
        val ts: Long,
        val sig: String
    )
}

object RelayAuth {
    fun message(deviceId: String, timestampSeconds: Long): ByteArray =
        "EdgeLink relay auth v1\n$deviceId\n$timestampSeconds".encodeToByteArray()

    fun envelope(hostId: String, identity: LocalIdentity, timestampSeconds: Long, signature: ByteArray): RelayAuthEnvelope =
        RelayAuthEnvelope(
            b = RelayAuthEnvelope.Body(
                hostId = hostId,
                deviceId = identity.deviceId,
                ts = timestampSeconds,
                sig = Base64.getEncoder().encodeToString(signature)
            )
        )
}
