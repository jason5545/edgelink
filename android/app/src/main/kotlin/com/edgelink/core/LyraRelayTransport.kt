package com.edgelink.core

import kotlinx.serialization.EncodeDefault
import kotlinx.serialization.Serializable
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi

// MARK: - Relay Transport Datagrams (Xiaomi mesh / channel over relay)
//
// Carries the phone's native Lyra mesh + channel datagrams over the EdgeLink
// E2EE relay session so the Mac's production announce / relayCall / cast logic
// runs unchanged when the phone is only reachable through the cloud relay. The
// worker stays blind: these are opaque payloads inside the secure frame.
//
// Wire shape matches the Mac (EdgeLinkKit.RelayDatagramBody):
//   {"t":"relay.mesh.datagram","b":{"payload":"<base64 datagram>"}}
//   {"t":"relay.channel.datagram","b":{"payload":"<base64 datagram>"}}
//
// "f" is the logical flow index within the envelope type (absent = 0): the
// announce / relayCall dial rides mesh flow 0, the cast trust dial rides mesh
// flow 1 so the phone presents it from a fresh UDP socket (the Xiaomi mesh
// service only answers phys sync from a peer it has not yet authenticated).
//
// "p" is channel-only: the local Xiaomi channel port the Mac dialed for this
// flow; the phone bridge binds its local forward lazily on first datagram.

@Serializable
data class RelayDatagramBody(
    val payload: String,
    @EncodeDefault(EncodeDefault.Mode.NEVER)
    val f: Int? = null,
    @EncodeDefault(EncodeDefault.Mode.NEVER)
    val p: Int? = null
)

object RelayDatagram {
    @OptIn(ExperimentalEncodingApi::class)
    fun encode(datagram: ByteArray, flow: Int = 0): RelayDatagramBody =
        RelayDatagramBody(payload = Base64.encode(datagram), f = flow.takeIf { it != 0 })

    @OptIn(ExperimentalEncodingApi::class)
    fun decode(body: RelayDatagramBody): ByteArray? =
        runCatching { Base64.decode(body.payload) }.getOrNull()
}
