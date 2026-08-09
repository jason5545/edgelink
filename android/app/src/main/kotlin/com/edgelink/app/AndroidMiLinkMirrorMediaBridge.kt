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
    private const val RTSP_KEEPALIVE_INTERVAL_MS = 30_000L
    private const val TURN_IDR_REQUEST_POLL_MS = 200L
    private const val TURN_PACER_BYTES_PER_SECOND = 600_000.0
    // Direct data-channel paths (host/srflx candidates, no TURN relay in the
    // leg) are not bound by the ~5-6 Mbps Cloudflare allocation cap; pace
    // just above the ~5 Mbps video + ~1.5 Mbps PCM audio media rate so the
    // token bucket only engages on retransmission bursts, never in steady
    // state (a chronic pace deficit delays source ACKs past their RTO and
    // ignites a retransmission storm — live 2026-08-09).
    private const val TURN_PACER_DIRECT_BYTES_PER_SECOND = 900_000.0
    private const val TURN_PACER_BURST_BYTES = 65_536
    private const val TURN_PACER_MAX_DELAY_MS = 30L
    // Data-channel backpressure: once libwebrtc's SCTP buffer grows past the
    // ceiling, drop instead of piling more into it (bufferbloat inflated RTT
    // to 250ms at a 1MB ceiling, live 2026-08-09). Withheld ACKs make the
    // source retransmit the dropped segments once the buffer drains.
    private const val TURN_DC_BUFFERED_CEILING_BYTES = 262_144L
    private const val RTP_BATCH_MAX_PAYLOAD_BYTES = 6_144
    private const val RTP_BATCH_MAX_DELAY_MS = 3L
    private const val RTP_BATCH_QUEUE_CAPACITY = 1_024
    private const val KCP_ADVERTISED_RECEIVE_WINDOW = 128
    private const val OWN_ADDRESSES_REFRESH_MS = 30_000L
    private const val TURN_DATA_CHANNEL_TIMEOUT_MS = 8_000L
    private const val ACK_WATCH_WINDOW_PUSHES = 2_000L
    private const val ACK_WATCH_MIN_PUSHES = 500L
    private const val LOCAL_RTP_RECEIVE_BUFFER_BYTES = 8 * 1024 * 1024
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
                    // A new cloud session normally restarts the phone-side
                    // source stream along with it (fresh OPEN / source
                    // recovery). The session object — and its KCP sink —
                    // outlive the retarget; without this reset the stale
                    // sequence window black-holes the fresh stream as
                    // "duplicates" (live 2026-08-08: expected=113855 vs a
                    // brand new sn=0 stream).
                    existing.resetSourceStreamState()
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
                    turnMode = request.turnMode,
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
        if (body.direction != MAC_TO_ANDROID || (body.kind != "rtp" && body.kind != "rtp_batch")) {
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

    fun attachTurnDataChannel(
        sessionId: String,
        sendDatagram: (ByteArray) -> Boolean,
        dcBufferedBytes: () -> Long,
        dcPathIsRelay: () -> Boolean?
    ): Boolean {
        val session = activeSession
        if (session == null || sessionId != activeSessionId) {
            EdgeLinkLog.info(
                "mirror.turn.attach_ignored sessionId=$sessionId active=${activeSessionId ?: "none"}"
            )
            return false
        }
        return session.attachTurnDataChannel(sendDatagram, dcBufferedBytes, dcPathIsRelay)
    }

    fun detachTurnDataChannel(sessionId: String, reason: String) {
        val session = activeSession
        if (session != null && sessionId == activeSessionId) {
            session.detachTurnDataChannel(reason)
        }
    }

    fun handleTurnDatagram(data: ByteArray) {
        activeSession?.sendTurnDatagramToSource(data)
    }

    fun switchToWebSocketFallback(reason: String) {
        activeSession?.switchToWebSocketFallback(reason)
    }

    private class MirrorMediaBridgeSession(
        sessionId: String,
        private val localRtspPorts: List<Int>,
        private val startReason: String,
        private val turnMode: Boolean,
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
        private var payloadsQueued = 0L
        private var payloadsBatched = 0L

        fun retarget(newSessionId: String, newSendMedia: suspend (MiLinkMirrorMediaBody) -> Unit) {
            sessionId = newSessionId
            sendMedia = newSendMedia
        }

        // Retarget = new cloud session = the source stream restarts with a
        // fresh KCP conversation. Drop the sink's per-stream state so the
        // new sn=0 stream is not judged against the old sequence window.
        fun resetSourceStreamState() {
            kcpSink?.resetForNewStream()
            // Break the current local RTSP dialog: the run loop reconnects
            // with a fresh OPTIONS/SETUP/PLAY and the WFD source restarts
            // its stream, re-emitting the head (HEVC parameter sets + IDR).
            // Without this the retargeted receiver joins mid-stream and can
            // never decode (the source only emits VPS/SPS/PPS at stream
            // start — live 2026-08-08: firstSn=733/6819/14450, 0 frames).
            runCatching { writer?.close() }
            runCatching { socket?.close() }
            turnIdrRequestPending = true
            // Each cloud session brings its own TURN offer/data channel; a
            // fallback decision from the previous session must not reject
            // the new one's attach.
            turnFallbackTriggered = false
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
        @Volatile
        private var turnDataChannelActive = false
        @Volatile
        private var turnFallbackTriggered = false
        @Volatile
        private var turnSendDatagram: ((ByteArray) -> Boolean)? = null
        @Volatile
        private var turnDcBufferedBytes: (() -> Long)? = null
        @Volatile
        private var turnDcPathIsRelay: (() -> Boolean?)? = null
        private var turnLoopbackIn = 0L
        private var turnLoopbackDropped = 0L
        private var turnMacControlDropped = 0L
        private var turnDcSendFailed = 0L
        private var turnDcBackpressureDrops = 0L
        private var kcpSink: MiLinkMirrorKcpSink? = null
        private var ackViaLoopback = false
        private val turnPacer = TurnPacer(
            rateBytesPerSecond = {
                if (turnDcPathIsRelay?.invoke() == false) {
                    TURN_PACER_DIRECT_BYTES_PER_SECOND
                } else {
                    TURN_PACER_BYTES_PER_SECOND
                }
            },
            burstBytes = TURN_PACER_BURST_BYTES,
            maxDelayMs = TURN_PACER_MAX_DELAY_MS
        )
        @Volatile
        private var turnIdrRequestPending = false
        private var ownAddresses: Set<InetAddress> = emptySet()
        private var ownAddressesRefreshedAtMs = 0L

        fun attachTurnDataChannel(
            sendDatagram: (ByteArray) -> Boolean,
            dcBufferedBytes: () -> Long,
            dcPathIsRelay: () -> Boolean?
        ): Boolean {
            if (!turnMode || turnFallbackTriggered) {
                EdgeLinkLog.info(
                    "mirror.turn.attach_rejected sessionId=$sessionId turnMode=$turnMode fallback=$turnFallbackTriggered"
                )
                return false
            }
            turnSendDatagram = sendDatagram
            turnDcBufferedBytes = dcBufferedBytes
            turnDcPathIsRelay = dcPathIsRelay
            turnDataChannelActive = true
            // The source starts streaming on PLAY before the data channel
            // opens, so the first IDR is always dropped pre-attach. Ask for a
            // fresh one as soon as the channel is up.
            turnIdrRequestPending = true
            EdgeLinkLog.info("mirror.turn.bridge_attached sessionId=$sessionId")
            return true
        }

        fun detachTurnDataChannel(reason: String) {
            if (turnSendDatagram != null || turnDataChannelActive) {
                EdgeLinkLog.info("mirror.turn.bridge_detached sessionId=$sessionId reason=$reason")
            }
            turnDataChannelActive = false
            turnSendDatagram = null
            turnDcBufferedBytes = null
            turnDcPathIsRelay = null
        }

        fun switchToWebSocketFallback(reason: String) {
            if (!turnMode || turnFallbackTriggered) {
                return
            }
            turnFallbackTriggered = true
            turnDataChannelActive = false
            turnSendDatagram = null
            turnDcBufferedBytes = null
            turnDcPathIsRelay = null
            EdgeLinkLog.warn(
                "mirror.turn.ws_fallback sessionId=$sessionId reason=$reason loopbackIn=$turnLoopbackIn dropped=$turnLoopbackDropped"
            )
        }

        private fun resolveAckTarget(socket: DatagramSocket, target: InetSocketAddress): InetSocketAddress {
            if (!ackViaLoopback || target.address.isLoopbackAddress) {
                return target
            }
            val now = System.currentTimeMillis()
            if (now - ownAddressesRefreshedAtMs > OWN_ADDRESSES_REFRESH_MS) {
                ownAddressesRefreshedAtMs = now
                ownAddresses = runCatching {
                    NetworkInterface.getNetworkInterfaces().toList()
                        .flatMap { it.inetAddresses.toList() }
                        .toSet()
                }.getOrDefault(emptySet())
            }
            if (!ownAddresses.contains(target.address)) {
                return target
            }
            return InetSocketAddress(InetAddress.getLoopbackAddress(), target.port)
        }

        fun sendTurnDatagramToSource(data: ByteArray) {
            if (!turnMode || turnFallbackTriggered || !turnDataChannelActive) {
                return
            }
            // Mac-side KCP control (ACK/WINS) is NOT relayed to the source:
            // the local sink terminates the source-facing KCP in TURN mode.
            // Relaying these ACKs end-to-end arrives ~0.5s late (past the
            // source's LAN-tuned RTO), which made the source retransmit
            // every segment exactly once — half of all relay traffic was
            // duplicates and audio/video stuttered (live 2026-08-08).
            turnMacControlDropped += 1
            if (turnMacControlDropped == 1L || turnMacControlDropped % 1_000 == 0L) {
                EdgeLinkLog.info(
                    "mirror.turn.mac_control_dropped sessionId=$sessionId count=$turnMacControlDropped bytes=${data.size}"
                )
            }
        }

        private fun ensureKcpSink(socket: DatagramSocket): MiLinkMirrorKcpSink =
            kcpSink ?: MiLinkMirrorKcpSink(
                sessionId = { sessionId },
                receiveWindow = { KCP_ADVERTISED_RECEIVE_WINDOW },
                onSendDatagram = { reply ->
                    val target = sourceRtpEndpoint
                    if (target != null && !socket.isClosed) {
                        runCatching {
                            val ackTarget = resolveAckTarget(socket, target)
                            socket.send(DatagramPacket(reply, reply.size, ackTarget))
                        }
                    }
                },
                onPayload = { payload ->
                    if (turnMode && !turnFallbackTriggered) {
                        // TURN forwards the raw datagrams; the sink runs in
                        // ACK-only mode here, so the extracted payload must
                        // not also queue onto the WebSocket batch path.
                        return@MiLinkMirrorKcpSink
                    }
                    payloadsQueued += 1
                    if (rtpBatchQueue.trySend(payload).isFailure) {
                        rtpBatchDatagramsDropped += 1
                        if (rtpBatchDatagramsDropped == 1 || rtpBatchDatagramsDropped % 100 == 0) {
                            EdgeLinkLog.warn(
                                "xiaomi.mirror.android.cloudflare_rtp_batch_queue_full sessionId=$sessionId " +
                                    "dropped=$rtpBatchDatagramsDropped"
                            )
                        }
                    }
                }
            ).also { kcpSink = it }

        suspend fun run() = coroutineScope {
            sendStatus("bridge_starting")
            val udp = DatagramSocket(null).apply {
                reuseAddress = true
                soTimeout = 2_000
                receiveBufferSize = LOCAL_RTP_RECEIVE_BUFFER_BYTES
                bind(InetSocketAddress(0))
            }
            udpSocket = udp
            EdgeLinkLog.info(
                "xiaomi.mirror.android.cloudflare_local_rtp_ready sessionId=$sessionId " +
                    "port=${udp.localPort} receiveBuffer=${udp.receiveBufferSize} reason=$startReason"
            )
            val udpJob = launch { receiveRTP(udp) }
            val batchJob = launch { flushRTPBatches() }
            val rtspKeepaliveJob = launch { rtspKeepaliveLoop() }
            if (turnMode) {
                launch { turnIdrRequestLoop() }
                launch {
                    delay(TURN_DATA_CHANNEL_TIMEOUT_MS)
                    if (!turnDataChannelActive) {
                        switchToWebSocketFallback("dc_open_timeout")
                    }
                }
            }
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
                rtspKeepaliveJob.cancel()
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
            var ackWatchLastPushes = 0L
            var ackWatchLastDuplicates = 0L
            var ackWatchLoggedLoopback = false
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
                if (turnMode && !turnFallbackTriggered) {
                    turnLoopbackIn += 1
                    if (turnLoopbackIn == 1L || turnLoopbackIn % 100 == 0L) {
                        EdgeLinkLog.info(
                            "mirror.turn.loopback_in sessionId=$sessionId count=$turnLoopbackIn " +
                                "from=${packet.address.hostAddress}:${packet.port} bytes=${data.size} " +
                                "fp=${EdgeLinkLog.fingerprint(data)}"
                        )
                    }
                    val forward = turnSendDatagram
                    if (turnDataChannelActive && forward != null) {
                        // Conditional ACK on every path: the sink ACKs only
                        // segments that were actually handed to the data
                        // channel. Withheld ACKs make the source's KCP
                        // retransmit drops and — just as important — throttle
                        // the source down to the rate the dc leg can sustain.
                        // Unconditional immediate ACKs let the source stream
                        // at encoder rate regardless of dc capacity: the
                        // excess either shed inside the unreliable SCTP
                        // association (40% loss, live 2026-08-09) or pinned
                        // the reliable SCTP buffer at its ceiling and inflated
                        // RTT to 250ms while the receive loop stalled behind
                        // backpressure waits, delaying source ACKs ~400ms and
                        // igniting a retransmission storm (pcap 2026-08-09).
                        // Drops below (pacing, backpressure, pre-attach) heal
                        // themselves via source retransmit.
                        val buffered = turnDcBufferedBytes?.invoke() ?: 0L
                        var forwarded = false
                        if (buffered > TURN_DC_BUFFERED_CEILING_BYTES) {
                            // Do not pile into a congested SCTP buffer
                            // (bufferbloat). Dropping here withholds the ACK,
                            // so the source retransmits once the buffer has
                            // drained — the dc drain rate becomes the source
                            // rate.
                            turnDcBackpressureDrops += 1
                            if (turnDcBackpressureDrops == 1L || turnDcBackpressureDrops % 500 == 0L) {
                                EdgeLinkLog.warn(
                                    "mirror.turn.dc_backpressure_drop sessionId=$sessionId " +
                                        "count=$turnDcBackpressureDrops bufferedBytes=$buffered"
                                )
                            }
                        } else {
                            when (val paceWaitMs = turnPacer.admit(data.size)) {
                                null -> {
                                    if (turnPacer.droppedCount == 1L || turnPacer.droppedCount % 500 == 0L) {
                                        EdgeLinkLog.warn(
                                            "mirror.turn.pace_dropped sessionId=$sessionId " +
                                                "count=${turnPacer.droppedCount}"
                                        )
                                    }
                                }
                                else -> {
                                    if (paceWaitMs > 0) {
                                        if (turnPacer.delayedCount == 1L || turnPacer.delayedCount % 2_000 == 0L) {
                                            EdgeLinkLog.info(
                                                "mirror.turn.pace_delayed sessionId=$sessionId " +
                                                    "count=${turnPacer.delayedCount} delayMs=$paceWaitMs"
                                            )
                                        }
                                        delay(paceWaitMs)
                                    }
                                    forwarded = forward(data)
                                    if (!forwarded) {
                                        turnDcSendFailed += 1
                                        if (turnDcSendFailed == 1L || turnDcSendFailed % 500 == 0L) {
                                            EdgeLinkLog.warn(
                                                "mirror.turn.dc_send_failed sessionId=$sessionId " +
                                                    "count=$turnDcSendFailed bufferedBytes=$buffered"
                                            )
                                        }
                                    }
                                }
                            }
                        }
                        if (forwarded) {
                            ensureKcpSink(socket).receiveDatagram(data)
                        }
                    } else {
                        turnLoopbackDropped += 1
                    }
                    continue
                }
                if (rtpPackets == 1 || rtpPackets % 100 == 0) {
                    EdgeLinkLog.info(
                        "xiaomi.mirror.android.cloudflare_local_rtp_in sessionId=$sessionId " +
                            "count=$rtpPackets from=${packet.address.hostAddress}:${packet.port} " +
                            "bytes=${data.size} ${rtpSummary(data)} fp=${EdgeLinkLog.fingerprint(data)}"
                    )
                }
                val sink = ensureKcpSink(socket)
                sink.receiveDatagram(data)
                val watchPushes = sink.pushReceived
                if (watchPushes - ackWatchLastPushes >= ACK_WATCH_WINDOW_PUSHES) {
                    val dupDelta = sink.duplicateDropped - ackWatchLastDuplicates
                    val pushDelta = watchPushes - ackWatchLastPushes
                    ackWatchLastPushes = watchPushes
                    ackWatchLastDuplicates = sink.duplicateDropped
                    val replyEndpoint = sourceRtpEndpoint
                    if (ackViaLoopback && !ackWatchLoggedLoopback && replyEndpoint != null &&
                        !replyEndpoint.address.isLoopbackAddress
                    ) {
                        ackWatchLoggedLoopback = true
                        EdgeLinkLog.info(
                            "xiaomi.mirror.android.kcp_ack_loopback sessionId=$sessionId " +
                                "source=${replyEndpoint.address.hostAddress}:${replyEndpoint.port}"
                        )
                    }
                    if (ackViaLoopback && ackWatchLoggedLoopback && pushDelta >= ACK_WATCH_MIN_PUSHES &&
                        dupDelta * 4 > pushDelta
                    ) {
                        ackViaLoopback = false
                        EdgeLinkLog.warn(
                            "xiaomi.mirror.android.kcp_ack_loopback_fallback sessionId=$sessionId " +
                                "dupDelta=$dupDelta pushDelta=$pushDelta"
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
                    payloadsBatched += 1
                    next = kotlinx.coroutines.withTimeoutOrNull(RTP_BATCH_MAX_DELAY_MS) {
                        rtpBatchQueue.receiveCatching().getOrNull()
                    }
                }
                if (datagrams == 0) {
                    continue
                }
                if (rtpBatchesSent % 500 == 0) {
                    val backlog = payloadsQueued - payloadsBatched
                    EdgeLinkLog.info(
                        "xiaomi.mirror.android.cloudflare_queue_health sessionId=$sessionId " +
                            "queued=$payloadsQueued batched=$payloadsBatched backlog=$backlog"
                    )
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
                        kind = "rtp_payload_batch",
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
                if (body.kind == "rtp_batch") {
                    var offset = 0
                    while (offset + 2 <= packet.size) {
                        val chunkLength = (packet[offset].toInt() and 0xFF shl 8) or
                            (packet[offset + 1].toInt() and 0xFF)
                        if (chunkLength <= 0 || offset + 2 + chunkLength > packet.size) {
                            break
                        }
                        udp.send(DatagramPacket(packet, offset + 2, chunkLength, target))
                        offset += 2 + chunkLength
                    }
                } else {
                    udp.send(DatagramPacket(packet, packet.size, target))
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

        // Token-bucket pacing lives in TurnPacer (unit-tested); the pacer
        // decides delay-or-drop and this loop performs the wait and the send.
        private suspend fun turnIdrRequestLoop() {
            while (currentCoroutineContext().isActive) {
                delay(TURN_IDR_REQUEST_POLL_MS)
                if (!turnIdrRequestPending || !sentPLAY || sessionHeader == null) {
                    continue
                }
                turnIdrRequestPending = false
                runCatching {
                    sendRTSPRequest(
                        method = "SET_PARAMETER",
                        uri = presentationURL ?: "rtsp://localhost/wfd1.0/streamid=0",
                        headers = listOfNotNull(
                            sessionHeader?.let { "Session" to it },
                            "Content-Type" to "text/parameters"
                        ),
                        body = "wfd_idr_request\r\n",
                        label = "idr_request"
                    )
                    EdgeLinkLog.info(
                        "xiaomi.mirror.android.cloudflare_rtsp_idr_sent sessionId=$sessionId reason=turn_attach"
                    )
                }
            }
        }

        private suspend fun rtspKeepaliveLoop() {
            while (currentCoroutineContext().isActive) {
                delay(RTSP_KEEPALIVE_INTERVAL_MS)
                if (!sentPLAY || sessionHeader == null) {
                    continue
                }
                runCatching {
                    sendRTSPRequest(
                        method = "GET_PARAMETER",
                        uri = presentationURL ?: "rtsp://localhost/wfd1.0/streamid=0",
                        headers = sessionHeader?.let { listOf("Session" to it) } ?: emptyList(),
                        label = "KEEPALIVE"
                    )
                    EdgeLinkLog.info(
                        "xiaomi.mirror.android.cloudflare_rtsp_keepalive_sent sessionId=$sessionId"
                    )
                }
            }
        }

        private suspend fun sendPLAYIfNeeded(reason: String) {
            if (sentPLAY) {
                return
            }
            if (turnMode && !turnFallbackTriggered) {
                // The official source emits its HEVC parameter sets + first
                // IDR at stream start and does not re-send them on IDR
                // request, so any media produced before the data channel
                // opens is unrecoverable on the Mac. Hold PLAY until the
                // channel is attached (or the WS fallback decision lands).
                val waitedStartMs = android.os.SystemClock.elapsedRealtime()
                while (currentCoroutineContext().isActive &&
                    !turnDataChannelActive && !turnFallbackTriggered
                ) {
                    delay(100)
                }
                EdgeLinkLog.info(
                    "mirror.turn.play_gate sessionId=$sessionId reason=$reason " +
                        "dcActive=$turnDataChannelActive fallback=$turnFallbackTriggered " +
                        "waitedMs=${android.os.SystemClock.elapsedRealtime() - waitedStartMs}"
                )
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
                "wfd_video_bitrate" to (if (turnMode) XIAOMI_TURN_VIDEO_BITRATE else XIAOMI_OFFICIAL_VIDEO_BITRATE).toString(),
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
private const val XIAOMI_OFFICIAL_VIDEO_BITRATE = 5_000_000
private const val XIAOMI_TURN_VIDEO_BITRATE = 5_000_000
private val OFFICIAL_ALWAYS_RETURNED_PARAMETERS = setOf(
    "wfd_audio_codecs",
    "wfd_audio_codecs_v2",
    "wfd_video_formats",
    "wfd_video_bitrate",
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
