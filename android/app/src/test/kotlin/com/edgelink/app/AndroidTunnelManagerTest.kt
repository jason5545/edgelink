package com.edgelink.app

import com.edgelink.core.EnvelopeCodec
import com.edgelink.core.EnvelopeTypes
import com.edgelink.core.TunnelChunker
import com.edgelink.core.TunnelDataBody
import com.edgelink.core.TunnelDirection
import com.edgelink.core.TunnelOpenBody
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test
import java.net.InetAddress
import java.net.ServerSocket
import kotlin.concurrent.thread

/**
 * Unit tests for [AndroidTunnelManager]'s local-forward dial. The live
 * phone's Xiaomi mirror WFD RTSP listener (127.0.0.1:7236) comes up
 * asynchronously after the phone processes OPEN_MIRROR_SCREEN, so the first
 * tunnel dial can land before it listens; the dial must retry
 * connection-refused instead of tearing the stream down immediately.
 */
class AndroidTunnelManagerTest {

    private fun startEchoTcpServer(port: Int): ServerSocket {
        val server = ServerSocket(port, 50, InetAddress.getLoopbackAddress())
        thread(isDaemon = true) {
            while (!server.isClosed) {
                val client = try {
                    server.accept()
                } catch (_: Exception) {
                    break
                }
                thread(isDaemon = true) {
                    try {
                        val input = client.getInputStream()
                        val output = client.getOutputStream()
                        val buffer = ByteArray(4096)
                        while (true) {
                            val read = input.read(buffer)
                            if (read <= 0) break
                            output.write(buffer, 0, read)
                            output.flush()
                        }
                    } catch (_: Exception) {
                    } finally {
                        try { client.close() } catch (_: Exception) {}
                    }
                }
            }
        }
        return server
    }

    // Production dispatch decodes the full envelope JSON and hands the inner
    // "b" object to the manager; do the same here.
    private inline fun <reified T> bodyOf(type: String, body: T): JsonObject {
        val envelope = EnvelopeCodec.json.decodeFromString<JsonObject>(
            EnvelopeCodec.encode(type, body).decodeToString()
        )
        return envelope["b"] as JsonObject
    }

    @Test
    fun localForwardDialRetriesUntilLateListenerComesUp() = runBlocking {
        // Bind a server socket just to reserve the port, then close it: the
        // tunnel dial begins against a refused port, exactly like the live
        // phone before its RTSP listener starts.
        val placeholder = ServerSocket(0, 1, InetAddress.getLoopbackAddress())
        val port = placeholder.localPort
        placeholder.close()

        val emitted = java.util.Collections.synchronizedList(mutableListOf<Pair<String, Any>>())
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val manager = AndroidTunnelManager(
            scope = scope,
            log = { },
            sendEnvelope = { type, body -> emitted.add(type to body) }
        )
        try {
            val tunnelId = "tunnel-dial-retry"
            launch {
                manager.handleEnvelope(
                    EnvelopeTypes.TUNNEL_OPEN,
                    bodyOf(
                        EnvelopeTypes.TUNNEL_OPEN,
                        TunnelOpenBody(
                            tunnelId = tunnelId,
                            direction = TunnelDirection.local,
                            targetHost = "127.0.0.1",
                            targetPort = port,
                            label = "wfd"
                        )
                    )
                )
                // The Mac primes the stream with an empty datagram; that
                // triggers the phone-side dial while the port is refused.
                manager.handleEnvelope(
                    EnvelopeTypes.TUNNEL_DATA,
                    bodyOf(
                        EnvelopeTypes.TUNNEL_DATA,
                        TunnelDataBody(tunnelId = tunnelId, streamId = 1, seq = 0, payload = "")
                    )
                )
            }

            // The RTSP listener comes up 1.2 s later (after OPEN processing).
            delay(1_200)
            val server = startEchoTcpServer(port)

            // Now send real data; the dial must have recovered and echo it.
            val payload = "OPTIONS * RTSP/1.0"
            launch {
                manager.handleEnvelope(
                    EnvelopeTypes.TUNNEL_DATA,
                    bodyOf(
                        EnvelopeTypes.TUNNEL_DATA,
                        TunnelDataBody(
                            tunnelId = tunnelId,
                            streamId = 1,
                            seq = 1,
                            payload = TunnelChunker.payloadBase64(payload.toByteArray())
                        )
                    )
                )
            }

            val deadline = System.currentTimeMillis() + 8_000
            var echoed: String? = null
            while (System.currentTimeMillis() < deadline && echoed == null) {
                val dataEnvelope = emitted.firstOrNull { (type, _) -> type == EnvelopeTypes.TUNNEL_DATA }
                echoed = (dataEnvelope?.second as? TunnelDataBody)
                    ?.let { TunnelChunker.payloadFromBase64(it.payload)?.decodeToString() }
                    ?.takeIf { it.isNotEmpty() }
                if (echoed == null) delay(50)
            }
            assertEquals(payload, echoed)
            assertFalse(
                "dial retry must not surface a tunnel error",
                emitted.any { it.first == EnvelopeTypes.TUNNEL_ERROR }
            )
            server.close()
        } finally {
            scope.cancel()
        }
    }
}
