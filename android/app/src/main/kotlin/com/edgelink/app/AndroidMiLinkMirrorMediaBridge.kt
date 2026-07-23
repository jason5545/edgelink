package com.edgelink.app

import com.edgelink.core.MiLinkMirrorMediaBody
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
import java.util.Base64

object AndroidMiLinkMirrorMediaBridge {
    private const val DEFAULT_LOCAL_RTSP_PORT = 7_102
    private const val RTSP_KICKSTART_DELAY_MS = 800L
    private const val RTSP_PLAY_RESPONSE_TIMEOUT_MS = 2_500L
    private const val RTP_BATCH_MAX_PAYLOAD_BYTES = 6_144
    private const val RTP_BATCH_MAX_DELAY_MS = 10L
    private const val RTP_BATCH_QUEUE_CAPACITY = 1_024
    private const val ANDROID_TO_MAC = "android_to_mac"
    private const val MAC_TO_ANDROID = "mac_to_android"
    private const val OFFICIAL_RTSP_USER_AGENT = "stagefright/1.1 (Linux;Android 4.1)"
    private const val OFFICIAL_RTSP_LIB_VERSION = "miplaycast_os3_release1.7 3.2.6011403"
    private const val OFFICIAL_RTSP_AUTH_KEY_TYPE = "3"
    private const val OFFICIAL_RTSP_AUTH_ALGORITHM_TYPES = "7"
    private const val OFFICIAL_RTSP_PREFERRED_AUTH_ALGORITHM_VAL = "4"
    private const val SOURCE_TEARDOWN_TIMEOUT_MS = 1_500L
    private val OFFICIAL_SCREEN_AUTH_KEY = "EdgeLinkMirrorK!".toByteArray(Charsets.UTF_8)

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val lifecycleMutex = Mutex()
    private var activeJob: Job? = null
    private var activeSessionId: String? = null
    private var activeSession: MirrorMediaBridgeSession? = null

    fun start(
        request: AndroidMiLinkMirrorCloudBridgeRequest,
        sendMedia: suspend (MiLinkMirrorMediaBody) -> Unit
    ) {
        val sessionId = request.sessionId.trim().takeIf { it.isNotEmpty() } ?: return
        val localRtspPorts = (request.localRtspPorts + DEFAULT_LOCAL_RTSP_PORT)
            .filter { it in 1..65_535 }
            .distinct()
        scope.launch {
            lifecycleMutex.withLock {
                val existing = activeSession
                if (existing != null && activeJob?.isActive == true) {
                    if (activeSessionId == sessionId) {
                        EdgeLinkLog.info("xiaomi.mirror.android.cloudflare_bridge_reuse sessionId=$sessionId")
                        return@withLock
                    }
                    existing.retarget(sessionId, sendMedia)
                    activeSessionId = sessionId
                    EdgeLinkLog.info(
                        "xiaomi.mirror.android.cloudflare_bridge_adopt sessionId=$sessionId reason=${request.reason}"
                    )
                    return@withLock
                }
                activeJob?.cancelAndJoin()
                activeSessionId = sessionId
                val bridge = MirrorMediaBridgeSession(
                    sessionId = sessionId,
                    localRtspPorts = localRtspPorts,
                    startReason = request.reason,
                    sendMedia = sendMedia
                )
                activeSession = bridge
                activeJob = launch {
                    bridge.run()
                }
            }
        }
    }

    fun stop(reason: String) {
        scope.launch {
            lifecycleMutex.withLock {
                val sessionId = activeSessionId
                val session = activeSession
                activeSessionId = null
                activeSession = null
                if (session != null) {
                    kotlinx.coroutines.withTimeoutOrNull(SOURCE_TEARDOWN_TIMEOUT_MS) {
                        session.sendSourceTeardown(reason)
                    }
                }
                activeJob?.cancelAndJoin()
                activeJob = null
                if (sessionId != null) {
                    EdgeLinkLog.info(
                        "xiaomi.mirror.android.cloudflare_bridge_stop sessionId=$sessionId reason=$reason"
                    )
                }
            }
        }
    }

    suspend fun handleMedia(body: MiLinkMirrorMediaBody) {
        if (body.direction != MAC_TO_ANDROID || body.kind != "rtp") {
            return
        }
        val session = activeSession
        if (session == null || body.sessionId != activeSessionId) {
            EdgeLinkLog.info(
                "xiaomi.mirror.android.cloudflare_media_ignored sessionId=${body.sessionId} " +
                    "active=${activeSessionId ?: "none"} direction=${body.direction} kind=${body.kind}"
            )
            return
        }
        session.sendDatagramToSource(body)
    }

    private class MirrorMediaBridgeSession(
        sessionId: String,
        private val localRtspPorts: List<Int>,
        private val startReason: String,
        sendMedia: suspend (MiLinkMirrorMediaBody) -> Unit
    ) {
        @Volatile
        private var sessionId: String = sessionId

        @Volatile
        private var sendMedia: suspend (MiLinkMirrorMediaBody) -> Unit = sendMedia

        private val rtpBatchQueue = kotlinx.coroutines.channels.Channel<ByteArray>(
            capacity = RTP_BATCH_QUEUE_CAPACITY,
            onBufferOverflow = kotlinx.coroutines.channels.BufferOverflow.DROP_OLDEST
        )
        private var rtpBatchesSent = 0
        private var rtpBatchDatagramsDropped = 0

        fun retarget(newSessionId: String, newSendMedia: suspend (MiLinkMirrorMediaBody) -> Unit) {
            sessionId = newSessionId
            sendMedia = newSendMedia
        }

        suspend fun sendSourceTeardown(reason: String) {
            val uri = presentationURL ?: return
            if (!sentPLAY || socket == null || writer == null) {
                return
            }
            runCatching {
                sendRTSPRequest(
                    method = "SET_PARAMETER",
                    uri = uri,
                    headers = listOfNotNull(
                        sessionHeader?.let { "Session" to it },
                        "Content-Type" to "text/parameters"
                    ),
                    body = "wfd_trigger_method: TEARDOWN\r\n",
                    label = "teardown_trigger"
                )
                sendRTSPRequest(
                    method = "TEARDOWN",
                    uri = uri,
                    headers = listOfNotNull(sessionHeader?.let { "Session" to it }),
                    label = "TEARDOWN"
                )
                EdgeLinkLog.info(
                    "xiaomi.mirror.android.cloudflare_rtsp_teardown_sent sessionId=$sessionId reason=$reason"
                )
            }.onFailure { error ->
                EdgeLinkLog.info(
                    "xiaomi.mirror.android.cloudflare_rtsp_teardown_failed sessionId=$sessionId " +
                        "reason=$reason error=${error.javaClass.simpleName}:${error.message.orEmpty()}"
                )
            }
        }
        private val pendingRequests = mutableMapOf<String, String>()
        private val rtspWriteMutex = Mutex()
        private val rtspCharset: Charset = Charsets.ISO_8859_1
        private var socket: Socket? = null
        private var writer: BufferedWriter? = null
        private var udpSocket: DatagramSocket? = null
        private var tcpBuffer = ByteArray(0)
        private var nextCSeq = 1
        private var sentOptions = false
        private var sentSinkSETUP = false
        private var sentPLAY = false
        private var playSentAtMs = 0L
        private var sessionHeader: String? = null
        private var presentationURL: String? = null
        private var connectedRtspPort: Int? = null
        private var localAuthMsg: String? = null
        private var mptUserId: String? = null
        private var sourceRtpEndpoint: InetSocketAddress? = null
        private var rtpPackets = 0
        private var macToSourceDatagrams = 0

        suspend fun run() = coroutineScope {
            sendStatus("bridge_starting")
            val udp = DatagramSocket(null).apply {
                reuseAddress = true
                soTimeout = 2_000
                bind(InetSocketAddress(0))
            }
            udpSocket = udp
            EdgeLinkLog.info(
                "xiaomi.mirror.android.cloudflare_local_rtp_ready sessionId=$sessionId " +
                    "port=${udp.localPort} reason=$startReason"
            )
            val udpJob = launch { receiveRTP(udp) }
            val batchJob = launch { flushRTPBatches() }
            try {
                while (currentCoroutineContext().isActive) {
                    try {
                        resetSourceControlState()
                        connectRTSPWithRetry()
                        sendStatus("local_rtsp_connected")
                        sendStatus("bridge_ready")
                        readRTSPLoop()
                    } catch (error: CancellationException) {
                        throw error
                    } catch (error: Throwable) {
                        EdgeLinkLog.info(
                            "xiaomi.mirror.android.cloudflare_local_rtsp_retry sessionId=$sessionId " +
                                "error=${error.javaClass.simpleName}:${error.message.orEmpty()}"
                        )
                    } finally {
                        runCatching { writer?.close() }
                        runCatching { socket?.close() }
                        writer = null
                        socket = null
                        connectedRtspPort = null
                    }
                    if (currentCoroutineContext().isActive) {
                        delay(200)
                    }
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                EdgeLinkLog.warn(
                    "xiaomi.mirror.android.cloudflare_bridge_failed sessionId=$sessionId " +
                        "error=${error.javaClass.simpleName}:${error.message.orEmpty()}",
                    error
                )
                sendStatus("bridge_failed")
            } finally {
                udpJob.cancel()
                rtpBatchQueue.close()
                batchJob.cancelAndJoin()
                runCatching { udp.close() }
                writer = null
                socket = null
                udpSocket = null
                sendStatus("source_stop")
                sendStatus("bridge_stopped")
                EdgeLinkLog.info(
                    "xiaomi.mirror.android.cloudflare_bridge_closed sessionId=$sessionId rtpPackets=$rtpPackets"
                )
            }
        }

        private fun resetSourceControlState() {
            pendingRequests.clear()
            tcpBuffer = ByteArray(0)
            nextCSeq = 1
            sentOptions = false
            sentSinkSETUP = false
            sentPLAY = false
            playSentAtMs = 0L
            sessionHeader = null
            presentationURL = null
            localAuthMsg = null
            mptUserId = null
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
                                connectedRtspPort = port
                                writer = BufferedWriter(
                                    OutputStreamWriter(nextSocket.getOutputStream(), rtspCharset)
                                )
                                EdgeLinkLog.info(
                                    "xiaomi.mirror.android.cloudflare_local_rtsp_connected " +
                                        "sessionId=$sessionId host=$host port=$port attempt=$attempt"
                                )
                                return
                            } catch (error: Throwable) {
                                runCatching { nextSocket.close() }
                                throw error
                            }
                        } catch (error: Throwable) {
                            lastError = error
                            EdgeLinkLog.info(
                                "xiaomi.mirror.android.cloudflare_local_rtsp_connect_failed " +
                                    "sessionId=$sessionId host=$host port=$port attempt=$attempt " +
                                    "error=${error.javaClass.simpleName}:${error.message.orEmpty()}"
                            )
                        }
                    }
                }
                delay(500)
            }
            throw lastError ?: IllegalStateException("MiLink mirror local RTSP listener was not reachable.")
        }

        private suspend fun readRTSPLoop() {
            val input = checkNotNull(socket).getInputStream()
            val scratch = ByteArray(4096)
            val connectedAt = android.os.SystemClock.elapsedRealtime()
            var receivedAny = false
            while (currentCoroutineContext().isActive) {
                val now = android.os.SystemClock.elapsedRealtime()
                if (!receivedAny && !sentOptions && now - connectedAt >= RTSP_KICKSTART_DELAY_MS) {
                    EdgeLinkLog.info("xiaomi.mirror.android.cloudflare_local_rtsp_kickstart sessionId=$sessionId")
                    sendOptionsIfNeeded("connect_kickstart")
                }
                if (sentPLAY && playSentAtMs > 0 &&
                    pendingRequests.containsValue("PLAY") &&
                    now - playSentAtMs >= RTSP_PLAY_RESPONSE_TIMEOUT_MS
                ) {
                    EdgeLinkLog.info("xiaomi.mirror.android.cloudflare_local_rtsp_play_timeout sessionId=$sessionId")
                    throw java.io.IOException("RTSP PLAY response timeout")
                }
                val read = try {
                    withContext(Dispatchers.IO) { input.read(scratch) }
                } catch (_: SocketTimeoutException) {
                    continue
                }
                if (read < 0) {
                    return
                }
                if (read > 0) {
                    receivedAny = true
                    processTCPData(scratch.copyOf(read))
                }
            }
        }

        private suspend fun receiveRTP(socket: DatagramSocket) {
            val buffer = ByteArray(64 * 1024)
            while (currentCoroutineContext().isActive) {
                val packet = DatagramPacket(buffer, buffer.size)
                try {
                    withContext(Dispatchers.IO) { socket.receive(packet) }
                } catch (error: Throwable) {
                    if (currentCoroutineContext().isActive && error !is SocketTimeoutException) {
                        EdgeLinkLog.warn("xiaomi.mirror.android.cloudflare_local_rtp_receive_failed", error)
                    }
                    if (error is SocketTimeoutException) {
                        continue
                    }
                    return
                }
                if (isSelfEcho(packet, socket)) {
                    if (rtpPackets == 0) {
                        EdgeLinkLog.warn(
                            "xiaomi.mirror.android.cloudflare_local_rtp_self_echo_ignored " +
                                "sessionId=$sessionId from=${packet.address.hostAddress}:${packet.port} " +
                                "localPort=${socket.localPort}"
                        )
                    }
                    continue
                }
                val data = packet.data.copyOfRange(packet.offset, packet.offset + packet.length)
                sourceRtpEndpoint = InetSocketAddress(packet.address, packet.port)
                rtpPackets += 1
                if (rtpPackets == 1 || rtpPackets % 100 == 0) {
                    EdgeLinkLog.info(
                        "xiaomi.mirror.android.cloudflare_local_rtp_in sessionId=$sessionId " +
                            "count=$rtpPackets from=${packet.address.hostAddress}:${packet.port} " +
                            "bytes=${data.size} ${rtpSummary(data)} fp=${EdgeLinkLog.fingerprint(data)}"
                    )
                }
                if (rtpBatchQueue.trySend(data).isFailure) {
                    rtpBatchDatagramsDropped += 1
                    if (rtpBatchDatagramsDropped == 1 || rtpBatchDatagramsDropped % 100 == 0) {
                        EdgeLinkLog.warn(
                            "xiaomi.mirror.android.cloudflare_rtp_batch_queue_full sessionId=$sessionId " +
                                "dropped=$rtpBatchDatagramsDropped"
                        )
                    }
                }
            }
        }

        private suspend fun flushRTPBatches() {
            val scratch = java.io.ByteArrayOutputStream(RTP_BATCH_MAX_PAYLOAD_BYTES + 64)
            var pending: ByteArray? = null
            while (currentCoroutineContext().isActive) {
                val first = pending ?: rtpBatchQueue.receiveCatching().getOrNull() ?: return
                pending = null
                scratch.reset()
                var datagrams = 0
                var payloadBytes = 0
                var next: ByteArray? = first
                while (next != null) {
                    if (payloadBytes + next.size + 2 > RTP_BATCH_MAX_PAYLOAD_BYTES && datagrams > 0) {
                        pending = next
                        break
                    }
                    scratch.write(next.size shr 8 and 0xff)
                    scratch.write(next.size and 0xff)
                    scratch.write(next)
                    payloadBytes += next.size + 2
                    datagrams += 1
                    next = kotlinx.coroutines.withTimeoutOrNull(RTP_BATCH_MAX_DELAY_MS) {
                        rtpBatchQueue.receiveCatching().getOrNull()
                    }
                }
                if (datagrams == 0) {
                    continue
                }
                val packed = scratch.toByteArray()
                rtpBatchesSent += 1
                if (rtpBatchesSent == 1 || rtpBatchesSent % 100 == 0) {
                    EdgeLinkLog.info(
                        "xiaomi.mirror.android.cloudflare_rtp_batch_out sessionId=$sessionId " +
                            "count=$rtpBatchesSent datagrams=$datagrams bytes=${packed.size} " +
                            "fp=${EdgeLinkLog.fingerprint(packed)}"
                    )
                }
                sendMedia(
                    MiLinkMirrorMediaBody(
                        sessionId = sessionId,
                        direction = ANDROID_TO_MAC,
                        kind = "rtp_batch",
                        dataBase64 = Base64.getEncoder().encodeToString(packed),
                        bytes = packed.size,
                        sequence = rtpBatchesSent,
                        ts = System.currentTimeMillis()
                    )
                )
            }
        }

        suspend fun sendDatagramToSource(body: MiLinkMirrorMediaBody) {
            val packet = body.dataBase64
                ?.takeIf { it.isNotEmpty() }
                ?.let { runCatching { Base64.getDecoder().decode(it) }.getOrNull() }
            if (packet == null) {
                EdgeLinkLog.warn(
                    "xiaomi.mirror.android.cloudflare_mac_datagram_invalid sessionId=$sessionId"
                )
                return
            }
            val udp = udpSocket
            val target = sourceRtpEndpoint
            if (udp == null || udp.isClosed || target == null) {
                EdgeLinkLog.info(
                    "xiaomi.mirror.android.cloudflare_mac_datagram_dropped sessionId=$sessionId " +
                        "bytes=${packet.size} reason=no_source_endpoint"
                )
                return
            }
            macToSourceDatagrams += 1
            if (macToSourceDatagrams == 1 || macToSourceDatagrams % 100 == 0) {
                EdgeLinkLog.info(
                    "xiaomi.mirror.android.cloudflare_mac_datagram_out sessionId=$sessionId " +
                        "count=$macToSourceDatagrams to=${target.address.hostAddress}:${target.port} " +
                        "bytes=${packet.size} fp=${EdgeLinkLog.fingerprint(packet)}"
                )
            }
            withContext(Dispatchers.IO) {
                udp.send(DatagramPacket(packet, packet.size, target))
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
                "xiaomi.mirror.android.cloudflare_rtsp_message sessionId=$sessionId dir=in " +
                    "firstLine=${firstLine.forRTSPLog()} cseq=${cseq.forRTSPLog()} " +
                    "bytes=${message.toByteArray(rtspCharset).size}"
            )
            if (bodyText.isNotBlank()) {
                EdgeLinkLog.info(
                    "xiaomi.mirror.android.cloudflare_rtsp_body sessionId=$sessionId dir=in " +
                        "firstLine=${firstLine.forRTSPLog()} preview=${bodyText.forRTSPLog()}"
                )
            }
            if (firstLine.uppercase().startsWith("RTSP/")) {
                handleRTSPResponse(firstLine, headerText, bodyText, cseq)
                return
            }
            when (rtspRequestMethod(firstLine)) {
                "OPTIONS" -> {
                    sendOfficialOptionsResponse(cseq, headerText)
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
                    sessionHeader = sessionHeader ?: kotlin.math.abs((firstLine + System.nanoTime()).hashCode()).toString()
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
                    sendStatus("source_start")
                }
                "PAUSE", "TEARDOWN" -> {
                    sendRTSPResponse(cseq)
                    sendStatus("source_stop")
                }
                else -> sendRTSPResponse(cseq)
            }
        }

        private suspend fun handleRTSPResponse(firstLine: String, headerText: String, bodyText: String, cseq: String) {
            val requestMethod = pendingRequests.remove(cseq)
            rtspHeader("Session", headerText)
                ?.substringBefore(";")
                ?.trim()
                ?.takeIf { it.isNotEmpty() }
                ?.let { sessionHeader = it }
            val status = rtspStatusCode(firstLine)
            if (status != null && status >= 300) {
                EdgeLinkLog.warn(
                    "xiaomi.mirror.android.cloudflare_rtsp_non_success sessionId=$sessionId " +
                        "request=$requestMethod status=$status firstLine=${firstLine.forRTSPLog()}"
                )
            }
            when (requestMethod) {
                "OPTIONS" -> if (status == null || status < 300) {
                    EdgeLinkLog.info(
                        "xiaomi.mirror.android.cloudflare_rtsp_official_sink_wait_peer_m3 sessionId=$sessionId"
                    )
                }
                "SETUP" -> if (status == null || status < 300) sendPLAYIfNeeded("setup_response")
                "PLAY" -> if (status == null || status < 300) sendStatus("source_start")
            }
        }

        private suspend fun sendOfficialOptionsResponse(cseq: String, requestHeaderText: String) {
            val headers = mutableListOf(
                "Public" to "org.wfa.wfd1.0, GET_PARAMETER, SET_PARAMETER",
                "fastRTSPVersion" to "0"
            )
            val peerAuthMsg = rtspHeader("authMsg", requestHeaderText)
                ?.takeIf { it.isNotEmpty() }
            if (peerAuthMsg == null) {
                EdgeLinkLog.warn(
                    "xiaomi.mirror.android.cloudflare_rtsp_official_auth_ack_unavailable " +
                        "sessionId=$sessionId reason=missing_peer_auth_msg"
                    )
            } else {
                val authKeyType = rtspHeader("authKeyType", requestHeaderText)
                    ?.takeIf { it.isNotEmpty() }
                    ?: OFFICIAL_RTSP_AUTH_KEY_TYPE
                val authAlgorithmVal = officialResponseAuthAlgorithmVal(requestHeaderText)
                val ack = officialAuthMsgAck(peerAuthMsg)
                headers += "authKeyType" to authKeyType
                headers += "authAlgorithmVal" to authAlgorithmVal
                headers += "authMsgAck" to ack
                EdgeLinkLog.info(
                    "xiaomi.mirror.android.cloudflare_rtsp_official_auth_ack_ready sessionId=$sessionId " +
                        "authKeyType=$authKeyType authAlgorithmVal=$authAlgorithmVal"
                )
            }
            sendRTSPResponse(cseq = cseq, headers = headers)
        }

        private fun officialResponseAuthAlgorithmVal(requestHeaderText: String): String {
            val rawTypes = rtspHeader("authAlgorithmTypes", requestHeaderText)
                ?.let(::parseRTSPAuthInteger)
                ?: return OFFICIAL_RTSP_PREFERRED_AUTH_ALGORITHM_VAL
            return when {
                rawTypes and 4 != 0 -> "4"
                rawTypes and 2 != 0 -> "2"
                rawTypes and 1 != 0 -> "1"
                else -> OFFICIAL_RTSP_PREFERRED_AUTH_ALGORITHM_VAL
            }
        }

        private fun officialAuthMsgAck(authMsg: String): String {
            val mac = javax.crypto.Mac.getInstance("HmacSHA256")
            mac.init(javax.crypto.spec.SecretKeySpec(OFFICIAL_SCREEN_AUTH_KEY, "HmacSHA256"))
            return mac.doFinal(authMsg.toByteArray(Charsets.UTF_8)).joinToString("") {
                "%02x".format(it)
            }
        }

        private fun parseRTSPAuthInteger(raw: String): Int? {
            val trimmed = raw.trim()
            return if (trimmed.startsWith("0x", ignoreCase = true)) {
                trimmed.drop(2).toIntOrNull(16)
            } else {
                trimmed.toIntOrNull()
            }
        }

        private suspend fun sendOptionsIfNeeded(reason: String) {
            if (sentOptions) {
                return
            }
            sentOptions = true
            val authMsg = localAuthMsg ?: randomHex(16).also { localAuthMsg = it }
            sendRTSPRequest(
                method = "OPTIONS",
                uri = "*",
                headers = listOf(
                    "User-Agent" to OFFICIAL_RTSP_USER_AGENT,
                    "Require" to "org.wfa.wfd1.0",
                    "lib_version" to OFFICIAL_RTSP_LIB_VERSION,
                    "authMsg" to authMsg,
                    "authKeyType" to OFFICIAL_RTSP_AUTH_KEY_TYPE,
                    "authAlgorithmTypes" to OFFICIAL_RTSP_AUTH_ALGORITHM_TYPES,
                    "fastRTSPVersion" to "0"
                ),
                label = "OPTIONS"
            )
            EdgeLinkLog.info(
                "xiaomi.mirror.android.cloudflare_rtsp_options_sent sessionId=$sessionId reason=$reason"
            )
        }

        private suspend fun sendSinkSETUPIfNeeded(reason: String) {
            if (sentSinkSETUP) {
                return
            }
            sentSinkSETUP = true
            val port = checkNotNull(udpSocket).localPort
            val userId = mptUserId ?: (10_000..65_535).random().toString().also { mptUserId = it }
            sendRTSPRequest(
                method = "SETUP",
                uri = presentationURL ?: "rtsp://localhost/wfd1.0/streamid=0",
                headers = listOf(
                    "Transport" to "RTP/AVP/MPT;unicast;client_port=$port;userid=$userId"
                ),
                label = "SETUP"
            )
            EdgeLinkLog.info(
                "xiaomi.mirror.android.cloudflare_rtsp_setup_sent sessionId=$sessionId " +
                    "reason=$reason rtpPort=$port userid=$userId"
            )
        }

        private suspend fun sendPLAYIfNeeded(reason: String) {
            if (sentPLAY) {
                return
            }
            sentPLAY = true
            playSentAtMs = android.os.SystemClock.elapsedRealtime()
            val headers = sessionHeader?.let { listOf("Session" to it) } ?: emptyList()
            sendRTSPRequest(
                method = "PLAY",
                uri = presentationURL ?: "rtsp://localhost/wfd1.0/streamid=0",
                headers = headers,
                label = "PLAY"
            )
            EdgeLinkLog.info(
                "xiaomi.mirror.android.cloudflare_rtsp_play_sent sessionId=$sessionId reason=$reason"
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
                        "User-Agent" to OFFICIAL_RTSP_USER_AGENT,
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
                        "Server" to "EdgeLinkAndroidMirrorBridge",
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
                "xiaomi.mirror.android.cloudflare_rtsp_message sessionId=$sessionId dir=out " +
                    "firstLine=${firstLine.forRTSPLog()} label=$label bytes=${message.toByteArray(rtspCharset).size}"
            )
            rtspWriteMutex.withLock {
                withContext(Dispatchers.IO) {
                    val activeWriter = checkNotNull(writer)
                    activeWriter.write(message)
                    activeWriter.flush()
                }
            }
        }

        private fun wfdParameterResponseBody(requestBody: String): String {
            val requested = requestBody
                .lineSequence()
                .map { it.trim() }
                .filter { it.isNotEmpty() }
                .map { it.substringBefore(":").lowercase() }
                .toSet()
            val rtpPort = udpSocket?.localPort ?: 0
            val parameters = listOf(
                "wfd_audio_codecs" to "AAC 00000001 00",
                "wfd_audio_codecs_v2" to "2 0 0 0",
                "wfd_video_formats" to XIAOMI_OFFICIAL_HEVC_VIDEO_FORMATS,
                "wfd_video_enctype" to "1 1",
                "wfd_video_gamuttype" to "1 1",
                "wfd_current_video_info" to "-1 -1 -1 -1",
                "wfd_client_rtp_ports" to "RTP/AVP/MPT;unicast $rtpPort 0 mode=play",
                "wfd_content_protection" to "none",
                "wfd_content_SP_protection" to "4 1 256 3 1 1 1 1",
                "wfd_mirror_control_enable" to "enable",
                "wfd_support_secure_win" to "enable",
                "wfd_buffer_capabity" to "1F",
                "wfd_standby_resume_capability" to "supported",
                "wfd_tcp_enable" to "0",
                "wfd_tcp_multi_session_enable" to "0",
                "wfd_mpt_enable" to "1",
                "wfd_image_enable_v2" to "none",
                "wfd_slice_codec" to "none",
                "wfd_delay_test_enable" to "enable",
                "wfd_connector_type" to "07",
                "wfd_presentation_URL" to "${presentationURLForLocalBridge()} none"
            )
            return parameters
                .filter { (name, _) ->
                    name.lowercase() in OFFICIAL_ALWAYS_RETURNED_PARAMETERS ||
                        requested.isEmpty() ||
                        name.lowercase() in requested
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
                EdgeLinkLog.info(
                    "xiaomi.mirror.android.cloudflare_rtsp_presentation_url " +
                        "sessionId=$sessionId url=${value.forRTSPLog()}"
                )
            }
        }

        private fun presentationURLForLocalBridge(): String {
            val host = preferredLocalIPv4Address() ?: "127.0.0.1"
            val port = connectedRtspPort ?: localRtspPorts.firstOrNull() ?: DEFAULT_LOCAL_RTSP_PORT
            return "rtsp://$host:$port/wfd1.0/streamid=0"
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
            val serverPort = udpSocket?.localPort ?: 0
            return if (clientPort != null) {
                "RTP/AVP/UDP;unicast;client_port=$clientPort;server_port=$serverPort-${serverPort + 1}"
            } else {
                "RTP/AVP/UDP;unicast;server_port=$serverPort-${serverPort + 1}"
            }
        }

        private suspend fun sendStatus(event: String) {
            sendMedia(
                MiLinkMirrorMediaBody(
                    sessionId = sessionId,
                    direction = ANDROID_TO_MAC,
                    kind = "status",
                    event = event,
                    ts = System.currentTimeMillis()
                )
            )
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

private const val XIAOMI_OFFICIAL_HEVC_VIDEO_FORMATS = "40 0 2 10 1ffff 1fffffff 0fff 0 0 0 0 none none"
private val OFFICIAL_ALWAYS_RETURNED_PARAMETERS = setOf(
    "wfd_audio_codecs",
    "wfd_audio_codecs_v2",
    "wfd_video_formats",
    "wfd_current_video_info",
    "wfd_client_rtp_ports",
    "wfd_content_sp_protection",
    "wfd_mirror_control_enable",
    "wfd_support_secure_win",
    "wfd_buffer_capabity"
)
private val CRLFCRLF = byteArrayOf(13, 10, 13, 10)

private fun randomHex(byteCount: Int): String {
    val bytes = ByteArray(byteCount)
    java.security.SecureRandom().nextBytes(bytes)
    return bytes.joinToString("") { "%02x".format(it) }
}

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
