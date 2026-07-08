package com.edgelink.core

import kotlinx.serialization.Serializable
import java.util.Base64

@Serializable
data class PairStartRequest(
    val hostId: String,
    val hostPk: String,
    val name: String
)

@Serializable
data class PairClaimRequest(
    val hostId: String,
    val clientId: String,
    val clientPk: String,
    val name: String
)

@Serializable
data class PairConfirmRequest(
    val role: String,
    val hostId: String,
    val clientId: String,
    val hostPk: String,
    val clientPk: String,
    val hostName: String,
    val clientName: String
)

@Serializable
data class PairReadyBody(val deviceId: String)

@Serializable
data class PairCommitBody(val commit: String)

@Serializable
data class PairRevealClientBody(
    val clientId: String,
    val clientPk: String,
    val nonceC: String,
    val name: String
)

@Serializable
data class PairRevealHostBody(
    val hostId: String,
    val hostPk: String,
    val nonceH: String,
    val name: String
)

@Serializable
data class PairCompleteBody(
    val hostId: String,
    val clientId: String
)

object PairingTypes {
    const val READY = "pair.ready"
    const val COMMIT = "pair.commit"
    const val REVEAL_CLIENT = "pair.reveal_client"
    const val REVEAL_HOST = "pair.reveal_host"
    const val COMPLETE = "pair.complete"
}

object PairingWire {
    fun encodeReady(deviceId: String): String =
        EnvelopeCodec.json.encodeToString(Envelope(PairingTypes.READY, PairReadyBody(deviceId)))

    fun encodeCommit(commitment: ByteArray): String =
        EnvelopeCodec.json.encodeToString(
            Envelope(PairingTypes.COMMIT, PairCommitBody(Base64.getEncoder().encodeToString(commitment)))
        )

    fun encodeRevealClient(identity: LocalIdentity, nonce: ByteArray): String =
        EnvelopeCodec.json.encodeToString(
            Envelope(
                PairingTypes.REVEAL_CLIENT,
                PairRevealClientBody(
                    clientId = identity.deviceId,
                    clientPk = Base64.getEncoder().encodeToString(identity.publicKey),
                    nonceC = Base64.getEncoder().encodeToString(nonce),
                    name = identity.name
                )
            )
        )

    fun decodeCommit(text: String): PairCommitBody =
        EnvelopeCodec.json.decodeFromString<Envelope<PairCommitBody>>(text).b

    fun decodeRevealHost(text: String): PairRevealHostBody =
        EnvelopeCodec.json.decodeFromString<Envelope<PairRevealHostBody>>(text).b

    fun decodeComplete(text: String): PairCompleteBody =
        EnvelopeCodec.json.decodeFromString<Envelope<PairCompleteBody>>(text).b

    fun type(text: String): String =
        EnvelopeCodec.json.decodeFromString<Envelope<kotlinx.serialization.json.JsonObject>>(text).t
}
