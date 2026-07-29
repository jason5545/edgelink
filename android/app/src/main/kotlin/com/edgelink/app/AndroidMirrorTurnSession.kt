package com.edgelink.app

import android.content.Context
import android.os.Handler
import android.os.HandlerThread
import com.edgelink.core.EnvelopeCodec
import com.edgelink.core.EnvelopeTypes
import com.edgelink.core.MiLinkMirrorRtcAnswerBody
import com.edgelink.core.MiLinkMirrorRtcIceBody
import com.edgelink.core.MiLinkMirrorRtcOfferBody
import java.nio.ByteBuffer
import java.util.Locale
import org.webrtc.DataChannel
import org.webrtc.IceCandidate
import org.webrtc.MediaConstraints
import org.webrtc.MediaStream
import org.webrtc.PeerConnection
import org.webrtc.PeerConnectionFactory
import org.webrtc.RTCStats
import org.webrtc.RTCStatsReport
import org.webrtc.RtpReceiver
import org.webrtc.SdpObserver
import org.webrtc.SessionDescription

class AndroidMirrorTurnSession(
    context: Context,
    private val sessionId: String,
    iceServers: List<AndroidScreenIceServerConfig>,
    private val sendPlaintext: (ByteArray) -> Unit,
    private val onDatagram: (ByteArray) -> Unit,
    private val onDataChannelOpen: () -> Unit,
    private val onFailed: (String) -> Unit
) {
    private val appContext = context.applicationContext
    private val turnIceServers: List<PeerConnection.IceServer> = iceServers.mapNotNull { server ->
        val udpUrls = server.urls.filter { it.contains("transport=udp") }
        if (udpUrls.isEmpty()) {
            null
        } else {
            val builder = PeerConnection.IceServer.builder(udpUrls)
            if (!server.username.isNullOrBlank() && !server.credential.isNullOrBlank()) {
                builder.setUsername(server.username)
                builder.setPassword(server.credential)
            }
            builder.createIceServer()
        }
    }

    private val lock = Any()
    private var factory: PeerConnectionFactory? = null
    private var peerConnection: PeerConnection? = null
    private var dataChannel: DataChannel? = null
    private var dataChannelObserver: DataChannel.Observer? = null
    private var statsHandlerThread: HandlerThread? = null
    private var statsHandler: Handler? = null
    @Volatile
    private var closed = false
    @Volatile
    private var dataChannelOpen = false
    @Volatile
    private var iceDisconnectedRunnable: Runnable? = null
    private val createdAtMs = android.os.SystemClock.elapsedRealtime()
    private var datagramsSent = 0L
    private var datagramsSentBytes = 0L
    private var datagramsReceived = 0L

    @Synchronized
    fun handleOffer(body: MiLinkMirrorRtcOfferBody) {
        if (closed) {
            return
        }
        if (body.sessionId != sessionId) {
            EdgeLinkLog.info(
                "mirror.turn.offer_ignored sessionId=${body.sessionId} active=$sessionId"
            )
            return
        }
        if (turnIceServers.isEmpty()) {
            fail("no_udp_turn_urls")
            return
        }
        val pc = ensurePeerConnection() ?: return
        EdgeLinkLog.info("mirror.turn.offer_in sessionId=$sessionId bytes=${body.sdp.length}")
        pc.setRemoteDescription(
            object : SdpObserver by noopSdpObserver() {
                override fun onSetSuccess() {
                    createAnswer(pc)
                }

                override fun onSetFailure(error: String) {
                    fail("set_remote_offer_failed:$error")
                }
            },
            SessionDescription(SessionDescription.Type.OFFER, body.sdp)
        )
    }

    @Synchronized
    fun handleIce(body: MiLinkMirrorRtcIceBody) {
        if (closed || body.sessionId != sessionId) {
            return
        }
        peerConnection?.addIceCandidate(IceCandidate(body.mid, body.index, body.candidate))
    }

    fun send(datagram: ByteArray) {
        val channel = dataChannel ?: return
        if (!dataChannelOpen) {
            return
        }
        datagramsSent += 1
        datagramsSentBytes += datagram.size
        if (datagramsSent == 1L || datagramsSent % 100 == 0L) {
            EdgeLinkLog.info(
                "mirror.turn.dc_out sessionId=$sessionId datagrams=$datagramsSent bytes=$datagramsSentBytes"
            )
        }
        channel.send(DataChannel.Buffer(ByteBuffer.wrap(datagram), true))
    }

    @Synchronized
    fun close(reason: String) {
        if (closed) {
            return
        }
        closed = true
        EdgeLinkLog.info("mirror.turn.stop sessionId=$sessionId reason=$reason open=$dataChannelOpen")
        statsHandler?.removeCallbacksAndMessages(null)
        statsHandler = null
        statsHandlerThread?.quitSafely()
        statsHandlerThread = null
        dataChannel?.let { channel ->
            runCatching { channel.unregisterObserver() }
            runCatching { channel.close() }
            runCatching { channel.dispose() }
        }
        dataChannel = null
        dataChannelObserver = null
        peerConnection?.let { pc ->
            runCatching { pc.close() }
            runCatching { pc.dispose() }
        }
        peerConnection = null
        factory?.let { runCatching { it.dispose() } }
        factory = null
    }

    private fun ensurePeerConnection(): PeerConnection? {
        peerConnection?.let { return it }
        if (closed) {
            return null
        }
        AndroidScreenSession.ensureWebRtcInitialized(appContext)
        val localFactory = PeerConnectionFactory.builder().createPeerConnectionFactory()
        factory = localFactory
        val config = PeerConnection.RTCConfiguration(turnIceServers).apply {
            sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN
            iceTransportsType = PeerConnection.IceTransportsType.ALL
        }
        EdgeLinkLog.info(
            "mirror.turn.peer_connection_config sessionId=$sessionId servers=${turnIceServers.size} " +
                "urls=${turnIceServers.flatMap { it.urls }.joinToString(",")}"
        )
        val pc = localFactory.createPeerConnection(config, peerObserver()) ?: run {
            fail("peer_connection_create_failed")
            return null
        }
        peerConnection = pc
        startStatsLogging(pc)
        return pc
    }

    private fun createAnswer(pc: PeerConnection) {
        pc.createAnswer(
            object : SdpObserver {
                override fun onCreateSuccess(description: SessionDescription) {
                    pc.setLocalDescription(
                        object : SdpObserver by noopSdpObserver() {
                            override fun onSetSuccess() {
                                EdgeLinkLog.info(
                                    "mirror.turn.answer_out sessionId=$sessionId bytes=${description.description.length}"
                                )
                                sendPlaintext(
                                    EnvelopeCodec.encode(
                                        EnvelopeTypes.MILINK_MIRROR_RTC_ANSWER,
                                        MiLinkMirrorRtcAnswerBody(sessionId = sessionId, sdp = description.description)
                                    )
                                )
                            }

                            override fun onSetFailure(error: String) {
                                fail("set_local_answer_failed:$error")
                            }
                        },
                        description
                    )
                }

                override fun onSetSuccess() = Unit

                override fun onCreateFailure(error: String) {
                    fail("answer_create_failed:$error")
                }

                override fun onSetFailure(error: String) = Unit
            },
            MediaConstraints()
        )
    }

    private fun peerObserver(): PeerConnection.Observer =
        object : PeerConnection.Observer {
            override fun onSignalingChange(newState: PeerConnection.SignalingState) = Unit

            override fun onIceConnectionChange(newState: PeerConnection.IceConnectionState) {
                EdgeLinkLog.info("mirror.turn.ice_state sessionId=$sessionId state=$newState")
                when (newState) {
                    PeerConnection.IceConnectionState.FAILED -> fail("ice_failed")
                    PeerConnection.IceConnectionState.CLOSED -> if (!closed) fail("ice_closed")
                    PeerConnection.IceConnectionState.DISCONNECTED -> scheduleIceDisconnectedFail()
                    PeerConnection.IceConnectionState.CONNECTED,
                    PeerConnection.IceConnectionState.COMPLETED -> cancelIceDisconnectedFail()
                    else -> Unit
                }
            }

            override fun onIceConnectionReceivingChange(receiving: Boolean) = Unit

            override fun onIceGatheringChange(newState: PeerConnection.IceGatheringState) = Unit

            override fun onIceCandidate(candidate: IceCandidate) {
                sendPlaintext(
                    EnvelopeCodec.encode(
                        EnvelopeTypes.MILINK_MIRROR_RTC_ICE,
                        MiLinkMirrorRtcIceBody(
                            sessionId = sessionId,
                            mid = candidate.sdpMid.orEmpty(),
                            index = candidate.sdpMLineIndex,
                            candidate = candidate.sdp
                        )
                    )
                )
            }

            override fun onIceCandidatesRemoved(candidates: Array<out IceCandidate>) = Unit
            override fun onAddStream(stream: MediaStream) = Unit
            override fun onRemoveStream(stream: MediaStream) = Unit
            override fun onRenegotiationNeeded() = Unit
            override fun onAddTrack(receiver: RtpReceiver, mediaStreams: Array<out MediaStream>) = Unit

            override fun onDataChannel(channel: DataChannel) {
                if (channel.label() != DATA_CHANNEL_LABEL) {
                    EdgeLinkLog.info("mirror.turn.dc_ignored label=${channel.label()}")
                    return
                }
                val observer = object : DataChannel.Observer {
                    override fun onBufferedAmountChange(previousAmount: Long) = Unit

                    override fun onStateChange() {
                        val state = channel.state()
                        EdgeLinkLog.info("mirror.turn.dc_state sessionId=$sessionId state=$state")
                        if (state == DataChannel.State.OPEN && !dataChannelOpen) {
                            dataChannelOpen = true
                            val elapsedMs = android.os.SystemClock.elapsedRealtime() - createdAtMs
                            EdgeLinkLog.info("mirror.turn.dc_open sessionId=$sessionId elapsedMs=$elapsedMs")
                            onDataChannelOpen()
                        } else if ((state == DataChannel.State.CLOSING || state == DataChannel.State.CLOSED) &&
                            dataChannelOpen && !closed
                        ) {
                            fail("dc_closed")
                        }
                    }

                    override fun onMessage(buffer: DataChannel.Buffer) {
                        val bytes = ByteArray(buffer.data.remaining())
                        buffer.data.get(bytes)
                        datagramsReceived += 1
                        onDatagram(bytes)
                    }
                }
                dataChannel = channel
                dataChannelObserver = observer
                channel.registerObserver(observer)
            }
        }

    private fun startStatsLogging(pc: PeerConnection) {
        val thread = HandlerThread("EdgeLinkMirrorTurnStats").apply { start() }
        val handler = Handler(thread.looper)
        statsHandlerThread = thread
        statsHandler = handler
        val task = object : Runnable {
            override fun run() {
                if (closed || peerConnection !== pc) {
                    return
                }
                pc.getStats { report ->
                    handler.post {
                        if (!closed && peerConnection === pc) {
                            logStats(report)
                        }
                    }
                }
                handler.postDelayed(this, STATS_INTERVAL_MS)
            }
        }
        handler.postDelayed(task, STATS_INTERVAL_MS)
    }

    private fun logStats(report: RTCStatsReport) {
        val statsById = report.statsMap
        val pair = statsById.values.firstOrNull { stat ->
            stat.type == "candidate-pair" &&
                stat.members.statString("state") == "succeeded" &&
                (stat.members.statBoolean("nominated") == true || stat.members.statBoolean("selected") == true)
        } ?: return
        val members = pair.members
        val localType = members.statString("localCandidateId")
            ?.let { statsById[it]?.members?.statString("candidateType") }
        val remoteType = members.statString("remoteCandidateId")
            ?.let { statsById[it]?.members?.statString("candidateType") }
        val rttMs = members.statDouble("currentRoundTripTime")?.let { it * 1_000.0 }
        val bitrate = members.statDouble("availableOutgoingBitrate")
            ?: members.statDouble("availableIncomingBitrate")
        EdgeLinkLog.info(
            "mirror.turn.stats sessionId=$sessionId open=$dataChannelOpen " +
                "rttMs=${formatStat1(rttMs)} abwKbps=${formatStatKbps(bitrate)} " +
                "path=${localType ?: "-"}>${remoteType ?: "-"} " +
                "dcIn=$datagramsReceived dcOut=$datagramsSent"
        )
    }

    private fun fail(reason: String) {
        if (closed) {
            return
        }
        EdgeLinkLog.warn("mirror.turn.dc_failed sessionId=$sessionId reason=$reason")
        onFailed(reason)
    }

    // ICE DISCONNECTED is frequently transient (Wi-Fi jitter); only treat it
    // as fatal when it persists, so the bridge can fall back to WebSocket.
    private fun scheduleIceDisconnectedFail() {
        if (!dataChannelOpen || closed || iceDisconnectedRunnable != null) {
            return
        }
        val runnable = Runnable {
            iceDisconnectedRunnable = null
            EdgeLinkLog.warn(
                "mirror.turn.ice_disconnected_sustained sessionId=$sessionId waitMs=$ICE_DISCONNECTED_FAIL_MS"
            )
            fail("ice_disconnected_sustained")
        }
        iceDisconnectedRunnable = runnable
        statsHandler?.postDelayed(runnable, ICE_DISCONNECTED_FAIL_MS)
    }

    private fun cancelIceDisconnectedFail() {
        iceDisconnectedRunnable?.let { statsHandler?.removeCallbacks(it) }
        iceDisconnectedRunnable = null
    }

    private fun noopSdpObserver(): SdpObserver =
        object : SdpObserver {
            override fun onCreateSuccess(description: SessionDescription) = Unit
            override fun onSetSuccess() = Unit
            override fun onCreateFailure(error: String) = Unit
            override fun onSetFailure(error: String) = Unit
        }

    companion object {
        const val DATA_CHANNEL_LABEL = "edgelink-mirror-media"
        private const val STATS_INTERVAL_MS = 5_000L
        private const val ICE_DISCONNECTED_FAIL_MS = 4_000L
    }
}

private fun Map<String, Any>.statString(name: String): String? =
    this[name]?.toString()

private fun Map<String, Any>.statDouble(name: String): Double? =
    when (val value = this[name]) {
        is Number -> value.toDouble()
        is String -> value.toDoubleOrNull()
        else -> null
    }

private fun Map<String, Any>.statBoolean(name: String): Boolean? =
    when (val value = this[name]) {
        is Boolean -> value
        is String -> value.toBooleanStrictOrNull()
        else -> null
    }

private fun formatStat1(value: Double?): String =
    value?.let { String.format(Locale.US, "%.1f", it) } ?: "-"

private fun formatStatKbps(value: Double?): String =
    value?.let { String.format(Locale.US, "%.0f", it / 1_000.0) } ?: "-"
