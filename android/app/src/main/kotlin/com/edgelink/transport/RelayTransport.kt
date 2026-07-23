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
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.TimeUnit

private const val RELAY_WEBSOCKET_PING_INTERVAL_SECONDS = 15L
private const val RELAY_APP_PING_TEXT = "{\"t\":\"ping\"}"
private const val RELAY_APP_PONG_TEXT = "{\"t\":\"pong\"}"

class RelayTransport(
    private val client: OkHttpClient = OkHttpClient.Builder()
        .pingInterval(RELAY_WEBSOCKET_PING_INTERVAL_SECONDS, TimeUnit.SECONDS)
        .build(),
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
        try {
            channel.awaitReady()
            return channel
        } catch (error: Throwable) {
            channel.close()
            throw error
        }
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
    // SecureChannel uses an implicit receive counter, so dropping even one
    // WebSocket message makes every following frame fail authentication. The
    // default buffered channel only holds 64 messages and phone audio can burst
    // past that in a couple of seconds. Keep the reliable WebSocket stream
    // lossless here and let the suspending receive loop drain it in order.
    private val incoming = Channel<ByteArray>(Channel.UNLIMITED)
    private val binaryFramesReceived = AtomicLong(0)
    private val binaryFramesSent = AtomicLong(0)
    private var webSocket: WebSocket? = null
    private var appPingScheduler: ScheduledExecutorService? = null

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
            startAppPing()
        } else if (text == RELAY_APP_PONG_TEXT) {
            EdgeLinkLog.info("relay.transport.app_pong hostId=$hostId deviceId=$deviceId")
        } else {
            EdgeLinkLog.warn("relay.transport.text_unexpected hostId=$hostId deviceId=$deviceId text=$text")
        }
    }

    override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
        val count = binaryFramesReceived.incrementAndGet()
        if (count <= 3 || count % 100L == 0L) {
            EdgeLinkLog.info("relay.transport.binary_in hostId=$hostId deviceId=$deviceId count=$count bytes=${bytes.size}")
        }
        val result = incoming.trySend(bytes.toByteArray())
        if (result.isFailure) {
            EdgeLinkLog.warn("relay.transport.binary_queue_failed hostId=$hostId deviceId=$deviceId")
        }
    }

    override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
        EdgeLinkLog.error("relay.transport.failure hostId=$hostId deviceId=$deviceId status=${response?.code}", t)
        stopAppPing()
        ready.completeExceptionally(t)
        incoming.close(t)
    }

    override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
        EdgeLinkLog.info("relay.transport.closed hostId=$hostId deviceId=$deviceId code=$code reason=$reason")
        stopAppPing()
        if (!ready.isCompleted) {
            ready.completeExceptionally(IllegalStateException("Relay WebSocket closed before ready: $code $reason"))
        }
        incoming.close()
    }

    private fun startAppPing() {
        stopAppPing()
        val scheduler = Executors.newSingleThreadScheduledExecutor()
        scheduler.scheduleWithFixedDelay({
            val socket = webSocket ?: return@scheduleWithFixedDelay
            try {
                socket.send(RELAY_APP_PING_TEXT)
            } catch (error: Throwable) {
                EdgeLinkLog.warn("relay.transport.app_ping_failed hostId=$hostId deviceId=$deviceId error=$error")
            }
        }, RELAY_WEBSOCKET_PING_INTERVAL_SECONDS, RELAY_WEBSOCKET_PING_INTERVAL_SECONDS, TimeUnit.SECONDS)
        appPingScheduler = scheduler
    }

    private fun stopAppPing() {
        appPingScheduler?.shutdownNow()
        appPingScheduler = null
    }

    override suspend fun send(bytes: ByteArray) {
        ready.await()
        val socket = webSocket ?: error("Relay WebSocket is not attached.")
        val count = binaryFramesSent.incrementAndGet()
        if (count <= 3 || count % 100L == 0L) {
            EdgeLinkLog.info("relay.transport.binary_out hostId=$hostId deviceId=$deviceId count=$count bytes=${bytes.size}")
        }
        val accepted = withContext(Dispatchers.IO) {
            socket.send(bytes.toByteString())
        }
        if (!accepted) {
            error("Relay WebSocket rejected binary frame.")
        }
    }

    override suspend fun receive(): ByteArray? =
        incoming.receiveCatching().getOrNull()

    override fun close() {
        EdgeLinkLog.info("relay.transport.close hostId=$hostId deviceId=$deviceId")
        stopAppPing()
        incoming.close()
        webSocket?.close(1000, "Client closing")
    }
}
