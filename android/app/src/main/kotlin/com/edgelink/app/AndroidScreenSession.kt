package com.edgelink.app

import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjection
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.util.DisplayMetrics
import android.view.WindowManager
import com.edgelink.core.EnvelopeCodec
import com.edgelink.core.EnvelopeTypes
import com.edgelink.core.RtcIceBody
import com.edgelink.core.RtcSdpBody
import com.edgelink.core.ScreenMetaBody
import org.webrtc.DataChannel
import org.webrtc.CapturerObserver
import org.webrtc.DefaultVideoDecoderFactory
import org.webrtc.DefaultVideoEncoderFactory
import org.webrtc.EglBase
import org.webrtc.IceCandidate
import org.webrtc.MediaConstraints
import org.webrtc.MediaStream
import org.webrtc.PeerConnection
import org.webrtc.PeerConnectionFactory
import org.webrtc.RtpReceiver
import org.webrtc.RtpParameters
import org.webrtc.RtpSender
import org.webrtc.RTCStats
import org.webrtc.RTCStatsReport
import org.webrtc.ScreenCapturerAndroid
import org.webrtc.SessionDescription
import org.webrtc.SdpObserver
import org.webrtc.SurfaceTextureHelper
import org.webrtc.VideoCapturer
import org.webrtc.VideoFrame
import org.webrtc.VideoSource
import org.webrtc.VideoTrack
import java.util.Locale
import java.util.concurrent.atomic.AtomicBoolean

class AndroidScreenSession(
    private val context: Context,
    private val sendPlaintext: (ByteArray) -> Unit
) {
    private val appContext = context.applicationContext
    private var eglBase: EglBase? = null
    private var factory: PeerConnectionFactory? = null
    private var peerConnection: PeerConnection? = null
    private var surfaceTextureHelper: SurfaceTextureHelper? = null
    private var capturer: VideoCapturer? = null
    private var videoSource: VideoSource? = null
    private var videoTrack: VideoTrack? = null
    private var statsHandlerThread: HandlerThread? = null
    private var statsHandler: Handler? = null
    private val statsLogger = ScreenStatsLogger()
    private val isStopping = AtomicBoolean(false)

    fun requestStart() {
        EdgeLinkLog.info("screen.android.start_requested")
        ScreenCapturePermissionActivity.start(appContext)
    }

    fun startWithPermission(resultCode: Int, data: Intent) {
        EdgeLinkLog.info("screen.android.permission_granted resultCode=$resultCode")
        stop(sendStopToService = false)
        isStopping.set(false)

        try {
            initializeWebRtc()
            val meta = currentScreenMeta()
            sendPlaintext(EnvelopeCodec.encode(EnvelopeTypes.SCREEN_META, meta))

            val localEglBase = eglBase ?: error("EGL is not initialized.")
            val localFactory = factory ?: error("PeerConnectionFactory is not initialized.")
            val helper = SurfaceTextureHelper.create(
                "EdgeLinkScreenCapture",
                localEglBase.eglBaseContext
            )
            surfaceTextureHelper = helper

            val localCapturer = ScreenCapturerAndroid(data, projectionCallback())
            capturer = localCapturer

            val captureSize = captureSizeFor(meta)
            EdgeLinkLog.info(
                "screen.android.capture_start source=${meta.w}x${meta.h} capture=${captureSize.width}x${captureSize.height} fps=$SCREEN_FPS"
            )

            val localVideoSource = localFactory.createVideoSource(true)
            videoSource = localVideoSource
            localCapturer.initialize(
                helper,
                appContext,
                GapLoggingCapturerObserver(localVideoSource.capturerObserver)
            )
            localCapturer.startCapture(captureSize.width, captureSize.height, SCREEN_FPS)

            val track = localFactory.createVideoTrack(SCREEN_VIDEO_TRACK_ID, localVideoSource)
            track.setEnabled(true)
            videoTrack = track

            val pc = createPeerConnection(localFactory)
            peerConnection = pc
            val sender = pc.addTrack(track, listOf(SCREEN_STREAM_ID))
            configureVideoQuality(pc, sender)
            createOffer(pc)
            startStatsLogging(pc)
        } catch (error: Throwable) {
            EdgeLinkLog.error("screen.android.start_failed", error)
            stop()
        }
    }

    fun handleAnswer(body: RtcSdpBody) {
        val pc = peerConnection ?: run {
            EdgeLinkLog.warn("screen.android.answer_ignored no_peer_connection")
            return
        }
        EdgeLinkLog.info("screen.android.answer_in bytes=${body.sdp.length}")
        pc.setRemoteDescription(
            LoggingSdpObserver("screen.android.set_remote_answer"),
            SessionDescription(SessionDescription.Type.ANSWER, body.sdp)
        )
    }

    fun handleIce(body: RtcIceBody) {
        val pc = peerConnection ?: run {
            EdgeLinkLog.warn("screen.android.ice_ignored no_peer_connection")
            return
        }
        EdgeLinkLog.info("screen.android.ice_in mid=${body.mid} index=${body.index}")
        pc.addIceCandidate(IceCandidate(body.mid, body.index, body.candidate))
    }

    fun noteControlEvent(kind: String) {
        val pc = peerConnection ?: return
        val handler = statsHandler ?: return
        CONTROL_STATS_DELAYS_MS.forEach { delayMs ->
            handler.postDelayed({
                if (peerConnection === pc && !isStopping.get()) {
                    collectStats(pc, "control:$kind:+${delayMs}ms")
                }
            }, delayMs)
        }
    }

    fun stop(sendStopToService: Boolean = true) {
        if (!isStopping.compareAndSet(false, true)) {
            return
        }
        EdgeLinkLog.info("screen.android.stop")
        stopStatsLogging()
        runCatching { capturer?.stopCapture() }
        runCatching { capturer?.dispose() }
        capturer = null
        videoTrack?.dispose()
        videoTrack = null
        videoSource?.dispose()
        videoSource = null
        surfaceTextureHelper?.dispose()
        surfaceTextureHelper = null
        peerConnection?.close()
        peerConnection?.dispose()
        peerConnection = null
        factory?.dispose()
        factory = null
        eglBase?.release()
        eglBase = null
        if (sendStopToService) {
            ScreenProjectionForegroundService.stop(appContext)
        }
        isStopping.set(false)
    }

    private fun initializeWebRtc() {
        ensureWebRtcInitialized(appContext)
        val localEglBase = EglBase.create()
        eglBase = localEglBase
        val encoderFactory = DefaultVideoEncoderFactory(localEglBase.eglBaseContext, true, true)
        val decoderFactory = DefaultVideoDecoderFactory(localEglBase.eglBaseContext)
        factory = PeerConnectionFactory.builder()
            .setVideoEncoderFactory(encoderFactory)
            .setVideoDecoderFactory(decoderFactory)
            .createPeerConnectionFactory()
    }

    private fun createPeerConnection(localFactory: PeerConnectionFactory): PeerConnection {
        val config = PeerConnection.RTCConfiguration(
            listOf(PeerConnection.IceServer.builder(STUN_SERVER).createIceServer())
        ).apply {
            sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN
        }
        return localFactory.createPeerConnection(config, peerObserver())
            ?: error("Unable to create PeerConnection.")
    }

    private fun configureVideoQuality(pc: PeerConnection, sender: RtpSender?) {
        val bitrateApplied = pc.setBitrate(
            SCREEN_MIN_BITRATE_BPS,
            SCREEN_START_BITRATE_BPS,
            SCREEN_MAX_BITRATE_BPS
        )
        val parameters = sender?.parameters
        if (parameters != null) {
            parameters.degradationPreference = RtpParameters.DegradationPreference.BALANCED
            parameters.encodings.forEach { encoding ->
                encoding.minBitrateBps = SCREEN_MIN_BITRATE_BPS
                encoding.maxBitrateBps = SCREEN_MAX_BITRATE_BPS
                encoding.maxFramerate = SCREEN_FPS
                encoding.scaleResolutionDownBy = 1.0
            }
        }
        val senderApplied = if (sender != null && parameters != null) {
            sender.setParameters(parameters)
        } else {
            false
        }
        EdgeLinkLog.info(
            "screen.android.quality bitrateApplied=$bitrateApplied senderApplied=$senderApplied min=$SCREEN_MIN_BITRATE_BPS start=$SCREEN_START_BITRATE_BPS max=$SCREEN_MAX_BITRATE_BPS"
        )
    }

    private fun createOffer(pc: PeerConnection) {
        pc.createOffer(
            object : SdpObserver {
                override fun onCreateSuccess(description: SessionDescription) {
                    EdgeLinkLog.info("screen.android.offer_created bytes=${description.description.length}")
                    pc.setLocalDescription(
                        object : SdpObserver by LoggingSdpObserver("screen.android.set_local_offer") {
                            override fun onSetSuccess() {
                                EdgeLinkLog.info("screen.android.offer_out bytes=${description.description.length}")
                                sendPlaintext(
                                    EnvelopeCodec.encode(
                                        EnvelopeTypes.RTC_OFFER,
                                        RtcSdpBody(description.description)
                                    )
                                )
                            }
                        },
                        description
                    )
                }

                override fun onSetSuccess() = Unit
                override fun onCreateFailure(error: String) {
                    EdgeLinkLog.warn("screen.android.offer_create_failed error=$error")
                }

                override fun onSetFailure(error: String) {
                    EdgeLinkLog.warn("screen.android.offer_set_failed error=$error")
                }
            },
            MediaConstraints()
        )
    }

    private fun startStatsLogging(pc: PeerConnection) {
        stopStatsLogging()
        statsLogger.reset()
        val thread = HandlerThread("EdgeLinkScreenStats").apply { start() }
        val handler = Handler(thread.looper)
        statsHandlerThread = thread
        statsHandler = handler
        val task = object : Runnable {
            override fun run() {
                if (peerConnection !== pc || isStopping.get()) {
                    return
                }
                collectStats(pc, "periodic")
                handler.postDelayed(this, STATS_INTERVAL_MS)
            }
        }
        handler.postDelayed(task, STATS_INTERVAL_MS)
    }

    private fun collectStats(pc: PeerConnection, reason: String) {
        val handler = statsHandler ?: return
        pc.getStats { report ->
            handler.post {
                if (peerConnection === pc && !isStopping.get()) {
                    statsLogger.log(report, reason)
                }
            }
        }
    }

    private fun stopStatsLogging() {
        statsHandler?.removeCallbacksAndMessages(null)
        statsHandler = null
        statsHandlerThread?.quitSafely()
        statsHandlerThread = null
        statsLogger.reset()
    }

    private fun peerObserver(): PeerConnection.Observer =
        object : PeerConnection.Observer {
            override fun onSignalingChange(newState: PeerConnection.SignalingState) {
                EdgeLinkLog.info("screen.android.signaling state=$newState")
            }

            override fun onIceConnectionChange(newState: PeerConnection.IceConnectionState) {
                EdgeLinkLog.info("screen.android.ice_connection state=$newState")
            }

            override fun onIceConnectionReceivingChange(receiving: Boolean) = Unit

            override fun onIceGatheringChange(newState: PeerConnection.IceGatheringState) {
                EdgeLinkLog.info("screen.android.ice_gathering state=$newState")
            }

            override fun onIceCandidate(candidate: IceCandidate) {
                EdgeLinkLog.info("screen.android.ice_out mid=${candidate.sdpMid} index=${candidate.sdpMLineIndex}")
                sendPlaintext(
                    EnvelopeCodec.encode(
                        EnvelopeTypes.RTC_ICE,
                        RtcIceBody(
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
            override fun onDataChannel(dataChannel: DataChannel) = Unit
            override fun onRenegotiationNeeded() = Unit
            override fun onAddTrack(receiver: RtpReceiver, mediaStreams: Array<out MediaStream>) = Unit
        }

    private fun projectionCallback(): MediaProjection.Callback =
        object : MediaProjection.Callback() {
            override fun onStop() {
                EdgeLinkLog.info("screen.android.projection_stopped")
                stop()
            }
        }

    private fun currentScreenMeta(): ScreenMetaBody {
        val resources = appContext.resources
        val densityDpi = resources.configuration.densityDpi
        val scale = resources.displayMetrics.density.toDouble()
        val bounds = if (Build.VERSION.SDK_INT >= 30) {
            appContext.getSystemService(WindowManager::class.java).maximumWindowMetrics.bounds
        } else {
            @Suppress("DEPRECATION")
            val metrics = DisplayMetrics().also {
                appContext.getSystemService(WindowManager::class.java).defaultDisplay.getRealMetrics(it)
            }
            android.graphics.Rect(0, 0, metrics.widthPixels, metrics.heightPixels)
        }
        return ScreenMetaBody(
            w = bounds.width(),
            h = bounds.height(),
            scale = scale,
            dpi = densityDpi
        )
    }

    private fun captureSizeFor(meta: ScreenMetaBody): CaptureSize {
        val maxDimension = maxOf(meta.w, meta.h)
        if (maxDimension <= SCREEN_MAX_CAPTURE_LONG_EDGE) {
            return CaptureSize(meta.w.evenAtLeastTwo(), meta.h.evenAtLeastTwo())
        }

        val scale = SCREEN_MAX_CAPTURE_LONG_EDGE.toDouble() / maxDimension.toDouble()
        return CaptureSize(
            width = (meta.w * scale).toInt().evenAtLeastTwo(),
            height = (meta.h * scale).toInt().evenAtLeastTwo()
        )
    }

    private fun Int.evenAtLeastTwo(): Int {
        val value = coerceAtLeast(2)
        return if (value % 2 == 0) value else value - 1
    }

    private data class CaptureSize(
        val width: Int,
        val height: Int
    )

    private class ScreenStatsLogger {
        private val previousOutbound = mutableMapOf<String, OutboundSnapshot>()

        fun reset() {
            previousOutbound.clear()
        }

        fun log(report: RTCStatsReport, reason: String) {
            val statsById = report.statsMap
            val outbound = statsById.values.firstOrNull { stat ->
                stat.type == "outbound-rtp" && stat.members.isVideo()
            }
            val pair = statsById.values.firstOrNull { stat ->
                stat.type == "candidate-pair" &&
                    stat.members.string("state") == "succeeded" &&
                    (stat.members.boolean("nominated") == true || stat.members.boolean("selected") == true)
            }

            val line = StringBuilder("screen.android.stats")
            line.append(" reason=$reason")
            line.append(" sinceCtrlMs=${ControlTimeline.sinceLastControlMs()}")
            if (outbound != null) {
                appendOutbound(line, outbound)
            }
            if (pair != null) {
                appendCandidatePair(line, pair, statsById)
            }
            EdgeLinkLog.info(line.toString())
        }

        private fun appendOutbound(line: StringBuilder, stat: RTCStats) {
            val members = stat.members
            val framesEncoded = members.long("framesEncoded")
            val framesSent = members.long("framesSent")
            val bytesSent = members.long("bytesSent")
            val packetsSent = members.long("packetsSent")
            val totalEncodeTime = members.double("totalEncodeTime")
            val qpSum = members.long("qpSum")
            val previous = previousOutbound[stat.id]
            val deltaFrames = framesEncoded?.let { current ->
                previous?.framesEncoded?.let { current - it }
            }
            val deltaSeconds = previous?.let { previousStat ->
                (stat.timestampUs - previousStat.timestampUs) / 1_000_000.0
            }?.takeIf { it > 0 }
            val measuredFps = deltaFrames?.let { frames ->
                deltaSeconds?.let { seconds -> frames.toDouble() / seconds }
            }
            val sendKbps = if (
                previous != null &&
                bytesSent != null &&
                previous.bytesSent != null &&
                deltaSeconds != null
            ) {
                (bytesSent - previous.bytesSent).toDouble() * 8.0 / deltaSeconds / 1000.0
            } else {
                null
            }
            val avgEncodeMs = if (
                previous != null &&
                deltaFrames != null &&
                deltaFrames > 0 &&
                totalEncodeTime != null &&
                previous.totalEncodeTime != null
            ) {
                (totalEncodeTime - previous.totalEncodeTime) * 1000.0 / deltaFrames.toDouble()
            } else {
                null
            }
            val avgQp = if (
                previous != null &&
                deltaFrames != null &&
                deltaFrames > 0 &&
                qpSum != null &&
                previous.qpSum != null
            ) {
                (qpSum - previous.qpSum).toDouble() / deltaFrames.toDouble()
            } else {
                null
            }

            if (
                framesEncoded != null ||
                framesSent != null ||
                bytesSent != null ||
                packetsSent != null ||
                totalEncodeTime != null ||
                qpSum != null
            ) {
                previousOutbound[stat.id] = OutboundSnapshot(
                    timestampUs = stat.timestampUs,
                    framesEncoded = framesEncoded ?: previous?.framesEncoded,
                    framesSent = framesSent ?: previous?.framesSent,
                    bytesSent = bytesSent ?: previous?.bytesSent,
                    packetsSent = packetsSent ?: previous?.packetsSent,
                    totalEncodeTime = totalEncodeTime ?: previous?.totalEncodeTime,
                    qpSum = qpSum ?: previous?.qpSum
                )
            }

            line.append(" fps=${format1(members.double("framesPerSecond") ?: measuredFps)}")
            line.append(" enc=${framesEncoded ?: "-"}")
            line.append(" w=${members.long("frameWidth") ?: "-"}")
            line.append(" h=${members.long("frameHeight") ?: "-"}")
            line.append(" limit=${members.string("qualityLimitationReason") ?: "-"}")
            line.append(" targetKbps=${formatKbps(members.double("targetBitrate"))}")
            line.append(" sendKbps=${format1(sendKbps)}")
            line.append(" encMs=${format1(avgEncodeMs)}")
            line.append(" qp=${format1(avgQp)}")
            line.append(" sent=${framesSent ?: "-"}")
            line.append(" bytes=${bytesSent ?: "-"}")
            line.append(" packets=${packetsSent ?: "-"}")
            line.append(" huge=${members.long("hugeFramesSent") ?: "-"}")
            line.append(" key=${members.long("keyFramesEncoded") ?: "-"}")
            line.append(" drop=${members.long("framesDropped") ?: "-"}")
            line.append(" qldur=${formatDurationMap(members["qualityLimitationDurations"]) ?: "-"}")
            line.append(" impl=${members.string("encoderImplementation") ?: "-"}")
        }

        private fun appendCandidatePair(
            line: StringBuilder,
            pair: RTCStats,
            statsById: Map<String, RTCStats>
        ) {
            val members = pair.members
            val localType = candidateType(statsById, members.string("localCandidateId"))
            val remoteType = candidateType(statsById, members.string("remoteCandidateId"))
            line.append(" rttMs=${format1(members.double("currentRoundTripTime")?.times(1000.0))}")
            line.append(" abwKbps=${formatKbps(members.double("availableOutgoingBitrate"))}")
            line.append(" path=${localType ?: "-"}>${remoteType ?: "-"}")
        }

        private fun candidateType(statsById: Map<String, RTCStats>, id: String?): String? =
            id?.let { statsById[it]?.members?.string("candidateType") }

        private data class OutboundSnapshot(
            val timestampUs: Double,
            val framesEncoded: Long?,
            val framesSent: Long?,
            val bytesSent: Long?,
            val packetsSent: Long?,
            val totalEncodeTime: Double?,
            val qpSum: Long?
        )
    }

    private class LoggingSdpObserver(private val label: String) : SdpObserver {
        override fun onCreateSuccess(description: SessionDescription) = Unit
        override fun onSetSuccess() {
            EdgeLinkLog.info("$label success")
        }

        override fun onCreateFailure(error: String) {
            EdgeLinkLog.warn("$label create_failed error=$error")
        }

        override fun onSetFailure(error: String) {
            EdgeLinkLog.warn("$label set_failed error=$error")
        }
    }

    private class GapLoggingCapturerObserver(
        private val delegate: CapturerObserver
    ) : CapturerObserver {
        private var lastFrameAtNanos = 0L

        override fun onCapturerStarted(success: Boolean) {
            delegate.onCapturerStarted(success)
        }

        override fun onCapturerStopped() {
            delegate.onCapturerStopped()
        }

        override fun onFrameCaptured(frame: VideoFrame) {
            val now = android.os.SystemClock.elapsedRealtimeNanos()
            val last = lastFrameAtNanos
            lastFrameAtNanos = now
            if (last != 0L) {
                val gapMs = (now - last) / 1_000_000L
                if (gapMs > CAPTURE_GAP_LOG_THRESHOLD_MS) {
                    EdgeLinkLog.info(
                        "screen.android.capture_gap gapMs=$gapMs sinceCtrlMs=${ControlTimeline.sinceLastControlMs()}"
                    )
                }
            }
            delegate.onFrameCaptured(frame)
        }
    }

    companion object {
        private const val SCREEN_FPS = 30
        private const val SCREEN_MIN_BITRATE_BPS = 300_000
        private const val SCREEN_START_BITRATE_BPS = 2_500_000
        private const val SCREEN_MAX_BITRATE_BPS = 4_000_000
        private const val SCREEN_MAX_CAPTURE_LONG_EDGE = 1280
        private const val SCREEN_STREAM_ID = "edgelink-screen"
        private const val SCREEN_VIDEO_TRACK_ID = "edgelink-screen-video"
        private const val STUN_SERVER = "stun:stun.l.google.com:19302"
        private const val STATS_INTERVAL_MS = 1_000L
        private const val CAPTURE_GAP_LOG_THRESHOLD_MS = 150L
        private val CONTROL_STATS_DELAYS_MS = longArrayOf(0L, 300L, 900L)
        private val initialized = AtomicBoolean(false)

        private fun ensureWebRtcInitialized(context: Context) {
            if (initialized.compareAndSet(false, true)) {
                PeerConnectionFactory.initialize(
                    PeerConnectionFactory.InitializationOptions.builder(context.applicationContext)
                        .createInitializationOptions()
                )
            }
        }
    }
}

private fun Map<String, Any>.isVideo(): Boolean =
    string("kind") == "video" ||
        string("mediaType") == "video" ||
        string("trackIdentifier")?.contains("video", ignoreCase = true) == true

private fun Map<String, Any>.string(name: String): String? =
    this[name]?.toString()

private fun Map<String, Any>.double(name: String): Double? =
    when (val value = this[name]) {
        is Number -> value.toDouble()
        is String -> value.toDoubleOrNull()
        else -> null
    }

private fun Map<String, Any>.long(name: String): Long? =
    when (val value = this[name]) {
        is Number -> value.toLong()
        is String -> value.toLongOrNull()
        else -> null
    }

private fun Map<String, Any>.boolean(name: String): Boolean? =
    when (val value = this[name]) {
        is Boolean -> value
        is String -> value.toBooleanStrictOrNull()
        else -> null
    }

private fun format1(value: Double?): String =
    value?.let { String.format(Locale.US, "%.1f", it) } ?: "-"

private fun formatKbps(value: Double?): String =
    value?.let { String.format(Locale.US, "%.0f", it / 1000.0) } ?: "-"

private fun formatDurationMap(value: Any?): String? {
    val map = value as? Map<*, *> ?: return null
    return listOf("bandwidth", "cpu", "other", "none").mapNotNull { key ->
        val duration = map[key]?.let {
            when (it) {
                is Number -> it.toDouble()
                is String -> it.toDoubleOrNull()
                else -> null
            }
        }
        duration?.let { "$key=${format1(it)}" }
    }.takeIf { it.isNotEmpty() }?.joinToString(",")
}
