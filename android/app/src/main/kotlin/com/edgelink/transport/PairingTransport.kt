package com.edgelink.transport

import com.edgelink.app.EdgeLinkLog
import com.edgelink.core.EnvelopeCodec
import com.edgelink.core.LocalIdentity
import com.edgelink.core.PairClaimRequest
import com.edgelink.core.PairConfirmRequest
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import java.util.Base64

class PairingTransport(
    private val client: OkHttpClient = OkHttpClient()
) {
    suspend fun connect(pairingWebSocketUrl: String, hostId: String): PairingTextChannel {
        val request = Request.Builder()
            .url(withHostId(pairingWebSocketUrl, hostId))
            .build()
        EdgeLinkLog.info("pair.transport.ws_open_start hostId=$hostId")
        val channel = OkHttpPairingTextChannel(hostId)
        channel.attach(client.newWebSocket(request, channel))
        channel.awaitOpen()
        return channel
    }

    suspend fun claim(workerBaseUrl: String, hostId: String, identity: LocalIdentity) {
        val body = EnvelopeCodec.json.encodeToString(
            PairClaimRequest.serializer(),
            PairClaimRequest(
                hostId = hostId,
                clientId = identity.deviceId,
                clientPk = Base64.getEncoder().encodeToString(identity.publicKey),
                name = identity.name
            )
        )
        postJson(workerBaseUrl.trimEnd('/') + "/v1/pair/claim", body)
    }

    suspend fun confirm(workerBaseUrl: String, request: PairConfirmRequest) {
        val body = EnvelopeCodec.json.encodeToString(PairConfirmRequest.serializer(), request)
        postJson(workerBaseUrl.trimEnd('/') + "/v1/pair/confirm", body)
    }

    private suspend fun postJson(url: String, body: String) {
        withContext(Dispatchers.IO) {
            val request = Request.Builder()
                .url(url)
                .post(body.toRequestBody("application/json".toMediaType()))
                .build()
            client.newCall(request).execute().use { response ->
                val responseBody = response.body?.string().orEmpty()
                EdgeLinkLog.info("pair.transport.http status=${response.code} url=$url body=$responseBody")
                if (!response.isSuccessful) {
                    error("Pairing request failed with HTTP ${response.code}: $responseBody")
                }
            }
        }
    }

    private fun withHostId(url: String, hostId: String): String {
        val separator = if ('?' in url) "&" else "?"
        return "$url${separator}hostId=$hostId"
    }
}

interface PairingTextChannel {
    suspend fun send(text: String)
    suspend fun receive(): String?
    fun close()
}

private class OkHttpPairingTextChannel(
    private val hostId: String
) : WebSocketListener(), PairingTextChannel {
    private val opened = CompletableDeferred<Unit>()
    private val incoming = Channel<String>(Channel.BUFFERED)
    private var webSocket: WebSocket? = null

    fun attach(socket: WebSocket) {
        webSocket = socket
    }

    suspend fun awaitOpen() {
        opened.await()
    }

    override fun onOpen(webSocket: WebSocket, response: Response) {
        EdgeLinkLog.info("pair.transport.ws_open hostId=$hostId status=${response.code}")
        opened.complete(Unit)
    }

    override fun onMessage(webSocket: WebSocket, text: String) {
        EdgeLinkLog.info("pair.transport.ws_text hostId=$hostId bytes=${text.encodeToByteArray().size}")
        incoming.trySend(text)
    }

    override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
        EdgeLinkLog.error("pair.transport.ws_failure hostId=$hostId status=${response?.code}", t)
        opened.completeExceptionally(t)
        incoming.close(t)
    }

    override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
        EdgeLinkLog.info("pair.transport.ws_closed hostId=$hostId code=$code reason=$reason")
        if (!opened.isCompleted) {
            opened.completeExceptionally(IllegalStateException("Pairing WebSocket closed before open: $code $reason"))
        }
        incoming.close()
    }

    override suspend fun send(text: String) {
        opened.await()
        EdgeLinkLog.info("pair.transport.ws_send hostId=$hostId bytes=${text.encodeToByteArray().size}")
        val accepted = withContext(Dispatchers.IO) {
            webSocket?.send(text) == true
        }
        if (!accepted) {
            error("Pairing WebSocket rejected text message.")
        }
    }

    override suspend fun receive(): String? =
        incoming.receiveCatching().getOrNull()

    override fun close() {
        webSocket?.close(1000, "done")
    }
}
