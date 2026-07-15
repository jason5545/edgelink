package com.edgelink.app

import com.edgelink.core.LocalIdentity
import com.edgelink.core.PhoneActionBody
import com.edgelink.core.RelayAuth
import com.edgelink.core.SodiumHandshakeCrypto
import kotlinx.coroutines.CompletableDeferred
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
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject
import java.io.BufferedReader
import java.io.BufferedWriter
import java.io.ByteArrayOutputStream
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.Socket
import java.net.SocketTimeoutException
import java.nio.charset.Charset
import java.time.Instant
import java.util.Base64
import kotlin.math.abs

object AndroidCallRelayBridge {
    private const val DEFAULT_LOCAL_RTSP_PORT = 7_102
    private const val START_READY_TIMEOUT_MS = 5_000L

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val lifecycleMutex = Mutex()
    private var activeJob: Job? = null
    private var activeSessionId: String? = null

    fun start(identity: LocalIdentity, body: PhoneActionBody, reason: String) {
        val relaySessionId = body.relaySessionId?.trim()?.takeIf { it.isNotEmpty() }
        val relayHost = body.relayHost?.trim()?.takeIf { it.isNotEmpty() } ?: EdgeLinkConfig.callRelayGatewayHost
        val relayControlPort = body.relayControlPort
            ?.takeIf { it in 1..65_535 }
            ?: EdgeLinkConfig.callRelayGatewayControlPort
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
                activeJob = launch {
                    AndroidCallRelayBridgeSession(
                        identity = identity,
                        relayHost = relayHost,
                        relayControlPort = relayControlPort,
                        relaySessionId = relaySessionId,
                        localRtspPorts = localRtspPorts,
                        startReason = reason
                    ).run()
                }
            }
        }
    }

    fun stop(reason: String) {
        scope.launch {
            lifecycleMutex.withLock {
                val sessionId = activeSessionId
                activeSessionId = null
                activeJob?.cancelAndJoin()
                activeJob = null
                if (sessionId != null) {
                    EdgeLinkLog.info("callrelay.android.bridge_stop sessionId=$sessionId reason=$reason")
                }
            }
        }
    }

    private class AndroidCallRelayBridgeSession(
        private val identity: LocalIdentity,
        private val relayHost: String,
        private val relayControlPort: Int,
        private val relaySessionId: String,
        private val localRtspPorts: List<Int>,
        private val startReason: String,
        private val crypto: SodiumHandshakeCrypto = SodiumHandshakeCrypto()
    ) {
        private val sendMutex = Mutex()
        private var controlSocket: Socket? = null
        private var controlReader: BufferedReader? = null
        private var controlWriter: BufferedWriter? = null
        private var bridgeRtpPackets = 0
        private var sourceRtpPackets = 0

        suspend fun run() {
            try {
                withContext(Dispatchers.IO) {
                    openControl()
                }
                coroutineScope {
                    val ready = CompletableDeferred<Unit>()
                    val localBridge = LocalMiLinkRTSPBridge(
                        relaySessionId = relaySessionId,
                        localRtspPorts = localRtspPorts,
                        rtpHandler = ::sendBridgeRTP,
                        statusHandler = ::sendStatus
                    )
                    val controlJob = launch { readControlLoop(ready, localBridge) }
                    sendHello()
                    val isReady = withTimeoutOrNull(START_READY_TIMEOUT_MS) {
                        ready.await()
                        true
                    } == true
                    if (!isReady) {
                        sendStatus("bridge_ready_timeout")
                        error("Call relay bridge did not become ready.")
                    }
                    sendStatus("bridge_ready")
                    val rtspJob = launch { localBridge.run() }
                    try {
                        controlJob.join()
                    } finally {
                        rtspJob.cancel()
                    }
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                EdgeLinkLog.warn(
                    "callrelay.android.bridge_failed sessionId=$relaySessionId reason=$startReason " +
                        "error=${error.javaClass.simpleName}:${error.message.orEmpty()}",
                    error
                )
            } finally {
                closeControl()
            }
        }

        private fun openControl() {
            val socket = Socket()
            socket.tcpNoDelay = true
            socket.keepAlive = true
            socket.soTimeout = 2_000
            socket.connect(InetSocketAddress(relayHost, relayControlPort), 4_000)
            controlSocket = socket
            controlReader = BufferedReader(InputStreamReader(socket.getInputStream(), Charsets.UTF_8))
            controlWriter = BufferedWriter(OutputStreamWriter(socket.getOutputStream(), Charsets.UTF_8))
            EdgeLinkLog.info(
                "callrelay.android.bridge_control_connected sessionId=$relaySessionId " +
                    "endpoint=$relayHost:$relayControlPort reason=$startReason"
            )
        }

        private suspend fun sendHello() {
            val timestamp = Instant.now().epochSecond
            val signature = crypto.signIdentity(RelayAuth.message(identity.deviceId, timestamp), identity)
            sendJSON(
                "hello",
                JSONObject()
                    .put("version", 1)
                    .put("role", "android.bridge")
                    .put("sessionId", relaySessionId)
                    .put("deviceId", identity.deviceId)
                    .put("ts", timestamp)
                    .put("sig", Base64.getEncoder().encodeToString(signature))
                    .put("localRtspHost", preferredLocalIPv4Address().orEmpty())
                    .put("localRtspPort", localRtspPorts.firstOrNull() ?: DEFAULT_LOCAL_RTSP_PORT)
                    .put("localRtspPorts", localRtspPorts.joinToString(","))
            )
        }

        private suspend fun readControlLoop(
            ready: CompletableDeferred<Unit>,
            localBridge: LocalMiLinkRTSPBridge
        ) {
            val reader = checkNotNull(controlReader)
            while (currentCoroutineContext().isActive) {
                val line = try {
                    withContext(Dispatchers.IO) { reader.readLine() } ?: break
                } catch (_: SocketTimeoutException) {
                    continue
                }
                if (line.isBlank()) {
                    continue
                }
                val envelope = runCatching { JSONObject(line) }.getOrNull() ?: continue
                when (val type = envelope.optString("t")) {
                    "bridge.ready" -> {
                        EdgeLinkLog.info("callrelay.android.bridge_ready sessionId=$relaySessionId")
                        ready.complete(Unit)
                    }
                    "source.rtp.in" -> {
                        val body = envelope.optJSONObject("b")
                        sourceRtpPackets += 1
                        val packet = body
                            ?.optString("data")
                            ?.takeIf { it.isNotEmpty() }
                            ?.let { dataText ->
                                runCatching { Base64.getDecoder().decode(dataText) }.getOrNull()
                            }
                        if (sourceRtpPackets == 1 || sourceRtpPackets % 100 == 0) {
                            EdgeLinkLog.info(
                                "callrelay.android.bridge_source_rtp_in sessionId=$relaySessionId " +
                                    "count=$sourceRtpPackets bytes=${body?.optInt("bytes") ?: -1} " +
                                    "decoded=${packet?.size ?: -1}"
                            )
                        }
                        if (packet == null) {
                            EdgeLinkLog.warn(
                                "callrelay.android.bridge_source_rtp_invalid sessionId=$relaySessionId " +
                                    "count=$sourceRtpPackets"
                            )
                        } else {
                            localBridge.sendSourceRTP(packet)
                        }
                    }
                    "session.closed" -> {
                        EdgeLinkLog.info("callrelay.android.bridge_session_closed sessionId=$relaySessionId")
                        return
                    }
                    "error" -> {
                        EdgeLinkLog.warn("callrelay.android.bridge_server_error sessionId=$relaySessionId body=${envelope.optJSONObject("b")}")
                        return
                    }
                    else -> {
                        if (type.isNotEmpty()) {
                            EdgeLinkLog.info("callrelay.android.bridge_control_ignored type=$type sessionId=$relaySessionId")
                        }
                    }
                }
            }
        }

        private suspend fun sendBridgeRTP(packet: ByteArray) {
            bridgeRtpPackets += 1
            if (bridgeRtpPackets == 1 || bridgeRtpPackets % 100 == 0) {
                EdgeLinkLog.info(
                    "callrelay.android.bridge_rtp_out sessionId=$relaySessionId " +
                        "count=$bridgeRtpPackets bytes=${packet.size} fp=${EdgeLinkLog.fingerprint(packet)}"
                )
            }
            sendJSON(
                "bridge.rtp",
                JSONObject()
                    .put("bytes", packet.size)
                    .put("data", Base64.getEncoder().encodeToString(packet))
            )
        }

        private suspend fun sendStatus(event: String) {
            runCatching {
                sendJSON(
                    "bridge.status",
                    JSONObject()
                        .put("event", event)
                        .put("sessionId", relaySessionId)
                )
            }
        }

        private suspend fun sendJSON(type: String, body: JSONObject) {
            val line = JSONObject()
                .put("t", type)
                .put("b", body)
                .toString() + "\n"
            sendMutex.withLock {
                val writer = controlWriter ?: return
                withContext(Dispatchers.IO) {
                    writer.write(line)
                    writer.flush()
                }
            }
        }

        private fun closeControl() {
            runCatching { controlWriter?.close() }
            runCatching { controlReader?.close() }
            runCatching { controlSocket?.close() }
            controlWriter = null
            controlReader = null
            controlSocket = null
            EdgeLinkLog.info("callrelay.android.bridge_control_closed sessionId=$relaySessionId")
        }
    }

    private class LocalMiLinkRTSPBridge(
        private val relaySessionId: String,
        private val localRtspPorts: List<Int>,
        private val rtpHandler: suspend (ByteArray) -> Unit,
        private val statusHandler: suspend (String) -> Unit
    ) {
        private val sourceSendMutex = Mutex()
        private val pendingSourceRTP = ArrayDeque<ByteArray>()
        private val pendingRequests = mutableMapOf<String, String>()
        private val rtspCharset: Charset = Charsets.ISO_8859_1
        private var socket: Socket? = null
        private var writer: BufferedWriter? = null
        private var udpSocket: DatagramSocket? = null
        private var sourceRTPDestination: InetSocketAddress? = null
        private var tcpBuffer = ByteArray(0)
        private var nextCSeq = 1
        private var sentOptions = false
        private var sentSinkSETUP = false
        private var sentPLAY = false
        private var sessionHeader: String? = null
        private var presentationURL: String? = null
        private var rtpPackets = 0
        private var sourceRTPOutPackets = 0
        private var sourceRTPBufferedPackets = 0
        private var sourceRTPDroppedPackets = 0

        suspend fun run() = coroutineScope {
            val udp = DatagramSocket(null).apply {
                reuseAddress = true
                soTimeout = 2_000
                bind(InetSocketAddress(0))
            }
            udpSocket = udp
            EdgeLinkLog.info("callrelay.android.local_rtp_ready port=${udp.localPort}")
            flushPendingSourceRTP("udp_ready")
            val udpJob = launch { receiveRTP(udp) }
            try {
                connectRTSPWithRetry()
                statusHandler("local_rtsp_connected")
                readRTSPLoop()
            } finally {
                udpJob.cancel()
                runCatching { udp.close() }
                runCatching { writer?.close() }
                runCatching { socket?.close() }
                writer = null
                socket = null
                udpSocket = null
                EdgeLinkLog.info("callrelay.android.local_rtsp_closed")
            }
        }

        suspend fun sendSourceRTP(packet: ByteArray) {
            sourceSendMutex.withLock {
                val udp = udpSocket
                val destination = sourceRTPDestination
                if (udp == null || udp.isClosed || destination == null) {
                    bufferSourceRTPLocked(packet, if (destination == null) "missing_destination" else "missing_socket")
                    return
                }
                sendSourceRTPLocked(udp, destination, packet)
            }
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
                    recordSourceRTPDestinationFromWFD(bodyText, "set_parameter")
                    sendRTSPResponse(cseq)
                    if (bodyText.contains("wfd_trigger_method: SETUP", ignoreCase = true)) {
                        sendSinkSETUPIfNeeded("trigger_setup")
                    }
                }
                "SETUP" -> {
                    recordSourceRTPDestinationFromTransport(headerText, "request_setup")
                    sessionHeader = sessionHeader ?: abs((firstLine + System.nanoTime()).hashCode()).toString()
                    sendRTSPResponse(
                        cseq = cseq,
                        headers = listOf(
                            "Session" to checkNotNull(sessionHeader),
                            "Transport" to setupResponseTransport(headerText)
                        )
                    )
                }
                "PLAY", "PAUSE", "TEARDOWN" -> sendRTSPResponse(cseq)
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

        private suspend fun recordSourceRTPDestinationFromWFD(bodyText: String, reason: String) {
            val line = bodyText
                .lineSequence()
                .firstOrNull { it.trim().startsWith("wfd_client_rtp_ports:", ignoreCase = true) }
                ?: return
            val port = firstRTPPortToken(line.substringAfter(":", ""))
                ?.takeIf { it in 1..65_535 }
                ?: return
            val host = rtspPeerHost() ?: return
            setSourceRTPDestination(host, sourceRTPPortForCandidate(port), reason, line)
        }

        private suspend fun recordSourceRTPDestinationFromTransport(headerText: String, reason: String) {
            val transport = rtspHeader("Transport", headerText).orEmpty()
            val clientPort = rtspTransportValue("client_port", transport)
            val port = clientPort
                ?.let(::firstRTPPortToken)
                ?.takeIf { it in 1..65_535 }
                ?: return
            val host = rtspPeerHost() ?: return
            setSourceRTPDestination(host, sourceRTPPortForCandidate(port), reason, transport)
        }

        private fun sourceRTPPortForCandidate(port: Int): Int {
            val localPort = udpSocket?.localPort
            if (localPort != null && port == localPort) {
                EdgeLinkLog.warn(
                    "callrelay.android.source_rtp_candidate_self_port sessionId=$relaySessionId " +
                        "candidate=$port fallback=$DEFAULT_LOCAL_SOURCE_RTP_PORT"
                )
                return DEFAULT_LOCAL_SOURCE_RTP_PORT
            }
            return port
        }

        private suspend fun setSourceRTPDestination(
            host: String,
            port: Int,
            reason: String,
            source: String
        ) {
            val address = runCatching { InetAddress.getByName(host) }.getOrNull() ?: return
            sourceSendMutex.withLock {
                val nextDestination = InetSocketAddress(address, port)
                val changed = sourceRTPDestination != nextDestination
                sourceRTPDestination = nextDestination
                if (changed) {
                    EdgeLinkLog.info(
                        "callrelay.android.source_rtp_destination sessionId=$relaySessionId " +
                            "host=$host port=$port reason=$reason pending=${pendingSourceRTP.size} " +
                            "source=${source.forRTSPLog()}"
                    )
                }
                flushPendingSourceRTPLocked("destination_$reason")
            }
        }

        private suspend fun flushPendingSourceRTP(reason: String) {
            sourceSendMutex.withLock {
                flushPendingSourceRTPLocked(reason)
            }
        }

        private suspend fun flushPendingSourceRTPLocked(reason: String) {
            val udp = udpSocket
            val destination = sourceRTPDestination
            if (udp == null || udp.isClosed || destination == null || pendingSourceRTP.isEmpty()) {
                return
            }
            val pendingCount = pendingSourceRTP.size
            while (pendingSourceRTP.isNotEmpty()) {
                sendSourceRTPLocked(udp, destination, pendingSourceRTP.removeFirst())
            }
            EdgeLinkLog.info(
                "callrelay.android.source_rtp_flush sessionId=$relaySessionId " +
                    "reason=$reason flushed=$pendingCount"
            )
        }

        private fun bufferSourceRTPLocked(packet: ByteArray, reason: String) {
            if (pendingSourceRTP.size >= MAX_PENDING_SOURCE_RTP_PACKETS) {
                pendingSourceRTP.removeFirst()
                sourceRTPDroppedPackets += 1
            }
            pendingSourceRTP.addLast(packet)
            sourceRTPBufferedPackets += 1
            if (sourceRTPBufferedPackets == 1 || sourceRTPBufferedPackets % 100 == 0) {
                EdgeLinkLog.info(
                    "callrelay.android.source_rtp_buffered sessionId=$relaySessionId " +
                        "reason=$reason pending=${pendingSourceRTP.size} dropped=$sourceRTPDroppedPackets " +
                        "bytes=${packet.size} fp=${EdgeLinkLog.fingerprint(packet)}"
                )
            }
        }

        private suspend fun sendSourceRTPLocked(
            udp: DatagramSocket,
            destination: InetSocketAddress,
            packet: ByteArray
        ) {
            val address = destination.address ?: return
            withContext(Dispatchers.IO) {
                udp.send(DatagramPacket(packet, packet.size, address, destination.port))
            }
            sourceRTPOutPackets += 1
            if (sourceRTPOutPackets == 1 || sourceRTPOutPackets % 100 == 0) {
                EdgeLinkLog.info(
                    "callrelay.android.source_rtp_out sessionId=$relaySessionId " +
                        "count=$sourceRTPOutPackets to=${address.hostAddress}:${destination.port} " +
                        "bytes=${packet.size} ${rtpSummary(packet)} fp=${EdgeLinkLog.fingerprint(packet)}"
                )
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
}

private const val MAX_PENDING_SOURCE_RTP_PACKETS = 150
private const val DEFAULT_LOCAL_SOURCE_RTP_PORT = 15_550
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
