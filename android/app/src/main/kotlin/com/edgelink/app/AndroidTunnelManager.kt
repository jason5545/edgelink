package com.edgelink.app

import com.edgelink.core.*
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.decodeFromJsonElement
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/**
 * EdgeLink TCP Tunnel Manager for Android (Route b).
 * Handles tunnel.open requests from Mac by dialing local targets (e.g. adbd on 127.0.0.1:5555).
 * Also supports remote forward (Android listens, Mac dials).
 */
class AndroidTunnelManager(
    private val scope: CoroutineScope,
    private val sendEnvelope: suspend (String, Any) -> Unit
) {
    private data class StreamState(
        val socket: Socket,
        var state: String = "open",
        var sendCredit: Int = TunnelConstants.INITIAL_CREDIT,
        var recvCredit: Int = TunnelConstants.INITIAL_CREDIT,
        var bytesIn: Long = 0,
        var bytesOut: Long = 0,
        var lastActivity: Long = System.currentTimeMillis(),
        val readJob: Job? = null
    )

    private data class TunnelState(
        val tunnelId: String,
        val direction: TunnelDirection,
        val targetHost: String,
        val targetPort: Int,
        val label: String?,
        val streams: ConcurrentHashMap<Int, StreamState> = ConcurrentHashMap(),
        val nextStreamId: AtomicInteger = AtomicInteger(1),
        var serverSocket: ServerSocket? = null,
        var listenJob: Job? = null
    )

    private val tunnels = ConcurrentHashMap<String, TunnelState>()
    private val allowlist = TunnelAllowlist()
    private val mutex = Mutex()

    // MARK: - Inbound Envelope Handling

    suspend fun handleEnvelope(type: String, body: kotlinx.serialization.json.JsonObject) {
        val json = EnvelopeCodec.json
        when (type) {
            EnvelopeTypes.TUNNEL_OPEN -> {
                val open = json.decodeFromJsonElement<TunnelOpenBody>(body)
                handleTunnelOpen(open)
            }
            EnvelopeTypes.TUNNEL_OPEN_RESULT -> {
                val result = json.decodeFromJsonElement<TunnelOpenResultBody>(body)
                handleTunnelOpenResult(result)
            }
            EnvelopeTypes.TUNNEL_DATA -> {
                val data = json.decodeFromJsonElement<TunnelDataBody>(body)
                handleTunnelData(data)
            }
            EnvelopeTypes.TUNNEL_CLOSE -> {
                val close = json.decodeFromJsonElement<TunnelCloseBody>(body)
                handleTunnelClose(close)
            }
            EnvelopeTypes.TUNNEL_ERROR -> {
                val error = json.decodeFromJsonElement<TunnelErrorBody>(body)
                handleTunnelError(error)
            }
            EnvelopeTypes.TUNNEL_FLOW -> {
                val flow = json.decodeFromJsonElement<TunnelFlowBody>(body)
                handleTunnelFlow(flow)
            }
        }
    }

    // MARK: - Local Forward (Mac listens, Android dials target)

    private suspend fun handleTunnelOpen(body: TunnelOpenBody) {
        if (!allowlist.isAllowed(body.targetHost, body.targetPort)) {
            sendEnvelope(EnvelopeTypes.TUNNEL_ERROR, TunnelErrorBody(
                tunnelId = body.tunnelId,
                code = TunnelErrorCode.not_allowed,
                message = "Target not in allowlist"
            ))
            return
        }

        if (body.direction == TunnelDirection.local) {
            // Mac listens, Android will dial target when streams arrive
            val tunnel = TunnelState(
                tunnelId = body.tunnelId,
                direction = body.direction,
                targetHost = body.targetHost,
                targetPort = body.targetPort,
                label = body.label
            )
            tunnels[body.tunnelId] = tunnel
            sendEnvelope(EnvelopeTypes.TUNNEL_OPEN_RESULT, TunnelOpenResultBody(
                tunnelId = body.tunnelId,
                ok = true
            ))
            EdgeLinkLog.info("tunnel.android.open_accepted tunnelId=${body.tunnelId} target=${body.targetHost}:${body.targetPort}")
        } else {
            // Remote forward: Android listens, Mac dials
            startRemoteForward(body)
        }
    }

    private suspend fun startRemoteForward(body: TunnelOpenBody) {
        if (!allowlist.isAllowed(body.targetHost, body.targetPort)) {
            sendEnvelope(EnvelopeTypes.TUNNEL_ERROR, TunnelErrorBody(
                tunnelId = body.tunnelId,
                code = TunnelErrorCode.not_allowed,
                message = "Target not in allowlist"
            ))
            return
        }

        try {
            val serverSocket = ServerSocket(0)
            val tunnel = TunnelState(
                tunnelId = body.tunnelId,
                direction = body.direction,
                targetHost = body.targetHost,
                targetPort = body.targetPort,
                label = body.label,
                serverSocket = serverSocket
            )
            tunnels[body.tunnelId] = tunnel

            val listenPort = serverSocket.localPort
            sendEnvelope(EnvelopeTypes.TUNNEL_OPEN_RESULT, TunnelOpenResultBody(
                tunnelId = body.tunnelId,
                ok = true,
                listenPort = listenPort
            ))

            tunnel.listenJob = scope.launch(Dispatchers.IO) {
                try {
                    while (isActive) {
                        val socket = serverSocket.accept()
                        val streamId = tunnel.nextStreamId.getAndIncrement()
                        handleRemoteConnection(socket, body.tunnelId, streamId)
                    }
                } catch (_: Exception) {
                    // Server socket closed
                }
            }
            EdgeLinkLog.info("tunnel.android.remote_listen tunnelId=${body.tunnelId} port=$listenPort")
        } catch (e: Exception) {
            sendEnvelope(EnvelopeTypes.TUNNEL_ERROR, TunnelErrorBody(
                tunnelId = body.tunnelId,
                code = TunnelErrorCode.internal_error,
                message = e.message
            ))
        }
    }

    private suspend fun handleRemoteConnection(socket: Socket, tunnelId: String, streamId: Int) {
        val tunnel = tunnels[tunnelId] ?: run { socket.close(); return }
        val readJob = scope.launch(Dispatchers.IO) {
            readFromSocket(tunnelId, streamId, socket)
        }
        val stream = StreamState(socket = socket, readJob = readJob)
        tunnel.streams[streamId] = stream

        // Notify Mac about the new stream via tunnel.open (reuse as stream notification)
        sendEnvelope(EnvelopeTypes.TUNNEL_OPEN, TunnelOpenBody(
            tunnelId = tunnelId,
            direction = TunnelDirection.remote,
            targetHost = tunnel.targetHost,
            targetPort = tunnel.targetPort,
            label = "stream:$streamId"
        ))
    }

    // MARK: - Data Handling

    private suspend fun handleTunnelData(body: TunnelDataBody) {
        val tunnel = tunnels[body.tunnelId] ?: return
        var stream = tunnel.streams[body.streamId]

        if (stream == null) {
            // For local forward: first data means we need to dial the target
            if (tunnel.direction == TunnelDirection.local) {
                stream = dialTarget(tunnel, body.streamId) ?: run {
                    sendEnvelope(EnvelopeTypes.TUNNEL_ERROR, TunnelErrorBody(
                        tunnelId = body.tunnelId,
                        streamId = body.streamId,
                        code = TunnelErrorCode.target_refused,
                        message = "Cannot connect to ${tunnel.targetHost}:${tunnel.targetPort}"
                    ))
                    return
                }
            } else {
                return
            }
        }

        stream.lastActivity = System.currentTimeMillis()
        stream.recvCredit -= body.payload.length

        val data = TunnelChunker.payloadFromBase64(body.payload)
        if (data != null && data.isNotEmpty()) {
            stream.bytesIn += data.size
            try {
                stream.socket.getOutputStream().write(data)
                stream.socket.getOutputStream().flush()
            } catch (_: Exception) {
                closeStream(body.tunnelId, body.streamId)
                return
            }
        }

        if (body.fin) {
            try {
                stream.socket.shutdownOutput()
            } catch (_: Exception) {}
            stream.state = "halfClosedRemote"
        }

        // Replenish credit aggressively after every receive
        if (stream.recvCredit < TunnelConstants.INITIAL_CREDIT * 3 / 4) {
            val grant = TunnelConstants.INITIAL_CREDIT - stream.recvCredit
            stream.recvCredit = TunnelConstants.INITIAL_CREDIT
            sendEnvelope(EnvelopeTypes.TUNNEL_FLOW, TunnelFlowBody(
                tunnelId = body.tunnelId,
                streamId = body.streamId,
                credit = grant
            ))
        }
    }

    private suspend fun dialTarget(tunnel: TunnelState, streamId: Int): StreamState? {
        return try {
            val socket = Socket()
            socket.connect(InetSocketAddress(tunnel.targetHost, tunnel.targetPort), 5000)
            socket.tcpNoDelay = true
            val readJob = scope.launch(Dispatchers.IO) {
                readFromSocket(tunnel.tunnelId, streamId, socket)
            }
            val stream = StreamState(socket = socket, readJob = readJob)
            tunnel.streams[streamId] = stream
            EdgeLinkLog.info("tunnel.android.dial_ok tunnelId=${tunnel.tunnelId} stream=$streamId target=${tunnel.targetHost}:${tunnel.targetPort}")
            stream
        } catch (e: Exception) {
            EdgeLinkLog.warn("tunnel.android.dial_failed tunnelId=${tunnel.tunnelId} stream=$streamId error=${e.message}")
            null
        }
    }

    private suspend fun readFromSocket(tunnelId: String, streamId: Int, socket: Socket) {
        val buffer = ByteArray(TunnelChunker.MAX_CHUNK_SIZE)
        try {
            val input = socket.getInputStream()
            while (true) {
                val read = input.read(buffer)
                if (read <= 0) break
                val data = buffer.copyOf(read)
                val chunks = TunnelChunker.chunk(data)
                for (chunk in chunks) {
                    sendEnvelope(EnvelopeTypes.TUNNEL_DATA, TunnelDataBody(
                        tunnelId = tunnelId,
                        streamId = streamId,
                        seq = chunk.seq,
                        payload = TunnelChunker.payloadBase64(chunk.data),
                        fin = false
                    ))
                }
                val tunnel = tunnels[tunnelId]
                tunnel?.streams?.get(streamId)?.let {
                    it.bytesOut += read
                    it.lastActivity = System.currentTimeMillis()
                }
            }
            // Socket closed normally - send FIN
            sendEnvelope(EnvelopeTypes.TUNNEL_DATA, TunnelDataBody(
                tunnelId = tunnelId,
                streamId = streamId,
                seq = 0,
                payload = "",
                fin = true
            ))
        } catch (_: Exception) {
            // Socket error
        } finally {
            closeStream(tunnelId, streamId)
        }
    }

    // MARK: - Close / Error / Flow

    private suspend fun handleTunnelClose(body: TunnelCloseBody) {
        closeStream(body.tunnelId, body.streamId)
    }

    private suspend fun handleTunnelError(body: TunnelErrorBody) {
        EdgeLinkLog.warn("tunnel.android.error tunnelId=${body.tunnelId} stream=${body.streamId} code=${body.code} msg=${body.message}")
        if (body.streamId != null) {
            closeStream(body.tunnelId, body.streamId)
        }
    }

    private suspend fun handleTunnelFlow(body: TunnelFlowBody) {
        val tunnel = tunnels[body.tunnelId] ?: return
        tunnel.streams[body.streamId]?.let {
            it.sendCredit += body.credit
        }
    }

    private suspend fun handleTunnelOpenResult(body: TunnelOpenResultBody) {
        if (!body.ok) {
            EdgeLinkLog.warn("tunnel.android.open_rejected tunnelId=${body.tunnelId} error=${body.error}")
            tunnels.remove(body.tunnelId)
        }
    }

    private fun closeStream(tunnelId: String, streamId: Int) {
        val tunnel = tunnels[tunnelId] ?: return
        val stream = tunnel.streams.remove(streamId) ?: return
        stream.readJob?.cancel()
        try { stream.socket.close() } catch (_: Exception) {}
    }

    fun removeTunnel(tunnelId: String) {
        val tunnel = tunnels.remove(tunnelId) ?: return
        tunnel.listenJob?.cancel()
        try { tunnel.serverSocket?.close() } catch (_: Exception) {}
        for ((streamId, stream) in tunnel.streams) {
            stream.readJob?.cancel()
            try { stream.socket.close() } catch (_: Exception) {}
        }
        tunnel.streams.clear()
    }

    fun resetAll() {
        for (tunnelId in tunnels.keys.toList()) {
            removeTunnel(tunnelId)
        }
    }

    fun activeTunnelCount(): Int = tunnels.size

    fun activeStreamCount(): Int = tunnels.values.sumOf { it.streams.size }
}
