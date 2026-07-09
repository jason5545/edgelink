package com.edgelink.app

import android.content.Context
import android.content.Intent
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.DisplayMetrics
import android.view.Surface
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
import org.webrtc.SessionDescription
import org.webrtc.SdpObserver
import org.webrtc.SurfaceTextureHelper
import org.webrtc.ThreadUtils
import org.webrtc.VideoFrame
import org.webrtc.VideoSink
import org.webrtc.VideoSource
import org.webrtc.VideoTrack
import java.nio.ByteBuffer
import java.util.Locale
import java.util.concurrent.TimeUnit
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
    private var mediaProjection: MediaProjection? = null
    private var mediaProjectionCallback: MediaProjection.Callback? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var projectionSurface: Surface? = null
    private var projectionCaptureSize: CaptureSize? = null
    private var projectionFrameSink: VideoSink? = null
    private var capturerObserver: GapLoggingCapturerObserver? = null
    private var videoSource: VideoSource? = null
    private var videoTrack: VideoTrack? = null
    private var controlDataChannel: DataChannel? = null
    private var controlDataChannelObserver: DataChannel.Observer? = null
    private val screenPowerGuard = AndroidScreenPowerGuard(appContext)
    @Volatile
    private var controlDataChannelHandler: ((ByteArray) -> Unit)? = null
    @Volatile
    private var viewerVisible = true
    private var statsHandlerThread: HandlerThread? = null
    private var statsHandler: Handler? = null
    private val statsLogger = ScreenStatsLogger()
    private val isStopping = AtomicBoolean(false)
    private val boostHandler = Handler(appContext.mainLooper)
    private val restoreBitrateRunnable = Runnable {
        if (isStopping.get()) return@Runnable
        applyViewerBitrate(reason = "boost_restore")
    }

    fun requestStart() {
        EdgeLinkLog.info("screen.android.start_requested")
        if (mediaProjection != null) {
            EdgeLinkLog.info("screen.android.start_reusing_projection")
            startWithActiveProjection()
            return
        }
        ScreenCapturePermissionActivity.start(appContext)
    }

    fun setControlDataChannelHandler(handler: ((ByteArray) -> Unit)?) {
        controlDataChannelHandler = handler
    }

    fun startWithPermission(resultCode: Int, data: Intent) {
        EdgeLinkLog.info("screen.android.permission_granted resultCode=$resultCode")
        releaseProjection(stopService = false)

        try {
            val manager = appContext.getSystemService(MediaProjectionManager::class.java)
            val projection = manager.getMediaProjection(resultCode, data)
                ?: error("MediaProjectionManager returned null projection.")
            val callback = projectionCallback()
            mediaProjection = projection
            mediaProjectionCallback = callback
            projection.registerCallback(callback, Handler(appContext.mainLooper))
            startWithActiveProjection()
        } catch (error: Throwable) {
            EdgeLinkLog.error("screen.android.permission_start_failed", error)
            releaseProjection(stopService = true)
        }
    }

    private fun startWithActiveProjection() {
        val projection = mediaProjection ?: run {
            EdgeLinkLog.warn("screen.android.start_needs_permission")
            ScreenCapturePermissionActivity.start(appContext)
            return
        }

        stopStreaming()
        isStopping.set(false)
        viewerVisible = true

        try {
            initializeWebRtc()
            val meta = currentScreenMeta()
            val captureSize = captureSizeFor(meta)
            val reusedProjectionDisplay = virtualDisplay != null
            val helper = ensureProjectionDisplay(projection, captureSize)
            val localFactory = factory ?: error("PeerConnectionFactory is not initialized.")

            sendPlaintext(EnvelopeCodec.encode(EnvelopeTypes.SCREEN_META, meta))
            EdgeLinkLog.info(
                "screen.android.capture_start source=${meta.w}x${meta.h} capture=${captureSize.width}x${captureSize.height} fps=$SCREEN_FPS warmProjection=$reusedProjectionDisplay"
            )

            val localVideoSource = localFactory.createVideoSource(true)
            videoSource = localVideoSource
            val localCapturerObserver = GapLoggingCapturerObserver(
                helper.handler,
                localVideoSource.capturerObserver
            )
            capturerObserver = localCapturerObserver
            attachProjectionFrames(helper, localCapturerObserver)

            val track = localFactory.createVideoTrack(SCREEN_VIDEO_TRACK_ID, localVideoSource)
            track.setEnabled(true)
            videoTrack = track

            val pc = createPeerConnection(localFactory)
            peerConnection = pc
            val sender = pc.addTrack(track, listOf(SCREEN_STREAM_ID))
            configureVideoQuality(pc, sender)
            setupControlDataChannel(pc)
            createOffer(pc)
            startStatsLogging(pc)
            screenPowerGuard.onSharingStarted()
        } catch (error: Throwable) {
            EdgeLinkLog.error("screen.android.start_failed", error)
            stopStreaming()
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

    fun setViewerVisible(visible: Boolean) {
        viewerVisible = visible
        boostHandler.removeCallbacks(restoreBitrateRunnable)
        val applied = applyViewerBitrate(reason = "viewer_visibility")
        EdgeLinkLog.info("screen.android.viewer_visibility visible=$visible applied=$applied")
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

    fun boostForIncomingInput() {
        val pc = peerConnection ?: return
        if (isStopping.get()) return
        if (viewerVisible) {
            return
        }
        val applied = pc.setBitrate(
            SCREEN_BOOST_MIN_BITRATE_BPS,
            SCREEN_BOOST_START_BITRATE_BPS,
            SCREEN_MAX_BITRATE_BPS
        )
        EdgeLinkLog.info(
            "screen.android.bitrate_boost applied=$applied min=$SCREEN_BOOST_MIN_BITRATE_BPS start=$SCREEN_BOOST_START_BITRATE_BPS max=$SCREEN_MAX_BITRATE_BPS durationMs=$SCREEN_BOOST_DURATION_MS"
        )
        boostHandler.removeCallbacks(restoreBitrateRunnable)
        boostHandler.postDelayed(restoreBitrateRunnable, SCREEN_BOOST_DURATION_MS)
    }

    fun stop() {
        stopStreaming()
    }

    fun shutdown() {
        releaseProjection(stopService = true)
    }

    private fun stopStreaming() {
        if (!isStopping.compareAndSet(false, true)) {
            return
        }
        try {
            val hadPeerConnection = peerConnection != null
            EdgeLinkLog.info("screen.android.stream_stop keepProjection=${mediaProjection != null}")
            boostHandler.removeCallbacks(restoreBitrateRunnable)
            screenPowerGuard.onSharingStopped()
            stopStatsLogging()
            closeControlDataChannel()
            detachProjectionFrames()
            videoTrack?.dispose()
            videoTrack = null
            videoSource?.dispose()
            videoSource = null
            peerConnection?.close()
            peerConnection?.dispose()
            peerConnection = null
            factory?.dispose()
            factory = null
            if (mediaProjection == null) {
                releaseCaptureResources()
            }
            if (hadPeerConnection) {
                EdgeLinkLog.info("screen.android.stream_stopped")
            }
            viewerVisible = true
        } finally {
            isStopping.set(false)
        }
    }

    private fun initializeWebRtc() {
        ensureWebRtcInitialized(appContext)
        val localEglBase = eglBase ?: EglBase.create().also { eglBase = it }
        eglBase = localEglBase
        val encoderFactory = DefaultVideoEncoderFactory(localEglBase.eglBaseContext, true, true)
        val decoderFactory = DefaultVideoDecoderFactory(localEglBase.eglBaseContext)
        factory = PeerConnectionFactory.builder()
            .setVideoEncoderFactory(encoderFactory)
            .setVideoDecoderFactory(decoderFactory)
            .createPeerConnectionFactory()
    }

    private fun ensureProjectionDisplay(
        projection: MediaProjection,
        captureSize: CaptureSize
    ): SurfaceTextureHelper {
        val localEglBase = eglBase ?: error("EGL is not initialized.")
        val helper = surfaceTextureHelper ?: SurfaceTextureHelper.create(
            "EdgeLinkScreenCapture",
            localEglBase.eglBaseContext
        ).also { surfaceTextureHelper = it }

        helper.setTextureSize(captureSize.width, captureSize.height)
        val surface = projectionSurface ?: Surface(helper.surfaceTexture).also {
            projectionSurface = it
        }
        val display = virtualDisplay
        if (display == null) {
            virtualDisplay = projection.createVirtualDisplay(
                "EdgeLinkScreenCapture",
                captureSize.width,
                captureSize.height,
                VIRTUAL_DISPLAY_DPI,
                DISPLAY_FLAGS,
                surface,
                null,
                helper.handler
            )
            projectionCaptureSize = captureSize
            EdgeLinkLog.info(
                "screen.android.projection_display_created capture=${captureSize.width}x${captureSize.height}"
            )
            return helper
        }

        if (projectionCaptureSize != captureSize) {
            if (Build.VERSION.SDK_INT >= 31) {
                display.resize(captureSize.width, captureSize.height, VIRTUAL_DISPLAY_DPI)
                display.setSurface(surface)
                projectionCaptureSize = captureSize
                EdgeLinkLog.info(
                    "screen.android.projection_display_resized capture=${captureSize.width}x${captureSize.height}"
                )
            } else {
                EdgeLinkLog.warn(
                    "screen.android.projection_display_resize_unavailable requested=${captureSize.width}x${captureSize.height}"
                )
            }
        }
        return helper
    }

    private fun attachProjectionFrames(
        helper: SurfaceTextureHelper,
        observer: GapLoggingCapturerObserver
    ) {
        val sink = VideoSink { frame ->
            observer.onFrameCaptured(frame)
        }
        projectionFrameSink = sink
        observer.onCapturerStarted(true)
        helper.startListening(sink)
    }

    private fun detachProjectionFrames() {
        val observer = capturerObserver
        val hadSink = projectionFrameSink != null
        capturerObserver = null
        projectionFrameSink = null
        val helper = surfaceTextureHelper
        if (helper != null && (hadSink || observer != null)) {
            runCatching {
                if (Thread.currentThread() == helper.handler.looper.thread) {
                    helper.stopListening()
                } else {
                    ThreadUtils.invokeAtFrontUninterruptibly(helper.handler, Runnable {
                        helper.stopListening()
                    })
                }
            }.onFailure { error ->
                EdgeLinkLog.warn("screen.android.frame_listener_stop_failed", error)
            }
        }
        observer?.onCapturerStopped()
    }

    private fun releaseProjection(stopService: Boolean, stopProjection: Boolean = true) {
        val hadProjection = mediaProjection != null
        stopStreaming()

        val projection = mediaProjection
        val callback = mediaProjectionCallback
        mediaProjection = null
        mediaProjectionCallback = null
        if (projection != null && callback != null) {
            runCatching { projection.unregisterCallback(callback) }
                .onFailure { error -> EdgeLinkLog.warn("screen.android.projection_callback_unregister_failed", error) }
        }
        releaseCaptureResources()
        if (stopProjection) {
            runCatching { projection?.stop() }
                .onFailure { error -> EdgeLinkLog.warn("screen.android.projection_stop_failed", error) }
        }
        if (stopService) {
            ScreenProjectionForegroundService.stop(appContext)
        }
        if (hadProjection) {
            EdgeLinkLog.info("screen.android.projection_released stopService=$stopService stopProjection=$stopProjection")
        }
    }

    private fun releaseCaptureResources() {
        runCatching { virtualDisplay?.release() }
            .onFailure { error -> EdgeLinkLog.warn("screen.android.virtual_display_release_failed", error) }
        virtualDisplay = null
        projectionCaptureSize = null
        runCatching { projectionSurface?.release() }
            .onFailure { error -> EdgeLinkLog.warn("screen.android.projection_surface_release_failed", error) }
        projectionSurface = null
        runCatching { surfaceTextureHelper?.dispose() }
            .onFailure { error -> EdgeLinkLog.warn("screen.android.surface_helper_dispose_failed", error) }
        surfaceTextureHelper = null
        runCatching { eglBase?.release() }
            .onFailure { error -> EdgeLinkLog.warn("screen.android.egl_release_failed", error) }
        eglBase = null
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

    private fun setupControlDataChannel(pc: PeerConnection) {
        closeControlDataChannel()
        val channel = pc.createDataChannel(
            SCREEN_CONTROL_CHANNEL_LABEL,
            DataChannel.Init().apply { ordered = true }
        )
        if (channel == null) {
            EdgeLinkLog.warn("screen.android.control_data_channel_create_failed")
            return
        }
        val observer = object : DataChannel.Observer {
            override fun onBufferedAmountChange(previousAmount: Long) = Unit

            override fun onStateChange() {
                EdgeLinkLog.info(
                    "screen.android.control_data_channel_state label=${channel.label()} state=${channel.state()}"
                )
            }

            override fun onMessage(buffer: DataChannel.Buffer) {
                val bytes = buffer.data.toByteArray()
                EdgeLinkLog.info(
                    "screen.android.control_data_channel_in bytes=${bytes.size} binary=${buffer.binary}"
                )
                controlDataChannelHandler?.invoke(bytes)
            }
        }
        controlDataChannelObserver = observer
        controlDataChannel = channel
        channel.registerObserver(observer)
        EdgeLinkLog.info("screen.android.control_data_channel_created label=${channel.label()}")
    }

    private fun closeControlDataChannel() {
        val channel = controlDataChannel
        controlDataChannel = null
        controlDataChannelObserver = null
        if (channel != null) {
            runCatching { channel.unregisterObserver() }
            runCatching { channel.close() }
            runCatching { channel.dispose() }
        }
    }

    private fun configureVideoQuality(pc: PeerConnection, sender: RtpSender?) {
        val profile = currentViewerBitrateProfile()
        val bitrateApplied = pc.setBitrate(
            profile.minBps,
            profile.startBps,
            profile.maxBps
        )
        val parameters = sender?.parameters
        if (parameters != null) {
            parameters.degradationPreference = RtpParameters.DegradationPreference.BALANCED
            parameters.encodings.forEach { encoding ->
                encoding.minBitrateBps = profile.minBps
                encoding.maxBitrateBps = profile.maxBps
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
            "screen.android.quality bitrateApplied=$bitrateApplied senderApplied=$senderApplied visible=$viewerVisible min=${profile.minBps} start=${profile.startBps} max=${profile.maxBps}"
        )
    }

    private fun applyViewerBitrate(reason: String): Boolean {
        val pc = peerConnection ?: return false
        val profile = currentViewerBitrateProfile()
        val applied = pc.setBitrate(profile.minBps, profile.startBps, profile.maxBps)
        EdgeLinkLog.info(
            "screen.android.bitrate_viewer reason=$reason visible=$viewerVisible applied=$applied min=${profile.minBps} start=${profile.startBps} max=${profile.maxBps}"
        )
        return applied
    }

    private fun currentViewerBitrateProfile(): BitrateProfile =
        if (viewerVisible) {
            BitrateProfile(
                minBps = SCREEN_VISIBLE_MIN_BITRATE_BPS,
                startBps = SCREEN_VISIBLE_START_BITRATE_BPS,
                maxBps = SCREEN_MAX_BITRATE_BPS
            )
        } else {
            BitrateProfile(
                minBps = SCREEN_HIDDEN_MIN_BITRATE_BPS,
                startBps = SCREEN_HIDDEN_START_BITRATE_BPS,
                maxBps = SCREEN_MAX_BITRATE_BPS
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
                releaseProjection(stopService = true, stopProjection = false)
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
        private val captureHandler: Handler,
        private val delegate: CapturerObserver
    ) : CapturerObserver {
        private var lastFrameAtNanos = 0L
        private var repeatBuffer: VideoFrame.I420Buffer? = null
        private var repeatRotation = 0
        private var lastForwardedTimestampNs = 0L
        @Volatile
        private var repeatingStopped = false
        private val firstRepeatRunnable = Runnable {
            repeatLastFrame(index = 1, delayMs = LAST_FRAME_REPEAT_DELAYS_MS[0])
        }
        private val secondRepeatRunnable = Runnable {
            repeatLastFrame(index = 2, delayMs = LAST_FRAME_REPEAT_DELAYS_MS[1])
        }

        override fun onCapturerStarted(success: Boolean) {
            if (success) {
                repeatingStopped = false
            }
            delegate.onCapturerStarted(success)
        }

        override fun onCapturerStopped() {
            stopRepeating()
            delegate.onCapturerStopped()
        }

        override fun onFrameCaptured(frame: VideoFrame) {
            val now = SystemClock.elapsedRealtimeNanos()
            val last = lastFrameAtNanos
            lastFrameAtNanos = now
            if (last != 0L) {
                val gapMs = (now - last) / 1_000_000L
                if (gapMs > CAPTURE_GAP_LOG_THRESHOLD_MS) {
                    val sinceCtrlMs = ControlTimeline.sinceLastControlMs()
                    EdgeLinkLog.info(
                        "screen.android.capture_gap gapMs=$gapMs phase=${gapPhase(sinceCtrlMs)} sinceCtrlMs=$sinceCtrlMs"
                    )
                }
            }
            if (!repeatingStopped) {
                updateRepeatFrame(frame)
            }
            delegate.onFrameCaptured(frame)
        }

        fun stopRepeating() {
            repeatingStopped = true
            if (Thread.currentThread() == captureHandler.looper.thread) {
                clearRepeatFrame()
            } else {
                runCatching {
                    ThreadUtils.invokeAtFrontUninterruptibly(captureHandler, Runnable {
                        clearRepeatFrame()
                    })
                }.onFailure { error ->
                    EdgeLinkLog.warn("screen.android.last_frame_repeat_stop_failed", error)
                }
            }
        }

        private fun updateRepeatFrame(frame: VideoFrame) {
            cancelRepeatCallbacks()
            val copiedBuffer = runCatching {
                frame.buffer.toI420()
            }.onFailure { error ->
                EdgeLinkLog.warn("screen.android.last_frame_copy_failed", error)
            }.getOrNull()
            val rotation = frame.rotation
            val timestampNs = frame.timestampNs
            val update = Runnable {
                replaceRepeatFrame(copiedBuffer, rotation, timestampNs)
            }
            if (Thread.currentThread() == captureHandler.looper.thread) {
                update.run()
            } else if (!captureHandler.post(update)) {
                copiedBuffer?.release()
            }
        }

        private fun replaceRepeatFrame(
            copiedBuffer: VideoFrame.I420Buffer?,
            rotation: Int,
            timestampNs: Long
        ) {
            cancelRepeatCallbacks()
            repeatBuffer?.release()
            repeatBuffer = null
            if (repeatingStopped || copiedBuffer == null) {
                copiedBuffer?.release()
                return
            }
            repeatBuffer = copiedBuffer
            repeatRotation = rotation
            lastForwardedTimestampNs = maxOf(lastForwardedTimestampNs, timestampNs)
            captureHandler.postDelayed(firstRepeatRunnable, LAST_FRAME_REPEAT_DELAYS_MS[0])
            captureHandler.postDelayed(secondRepeatRunnable, LAST_FRAME_REPEAT_DELAYS_MS[1])
        }

        private fun repeatLastFrame(index: Int, delayMs: Long) {
            if (repeatingStopped) {
                return
            }
            val buffer = repeatBuffer ?: return
            val timestampNs = nextRepeatTimestampNs()
            buffer.retain()
            val repeatedFrame = VideoFrame(buffer, repeatRotation, timestampNs)
            try {
                delegate.onFrameCaptured(repeatedFrame)
                EdgeLinkLog.info(
                    "screen.android.last_frame_repeat index=$index delayMs=$delayMs w=${buffer.width} h=${buffer.height} sinceCtrlMs=${ControlTimeline.sinceLastControlMs()}"
                )
            } finally {
                repeatedFrame.release()
            }
        }

        private fun nextRepeatTimestampNs(): Long {
            val timestampNs = maxOf(
                SystemClock.elapsedRealtimeNanos(),
                lastForwardedTimestampNs + 1
            )
            lastForwardedTimestampNs = timestampNs
            return timestampNs
        }

        private fun clearRepeatFrame() {
            cancelRepeatCallbacks()
            repeatBuffer?.release()
            repeatBuffer = null
            lastFrameAtNanos = 0L
            lastForwardedTimestampNs = 0L
        }

        private fun cancelRepeatCallbacks() {
            captureHandler.removeCallbacks(firstRepeatRunnable)
            captureHandler.removeCallbacks(secondRepeatRunnable)
        }
    }

    private data class BitrateProfile(
        val minBps: Int,
        val startBps: Int,
        val maxBps: Int
    )

    companion object {
        private const val SCREEN_FPS = 30
        private const val SCREEN_VISIBLE_MIN_BITRATE_BPS = 2_500_000
        private const val SCREEN_VISIBLE_START_BITRATE_BPS = 2_500_000
        private const val SCREEN_HIDDEN_MIN_BITRATE_BPS = 300_000
        private const val SCREEN_HIDDEN_START_BITRATE_BPS = 1_000_000
        private const val SCREEN_BOOST_MIN_BITRATE_BPS = 2_500_000
        private const val SCREEN_BOOST_START_BITRATE_BPS = 2_500_000
        private const val SCREEN_MAX_BITRATE_BPS = 8_000_000
        private const val SCREEN_BOOST_DURATION_MS = 3_000L
        private const val SCREEN_MAX_CAPTURE_LONG_EDGE = 1280
        private const val VIRTUAL_DISPLAY_DPI = 400
        private val DISPLAY_FLAGS =
            DisplayManager.VIRTUAL_DISPLAY_FLAG_PUBLIC or
                DisplayManager.VIRTUAL_DISPLAY_FLAG_PRESENTATION
        private const val SCREEN_STREAM_ID = "edgelink-screen"
        private const val SCREEN_VIDEO_TRACK_ID = "edgelink-screen-video"
        private const val SCREEN_CONTROL_CHANNEL_LABEL = "edgelink-control"
        private const val STUN_SERVER = "stun:stun.l.google.com:19302"
        private const val STATS_INTERVAL_MS = 2_000L
        private const val CAPTURE_GAP_LOG_THRESHOLD_MS = 150L
        private const val POST_CONTROL_GAP_WINDOW_MS = 2_000L
        private val LAST_FRAME_REPEAT_DELAYS_MS = longArrayOf(
            TimeUnit.MILLISECONDS.toMillis(400L),
            TimeUnit.SECONDS.toMillis(1L)
        )
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

        private fun gapPhase(sinceCtrlMs: Long?): String =
            when {
                sinceCtrlMs == null || sinceCtrlMs < 0 -> "unknown"
                sinceCtrlMs <= POST_CONTROL_GAP_WINDOW_MS -> "post_control"
                else -> "idle_or_static"
            }
    }
}

private fun ByteBuffer.toByteArray(): ByteArray {
    val duplicate = duplicate()
    val bytes = ByteArray(duplicate.remaining())
    duplicate.get(bytes)
    return bytes
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
