package com.edgelink.app

import com.edgelink.core.EnvelopeCodec
import com.edgelink.core.EnvelopeTypes
import com.edgelink.core.RelayDatagram
import com.edgelink.core.RelayDatagramBody
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.encodeToJsonElement
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import kotlin.concurrent.thread
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi

/**
 * Unit tests for [AndroidLyraRelayTransportBridge]. The phone's real Xiaomi
 * mesh/channel endpoint is stand-in'ed by a loopback UDP echo server, so the
 * bridge's relay <-> local datagram plumbing is validated without a device.
 */
class AndroidLyraRelayTransportBridgeTest {

    private fun startEchoUdpServer(): DatagramSocket {
        val server = DatagramSocket(0, InetAddress.getLoopbackAddress())
        thread(isDaemon = true) {
            val buffer = ByteArray(65_535)
            while (!server.isClosed) {
                val packet = DatagramPacket(buffer, buffer.size)
                try {
                    server.receive(packet)
                } catch (_: Exception) {
                    break
                }
                val echo = packet.data.copyOfRange(packet.offset, packet.offset + packet.length)
                try {
                    server.send(DatagramPacket(echo, echo.size, packet.address, packet.port))
                } catch (_: Exception) {
                    break
                }
            }
        }
        return server
    }

    private fun startFixedReplyUdpServer(reply: ByteArray): DatagramSocket {
        val server = DatagramSocket(0, InetAddress.getLoopbackAddress())
        thread(isDaemon = true) {
            val buffer = ByteArray(65_535)
            while (!server.isClosed) {
                val packet = DatagramPacket(buffer, buffer.size)
                try {
                    server.receive(packet)
                } catch (_: Exception) {
                    break
                }
                try {
                    server.send(DatagramPacket(reply, reply.size, packet.address, packet.port))
                } catch (_: Exception) {
                    break
                }
            }
        }
        return server
    }

    private fun waitFor(timeoutMs: Long = 3_000, condition: () -> Boolean): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (condition()) return true
            Thread.sleep(10)
        }
        return condition()
    }

    @OptIn(ExperimentalEncodingApi::class)
    private fun relayBody(datagram: ByteArray, flow: Int = 0): JsonObject =
        EnvelopeCodec.json.encodeToJsonElement(RelayDatagram.encode(datagram, flow)) as JsonObject

    @Test
    fun meshFlowStatsExposeCastDialSilenceAndRebindRecovers() = runBlocking {
        // Wrong-port scenario (2026-08-08): the mesh dial targets a dead
        // endpoint — flow 1 (cast) sends datagrams, zero inbound. The
        // watchdog reads these stats, rebinds to the next candidate, and the
        // responsive callback reports the recovered port.
        val deadEnd = DatagramSocket(0, InetAddress.getLoopbackAddress()) // never answers
        val echo = startEchoUdpServer()
        val responsivePorts = java.util.Collections.synchronizedList(mutableListOf<Int>())
        val emitted = java.util.Collections.synchronizedList(mutableListOf<ByteArray>())
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val bridge = AndroidLyraRelayTransportBridge(
            scope = scope,
            log = { },
            onMeshTargetResponsive = { responsivePorts.add(it) },
            sendEnvelope = { _, body ->
                val relayBody = body as RelayDatagramBody
                RelayDatagram.decode(relayBody)?.let { emitted.add(it) }
            }
        )
        try {
            bridge.startMesh("127.0.0.1", deadEnd.localPort)
            repeat(3) {
                bridge.handleEnvelope(EnvelopeTypes.RELAY_MESH_DATAGRAM, relayBody(byteArrayOf(0x31), flow = 1))
            }
            assertTrue("outbound should land on the dead endpoint", waitFor {
                bridge.meshFlowStats().firstOrNull { it.flowIndex == 1 }?.let { it.outboundCount > 0 } == true
            })
            Thread.sleep(200)
            val silent = bridge.meshFlowStats().first { it.flowIndex == 1 }
            assertEquals(0, silent.inboundCount)

            bridge.rebindMesh("127.0.0.1", echo.localPort)
            // Push-framed (cmd 0x51 at offset 4): only a data segment marks
            // the target responsive — bare ACKs must not.
            bridge.handleEnvelope(
                EnvelopeTypes.RELAY_MESH_DATAGRAM,
                relayBody(byteArrayOf(0x78, 0x56, 0x34, 0x12, 0x51, 0x00), flow = 1)
            )

            assertTrue("echo after rebind", waitFor {
                bridge.meshFlowStats().firstOrNull { it.flowIndex == 1 }?.let { it.inboundCount > 0 } == true
            })
            assertTrue("responsive port reported", waitFor { responsivePorts.isNotEmpty() })
            assertEquals(echo.localPort, responsivePorts.first())
        } finally {
            bridge.stop()
            deadEnd.close()
            echo.close()
            scope.cancel()
        }
    }

    @Test
    fun freshCastFlowIndexReplacesPreviousCastFlow() = runBlocking {
        // Live 2026-08-08: the first relay cast dial worked, but every
        // redial on the reused flow-1 socket got only KCP ACKs — the Xiaomi
        // mesh service ignores phys sync from a source endpoint it has seen
        // before. A new flow index (the Mac randomizes it per dial) must
        // drop the previous cast flow's socket so the redial presents a
        // fresh peer; the announcer's flow 0 stays untouched.
        val echo = startEchoUdpServer()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val bridge = AndroidLyraRelayTransportBridge(
            scope = scope,
            log = { },
            sendEnvelope = { _, _ -> }
        )
        try {
            bridge.startMesh("127.0.0.1", echo.localPort)
            bridge.handleEnvelope(EnvelopeTypes.RELAY_MESH_DATAGRAM, relayBody(byteArrayOf(0x31), flow = 1))
            assertTrue("flow 1 started", waitFor {
                bridge.meshFlowStats().firstOrNull { it.flowIndex == 1 }?.let { it.outboundCount > 0 } == true
            })
            bridge.handleEnvelope(EnvelopeTypes.RELAY_MESH_DATAGRAM, relayBody(byteArrayOf(0x32), flow = 2))
            assertTrue("flow 2 started", waitFor {
                bridge.meshFlowStats().firstOrNull { it.flowIndex == 2 }?.let { it.outboundCount > 0 } == true
            })
            assertTrue(
                "previous cast flow socket dropped",
                bridge.meshFlowStats().none { it.flowIndex == 1 }
            )
            bridge.handleEnvelope(EnvelopeTypes.RELAY_MESH_DATAGRAM, relayBody(byteArrayOf(0x33), flow = 0))
            assertTrue("announcer flow 0 survives", waitFor {
                bridge.meshFlowStats().firstOrNull { it.flowIndex == 0 }?.let { it.outboundCount > 0 } == true
            })
        } finally {
            bridge.stop()
            echo.close()
            scope.cancel()
        }
    }

    @Test
    fun probeLocksOnlyOnDataSegmentNotBareAck() = runBlocking {
        // Live 2026-08-09: wrong Lyra service sockets (37067/56666/57777)
        // answered the fan-out with bare KCP ACKs and won the probe, but
        // never answered phys sync — the cast dial timed out. Only a DATA
        // segment (cmd 0x51) may win the lock.
        val ackFrame = byteArrayOf(0x78, 0x56, 0x34, 0x12, 0x52, 0x00)
        val pushFrame = byteArrayOf(0x78, 0x56, 0x34, 0x12, 0x51, 0x00, 0x01)
        val ackOnly = startFixedReplyUdpServer(ackFrame)
        val pusher = startFixedReplyUdpServer(pushFrame)
        val responsivePorts = java.util.Collections.synchronizedList(mutableListOf<Int>())
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val bridge = AndroidLyraRelayTransportBridge(
            scope = scope,
            log = { },
            onMeshTargetResponsive = { responsivePorts.add(it) },
            sendEnvelope = { _, _ -> }
        )
        try {
            bridge.setMeshProbePorts(listOf(ackOnly.localPort, pusher.localPort))
            repeat(3) {
                bridge.handleEnvelope(
                    EnvelopeTypes.RELAY_MESH_DATAGRAM,
                    relayBody(byteArrayOf(0x78, 0x56, 0x34, 0x12, 0x51, 0x00), flow = 1)
                )
            }
            assertTrue("data-answering port wins", waitFor { responsivePorts.isNotEmpty() })
            assertEquals(pusher.localPort, responsivePorts.first())
        } finally {
            bridge.stop()
            ackOnly.close()
            pusher.close()
            scope.cancel()
        }
    }

    @Test
    fun retiredCastFlowStaysDeadOnLateDatagrams() = runBlocking {
        // Live 2026-08-09: after flow 480906435 was replaced by 735712576,
        // its late relay datagrams recreated it — the recreation killed the
        // live dial's socket and the two flows flip-flopped within 300ms.
        val echo = startEchoUdpServer()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val bridge = AndroidLyraRelayTransportBridge(
            scope = scope,
            log = { },
            sendEnvelope = { _, _ -> }
        )
        try {
            bridge.startMesh("127.0.0.1", echo.localPort)
            bridge.handleEnvelope(EnvelopeTypes.RELAY_MESH_DATAGRAM, relayBody(byteArrayOf(0x31), flow = 1))
            assertTrue("flow 1 started", waitFor {
                bridge.meshFlowStats().firstOrNull { it.flowIndex == 1 }?.let { it.outboundCount > 0 } == true
            })
            bridge.handleEnvelope(EnvelopeTypes.RELAY_MESH_DATAGRAM, relayBody(byteArrayOf(0x32), flow = 2))
            assertTrue("flow 2 started", waitFor {
                bridge.meshFlowStats().firstOrNull { it.flowIndex == 2 }?.let { it.outboundCount > 0 } == true
            })
            // Late datagram of the retired dial: must be dropped, not
            // resurrect the flow (and must not kill flow 2).
            bridge.handleEnvelope(EnvelopeTypes.RELAY_MESH_DATAGRAM, relayBody(byteArrayOf(0x33), flow = 1))
            Thread.sleep(200)
            assertTrue("retired flow stays dead", bridge.meshFlowStats().none { it.flowIndex == 1 })
            assertTrue("live flow survives", bridge.meshFlowStats().any { it.flowIndex == 2 })
        } finally {
            bridge.stop()
            echo.close()
            scope.cancel()
        }
    }

    @Test
    fun handlesOnlyRelayDatagramTypes() {        assertTrue(AndroidLyraRelayTransportBridge.handles(EnvelopeTypes.RELAY_MESH_DATAGRAM))
        assertTrue(AndroidLyraRelayTransportBridge.handles(EnvelopeTypes.RELAY_CHANNEL_DATAGRAM))
        assertFalse(AndroidLyraRelayTransportBridge.handles(EnvelopeTypes.TUNNEL_DATA))
        assertFalse(AndroidLyraRelayTransportBridge.handles("milink.status"))
    }

    @OptIn(ExperimentalEncodingApi::class)
    @Test
    fun relayDatagramWireFormatRoundTrip() {
        val datagram = byteArrayOf(0x78, 0x56, 0x34, 0x12, 0x51, 0x00, 0x00)
        val body = RelayDatagram.encode(datagram)
        assertEquals(Base64.encode(datagram), body.payload)
        val decoded = RelayDatagram.decode(body)
        assertNotNull(decoded)
        assertTrue(datagram.contentEquals(decoded))
    }

    @Test
    fun meshFlowRelaysDatagramToEndpointAndEmitsResponse() = runBlocking {
        val server = startEchoUdpServer()
        val emitted = java.util.Collections.synchronizedList(mutableListOf<Pair<String, ByteArray>>())
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val bridge = AndroidLyraRelayTransportBridge(
            scope = scope,
            log = { },
            sendEnvelope = { type, body ->
                val relayBody = body as RelayDatagramBody
                emitted.add(type to (RelayDatagram.decode(relayBody) ?: ByteArray(0)))
            }
        )
        try {
            bridge.startMesh("127.0.0.1", server.localPort)
            val payload = byteArrayOf(1, 2, 3, 4, 5)
            bridge.handleEnvelope(EnvelopeTypes.RELAY_MESH_DATAGRAM, relayBody(payload))

            assertTrue("expected the echoed datagram back over the relay", waitFor { emitted.isNotEmpty() })
            val (type, datagram) = emitted[0]
            assertEquals(EnvelopeTypes.RELAY_MESH_DATAGRAM, type)
            assertTrue(payload.contentEquals(datagram))
        } finally {
            bridge.stop()
            server.close()
            scope.cancel()
        }
    }

    @Test
    fun channelFlowIsIndependentFromMeshFlow() = runBlocking {
        val meshServer = startEchoUdpServer()
        val channelServer = startEchoUdpServer()
        val emitted = java.util.Collections.synchronizedList(mutableListOf<Pair<String, ByteArray>>())
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val bridge = AndroidLyraRelayTransportBridge(
            scope = scope,
            log = { },
            sendEnvelope = { type, body ->
                val relayBody = body as RelayDatagramBody
                emitted.add(type to (RelayDatagram.decode(relayBody) ?: ByteArray(0)))
            }
        )
        try {
            bridge.startMesh("127.0.0.1", meshServer.localPort)
            bridge.startChannel("127.0.0.1", channelServer.localPort)

            val meshPayload = byteArrayOf(10, 11, 12)
            val channelPayload = byteArrayOf(20, 21, 22)
            bridge.handleEnvelope(EnvelopeTypes.RELAY_MESH_DATAGRAM, relayBody(meshPayload))
            bridge.handleEnvelope(EnvelopeTypes.RELAY_CHANNEL_DATAGRAM, relayBody(channelPayload))

            assertTrue(
                "expected both flows to echo back",
                waitFor { emitted.size >= 2 }
            )
            val meshResponses = emitted.filter { it.first == EnvelopeTypes.RELAY_MESH_DATAGRAM }
            val channelResponses = emitted.filter { it.first == EnvelopeTypes.RELAY_CHANNEL_DATAGRAM }
            assertEquals(1, meshResponses.size)
            assertEquals(1, channelResponses.size)
            assertTrue(meshPayload.contentEquals(meshResponses[0].second))
            assertTrue(channelPayload.contentEquals(channelResponses[0].second))
        } finally {
            bridge.stop()
            meshServer.close()
            channelServer.close()
            scope.cancel()
        }
    }

    @Test
    fun meshFlowPreservesDatagramOrder() = runBlocking {
        val server = startEchoUdpServer()
        val emitted = java.util.Collections.synchronizedList(mutableListOf<ByteArray>())
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val bridge = AndroidLyraRelayTransportBridge(
            scope = scope,
            log = { },
            sendEnvelope = { _, body ->
                val relayBody = body as RelayDatagramBody
                RelayDatagram.decode(relayBody)?.let { emitted.add(it) }
            }
        )
        try {
            bridge.startMesh("127.0.0.1", server.localPort)
            val count = 40
            repeat(count) { index ->
                // Distinct first byte encodes the send position.
                bridge.handleEnvelope(
                    EnvelopeTypes.RELAY_MESH_DATAGRAM,
                    relayBody(byteArrayOf(index.toByte(), 0x42, 0x42))
                )
            }
            assertTrue(
                "expected all $count datagrams echoed back",
                waitFor(timeoutMs = 5_000) { emitted.size >= count }
            )
            for (index in 0 until count) {
                assertEquals(
                    "datagram $index out of order",
                    index.toByte(),
                    emitted[index][0]
                )
            }
        } finally {
            bridge.stop()
            server.close()
            scope.cancel()
        }
    }

    @Test
    fun deliverBeforeStartIsDropped() = runBlocking {
        val emitted = java.util.Collections.synchronizedList(mutableListOf<ByteArray>())
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val bridge = AndroidLyraRelayTransportBridge(
            scope = scope,
            log = { },
            sendEnvelope = { _, body ->
                val relayBody = body as RelayDatagramBody
                RelayDatagram.decode(relayBody)?.let { emitted.add(it) }
            }
        )
        try {
            // No startMesh/startChannel: the envelope has nowhere to go yet —
            // it is buffered, but nothing emits until a target is known.
            bridge.handleEnvelope(EnvelopeTypes.RELAY_MESH_DATAGRAM, relayBody(byteArrayOf(1, 2, 3)))
            Thread.sleep(100)
            assertTrue(emitted.isEmpty())
        } finally {
            bridge.stop()
            scope.cancel()
        }
    }

    @Test
    fun datagramsBeforeMeshTargetAreBufferedAndFlushedOnStartMesh() = runBlocking {
        // Production ordering after a relay reconnect: the Mac's cast dial
        // (flow 1) can land before the milink status re-announces the mesh
        // port. The datagrams must be buffered, not dropped, and flushed once
        // startMesh supplies the target — or the phys-sync handshake dies.
        val server = startEchoUdpServer()
        val emitted = java.util.Collections.synchronizedList(mutableListOf<RelayDatagramBody>())
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val bridge = AndroidLyraRelayTransportBridge(
            scope = scope,
            log = { },
            sendEnvelope = { _, body -> emitted.add(body as RelayDatagramBody) }
        )
        try {
            bridge.handleEnvelope(EnvelopeTypes.RELAY_MESH_DATAGRAM, relayBody(byteArrayOf(0x21), flow = 1))
            bridge.handleEnvelope(EnvelopeTypes.RELAY_MESH_DATAGRAM, relayBody(byteArrayOf(0x22), flow = 1))
            Thread.sleep(100)
            assertTrue("nothing can emit before the target is known", emitted.isEmpty())

            bridge.startMesh("127.0.0.1", server.localPort)

            assertTrue("expected buffered datagrams flushed after startMesh", waitFor { emitted.size >= 2 })
            val responses = emitted.mapNotNull { body ->
                RelayDatagram.decode(body)?.let { (body.f ?: 0) to it }
            }.filter { it.first == 1 }
            assertEquals(2, responses.size)
            assertEquals(0x21.toByte(), responses[0].second[0])
            assertEquals(0x22.toByte(), responses[1].second[0])
        } finally {
            bridge.stop()
            server.close()
            scope.cancel()
        }
    }

    @Test
    fun channelFlowBuffersUntilStampedTargetPortArrives() = runBlocking {
        // A channel datagram without a stamped port ("p") and no explicit
        // startChannel is buffered; when the first stamped envelope arrives,
        // the flow binds and flushes in order.
        val server = startEchoUdpServer()
        val emitted = java.util.Collections.synchronizedList(mutableListOf<ByteArray>())
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val bridge = AndroidLyraRelayTransportBridge(
            scope = scope,
            log = { },
            sendEnvelope = { _, body ->
                val relayBody = body as RelayDatagramBody
                RelayDatagram.decode(relayBody)?.let { emitted.add(it) }
            }
        )
        try {
            bridge.handleEnvelope(EnvelopeTypes.RELAY_CHANNEL_DATAGRAM, relayBody(byteArrayOf(40, 41)))
            Thread.sleep(100)
            assertTrue(emitted.isEmpty())

            val stamped = EnvelopeCodec.json.encodeToJsonElement(
                RelayDatagram.encode(byteArrayOf(42, 43)).copy(p = server.localPort)
            ) as JsonObject
            bridge.handleEnvelope(EnvelopeTypes.RELAY_CHANNEL_DATAGRAM, stamped)

            assertTrue("expected buffered + stamped datagrams echoed in order", waitFor { emitted.size >= 2 })
            assertEquals(40, emitted[0][0].toInt())
            assertEquals(42, emitted[1][0].toInt())
        } finally {
            bridge.stop()
            server.close()
            scope.cancel()
        }
    }

    @Test
    fun channelFlowBindsLazilyFromStampedTargetPort() = runBlocking {
        // No explicit startChannel: the channel flow must bind lazily to the
        // target port stamped ("p") on the first channel envelope — the
        // production ordering (the Mac dials the cast channel port after the
        // peer-port answer, then the negotiation datagrams flow).
        val server = startEchoUdpServer()
        val emitted = java.util.Collections.synchronizedList(mutableListOf<Pair<String, ByteArray>>())
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val bridge = AndroidLyraRelayTransportBridge(
            scope = scope,
            log = { },
            sendEnvelope = { type, body ->
                val relayBody = body as RelayDatagramBody
                emitted.add(type to (RelayDatagram.decode(relayBody) ?: ByteArray(0)))
            }
        )
        try {
            val payload = byteArrayOf(30, 31, 32)
            val body = EnvelopeCodec.json.encodeToJsonElement(
                RelayDatagram.encode(payload).copy(p = server.localPort)
            ) as JsonObject
            bridge.handleEnvelope(EnvelopeTypes.RELAY_CHANNEL_DATAGRAM, body)

            assertTrue(
                "expected the channel flow to lazy-bind and echo back",
                waitFor { emitted.isNotEmpty() }
            )
            val (type, datagram) = emitted[0]
            assertEquals(EnvelopeTypes.RELAY_CHANNEL_DATAGRAM, type)
            assertTrue(payload.contentEquals(datagram))
        } finally {
            bridge.stop()
            server.close()
            scope.cancel()
        }
    }

    @Test
    fun meshFlowIndexGetsDistinctSourcePortAndTaggedResponses() = runBlocking {
        // Echo server whose reply is the sender's source port (big-endian
        // UInt16) followed by the request payload — lets the test observe
        // which local socket each mesh flow index is presented from.
        val server = DatagramSocket(0, InetAddress.getLoopbackAddress())
        thread(isDaemon = true) {
            val buffer = ByteArray(65_535)
            while (!server.isClosed) {
                val packet = DatagramPacket(buffer, buffer.size)
                try {
                    server.receive(packet)
                } catch (_: Exception) {
                    break
                }
                val payload = packet.data.copyOfRange(packet.offset, packet.offset + packet.length)
                val reply = byteArrayOf(
                    (packet.port ushr 8).toByte(),
                    (packet.port and 0xFF).toByte()
                ) + payload
                try {
                    server.send(DatagramPacket(reply, reply.size, packet.address, packet.port))
                } catch (_: Exception) {
                    break
                }
            }
        }
        val emitted = java.util.Collections.synchronizedList(mutableListOf<RelayDatagramBody>())
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val bridge = AndroidLyraRelayTransportBridge(
            scope = scope,
            log = { },
            sendEnvelope = { _, body -> emitted.add(body as RelayDatagramBody) }
        )
        try {
            // Only flow 0 is started explicitly; flow 1 (the cast dial) starts
            // lazily against the remembered mesh target when its first
            // datagram arrives — exactly the production ordering.
            bridge.startMesh("127.0.0.1", server.localPort)
            bridge.handleEnvelope(EnvelopeTypes.RELAY_MESH_DATAGRAM, relayBody(byteArrayOf(0x11), flow = 0))
            bridge.handleEnvelope(EnvelopeTypes.RELAY_MESH_DATAGRAM, relayBody(byteArrayOf(0x22), flow = 1))

            assertTrue(
                "expected both mesh flows to echo back",
                waitFor { emitted.size >= 2 }
            )
            val responses = emitted.mapNotNull { body ->
                RelayDatagram.decode(body)?.let { (body.f ?: 0) to it }
            }
            val flow0 = responses.firstOrNull { it.first == 0 && it.second.size >= 3 && it.second[2] == 0x11.toByte() }
            val flow1 = responses.firstOrNull { it.first == 1 && it.second.size >= 3 && it.second[2] == 0x22.toByte() }
            assertNotNull("flow 0 response missing", flow0)
            assertNotNull("flow 1 response missing", flow1)
            val port0 = ((flow0!!.second[0].toInt() and 0xFF) shl 8) or (flow0.second[1].toInt() and 0xFF)
            val port1 = ((flow1!!.second[0].toInt() and 0xFF) shl 8) or (flow1.second[1].toInt() and 0xFF)
            assertTrue("each mesh flow must present its own source port", port0 != port1)
        } finally {
            bridge.stop()
            server.close()
            scope.cancel()
        }
    }

    // MARK: - responseOfPeerPort snoop + reverse channel routing

    private fun appendVarint(value: Long, to: MutableList<Byte>) {
        var remaining = value
        while (remaining > 0x7F) {
            to.add(((remaining and 0x7F) or 0x80).toByte())
            remaining = remaining ushr 7
        }
        to.add((remaining and 0x7F).toByte())
    }

    // Builds the Mac→phone mesh datagram (KCP segment wrapping a packType-5
    // plaintext responseOfPeerPort command) exactly as LyraCastTrustSession
    // emits it: peerPortResponseBody f1=clientChannelId, f3=port, f5=1.
    private fun meshDatagramWithPeerPortResponse(sn: Long, clientChannelId: Long, port: Int): ByteArray {
        val body = mutableListOf<Byte>()
        body.add(0x08) // f1 varint
        appendVarint(clientChannelId, body)
        body.add(0x18) // f3 varint
        appendVarint(port.toLong(), body)
        body.add(0x28) // f5 varint
        body.add(0x01)
        val command = mutableListOf<Byte>(0x10, 0x00, 0x03, 0x10)
        val totalLength = 16 + body.size
        command.add(((totalLength ushr 8) and 0xFF).toByte())
        command.add((totalLength and 0xFF).toByte())
        repeat(10) { command.add(0) }
        command.addAll(body)
        val framePayload = mutableListOf<Byte>(0x01, 0x00) // netId + flag=plaintext
        framePayload.addAll(command)
        val frameTotal = 4 + framePayload.size
        val frame = mutableListOf(
            (0x01 or (5 shl 3)).toByte(),
            0x04.toByte(),
            ((frameTotal ushr 8) and 0xFF).toByte(),
            (frameTotal and 0xFF).toByte()
        )
        frame.addAll(framePayload)
        val segment = mutableListOf(
            0x78.toByte(), 0x56, 0x34, 0x12,
            0x51, 0x00, 0x00, 0x10,
            0, 0, 0, 0, // tick
            (sn and 0xFF).toByte(),
            ((sn ushr 8) and 0xFF).toByte(),
            ((sn ushr 16) and 0xFF).toByte(),
            ((sn ushr 24) and 0xFF).toByte(),
            0, 0, 0, 0, // una
            (frame.size and 0xFF).toByte(),
            ((frame.size ushr 8) and 0xFF).toByte(),
            0, 0
        )
        segment.addAll(frame)
        return segment.toByteArray()
    }

    @Test
    fun announcedChannelListenBindsReverseListenerWithoutSnoop() = runBlocking {
        // Live 2026-08-13: the responseOfPeerPort snoop is loss-fragile
        // (mid-ceremony relay rebuild / reassembly gap reset) — a missed
        // snoop left no reverse listener and the phone's channel-client dial
        // went into a loopback void (562 kcp-timeout → authEvent code=1).
        // The Mac now announces the port out-of-band via relay.channel.listen
        // right before the responseOfPeerPort; the bridge must bind the
        // reverse listener from the envelope alone, no snoop involved.
        val emitted = java.util.Collections.synchronizedList(mutableListOf<RelayDatagramBody>())
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val bridge = AndroidLyraRelayTransportBridge(
            scope = scope,
            log = { },
            sendEnvelope = { _, body -> emitted.add(body as RelayDatagramBody) }
        )
        val dialedPort = 54_323
        try {
            bridge.handleEnvelope(
                EnvelopeTypes.RELAY_CHANNEL_LISTEN,
                JsonObject(mapOf("p" to kotlinx.serialization.json.JsonPrimitive(dialedPort)))
            )
            assertTrue(
                "reverse listener should be bound for the announced port",
                waitFor { bridge.reverseChannelPorts().contains(dialedPort) }
            )
            // The phone's channel client dials the advertised port; the
            // datagrams must leave stamped with p=<port> so the Mac bridge
            // routes them to its mitrust pipe.
            val client = DatagramSocket(0, InetAddress.getLoopbackAddress())
            try {
                val negotiation = byteArrayOf(0x01, 0x01, 0xCC.toByte(), 0xDD.toByte())
                client.send(DatagramPacket(negotiation, negotiation.size, InetAddress.getLoopbackAddress(), dialedPort))
                assertTrue(
                    "phone-dialed datagram should be emitted with p=$dialedPort",
                    waitFor {
                        emitted.any { body ->
                            body.p == dialedPort &&
                                (RelayDatagram.decode(body)?.contentEquals(negotiation) == true)
                        }
                    }
                )
            } finally {
                client.close()
            }
        } finally {
            bridge.stop()
            scope.cancel()
        }
    }

    @Test
    fun snoopedPeerPortBindsReverseListenerAndStampsDialedPort() = runBlocking {
        // The Mac's mitrust responseOfPeerPort crosses a mesh flow as a
        // plaintext packType-5 command; the bridge must snoop it, bind a
        // reverse listener on the advertised port, and stamp p=<port> onto
        // the phone-dialed channel datagrams so the Mac bridge can demux
        // them off the cast channel stream.
        val emitted = java.util.Collections.synchronizedList(mutableListOf<RelayDatagramBody>())
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val bridge = AndroidLyraRelayTransportBridge(
            scope = scope,
            log = { },
            sendEnvelope = { _, body -> emitted.add(body as RelayDatagramBody) }
        )
        val dialedPort = 54_321
        try {
            bridge.handleEnvelope(
                EnvelopeTypes.RELAY_MESH_DATAGRAM,
                relayBody(meshDatagramWithPeerPortResponse(sn = 0, clientChannelId = 13, port = dialedPort), flow = 1)
            )
            assertTrue(
                "reverse listener should be bound for the snooped port",
                waitFor { bridge.reverseChannelPorts().contains(dialedPort) }
            )
            // The phone's channel client dials the advertised port.
            val client = DatagramSocket(0, InetAddress.getLoopbackAddress())
            try {
                val negotiation = byteArrayOf(0x01, 0x01, 0xAA.toByte(), 0xBB.toByte())
                client.send(DatagramPacket(negotiation, negotiation.size, InetAddress.getLoopbackAddress(), dialedPort))
                assertTrue(
                    "phone-dialed datagram should be emitted with p=$dialedPort",
                    waitFor {
                        emitted.any { body ->
                            body.p == dialedPort &&
                                (RelayDatagram.decode(body)?.contentEquals(negotiation) == true)
                        }
                    }
                )
            } finally {
                client.close()
            }
        } finally {
            bridge.stop()
            scope.cancel()
        }
    }

    @Test
    fun reverseFlowDeliversMacRepliesToTheDialingClient() = runBlocking {
        val emitted = java.util.Collections.synchronizedList(mutableListOf<RelayDatagramBody>())
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val bridge = AndroidLyraRelayTransportBridge(
            scope = scope,
            log = { },
            sendEnvelope = { _, body -> emitted.add(body as RelayDatagramBody) }
        )
        val dialedPort = 54_322
        try {
            bridge.handleEnvelope(
                EnvelopeTypes.RELAY_MESH_DATAGRAM,
                relayBody(meshDatagramWithPeerPortResponse(sn = 0, clientChannelId = 13, port = dialedPort), flow = 1)
            )
            assertTrue(waitFor { bridge.reverseChannelPorts().contains(dialedPort) })
            val client = DatagramSocket(0, InetAddress.getLoopbackAddress())
            try {
                client.soTimeout = 3_000
                val hello = byteArrayOf(0x55)
                client.send(DatagramPacket(hello, hello.size, InetAddress.getLoopbackAddress(), dialedPort))
                assertTrue("client registration datagram not relayed", waitFor { emitted.isNotEmpty() })
                // Mac's reply arrives stamped with the dialed port and must
                // land back on the phone client's socket.
                val reply = byteArrayOf(0x66, 0x67)
                val body = EnvelopeCodec.json.encodeToJsonElement(
                    RelayDatagram.encode(reply, 0, p = dialedPort)
                ) as JsonObject
                bridge.handleEnvelope(EnvelopeTypes.RELAY_CHANNEL_DATAGRAM, body)
                val buffer = ByteArray(1_024)
                val packet = DatagramPacket(buffer, buffer.size)
                client.receive(packet)
                assertEquals(2, packet.length)
                assertTrue(packet.data.copyOfRange(0, 2).contentEquals(reply))
            } finally {
                client.close()
            }
        } finally {
            bridge.stop()
            scope.cancel()
        }
    }

    @Test
    fun castChannelEmissionsStayUnstampedForCompatibility() = runBlocking {
        // The Mac-dialed cast channel (no snoop involved) must keep emitting
        // without a port stamp so the Mac bridge's legacy fallback keeps
        // routing it to the cast pipe.
        val echo = startEchoUdpServer()
        val emitted = java.util.Collections.synchronizedList(mutableListOf<RelayDatagramBody>())
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val bridge = AndroidLyraRelayTransportBridge(
            scope = scope,
            log = { },
            sendEnvelope = { _, body -> emitted.add(body as RelayDatagramBody) }
        )
        try {
            val payload = byteArrayOf(0x51, 0x52)
            val body = EnvelopeCodec.json.encodeToJsonElement(
                RelayDatagram.encode(payload, 0, p = echo.localPort)
            ) as JsonObject
            bridge.handleEnvelope(EnvelopeTypes.RELAY_CHANNEL_DATAGRAM, body)
            assertTrue("cast echo should be emitted", waitFor { emitted.isNotEmpty() })
            assertTrue(emitted.all { it.p == null })
        } finally {
            bridge.stop()
            echo.close()
            scope.cancel()
        }
    }
}
