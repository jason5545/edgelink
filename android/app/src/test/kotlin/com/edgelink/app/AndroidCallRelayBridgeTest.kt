package com.edgelink.app

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread

/**
 * Regression tests for the Mac-issued `source_rtsp` endpoint hint consumed by
 * [AndroidCallRelayBridge]. Live 2026-09-03: MirrorCallService walks its
 * source listen port when 7102 is occupied (7102 -> 7105 -> 7108, Mirror.apk
 * `G.java` `p(int)` retries i+3), the phone's event-23 KeyData advertised
 * 7105, and the bridge burned all 30s of connect retries on the dead 7102 ->
 * ECONNREFUSED, zero downlink audio. The Mac now forwards the advertised
 * endpoint as kind=source_rtsp (dataBase64 = base64(ascii "host:port")) and
 * the bridge must dial the hinted endpoint first.
 */
class AndroidCallRelayBridgeTest {

    private fun waitFor(timeoutMs: Long = 3_000, condition: () -> Boolean): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (condition()) return true
            Thread.sleep(10)
        }
        return condition()
    }

    // A port nothing listens on: bind, read the port, close.
    private fun unusedTcpPort(): Int {
        val probe = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"))
        val port = probe.localPort
        probe.close()
        return port
    }

    private fun startAcceptor(server: ServerSocket, accepted: AtomicReference<Socket?>) {
        thread(isDaemon = true) {
            runCatching { accepted.set(server.accept()) }
        }
    }

    private fun makeBridge(
        ports: List<Int>,
        logs: CopyOnWriteArrayList<String> = CopyOnWriteArrayList()
    ): AndroidCallRelayBridge.LocalMiLinkRTSPBridge {
        val bridge = AndroidCallRelayBridge.LocalMiLinkRTSPBridge(
            relaySessionId = "test-session",
            localRtspPorts = ports,
            rtpHandler = { },
            statusHandler = { }
        )
        bridge.log = { logs += it }
        return bridge
    }

    @Test
    fun sourceRtspHintArrivingMidRetryConnectsToHintedPort() = runBlocking {
        // The retry loop is already burning rounds on the dead configured
        // port when the Mac's hint lands; it must be picked up within ~one
        // 500ms round and the TCP connect must land on the hinted port.
        val deadPort = unusedTcpPort()
        val source = ServerSocket(0, 4, InetAddress.getByName("127.0.0.1"))
        val accepted = AtomicReference<Socket?>()
        startAcceptor(source, accepted)
        val bridge = makeBridge(listOf(deadPort))
        val connect = launch(Dispatchers.IO) {
            runCatching { bridge.connectRTSPWithRetry() }
        }
        try {
            delay(700) // at least one full round against the dead port
            assertNull("nothing may connect before the hint", accepted.get())

            bridge.addSourceEndpointHint("127.0.0.1", source.localPort)

            assertTrue(
                "hint should be picked up within ~one round",
                waitFor { accepted.get() != null }
            )
            assertEquals(source.localPort, accepted.get()?.localPort)
            connect.join() // connectRTSPWithRetry returned right after connecting
            assertTrue(connect.isCompleted)
        } finally {
            connect.cancelAndJoin()
            runCatching { accepted.get()?.close() }
            runCatching { source.close() }
        }
    }

    @Test
    fun sourceRtspHintedPortIsTriedBeforeConfiguredPorts() = runBlocking {
        // The hint is authoritative: even with a live listener on the
        // configured port, the hinted port must be dialed first — and once it
        // answers, the configured port is never tried at all.
        val configured = ServerSocket(0, 4, InetAddress.getByName("127.0.0.1"))
        val hinted = ServerSocket(0, 4, InetAddress.getByName("127.0.0.1"))
        val configuredAccepted = AtomicReference<Socket?>()
        val hintedAccepted = AtomicReference<Socket?>()
        startAcceptor(configured, configuredAccepted)
        startAcceptor(hinted, hintedAccepted)
        val bridge = makeBridge(listOf(configured.localPort))
        bridge.addSourceEndpointHint("127.0.0.1", hinted.localPort)
        val connect = launch(Dispatchers.IO) {
            runCatching { bridge.connectRTSPWithRetry() }
        }
        try {
            assertTrue("hinted port accepts", waitFor { hintedAccepted.get() != null })
            Thread.sleep(300)
            assertNull(
                "configured port must not be dialed once the hint answers",
                configuredAccepted.get()
            )
        } finally {
            connect.cancelAndJoin()
            runCatching { hintedAccepted.get()?.close() }
            runCatching { configuredAccepted.get()?.close() }
            runCatching { hinted.close() }
            runCatching { configured.close() }
        }
    }

    @Test
    fun sourceRtspHintIsIgnoredWhenSourceAlreadyConnected() = runBlocking {
        // A hint arriving after the source connected must be logged and
        // ignored — no reconnect, no dial towards the hinted port.
        val primary = ServerSocket(0, 4, InetAddress.getByName("127.0.0.1"))
        val other = ServerSocket(0, 4, InetAddress.getByName("127.0.0.1"))
        val primaryAccepted = AtomicReference<Socket?>()
        val otherAccepted = AtomicReference<Socket?>()
        startAcceptor(primary, primaryAccepted)
        startAcceptor(other, otherAccepted)
        val logs = CopyOnWriteArrayList<String>()
        val bridge = makeBridge(listOf(primary.localPort), logs)
        val connect = launch(Dispatchers.IO) {
            runCatching { bridge.connectRTSPWithRetry() }
        }
        try {
            assertTrue("primary accepts", waitFor { primaryAccepted.get() != null })
            connect.join()

            bridge.addSourceEndpointHint("127.0.0.1", other.localPort)

            assertTrue(
                "hint receipt must be logged",
                logs.any {
                    it.contains("callrelay.android.local_rtsp_source_hint") &&
                        it.contains("port=${other.localPort}") &&
                        it.contains("ignored=already_connected")
                }
            )
            Thread.sleep(300)
            assertNull("no dial towards the ignored hint", otherAccepted.get())
        } finally {
            connect.cancelAndJoin()
            runCatching { primaryAccepted.get()?.close() }
            runCatching { otherAccepted.get()?.close() }
            runCatching { primary.close() }
            runCatching { other.close() }
        }
    }

    @Test
    fun sourceRtspHintIsLoggedOnReceipt() {
        val logs = CopyOnWriteArrayList<String>()
        val bridge = makeBridge(listOf(7102), logs)
        bridge.addSourceEndpointHint("127.0.0.1", 7105)
        assertTrue(
            logs.any {
                it.contains("callrelay.android.local_rtsp_source_hint") &&
                    it.contains("host=127.0.0.1") &&
                    it.contains("port=7105")
            }
        )
    }

    @Test
    fun sourceRtspHintWithInvalidPortIsRejected() {
        val logs = CopyOnWriteArrayList<String>()
        val bridge = makeBridge(listOf(7102), logs)
        bridge.addSourceEndpointHint("127.0.0.1", 0)
        assertTrue(logs.any { it.contains("callrelay.android.local_rtsp_source_hint_bad") })
    }

    @Test
    fun parseSourceRtspHintAcceptsIPv4HostPort() {
        assertEquals(
            "127.0.0.1" to 7105,
            AndroidCallRelayBridge.parseSourceRTSPEndpointHint("127.0.0.1:7105")
        )
        assertEquals(
            "192.168.1.7" to 1,
            AndroidCallRelayBridge.parseSourceRTSPEndpointHint("192.168.1.7:1")
        )
        assertNotNull(AndroidCallRelayBridge.parseSourceRTSPEndpointHint(" 127.0.0.1:7105 "))
    }

    @Test
    fun parseSourceRtspHintRejectsMalformedValues() {
        listOf(
            "",
            "127.0.0.1",
            "127.0.0.1:",
            ":7105",
            "127.0.0.1:0",
            "127.0.0.1:65536",
            "127.0.0.1:notaport",
            "127.0.0.1:7105:extra",
            "localhost:7105",
            "1.2.3:7105",
            "256.0.0.1:7105",
            "[::1]:7105"
        ).forEach { raw ->
            assertNull("must reject \"$raw\"", AndroidCallRelayBridge.parseSourceRTSPEndpointHint(raw))
        }
    }

    // -----------------------------------------------------------------
    // Live 2026-09-05 Mac-mic uplink failure regressions.
    //
    // The phone MirrorCallService sink RSTs its RTSP client connection
    // mid-call (a Mac event-25 made the phone TEARDOWN, then closed with
    // RST); the escaping SocketException killed the sink server coroutine,
    // which cancelled the whole bridge scope — downlink leg included — and
    // nothing restarted it until the next call. The sink server must also
    // negotiate the official miplaycast dialect (Mac reference:
    // LyraMirrorCallRelaySession M4 = LPCM 8 kHz mono + AESPART; the key
    // comes from the cast-channel event-23 ECDH exchange, the bridge only
    // forwards ciphertext) and rtpSummary must not sign-extend the RTP
    // version bits.
    // -----------------------------------------------------------------

    private fun startSinkServer(
        scope: CoroutineScope,
        logs: CopyOnWriteArrayList<String>,
        statuses: CopyOnWriteArrayList<String>
    ): Pair<AndroidCallRelayBridge.LocalMiLinkRTSPSinkServer, Job> {
        val server = AndroidCallRelayBridge.LocalMiLinkRTSPSinkServer(
            relaySessionId = "test-session",
            listenPort = 0, // ephemeral
            statusHandler = { statuses += it }
        )
        server.log = { logs += it }
        server.fingerprint = { "fp_test" }
        val job = scope.launch { server.run() }
        return server to job
    }

    /** Minimal blocking RTSP client speaking the phone-sink side of the dialect. */
    private class SinkClient(val socket: Socket) {
        class Message(val firstLine: String, val cseq: String, val body: String)

        private val input = socket.getInputStream()
        private val output = socket.getOutputStream()
        private var nextCSeq = 500
        private var buffer = ByteArray(0)

        fun readMessage(): Message {
            while (true) {
                val text = buffer.toString(Charsets.ISO_8859_1)
                val headerEnd = text.indexOf("\r\n\r\n")
                if (headerEnd >= 0) {
                    val headerText = text.substring(0, headerEnd)
                    val contentLength = headerText.lineSequence()
                        .map { it.trim() }
                        .firstOrNull { it.lowercase().startsWith("content-length:") }
                        ?.substringAfter(":")
                        ?.trim()
                        ?.toIntOrNull() ?: 0
                    val messageEnd = headerEnd + 4 + contentLength
                    if (text.length >= messageEnd) {
                        buffer = buffer.copyOfRange(messageEnd, buffer.size)
                        val firstLine = headerText.lineSequence().first()
                        val cseq = headerText.lineSequence()
                            .map { it.trim() }
                            .firstOrNull { it.lowercase().startsWith("cseq:") }
                            ?.substringAfter(":")
                            ?.trim()
                            .orEmpty()
                        return Message(firstLine, cseq, text.substring(headerEnd + 4, messageEnd))
                    }
                }
                val chunk = ByteArray(4096)
                val read = input.read(chunk)
                if (read < 0) {
                    throw java.io.EOFException("sink server closed the connection")
                }
                buffer += chunk.copyOf(read)
            }
        }

        fun respond(cseq: String, body: String? = null) {
            val message = buildString {
                append("RTSP/1.0 200 OK\r\nCSeq: $cseq\r\n")
                if (body != null) {
                    append("Content-Type: text/parameters\r\n")
                    append("Content-Length: ${body.toByteArray(Charsets.ISO_8859_1).size}\r\n")
                }
                append("\r\n")
                if (body != null) {
                    append(body)
                }
            }
            output.write(message.toByteArray(Charsets.ISO_8859_1))
            output.flush()
        }

        fun sendRequest(method: String, uri: String, headers: List<Pair<String, String>> = emptyList()) {
            val message = buildString {
                append("$method $uri RTSP/1.0\r\nCSeq: ${nextCSeq++}\r\n")
                for ((name, value) in headers) {
                    append("$name: $value\r\n")
                }
                append("\r\n")
            }
            output.write(message.toByteArray(Charsets.ISO_8859_1))
            output.flush()
        }
    }

    private fun connectSinkClient(port: Int): SinkClient {
        val socket = Socket()
        socket.tcpNoDelay = true
        socket.soTimeout = 5_000
        socket.connect(InetSocketAddress("127.0.0.1", port), 2_000)
        return SinkClient(socket)
    }

    private fun bindRtpCollector(received: AtomicReference<ByteArray>): DatagramSocket {
        val udp = DatagramSocket(null)
        udp.reuseAddress = true
        udp.bind(InetSocketAddress("127.0.0.1", 0))
        thread(isDaemon = true) {
            val scratch = ByteArray(2048)
            val packet = DatagramPacket(scratch, scratch.size)
            runCatching { udp.receive(packet) }
                .onSuccess {
                    received.set(packet.data.copyOfRange(packet.offset, packet.offset + packet.length))
                }
        }
        return udp
    }

    private fun makeRtpPacket(payloadBytes: Int = 188): ByteArray {
        val packet = ByteArray(12 + payloadBytes)
        packet[0] = 0x80.toByte() // RTP v2
        packet[1] = 33 // payload type MP2T
        packet[3] = 42 // sequence
        packet[6] = 0x10 // timestamp 0x00001000
        packet[8] = 0x0A
        packet[9] = 0x0B
        packet[10] = 0x0C
        packet[11] = 0x0D // SSRC
        for (index in 12 until packet.size) {
            packet[index] = (index and 0xff).toByte()
        }
        return packet
    }

    /**
     * Drives the full sink handshake (server OPTIONS -> client OPTIONS ->
     * GET_PARAMETER answered with capabilities -> SELECT_PARAMETERS ->
     * SETUP trigger -> SETUP -> PLAY) and returns the SELECT_PARAMETERS body.
     */
    private fun driveSinkHandshake(client: SinkClient, udpPort: Int): String {
        val options = client.readMessage()
        assertTrue("server opens with OPTIONS, got ${options.firstLine}", options.firstLine.startsWith("OPTIONS"))
        client.respond(options.cseq)
        // The server only sends GET_PARAMETER after the client asks OPTIONS.
        client.sendRequest("OPTIONS", "*")
        val optionsAck = client.readMessage()
        assertTrue("OPTIONS ack, got ${optionsAck.firstLine}", optionsAck.firstLine.startsWith("RTSP/"))
        val getParameter = client.readMessage()
        assertTrue(
            "GET_PARAMETER after OPTIONS, got ${getParameter.firstLine}",
            getParameter.firstLine.startsWith("GET_PARAMETER")
        )
        client.respond(
            getParameter.cseq,
            body = "wfd_client_rtp_ports: RTP/AVP/UDP;unicast $udpPort 0 mode=play\r\n"
        )
        val selectParameters = client.readMessage()
        assertTrue(
            "SELECT_PARAMETERS after capabilities, got ${selectParameters.firstLine}",
            selectParameters.firstLine.startsWith("SET_PARAMETER")
        )
        client.respond(selectParameters.cseq)
        val setupTrigger = client.readMessage()
        assertTrue(
            "SETUP trigger after SELECT_PARAMETERS, got ${setupTrigger.firstLine}",
            setupTrigger.firstLine.startsWith("SET_PARAMETER")
        )
        client.respond(setupTrigger.cseq)
        client.sendRequest(
            "SETUP",
            "rtsp://127.0.0.1/wfd1.0/streamid=0",
            listOf("Transport" to "RTP/AVP/UDP;unicast;client_port=$udpPort-${udpPort + 1}")
        )
        val setupAck = client.readMessage()
        assertTrue("SETUP ack, got ${setupAck.firstLine}", setupAck.firstLine.startsWith("RTSP/"))
        client.sendRequest("PLAY", "rtsp://127.0.0.1/wfd1.0/streamid=0")
        val playAck = client.readMessage()
        assertTrue("PLAY ack, got ${playAck.firstLine}", playAck.firstLine.startsWith("RTSP/"))
        return selectParameters.body
    }

    @Test
    fun sinkServerSurvivesClientResetAndAcceptsReconnect() = runBlocking {
        val logs = CopyOnWriteArrayList<String>()
        val statuses = CopyOnWriteArrayList<String>()
        val serverScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val (server, serverJob) = startSinkServer(serverScope, logs, statuses)
        val closables = mutableListOf<java.io.Closeable>()
        try {
            assertTrue("sink server binds an ephemeral port", waitFor { server.boundPort > 0 })

            // Client A completes the handshake and receives forwarded RTP.
            val receivedA = AtomicReference<ByteArray>()
            val udpA = bindRtpCollector(receivedA).also { closables += it }
            val clientA = connectSinkClient(server.boundPort).also { closables += it.socket }
            driveSinkHandshake(clientA, udpA.localPort)
            assertTrue("client A reaches sink_ready", waitFor { statuses.contains("sink_ready") })
            val packetA = makeRtpPacket()
            server.sendRTP(packetA)
            assertTrue("RTP is forwarded to client A", waitFor { receivedA.get() != null })
            assertTrue(receivedA.get().contentEquals(packetA))

            // The phone closes mid-call with RST (SO_LINGER 0), so the server
            // read loop sees SocketException("Connection reset"). That must
            // end only this client — never the accept loop.
            clientA.socket.setSoLinger(true, 0)
            clientA.socket.close()
            assertTrue(
                "client reset must be logged as a per-client end, got: $logs",
                waitFor { logs.any { it.contains("callrelay.android.sink_rtsp_client_ended") } }
            )
            assertTrue("sink server survives a client reset", serverJob.isActive)

            // Client B reconnects and completes the same handshake.
            val receivedB = AtomicReference<ByteArray>()
            val udpB = bindRtpCollector(receivedB).also { closables += it }
            val clientB = connectSinkClient(server.boundPort).also { closables += it.socket }
            driveSinkHandshake(clientB, udpB.localPort)
            assertTrue(
                "client B reaches sink_ready",
                waitFor { statuses.count { it == "sink_ready" } >= 2 }
            )
            val packetB = makeRtpPacket()
            server.sendRTP(packetB)
            assertTrue("RTP is forwarded to client B", waitFor { receivedB.get() != null })
            assertTrue(receivedB.get().contentEquals(packetB))
        } finally {
            closables.forEach { runCatching { it.close() } }
            serverJob.cancelAndJoin()
            server.close()
            serverScope.cancel()
        }
    }

    @Test
    fun sinkServerNegotiatesOfficialMirrorCallDialect() = runBlocking {
        val logs = CopyOnWriteArrayList<String>()
        val statuses = CopyOnWriteArrayList<String>()
        val serverScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val (server, serverJob) = startSinkServer(serverScope, logs, statuses)
        val closables = mutableListOf<java.io.Closeable>()
        try {
            assertTrue("sink server binds an ephemeral port", waitFor { server.boundPort > 0 })
            val udp = DatagramSocket(null).apply {
                reuseAddress = true
                bind(InetSocketAddress("127.0.0.1", 0))
            }.also { closables += it }
            val client = connectSinkClient(server.boundPort).also { closables += it.socket }

            val selectBody = driveSinkHandshake(client, udp.localPort)
            val lines = selectBody.lines().map { it.trim() }.filter { it.isNotEmpty() }
            assertTrue(
                "SELECT_PARAMETERS must pick LPCM 8 kHz mono, got: $selectBody",
                lines.any { it == "wfd_audio_codecs_v2: 0 3" }
            )
            assertTrue(
                "SELECT_PARAMETERS must pick AESPART encryption, got: $selectBody",
                lines.any { it == "wfd_type_encryp: 4 1 1 1 1" }
            )
            assertTrue(
                "no legacy wfd_audio_codecs line, got: $selectBody",
                lines.none { it.startsWith("wfd_audio_codecs:") }
            )
            assertTrue(
                "no wfd_content_protection line, got: $selectBody",
                lines.none { it.startsWith("wfd_content_protection") }
            )
            assertTrue(
                "client rtp ports kept, got: $selectBody",
                lines.any { it.startsWith("wfd_client_rtp_ports:") && it.contains(" ${udp.localPort} ") }
            )
            assertTrue(
                "presentation url kept, got: $selectBody",
                lines.any { it.startsWith("wfd_presentation_url:") }
            )
        } finally {
            closables.forEach { runCatching { it.close() } }
            serverJob.cancelAndJoin()
            server.close()
            serverScope.cancel()
        }
    }

    @Test
    fun rtpSummaryTreatsHighBitFirstByteAsRTP() {
        val summary = rtpSummary(makeRtpPacket())
        assertTrue(
            "0x80 first byte is RTP v2, got: $summary",
            summary.startsWith("format=rtp pt=33 seq=42 ")
        )
        assertEquals("format=unknown", rtpSummary(ByteArray(200)))
    }
}
