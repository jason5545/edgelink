package com.edgelink.app

import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjection
import android.os.Build
import android.util.DisplayMetrics
import android.view.WindowManager
import com.edgelink.core.EnvelopeCodec
import com.edgelink.core.EnvelopeTypes
import com.edgelink.core.CtrlGlobalBody
import com.edgelink.core.CtrlKeyBody
import com.edgelink.core.CtrlPointerBody
import com.edgelink.core.CtrlTextBody
import com.edgelink.core.RtcIceBody
import com.edgelink.core.RtcSdpBody
import com.edgelink.core.ScreenMetaBody
import org.webrtc.DataChannel
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
import org.webrtc.ScreenCapturerAndroid
import org.webrtc.SessionDescription
import org.webrtc.SdpObserver
import org.webrtc.SurfaceTextureHelper
import org.webrtc.VideoCapturer
import org.webrtc.VideoSource
import org.webrtc.VideoTrack
import java.nio.ByteBuffer
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
    private var inputDataChannel: DataChannel? = null
    private var videoSource: VideoSource? = null
    private var videoTrack: VideoTrack? = null
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
            localCapturer.initialize(helper, appContext, localVideoSource.capturerObserver)
            localCapturer.startCapture(captureSize.width, captureSize.height, SCREEN_FPS)

            val track = localFactory.createVideoTrack(SCREEN_VIDEO_TRACK_ID, localVideoSource)
            track.setEnabled(true)
            videoTrack = track

            val pc = createPeerConnection(localFactory)
            peerConnection = pc
            inputDataChannel = createInputDataChannel(pc)
            val sender = pc.addTrack(track, listOf(SCREEN_STREAM_ID))
            configureVideoQuality(pc, sender)
            createOffer(pc)
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

    fun stop(sendStopToService: Boolean = true) {
        if (!isStopping.compareAndSet(false, true)) {
            return
        }
        EdgeLinkLog.info("screen.android.stop")
        runCatching { capturer?.stopCapture() }
        runCatching { capturer?.dispose() }
        capturer = null
        runCatching { inputDataChannel?.unregisterObserver() }
        runCatching { inputDataChannel?.close() }
        runCatching { inputDataChannel?.dispose() }
        inputDataChannel = null
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

    private fun createInputDataChannel(pc: PeerConnection): DataChannel {
        val channel = pc.createDataChannel(
            INPUT_DATA_CHANNEL_LABEL,
            DataChannel.Init().apply {
                ordered = true
            }
        )
        registerInputDataChannel(channel)
        return channel
    }

    private fun registerInputDataChannel(channel: DataChannel) {
        EdgeLinkLog.info("screen.android.input_channel_created label=${channel.label()} state=${channel.state()}")
        channel.registerObserver(
            object : DataChannel.Observer {
                override fun onBufferedAmountChange(previousAmount: Long) = Unit

                override fun onStateChange() {
                    EdgeLinkLog.info("screen.android.input_channel state=${channel.state()}")
                }

                override fun onMessage(buffer: DataChannel.Buffer) {
                    handleInputDataChannelMessage(buffer)
                }
            }
        )
    }

    private fun handleInputDataChannelMessage(buffer: DataChannel.Buffer) {
        if (!buffer.binary) {
            EdgeLinkLog.warn("screen.android.input_channel_ignored non_binary")
            return
        }
        val plaintext = buffer.data.copyRemainingBytes()
        runCatching {
            when (EnvelopeCodec.type(plaintext)) {
                EnvelopeTypes.CTRL_POINTER -> {
                    val envelope = EnvelopeCodec.decode<CtrlPointerBody>(plaintext)
                    RemoteInputService.dispatchPointer(envelope.b)
                }
                EnvelopeTypes.CTRL_GLOBAL -> {
                    val envelope = EnvelopeCodec.decode<CtrlGlobalBody>(plaintext)
                    RemoteInputService.dispatchGlobal(envelope.b)
                }
                EnvelopeTypes.CTRL_TEXT -> {
                    val envelope = EnvelopeCodec.decode<CtrlTextBody>(plaintext)
                    RemoteInputService.dispatchText(envelope.b)
                }
                EnvelopeTypes.CTRL_KEY -> {
                    val envelope = EnvelopeCodec.decode<CtrlKeyBody>(plaintext)
                    RemoteInputService.dispatchKey(envelope.b)
                }
                else -> EdgeLinkLog.warn("screen.android.input_channel_ignored type=${EnvelopeCodec.type(plaintext)}")
            }
        }.onFailure { error ->
            EdgeLinkLog.error("screen.android.input_channel_decode_failed bytes=${plaintext.size}", error)
        }
    }

    private fun configureVideoQuality(pc: PeerConnection, sender: RtpSender?) {
        val bitrateApplied = pc.setBitrate(
            SCREEN_MIN_BITRATE_BPS,
            SCREEN_START_BITRATE_BPS,
            SCREEN_MAX_BITRATE_BPS
        )
        val parameters = sender?.parameters
        if (parameters != null) {
            parameters.degradationPreference = RtpParameters.DegradationPreference.MAINTAIN_RESOLUTION
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
            override fun onDataChannel(dataChannel: DataChannel) {
                EdgeLinkLog.info("screen.android.remote_data_channel label=${dataChannel.label()}")
                if (dataChannel.label() == INPUT_DATA_CHANNEL_LABEL && inputDataChannel == null) {
                    inputDataChannel = dataChannel
                    registerInputDataChannel(dataChannel)
                }
            }
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

    private fun ByteBuffer.copyRemainingBytes(): ByteArray {
        val duplicate = slice()
        val bytes = ByteArray(duplicate.remaining())
        duplicate.get(bytes)
        return bytes
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

    companion object {
        private const val SCREEN_FPS = 30
        private const val SCREEN_MIN_BITRATE_BPS = 3_500_000
        private const val SCREEN_START_BITRATE_BPS = 10_000_000
        private const val SCREEN_MAX_BITRATE_BPS = 16_000_000
        private const val SCREEN_MAX_CAPTURE_LONG_EDGE = 2560
        private const val SCREEN_STREAM_ID = "edgelink-screen"
        private const val SCREEN_VIDEO_TRACK_ID = "edgelink-screen-video"
        private const val INPUT_DATA_CHANNEL_LABEL = "input"
        private const val STUN_SERVER = "stun:stun.l.google.com:19302"
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
