package com.edgelink.app

import com.edgelink.core.PhoneActionBody
import com.edgelink.core.PhoneRelayMediaBody
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.BufferedWriter
import java.io.ByteArrayOutputStream
import java.io.OutputStreamWriter
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.nio.charset.Charset
import java.util.Base64
import kotlin.math.abs

object AndroidCallRelayBridge {
    private const val DEFAULT_LOCAL_RTSP_PORT = 7_102
    private const val DEFAULT_LOCAL_SINK_RTSP_PORT = 15_550
    private const val ANDROID_TO_MAC = "android_to_mac"
    private const val MAC_TO_ANDROID = "mac_to_android"

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val lifecycleMutex = Mutex()
    private var activeJob: Job? = null
    private var activeSessionId: String? = null
    private var activeSession: AndroidCallRelayBridgeSession? = null

    fun start(
        body: PhoneActionBody,
        reason: String,
        sendMedia: suspend (PhoneRelayMediaBody) -> Unit
    ) {
        val relaySessionId = body.relaySessionId?.trim()?.takeIf { it.isNotEmpty() }
        val localRtspPorts = listOfNotNull(
            body.relayPort?.takeIf { it in 1..65_535 },
            DEFAULT_LOCAL_RTSP_PORT
        ).distinct()
        if (relaySessionId == null) {
            EdgeLinkLog.info("callrelay.android.bridge_skip reason=$reason missing_session")
            return
        }

        scope.launch {
            lifecycleMutex.withLock {
                if (activeSessionId == relaySessionId && activeJob?.isActive == true) {
                    EdgeLinkLog.info("callrelay.android.bridge_reuse sessionId=$relaySessionId reason=$reason")
                    return@withLock
                }
                activeJob?.cancelAndJoin()
                activeSessionId = relaySessionId
                val relaySession = AndroidCallRelayBridgeSession(
                    relaySessionId = relaySessionId,
                    localRtspPorts = localRtspPorts,
                    startReason = reason,
                    sendMedia = sendMedia
                )
                activeSession = relaySession
                activeJob = launch {
                    relaySession.run()
                }
            }
        }
    }

    suspend fun handleMedia(body: PhoneRelayMediaBody) {
        if (body.direction != MAC_TO_ANDROID || body.kind != "rtp") {
            return
        }
        val session = activeSession
        if (session == null || body.sessionId != activeSessionId) {
            EdgeLinkLog.info(
                "callrelay.android.media_ignored sessionId=${body.sessionId} " +
                    "active=${activeSessionId ?: "none"} direction=${body.direction} kind=${body.kind}"
            )
            return
        }
        session.acceptSourceRTP(body)
    }

    fun stop(reason: String) {
        scope.launch {
            lifecycleMutex.withLock {
                val sessionId = activeSessionId
                activeSessionId = null
                activeSession = null
                activeJob?.cancelAndJoin()
                activeJob = null
                if (sessionId != null) {
                    EdgeLinkLog.info("callrelay.android.bridge_stop sessionId=$sessionId reason=$reason")
                }
            }
        }
    }

    private class AndroidCallRelayBridgeSession(
        private val relaySessionId: String,
        localRtspPorts: List<Int>,
        private val startReason: String,
        private val sendMedia: suspend (PhoneRelayMediaBody) -> Unit
    ) {
        private var bridgeRtpPackets = 0
        private var sourceRtpPackets = 0
        private val localBridge = LocalMiLinkRTSPBridge(
            relaySessionId = relaySessionId,
            localRtspPorts = localRtspPorts,
            rtpHandler = ::sendBridgeRTP,
            statusHandler = ::sendStatus
        )

        suspend fun run() {
            sendStatus("bridge_starting")
            try {
                localBridge.run()
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                EdgeLinkLog.warn(
                    "callrelay.android.bridge_failed sessionId=$relaySessionId reason=$startReason " +
                        "error=${error.javaClass.simpleName}:${error.message.orEmpty()}",
                    error
                )
                sendStatus("bridge_failed")
            } finally {
                sendStatus("source_stop")
                sendStatus("bridge_stopped")
            }
        }

        suspend fun acceptSourceRTP(body: PhoneRelayMediaBody) {
            val packet = body.dataBase64
                ?.takeIf { it.isNotEmpty() }
                ?.let { runCatching { Base64.getDecoder().decode(it) }.getOrNull() }
            sourceRtpPackets += 1
            if (sourceRtpPackets == 1 || sourceRtpPackets % 100 == 0) {
                EdgeLinkLog.info(
                    "callrelay.android.source_rtp_cloudflare_in sessionId=$relaySessionId " +
                        "count=$sourceRtpPackets bytes=${body.bytes ?: -1} decoded=${packet?.size ?: -1}"
                )
            }
            if (packet == null) {
                EdgeLinkLog.warn(
                    "callrelay.android.source_rtp_cloudflare_invalid sessionId=$relaySessionId " +
                        "count=$sourceRtpPackets"
                )
                return
            }
            localBridge.sendSourceRTP(packet)
        }

        private suspend fun sendBridgeRTP(packet: ByteArray) {
            bridgeRtpPackets += 1
            if (bridgeRtpPackets == 1 || bridgeRtpPackets % 100 == 0) {
                EdgeLinkLog.info(
                    "callrelay.android.rtp_cloudflare_out sessionId=$relaySessionId " +
                        "count=$bridgeRtpPackets bytes=${packet.size} fp=${EdgeLinkLog.fingerprint(packet)}"
                )
            }
            sendMedia(
                PhoneRelayMediaBody(
                    sessionId = relaySessionId,
                    direction = ANDROID_TO_MAC,
                    kind = "rtp",
                    dataBase64 = Base64.getEncoder().encodeToString(packet),
                    bytes = packet.size,
                    sequence = bridgeRtpPackets,
                    ts = System.currentTimeMillis()
                )
            )
        }

        private suspend fun sendStatus(event: String) {
            sendMedia(
                PhoneRelayMediaBody(
                    sessionId = relaySessionId,
                    direction = ANDROID_TO_MAC,
                    kind = "status",
                    event = event,
                    ts = System.currentTimeMillis()
                )
            )
        }
    }

    private class LocalMiLinkRTSPBridge(
        private val relaySessionId: String,
        private val localRtspPorts: List<Int>,
        private val rtpHandler: suspend (ByteArray) -> Unit,
        private val statusHandler: suspend (String) -> Unit
    ) {
        private val pendingRequests = mutableMapOf<String, String>()
        private val rtspCharset: Charset = Charsets.ISO_8859_1
        private val sinkServer = LocalMiLinkRTSPSinkServer(
            relaySessionId = relaySessionId,
            listenPort = DEFAULT_LOCAL_SINK_RTSP_PORT,
            statusHandler = statusHandler
        )
        private var socket: Socket? = null
        private var writer: BufferedWriter? = null
        private var udpSocket: DatagramSocket? = null
        private var tcpBuffer = ByteArray(0)
        private var nextCSeq = 1
        private var sentOptions = false
        private var sentSinkSETUP = false
        private var sentPLAY = false
        private var sessionHeader: String? = null
        private var presentationURL: String? = null
        private var rtpPackets = 0

        suspend fun run() = coroutineScope {
            val sinkServerJob = launch { sinkServer.run() }
            val udp = DatagramSocket(null).apply {
                reuseAddress = true
                soTimeout = 2_000
                bind(InetSocketAddress(0))
            }
            udpSocket = udp
            EdgeLinkLog.info("callrelay.android.local_rtp_ready port=${udp.localPort}")
            val udpJob = launch { receiveRTP(udp) }
            try {
                while (currentCoroutineContext().isActive) {
                    try {
                        resetSourceControlState()
                        connectRTSPWithRetry()
                        statusHandler("local_rtsp_connected")
                        statusHandler("bridge_ready")
                        readRTSPLoop()
                    } catch (error: CancellationException) {
                        throw error
                    } catch (error: Throwable) {
                        EdgeLinkLog.info(
                            "callrelay.android.local_rtsp_retry sessionId=$relaySessionId " +
                                "error=${error.javaClass.simpleName}:${error.message.orEmpty()}"
                        )
                    } finally {
                        runCatching { writer?.close() }
                        runCatching { socket?.close() }
                        writer = null
                        socket = null
                    }
                    if (currentCoroutineContext().isActive) {
                        delay(200)
                    }
                }
            } finally {
                udpJob.cancel()
                sinkServerJob.cancel()
                sinkServer.close()
                runCatching { udp.close() }
                writer = null
                socket = null
                udpSocket = null
                EdgeLinkLog.info("callrelay.android.local_rtsp_closed")
            }
        }

        suspend fun sendSourceRTP(packet: ByteArray) {
            sinkServer.sendRTP(packet)
        }

        private fun resetSourceControlState() {
            pendingRequests.clear()
            tcpBuffer = ByteArray(0)
            nextCSeq = 1
            sentOptions = false
            sentSinkSETUP = false
            sentPLAY = false
            sessionHeader = null
            presentationURL = null
        }

        private suspend fun connectRTSPWithRetry() {
            val deadline = System.currentTimeMillis() + 30_000L
            var attempt = 0
            var lastError: Throwable? = null
            while (currentCoroutineContext().isActive && System.currentTimeMillis() < deadline) {
                attempt += 1
                for (port in localRtspPorts) {
                    for (host in localRTSPHostCandidates()) {
                        try {
                            val nextSocket = Socket()
                            try {
                                nextSocket.tcpNoDelay = true
                                nextSocket.keepAlive = true
                                nextSocket.soTimeout = 2_000
                                nextSocket.connect(InetSocketAddress(host, port), 1_500)
                                nextSocket.soTimeout = 2_000
                                socket = nextSocket
                                writer = BufferedWriter(OutputStreamWriter(nextSocket.getOutputStream(), rtspCharset))
                                EdgeLinkLog.info(
                                    "callrelay.android.local_rtsp_connected host=$host port=$port attempt=$attempt"
                                )
                                return
                            } catch (error: Throwable) {
                                runCatching { nextSocket.close() }
                                throw error
                            }
                        } catch (error: Throwable) {
                            lastError = error
                            EdgeLinkLog.info(
                                "callrelay.android.local_rtsp_connect_failed host=$host port=$port " +
                                    "attempt=$attempt error=${error.javaClass.simpleName}:${error.message.orEmpty()}"
                            )
                        }
                    }
                }
                delay(500)
            }
            throw lastError ?: IllegalStateException("MiLink local RTSP listener was not reachable.")
        }

        private suspend fun readRTSPLoop() {
            val input = checkNotNull(socket).getInputStream()
            val scratch = ByteArray(4096)
            while (currentCoroutineContext().isActive) {
                val read = try {
                    withContext(Dispatchers.IO) { input.read(scratch) }
                } catch (_: SocketTimeoutException) {
                    continue
                }
                if (read < 0) {
                    return
                }
                if (read > 0) {
                    processTCPData(scratch.copyOf(read))
                }
            }
        }

        private suspend fun receiveRTP(socket: DatagramSocket) {
            val buffer = ByteArray(16 * 1024)
            while (currentCoroutineContext().isActive) {
                val packet = DatagramPacket(buffer, buffer.size)
                try {
                    withContext(Dispatchers.IO) { socket.receive(packet) }
                } catch (error: Throwable) {
                    if (currentCoroutineContext().isActive && error !is SocketTimeoutException) {
                        EdgeLinkLog.warn("callrelay.android.local_rtp_receive_failed", error)
                    }
                    if (error is SocketTimeoutException) {
                        continue
                    }
                    return
                }
                if (isSelfEcho(packet, socket)) {
                    if (rtpPackets == 0) {
                        EdgeLinkLog.warn(
                            "callrelay.android.local_rtp_self_echo_ignored sessionId=$relaySessionId " +
                                "from=${packet.address.hostAddress}:${packet.port} localPort=${socket.localPort}"
                        )
                    }
                    continue
                }
                val data = packet.data.copyOfRange(packet.offset, packet.offset + packet.length)
                rtpPackets += 1
                if (rtpPackets == 1 || rtpPackets % 100 == 0) {
                    EdgeLinkLog.info(
                        "callrelay.android.local_rtp_in count=$rtpPackets from=${packet.address.hostAddress}:${packet.port} " +
                            "bytes=${data.size} ${rtpSummary(data)} fp=${EdgeLinkLog.fingerprint(data)}"
                    )
                }
                rtpHandler(data)
            }
        }

        private suspend fun processTCPData(data: ByteArray) {
            tcpBuffer += data
            while (true) {
                val headerEnd = tcpBuffer.indexOf(CRLFCRLF)
                if (headerEnd < 0) {
                    return
                }
                val headerText = tcpBuffer.copyOfRange(0, headerEnd + CRLFCRLF.size).toString(rtspCharset)
                val contentLength = rtspHeader("Content-Length", headerText)?.toIntOrNull()?.coerceAtLeast(0) ?: 0
                val messageEnd = headerEnd + CRLFCRLF.size + contentLength
                if (tcpBuffer.size < messageEnd) {
                    return
                }
                val message = tcpBuffer.copyOfRange(0, messageEnd).toString(rtspCharset)
                tcpBuffer = tcpBuffer.copyOfRange(messageEnd, tcpBuffer.size)
                handleRTSPMessage(message)
            }
        }

        private suspend fun handleRTSPMessage(message: String) {
            val headerText = message.substringBefore("\r\n\r\n")
            val bodyText = message.substringAfter("\r\n\r\n", "")
            val firstLine = headerText.lineSequence().firstOrNull().orEmpty()
            val cseq = rtspHeader("CSeq", headerText) ?: "?"
            EdgeLinkLog.info(
                "callrelay.android.local_rtsp_message dir=in firstLine=${firstLine.forRTSPLog()} " +
                    "cseq=${cseq.forRTSPLog()} bytes=${message.toByteArray(rtspCharset).size}"
            )
            if (bodyText.isNotBlank()) {
                EdgeLinkLog.info(
                    "callrelay.android.local_rtsp_body dir=in firstLine=${firstLine.forRTSPLog()} " +
                        "preview=${bodyText.forRTSPLog()}"
                )
            }
            if (firstLine.uppercase().startsWith("RTSP/")) {
                handleRTSPResponse(firstLine, headerText, cseq)
                return
            }
            when (rtspRequestMethod(firstLine)) {
                "OPTIONS" -> {
                    sendRTSPResponse(
                        cseq = cseq,
                        headers = listOf(
                            "Public" to "org.wfa.wfd1.0, SETUP, TEARDOWN, PLAY, PAUSE, GET_PARAMETER, SET_PARAMETER",
                            "fastRTSPVersion" to "0"
                        )
                    )
                    sendOptionsIfNeeded("peer_options")
                }
                "GET_PARAMETER" -> {
                    sendRTSPResponse(
                        cseq = cseq,
                        headers = listOf("Content-Type" to "text/parameters"),
                        body = wfdParameterResponseBody(bodyText)
                    )
                }
                "SET_PARAMETER" -> {
                    recordPresentationURL(bodyText)
                    sendRTSPResponse(cseq)
                    if (bodyText.contains("wfd_trigger_method: SETUP", ignoreCase = true)) {
                        sendSinkSETUPIfNeeded("trigger_setup")
                    }
                }
                "SETUP" -> {
                    sessionHeader = sessionHeader ?: abs((firstLine + System.nanoTime()).hashCode()).toString()
                    sendRTSPResponse(
                        cseq = cseq,
                        headers = listOf(
                            "Session" to checkNotNull(sessionHeader),
                            "Transport" to setupResponseTransport(headerText)
                        )
                    )
                }
                "PLAY" -> {
                    sendRTSPResponse(cseq)
                    statusHandler("source_start")
                }
                "PAUSE", "TEARDOWN" -> {
                    sendRTSPResponse(cseq)
                    statusHandler("source_stop")
                }
                else -> sendRTSPResponse(cseq)
            }
        }

        private suspend fun handleRTSPResponse(firstLine: String, headerText: String, cseq: String) {
            val requestMethod = pendingRequests.remove(cseq)
            rtspHeader("Session", headerText)
                ?.substringBefore(";")
                ?.trim()
                ?.takeIf { it.isNotEmpty() }
                ?.let { sessionHeader = it }
            val status = rtspStatusCode(firstLine)
            if (status != null && status >= 300) {
                EdgeLinkLog.warn(
                    "callrelay.android.local_rtsp_non_success request=$requestMethod " +
                        "status=$status firstLine=${firstLine.forRTSPLog()}"
                )
            }
            when (requestMethod) {
                "SETUP" -> if (status == null || status < 300) sendPLAYIfNeeded("setup_response")
                "PLAY" -> if (status == null || status < 300) statusHandler("source_start")
            }
        }

        private suspend fun sendOptionsIfNeeded(reason: String) {
            if (sentOptions) {
                return
            }
            sentOptions = true
            sendRTSPRequest(
                method = "OPTIONS",
                uri = "*",
                headers = listOf(
                    "Require" to "org.wfa.wfd1.0",
                    "lib_version" to "edgelink_android_bridge",
                    "fastRTSPVersion" to "0"
                ),
                label = "options_$reason"
            )
        }

        private suspend fun sendSinkSETUPIfNeeded(reason: String) {
            if (sentSinkSETUP) {
                return
            }
            sentSinkSETUP = true
            val port = checkNotNull(udpSocket).localPort
            sendRTSPRequest(
                method = "SETUP",
                uri = presentationURL ?: "rtsp://localhost/wfd1.0/streamid=0",
                headers = listOf("Transport" to "RTP/AVP/UDP;unicast;client_port=$port-${port + 1}"),
                label = "sink_setup_$reason"
            )
        }

        private suspend fun sendPLAYIfNeeded(reason: String) {
            if (sentPLAY) {
                return
            }
            sentPLAY = true
            val headers = sessionHeader?.let { listOf("Session" to it) } ?: emptyList()
            sendRTSPRequest(
                method = "PLAY",
                uri = presentationURL ?: "rtsp://localhost/wfd1.0/streamid=0",
                headers = headers,
                label = "play_$reason"
            )
        }

        private suspend fun sendRTSPResponse(
            cseq: String,
            headers: List<Pair<String, String>> = emptyList(),
            body: String? = null
        ) {
            sendRTSP(
                buildRTSPMessage(
                    firstLine = "RTSP/1.0 200 OK",
                    headers = listOf(
                        "Date" to java.util.Date().toString(),
                        "User-Agent" to "EdgeLinkAndroidBridge",
                        "CSeq" to cseq
                    ) + headers,
                    body = body
                ),
                label = "response"
            )
        }

        private suspend fun sendRTSPRequest(
            method: String,
            uri: String,
            headers: List<Pair<String, String>> = emptyList(),
            body: String? = null,
            label: String
        ) {
            val cseq = nextCSeq++.toString()
            pendingRequests[cseq] = method
            sendRTSP(
                buildRTSPMessage(
                    firstLine = "$method $uri RTSP/1.0",
                    headers = listOf(
                        "Date" to java.util.Date().toString(),
                        "Server" to "EdgeLinkAndroidBridge",
                        "CSeq" to cseq
                    ) + headers,
                    body = body
                ),
                label = label
            )
        }

        private suspend fun sendRTSP(message: String, label: String) {
            val firstLine = message.substringBefore("\r\n")
            EdgeLinkLog.info(
                "callrelay.android.local_rtsp_message dir=out firstLine=${firstLine.forRTSPLog()} " +
                    "label=$label bytes=${message.toByteArray(rtspCharset).size}"
            )
            withContext(Dispatchers.IO) {
                val activeWriter = checkNotNull(writer)
                activeWriter.write(message)
                activeWriter.flush()
            }
        }

        private fun wfdParameterResponseBody(requestBody: String): String {
            val requested = requestBody
                .lineSequence()
                .map { it.trim() }
                .filter { it.isNotEmpty() }
                .map { it.substringBefore(":") }
                .toSet()
            val rtpPort = udpSocket?.localPort ?: 0
            val parameters = listOf(
                "wfd_video_formats" to "none",
                "wfd_video_bitrate" to "none",
                "wfd_video_enctype" to "none",
                "wfd_video_gamuttype" to "none",
                "wfd_current_video_info" to "none",
                "wfd_audio_codecs" to "AAC 00000001 00",
                "audio_sample_time_ms" to "20",
                "wfd_client_rtp_ports" to "RTP/AVP/UDP;unicast $rtpPort 0 mode=play",
                "wfd_content_protection" to "none",
                "wfd_content_SP_protection" to "0 0 0 0 0 0 0 0",
                "wfd_mirror_control_enable" to "enable",
                "wfd_support_secure_win" to "enable",
                "wfd_standby_resume_capability" to "supported",
                "wfd_mpt_enable" to "none",
                "wfd_tcp_enable" to "none",
                "wfd_tcp_multi_session_enable" to "none",
                "wfd_image_enable_v2" to "none",
                "wfd_slice_codec" to "none",
                "wfd_delay_test_enable" to "enable",
                "wfd_connector_type" to "07"
            )
            return parameters
                .filter { (name, _) ->
                    requested.isEmpty() || name in requested || (name == "wfd_audio_codecs" && "wfd_audio_codecs_v2" in requested)
                }
                .joinToString("\r\n") { (name, value) -> "$name: $value" } + "\r\n"
        }

        private fun recordPresentationURL(bodyText: String) {
            val value = bodyText
                .lineSequence()
                .firstOrNull { it.trim().startsWith("wfd_presentation_url:", ignoreCase = true) }
                ?.substringAfter(":", "")
                ?.trim()
                ?.substringBefore(" ")
                ?.takeIf { it.isNotEmpty() }
            if (value != null) {
                presentationURL = value
                EdgeLinkLog.info("callrelay.android.local_rtsp_presentation_url url=${value.forRTSPLog()}")
            }
        }

        private fun rtspPeerHost(): String? =
            socket?.inetAddress?.hostAddress
                ?: presentationURL
                    ?.substringAfter("rtsp://", "")
                    ?.substringBefore("/")
                    ?.substringBefore(":")
                    ?.takeIf { it.isNotEmpty() }

        private fun isSelfEcho(packet: DatagramPacket, socket: DatagramSocket): Boolean =
            packet.port == socket.localPort &&
                (packet.address.isLoopbackAddress || packet.address.hostAddress == rtspPeerHost())

        private fun setupResponseTransport(headerText: String): String {
            val transport = rtspHeader("Transport", headerText).orEmpty()
            val clientPort = rtspTransportValue("client_port", transport)
            return if (clientPort != null) {
                "RTP/AVP/UDP;unicast;client_port=$clientPort;server_port=${udpSocket?.localPort ?: 0}-${(udpSocket?.localPort ?: 0) + 1}"
            } else {
                "RTP/AVP/UDP;unicast;server_port=${udpSocket?.localPort ?: 0}-${(udpSocket?.localPort ?: 0) + 1}"
            }
        }

        private fun buildRTSPMessage(
            firstLine: String,
            headers: List<Pair<String, String>>,
            body: String?
        ): String {
            val finalHeaders = if (body == null) {
                headers
            } else {
                headers + ("Content-Length" to body.toByteArray(Charsets.UTF_8).size.toString())
            }
            return buildString {
                append(firstLine)
                for ((name, value) in finalHeaders) {
                    append("\r\n")
                    append(name)
                    append(": ")
                    append(value)
                }
                append("\r\n\r\n")
                if (body != null) {
                    append(body)
                }
            }
        }
    }

    private class LocalMiLinkRTSPSinkServer(
        private val relaySessionId: String,
        private val listenPort: Int,
        private val statusHandler: suspend (String) -> Unit
    ) {
        private val sendMutex = Mutex()
        private val pendingRTP = ArrayDeque<ByteArray>()
        private val pendingRequests = mutableMapOf<String, String>()
        private val rtspCharset: Charset = Charsets.ISO_8859_1
        private var serverSocket: ServerSocket? = null
        private var socket: Socket? = null
        private var writer: BufferedWriter? = null
        private var udpSocket: DatagramSocket? = null
        private var destination: InetSocketAddress? = null
        private var tcpBuffer = ByteArray(0)
        private var nextCSeq = 1
        private var sentOptions = false
        private var sentGetParameters = false
        private var sentSelectedParameters = false
        private var sentSetupTrigger = false
        private var sessionHeader: String? = null
        private var playing = false
        private var rtpPackets = 0
        private var bufferedPackets = 0
        private var droppedPackets = 0

        suspend fun run() = coroutineScope {
            val server = ServerSocket().apply {
                reuseAddress = true
                soTimeout = 2_000
                bind(InetSocketAddress(listenPort))
            }
            serverSocket = server
            EdgeLinkLog.info(
                "callrelay.android.sink_rtsp_listening sessionId=$relaySessionId " +
                    "host=0.0.0.0 port=$listenPort"
            )
            statusHandler("sink_rtsp_listening")
            try {
                while (currentCoroutineContext().isActive) {
                    val client = try {
                        withContext(Dispatchers.IO) { server.accept() }
                    } catch (_: SocketTimeoutException) {
                        continue
                    }
                    handleClient(client)
                }
            } finally {
                close()
                EdgeLinkLog.info("callrelay.android.sink_rtsp_closed sessionId=$relaySessionId")
            }
        }

        fun close() {
            runCatching { writer?.close() }
            runCatching { socket?.close() }
            runCatching { udpSocket?.close() }
            runCatching { serverSocket?.close() }
            writer = null
            socket = null
            udpSocket = null
            serverSocket = null
        }

        suspend fun sendRTP(packet: ByteArray) {
            sendMutex.withLock {
                val udp = udpSocket
                val target = destination
                if (!playing || udp == null || udp.isClosed || target == null) {
                    bufferRTPLocked(packet, when {
                        target == null -> "missing_destination"
                        !playing -> "waiting_for_play"
                        else -> "missing_socket"
                    })
                    return
                }
                sendRTPLocked(udp, target, packet)
            }
        }

        private suspend fun handleClient(client: Socket) {
            client.tcpNoDelay = true
            client.keepAlive = true
            client.soTimeout = 2_000
            socket = client
            writer = BufferedWriter(OutputStreamWriter(client.getOutputStream(), rtspCharset))
            val udp = DatagramSocket(null).apply {
                reuseAddress = true
                bind(InetSocketAddress(0))
            }
            udpSocket = udp
            resetControlState()
            EdgeLinkLog.info(
                "callrelay.android.sink_rtsp_connected sessionId=$relaySessionId " +
                    "from=${client.inetAddress.hostAddress}:${client.port} rtpSourcePort=${udp.localPort}"
            )
            statusHandler("sink_rtsp_connected")
            try {
                sendOptionsIfNeeded()
                readLoop(client)
            } finally {
                sendMutex.withLock {
                    playing = false
                    destination = null
                }
                runCatching { writer?.close() }
                runCatching { client.close() }
                runCatching { udp.close() }
                writer = null
                socket = null
                udpSocket = null
                EdgeLinkLog.info("callrelay.android.sink_rtsp_disconnected sessionId=$relaySessionId")
                statusHandler("sink_rtsp_disconnected")
            }
        }

        private fun resetControlState() {
            pendingRequests.clear()
            tcpBuffer = ByteArray(0)
            nextCSeq = 1
            sentOptions = false
            sentGetParameters = false
            sentSelectedParameters = false
            sentSetupTrigger = false
            sessionHeader = null
            playing = false
            destination = null
        }

        private suspend fun readLoop(client: Socket) {
            val input = client.getInputStream()
            val scratch = ByteArray(4096)
            while (currentCoroutineContext().isActive && !client.isClosed) {
                val read = try {
                    withContext(Dispatchers.IO) { input.read(scratch) }
                } catch (_: SocketTimeoutException) {
                    continue
                }
                if (read < 0) {
                    return
                }
                if (read > 0) {
                    processTCPData(scratch.copyOf(read))
                }
            }
        }

        private suspend fun processTCPData(data: ByteArray) {
            tcpBuffer += data
            while (true) {
                val headerEnd = tcpBuffer.indexOf(CRLFCRLF)
                if (headerEnd < 0) {
                    return
                }
                val headerText = tcpBuffer.copyOfRange(0, headerEnd + CRLFCRLF.size).toString(rtspCharset)
                val contentLength = rtspHeader("Content-Length", headerText)?.toIntOrNull()?.coerceAtLeast(0) ?: 0
                val messageEnd = headerEnd + CRLFCRLF.size + contentLength
                if (tcpBuffer.size < messageEnd) {
                    return
                }
                val message = tcpBuffer.copyOfRange(0, messageEnd).toString(rtspCharset)
                tcpBuffer = tcpBuffer.copyOfRange(messageEnd, tcpBuffer.size)
                handleRTSPMessage(message)
            }
        }

        private suspend fun handleRTSPMessage(message: String) {
            val headerText = message.substringBefore("\r\n\r\n")
            val bodyText = message.substringAfter("\r\n\r\n", "")
            val firstLine = headerText.lineSequence().firstOrNull().orEmpty()
            val cseq = rtspHeader("CSeq", headerText) ?: "?"
            EdgeLinkLog.info(
                "callrelay.android.sink_rtsp_message dir=in firstLine=${firstLine.forRTSPLog()} " +
                    "cseq=${cseq.forRTSPLog()} bytes=${message.toByteArray(rtspCharset).size}"
            )
            if (bodyText.isNotBlank()) {
                EdgeLinkLog.info(
                    "callrelay.android.sink_rtsp_body dir=in firstLine=${firstLine.forRTSPLog()} " +
                        "preview=${bodyText.forRTSPLog()}"
                )
            }
            if (firstLine.uppercase().startsWith("RTSP/")) {
                handleRTSPResponse(firstLine, headerText, bodyText, cseq)
                return
            }
            when (rtspRequestMethod(firstLine)) {
                "OPTIONS" -> {
                    sendRTSPResponse(
                        cseq = cseq,
                        headers = listOf(
                            "Public" to "org.wfa.wfd1.0, SETUP, TEARDOWN, PLAY, PAUSE, GET_PARAMETER, SET_PARAMETER",
                            "fastRTSPVersion" to "0"
                        )
                    )
                    sendGetParametersIfNeeded()
                }
                "GET_PARAMETER" -> sendRTSPResponse(cseq)
                "SET_PARAMETER" -> sendRTSPResponse(cseq)
                "SETUP" -> {
                    recordDestinationFromTransport(headerText, "setup")
                    sessionHeader = sessionHeader ?: abs((firstLine + System.nanoTime()).hashCode()).toString()
                    sendRTSPResponse(
                        cseq = cseq,
                        headers = listOf(
                            "Session" to checkNotNull(sessionHeader),
                            "Transport" to setupResponseTransport(headerText)
                        )
                    )
                }
                "PLAY" -> {
                    sendRTSPResponse(cseq, sessionHeader?.let { listOf("Session" to it) } ?: emptyList())
                    sendMutex.withLock {
                        playing = true
                        flushPendingRTPLocked("play")
                    }
                    statusHandler("sink_ready")
                }
                "PAUSE" -> {
                    sendRTSPResponse(cseq)
                    sendMutex.withLock { playing = false }
                }
                "TEARDOWN" -> {
                    sendRTSPResponse(cseq)
                    sendMutex.withLock { playing = false }
                }
                else -> sendRTSPResponse(cseq)
            }
        }

        private suspend fun handleRTSPResponse(
            firstLine: String,
            headerText: String,
            bodyText: String,
            cseq: String
        ) {
            val request = pendingRequests.remove(cseq)
            rtspHeader("Session", headerText)
                ?.substringBefore(";")
                ?.trim()
                ?.takeIf { it.isNotEmpty() }
                ?.let { sessionHeader = it }
            val status = rtspStatusCode(firstLine)
            if (status != null && status >= 300) {
                EdgeLinkLog.warn(
                    "callrelay.android.sink_rtsp_non_success request=$request status=$status " +
                        "firstLine=${firstLine.forRTSPLog()}"
                )
                return
            }
            when (request) {
                REQUEST_GET_PARAMETERS -> {
                    recordDestinationFromWFD(bodyText, "capabilities")
                    sendSelectedParametersIfNeeded()
                }
                REQUEST_SELECT_PARAMETERS -> sendSetupTriggerIfNeeded()
            }
        }

        private suspend fun sendOptionsIfNeeded() {
            if (sentOptions) {
                return
            }
            sentOptions = true
            sendRTSPRequest(
                method = "OPTIONS",
                uri = "*",
                headers = listOf(
                    "Require" to "org.wfa.wfd1.0",
                    "lib_version" to "edgelink_android_sink_source",
                    "fastRTSPVersion" to "0"
                ),
                label = REQUEST_OPTIONS
            )
        }

        private suspend fun sendGetParametersIfNeeded() {
            if (sentGetParameters) {
                return
            }
            sentGetParameters = true
            val body = listOf(
                "wfd_audio_codecs",
                "audio_sample_time_ms",
                "wfd_client_rtp_ports",
                "wfd_content_protection"
            ).joinToString("\r\n", postfix = "\r\n")
            sendRTSPRequest(
                method = "GET_PARAMETER",
                uri = "rtsp://localhost/wfd1.0",
                headers = listOf("Content-Type" to "text/parameters"),
                body = body,
                label = REQUEST_GET_PARAMETERS
            )
        }

        private suspend fun sendSelectedParametersIfNeeded() {
            if (sentSelectedParameters) {
                return
            }
            val sinkPort = sendMutex.withLock { destination?.port }
            if (sinkPort == null) {
                EdgeLinkLog.warn(
                    "callrelay.android.sink_rtsp_missing_rtp_port sessionId=$relaySessionId"
                )
                return
            }
            sentSelectedParameters = true
            val body = listOf(
                "wfd_video_formats: none",
                "wfd_audio_codecs: AAC 00000001 00",
                "audio_sample_time_ms: 20",
                "wfd_client_rtp_ports: RTP/AVP/UDP;unicast $sinkPort 0 mode=play",
                "wfd_content_protection: none",
                "wfd_presentation_url: rtsp://${preferredLocalIPv4Address() ?: "127.0.0.1"}:$listenPort/wfd1.0/streamid=0 none"
            ).joinToString("\r\n", postfix = "\r\n")
            sendRTSPRequest(
                method = "SET_PARAMETER",
                uri = "rtsp://localhost/wfd1.0",
                headers = listOf("Content-Type" to "text/parameters"),
                body = body,
                label = REQUEST_SELECT_PARAMETERS
            )
        }

        private suspend fun sendSetupTriggerIfNeeded() {
            if (sentSetupTrigger) {
                return
            }
            sentSetupTrigger = true
            sendRTSPRequest(
                method = "SET_PARAMETER",
                uri = "rtsp://localhost/wfd1.0",
                headers = listOf("Content-Type" to "text/parameters"),
                body = "wfd_trigger_method: SETUP\r\n",
                label = REQUEST_SETUP_TRIGGER
            )
        }

        private suspend fun recordDestinationFromWFD(bodyText: String, reason: String) {
            val line = bodyText
                .lineSequence()
                .firstOrNull { it.trim().startsWith("wfd_client_rtp_ports:", ignoreCase = true) }
                ?: return
            val port = firstRTPPortToken(line.substringAfter(":", ""))
                ?.takeIf { it in 1..65_535 }
                ?: return
            setDestination(port, reason, line)
        }

        private suspend fun recordDestinationFromTransport(headerText: String, reason: String) {
            val transport = rtspHeader("Transport", headerText).orEmpty()
            val port = rtspTransportValue("client_port", transport)
                ?.let(::firstRTPPortToken)
                ?.takeIf { it in 1..65_535 }
                ?: return
            setDestination(port, reason, transport)
        }

        private suspend fun setDestination(port: Int, reason: String, source: String) {
            val address = socket?.inetAddress ?: InetAddress.getLoopbackAddress()
            sendMutex.withLock {
                val next = InetSocketAddress(address, port)
                if (destination != next) {
                    destination = next
                    EdgeLinkLog.info(
                        "callrelay.android.sink_rtp_destination sessionId=$relaySessionId " +
                            "host=${address.hostAddress} port=$port reason=$reason pending=${pendingRTP.size} " +
                            "source=${source.forRTSPLog()}"
                    )
                }
            }
        }

        private fun setupResponseTransport(headerText: String): String {
            val transport = rtspHeader("Transport", headerText).orEmpty()
            val clientPort = rtspTransportValue("client_port", transport)
            val serverPort = udpSocket?.localPort ?: 0
            return if (clientPort != null) {
                "RTP/AVP/UDP;unicast;client_port=$clientPort;server_port=$serverPort-${serverPort + 1}"
            } else {
                "RTP/AVP/UDP;unicast;server_port=$serverPort-${serverPort + 1}"
            }
        }

        private fun bufferRTPLocked(packet: ByteArray, reason: String) {
            if (pendingRTP.size >= MAX_PENDING_SOURCE_RTP_PACKETS) {
                pendingRTP.removeFirst()
                droppedPackets += 1
            }
            pendingRTP.addLast(packet)
            bufferedPackets += 1
            if (bufferedPackets == 1 || bufferedPackets % 100 == 0) {
                EdgeLinkLog.info(
                    "callrelay.android.sink_rtp_buffered sessionId=$relaySessionId reason=$reason " +
                        "pending=${pendingRTP.size} dropped=$droppedPackets bytes=${packet.size}"
                )
            }
        }

        private suspend fun flushPendingRTPLocked(reason: String) {
            val udp = udpSocket
            val target = destination
            if (!playing || udp == null || udp.isClosed || target == null || pendingRTP.isEmpty()) {
                return
            }
            val count = pendingRTP.size
            while (pendingRTP.isNotEmpty()) {
                sendRTPLocked(udp, target, pendingRTP.removeFirst())
            }
            EdgeLinkLog.info(
                "callrelay.android.sink_rtp_flush sessionId=$relaySessionId reason=$reason flushed=$count"
            )
        }

        private suspend fun sendRTPLocked(
            udp: DatagramSocket,
            target: InetSocketAddress,
            packet: ByteArray
        ) {
            val address = target.address ?: return
            withContext(Dispatchers.IO) {
                udp.send(DatagramPacket(packet, packet.size, address, target.port))
            }
            rtpPackets += 1
            if (rtpPackets == 1 || rtpPackets % 100 == 0) {
                EdgeLinkLog.info(
                    "callrelay.android.sink_rtp_out sessionId=$relaySessionId count=$rtpPackets " +
                        "to=${address.hostAddress}:${target.port} bytes=${packet.size} " +
                        "${rtpSummary(packet)} fp=${EdgeLinkLog.fingerprint(packet)}"
                )
            }
        }

        private suspend fun sendRTSPResponse(
            cseq: String,
            headers: List<Pair<String, String>> = emptyList(),
            body: String? = null
        ) {
            sendRTSP(
                buildRTSPMessage(
                    firstLine = "RTSP/1.0 200 OK",
                    headers = listOf(
                        "Date" to java.util.Date().toString(),
                        "User-Agent" to "EdgeLinkAndroidSinkSource",
                        "CSeq" to cseq
                    ) + headers,
                    body = body
                ),
                label = "response"
            )
        }

        private suspend fun sendRTSPRequest(
            method: String,
            uri: String,
            headers: List<Pair<String, String>> = emptyList(),
            body: String? = null,
            label: String
        ) {
            val cseq = nextCSeq++.toString()
            pendingRequests[cseq] = label
            sendRTSP(
                buildRTSPMessage(
                    firstLine = "$method $uri RTSP/1.0",
                    headers = listOf(
                        "Date" to java.util.Date().toString(),
                        "Server" to "EdgeLinkAndroidSinkSource",
                        "CSeq" to cseq
                    ) + headers,
                    body = body
                ),
                label = label
            )
        }

        private suspend fun sendRTSP(message: String, label: String) {
            val firstLine = message.substringBefore("\r\n")
            EdgeLinkLog.info(
                "callrelay.android.sink_rtsp_message dir=out firstLine=${firstLine.forRTSPLog()} " +
                    "label=$label bytes=${message.toByteArray(rtspCharset).size}"
            )
            withContext(Dispatchers.IO) {
                val activeWriter = checkNotNull(writer)
                activeWriter.write(message)
                activeWriter.flush()
            }
        }

        private fun buildRTSPMessage(
            firstLine: String,
            headers: List<Pair<String, String>>,
            body: String?
        ): String {
            val finalHeaders = if (body == null) {
                headers
            } else {
                headers + ("Content-Length" to body.toByteArray(Charsets.UTF_8).size.toString())
            }
            return buildString {
                append(firstLine)
                for ((name, value) in finalHeaders) {
                    append("\r\n")
                    append(name)
                    append(": ")
                    append(value)
                }
                append("\r\n\r\n")
                if (body != null) {
                    append(body)
                }
            }
        }

        companion object {
            private const val REQUEST_OPTIONS = "OPTIONS"
            private const val REQUEST_GET_PARAMETERS = "GET_PARAMETERS"
            private const val REQUEST_SELECT_PARAMETERS = "SELECT_PARAMETERS"
            private const val REQUEST_SETUP_TRIGGER = "SETUP_TRIGGER"
        }
    }
}

private const val MAX_PENDING_SOURCE_RTP_PACKETS = 150
private val CRLFCRLF = byteArrayOf(13, 10, 13, 10)

private fun preferredLocalIPv4Address(): String? =
    runCatching {
        val interfaces = NetworkInterface.getNetworkInterfaces() ?: return@runCatching null
        var fallback: String? = null
        while (interfaces.hasMoreElements()) {
            val networkInterface = interfaces.nextElement()
            if (!networkInterface.isUp || networkInterface.isLoopback) {
                continue
            }
            val addresses = networkInterface.inetAddresses
            while (addresses.hasMoreElements()) {
                val address = addresses.nextElement()
                if (address is Inet4Address && !address.isLoopbackAddress) {
                    val host = address.hostAddress
                    if (networkInterface.name == "wlan0") {
                        return@runCatching host
                    }
                    if (fallback == null) {
                        fallback = host
                    }
                }
            }
        }
        fallback
    }.getOrNull()

private fun localRTSPHostCandidates(): List<String> =
    listOfNotNull(preferredLocalIPv4Address(), "127.0.0.1").distinct()

private fun ByteArray.indexOf(needle: ByteArray): Int {
    if (needle.isEmpty() || size < needle.size) {
        return -1
    }
    for (index in 0..(size - needle.size)) {
        var matched = true
        for (needleIndex in needle.indices) {
            if (this[index + needleIndex] != needle[needleIndex]) {
                matched = false
                break
            }
        }
        if (matched) {
            return index
        }
    }
    return -1
}

private fun rtspHeader(name: String, headerText: String): String? {
    val prefix = "${name.lowercase()}:"
    return headerText
        .lineSequence()
        .map { it.trim() }
        .firstOrNull { it.lowercase().startsWith(prefix) }
        ?.substringAfter(":")
        ?.trim()
}

private fun rtspRequestMethod(firstLine: String): String? {
    if (!firstLine.uppercase().endsWith(" RTSP/1.0")) {
        return null
    }
    return firstLine.substringBefore(" ").uppercase()
}

private fun rtspStatusCode(firstLine: String): Int? {
    val parts = firstLine.trim().split(Regex("\\s+"), limit = 3)
    if (parts.size < 2 || !parts[0].uppercase().startsWith("RTSP/")) {
        return null
    }
    return parts[1].toIntOrNull()
}

private fun rtspTransportValue(name: String, transport: String): String? {
    val prefix = "${name.lowercase()}="
    return transport
        .split(";")
        .map { it.trim() }
        .firstOrNull { it.lowercase().startsWith(prefix) }
        ?.substringAfter("=")
}

private fun firstRTPPortToken(value: String): Int? {
    val normalized = value.replace(";", " ")
    for (rawToken in normalized.split(Regex("\\s+"))) {
        val token = rawToken.trim()
        if (token.isEmpty()) {
            continue
        }
        val port = token
            .substringBefore("-")
            .toIntOrNull()
            ?.takeIf { it in 1..65_535 }
        if (port != null) {
            return port
        }
    }
    return null
}

private fun String.forRTSPLog(): String =
    replace(Regex("\\s+"), " ").trim().take(180)

private fun rtpSummary(data: ByteArray): String {
    if (data.size < 12 || data[0].toInt() shr 6 != 2) {
        return "format=unknown"
    }
    val payloadType = data[1].toInt() and 0x7f
    val sequence = ((data[2].toInt() and 0xff) shl 8) or (data[3].toInt() and 0xff)
    val timestamp = ((data[4].toLong() and 0xff) shl 24) or
        ((data[5].toLong() and 0xff) shl 16) or
        ((data[6].toLong() and 0xff) shl 8) or
        (data[7].toLong() and 0xff)
    return "format=rtp pt=$payloadType seq=$sequence ts=$timestamp payloadBytes=${data.size - 12}"
}
