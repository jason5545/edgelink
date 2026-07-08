package com.edgelink.transport

import com.edgelink.app.EdgeLinkLog
import com.edgelink.core.EnvelopeCodec
import com.edgelink.core.LocalIdentity
import com.edgelink.core.RelayAuth
import com.edgelink.core.RelayAuthEnvelope
import com.edgelink.core.SodiumHandshakeCrypto
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString
import java.time.Instant

class RelayTransport(
    private val client: OkHttpClient = OkHttpClient(),
    private val crypto: SodiumHandshakeCrypto = SodiumHandshakeCrypto()
) {
    suspend fun connect(relayUrl: String, hostId: String, identity: LocalIdentity): ByteChannel {
        val timestamp = Instant.now().epochSecond
        val signature = crypto.signIdentity(RelayAuth.message(identity.deviceId, timestamp), identity)
        val auth = EnvelopeCodec.json.encodeToString(
            RelayAuthEnvelope.serializer(),
            RelayAuth.envelope(hostId, identity, timestamp, signature)
        )
        val request = request(relayUrl, hostId)
        EdgeLinkLog.info("relay.transport.open_start hostId=$hostId deviceId=${identity.deviceId}")
        val channel = OkHttpRelayByteChannel(hostId, identity.deviceId, auth)
        channel.attach(client.newWebSocket(request, channel))
        channel.awaitReady()
        return channel
    }

    fun request(relayUrl: String, hostId: String): Request =
        Request.Builder()
            .url(withHostId(relayUrl, hostId))
            .build()

    private fun withHostId(url: String, hostId: String): String {
        val separator = if ('?' in url) "&" else "?"
        return "$url${separator}hostId=$hostId"
    }
}

@Serializable
private data class RelayReadyEnvelope(
    val t: String,
    val b: Body
) {
    @Serializable
    data class Body(val role: String)
}

private class OkHttpRelayByteChannel(
    private val hostId: String,
    private val deviceId: String,
    private val authText: String
) : WebSocketListener(), ByteChannel {
    private val ready = CompletableDeferred<Unit>()
    private val incoming = Channel<ByteArray>(Channel.BUFFERED)
    private var webSocket: WebSocket? = null

    fun attach(socket: WebSocket) {
        webSocket = socket
    }

    suspend fun awaitReady() {
        ready.await()
    }

    override fun onOpen(webSocket: WebSocket, response: Response) {
        EdgeLinkLog.info("relay.transport.open hostId=$hostId deviceId=$deviceId status=${response.code}")
        if (!webSocket.send(authText)) {
            ready.completeExceptionally(IllegalStateException("Relay WebSocket rejected auth frame."))
        }
    }

    override fun onMessage(webSocket: WebSocket, text: String) {
        val envelope = runCatching {
            EnvelopeCodec.json.decodeFromString(RelayReadyEnvelope.serializer(), text)
        }.getOrNull()
        if (envelope?.t == "relay.ready") {
            EdgeLinkLog.info("relay.transport.ready hostId=$hostId deviceId=$deviceId role=${envelope.b.role}")
            ready.complete(Unit)
        } else {
            EdgeLinkLog.warn("relay.transport.text_unexpected hostId=$hostId deviceId=$deviceId text=$text")
        }
    }

    override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
        EdgeLinkLog.info("relay.transport.binary_in hostId=$hostId deviceId=$deviceId bytes=${bytes.size}")
        incoming.trySend(bytes.toByteArray())
    }

    override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
        EdgeLinkLog.error("relay.transport.failure hostId=$hostId deviceId=$deviceId status=${response?.code}", t)
        ready.completeExceptionally(t)
        incoming.close(t)
    }

    override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
        EdgeLinkLog.info("relay.transport.closed hostId=$hostId deviceId=$deviceId code=$code reason=$reason")
        if (!ready.isCompleted) {
            ready.completeExceptionally(IllegalStateException("Relay WebSocket closed before ready: $code $reason"))
        }
        incoming.close()
    }

    override suspend fun send(bytes: ByteArray) {
        ready.await()
        val socket = webSocket ?: error("Relay WebSocket is not attached.")
        EdgeLinkLog.info("relay.transport.binary_out hostId=$hostId deviceId=$deviceId bytes=${bytes.size}")
        val accepted = withContext(Dispatchers.IO) {
            socket.send(bytes.toByteString())
        }
        if (!accepted) {
            error("Relay WebSocket rejected binary frame.")
        }
    }

    override suspend fun receive(): ByteArray? =
        incoming.receiveCatching().getOrNull()
}
