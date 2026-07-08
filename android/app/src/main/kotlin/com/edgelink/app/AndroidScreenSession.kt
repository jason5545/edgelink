package com.edgelink.app

import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjection
import android.os.Build
import android.util.DisplayMetrics
import android.view.WindowManager
import com.edgelink.core.EnvelopeCodec
import com.edgelink.core.EnvelopeTypes
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
import org.webrtc.ScreenCapturerAndroid
import org.webrtc.SessionDescription
import org.webrtc.SdpObserver
import org.webrtc.SurfaceTextureHelper
import org.webrtc.VideoCapturer
import org.webrtc.VideoSource
import org.webrtc.VideoTrack
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

            val localVideoSource = localFactory.createVideoSource(false)
            videoSource = localVideoSource
            localCapturer.initialize(helper, appContext, localVideoSource.capturerObserver)
            localCapturer.startCapture(meta.w, meta.h, SCREEN_FPS)

            val track = localFactory.createVideoTrack(SCREEN_VIDEO_TRACK_ID, localVideoSource)
            track.setEnabled(true)
            videoTrack = track

            val pc = createPeerConnection(localFactory)
            peerConnection = pc
            pc.addTrack(track, listOf(SCREEN_STREAM_ID))
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
        private const val SCREEN_STREAM_ID = "edgelink-screen"
        private const val SCREEN_VIDEO_TRACK_ID = "edgelink-screen-video"
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
