package com.edgelink.transport

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
import okhttp3.HttpUrl.Companion.toHttpUrl
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
        val channel = OkHttpRelayByteChannel(auth)
        channel.attach(client.newWebSocket(request, channel))
        channel.awaitReady()
        return channel
    }

    fun request(relayUrl: String, hostId: String): Request =
        Request.Builder()
            .url(relayUrl.toHttpUrl().newBuilder().addQueryParameter("hostId", hostId).build())
            .build()
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
        if (!webSocket.send(authText)) {
            ready.completeExceptionally(IllegalStateException("Relay WebSocket rejected auth frame."))
        }
    }

    override fun onMessage(webSocket: WebSocket, text: String) {
        val envelope = runCatching {
            EnvelopeCodec.json.decodeFromString(RelayReadyEnvelope.serializer(), text)
        }.getOrNull()
        if (envelope?.t == "relay.ready") {
            ready.complete(Unit)
        }
    }

    override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
        incoming.trySend(bytes.toByteArray())
    }

    override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
        ready.completeExceptionally(t)
        incoming.close(t)
    }

    override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
        if (!ready.isCompleted) {
            ready.completeExceptionally(IllegalStateException("Relay WebSocket closed before ready: $code $reason"))
        }
        incoming.close()
    }

    override suspend fun send(bytes: ByteArray) {
        ready.await()
        val socket = webSocket ?: error("Relay WebSocket is not attached.")
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
