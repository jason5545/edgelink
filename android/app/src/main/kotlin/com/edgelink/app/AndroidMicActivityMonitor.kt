package com.edgelink.app

import android.content.Context
import android.media.AudioManager
import android.media.AudioRecordingConfiguration
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import com.edgelink.core.AndroidMicStatusBody
import java.time.Instant

internal class AndroidMicActivityMonitor(
    context: Context,
    private val onStatus: (AndroidMicStatusBody) -> Unit
) {
    private val appContext = context.applicationContext
    private val audioManager = appContext.getSystemService(AudioManager::class.java)
    private val handlerThread = HandlerThread("EdgeLinkMicActivity")
    private var handler: Handler? = null
    private var started = false
    private var lastActive = false
    private var lastSignature: String? = null

    private val callback = object : AudioManager.AudioRecordingCallback() {
        override fun onRecordingConfigChanged(configs: MutableList<AudioRecordingConfiguration>) {
            emit(configs, reason = "callback", force = false)
        }
    }

    private val activeHeartbeat = object : Runnable {
        override fun run() {
            emitCurrent(reason = "heartbeat", force = true)
            if (lastActive) {
                handler?.postDelayed(this, ACTIVE_HEARTBEAT_MS)
            }
        }
    }

    fun start() {
        if (started) {
            return
        }
        started = true
        handlerThread.start()
        val localHandler = Handler(handlerThread.looper)
        handler = localHandler
        runCatching {
            audioManager.registerAudioRecordingCallback(callback, localHandler)
            emitCurrent(reason = "start", force = true)
            EdgeLinkLog.info("mic.android.monitor_started")
        }.onFailure { error ->
            EdgeLinkLog.warn("mic.android.monitor_start_failed", error)
        }
    }

    fun stop() {
        if (!started) {
            return
        }
        started = false
        handler?.removeCallbacks(activeHeartbeat)
        runCatching { audioManager.unregisterAudioRecordingCallback(callback) }
            .onFailure { error -> EdgeLinkLog.warn("mic.android.monitor_unregister_failed", error) }
        handlerThread.quitSafely()
        handler = null
        EdgeLinkLog.info("mic.android.monitor_stopped")
    }

    fun sendCurrent(reason: String) {
        emitCurrent(reason = reason, force = true)
    }

    private fun emitCurrent(reason: String, force: Boolean) {
        val localHandler = handler
        if (localHandler == null) {
            emit(emptyList(), reason = reason, force = force)
            return
        }
        localHandler.post {
            val configs = runCatching { audioManager.activeRecordingConfigurations }
                .getOrElse { error ->
                    EdgeLinkLog.warn("mic.android.active_recording_query_failed", error)
                    emptyList()
                }
            emit(configs, reason = reason, force = force)
        }
    }

    private fun emit(
        configs: List<AudioRecordingConfiguration>,
        reason: String,
        force: Boolean
    ) {
        val activeConfigs = configs.filter(::isUserMicRecording)
        val first = activeConfigs.firstOrNull()
        val source = first?.clientAudioSource
        val sessionId = first?.clientAudioSessionId
        val silenced = first?.let(::isClientSilencedCompat)
        val active = activeConfigs.isNotEmpty()
        val signature = listOf(
            active.toString(),
            source?.toString() ?: "none",
            sessionId?.toString() ?: "none",
            silenced?.toString() ?: "none",
            activeConfigs.size.toString()
        ).joinToString(":")

        if (!force && signature == lastSignature) {
            return
        }
        lastSignature = signature
        lastActive = active

        val body = AndroidMicStatusBody(
            active = active,
            source = source,
            sourceName = source?.let(::audioSourceName),
            sessionId = sessionId,
            silenced = silenced,
            activeRecordingCount = activeConfigs.size,
            reason = reason,
            ts = Instant.now().epochSecond
        )
        onStatus(body)
        EdgeLinkLog.info(
            "mic.android.status active=$active count=${activeConfigs.size} source=${body.sourceName ?: "none"} " +
                "session=${sessionId ?: "none"} silenced=${silenced ?: "none"} reason=$reason"
        )

        handler?.removeCallbacks(activeHeartbeat)
        if (active) {
            handler?.postDelayed(activeHeartbeat, ACTIVE_HEARTBEAT_MS)
        }
    }

    private fun isUserMicRecording(config: AudioRecordingConfiguration): Boolean {
        if (isClientSilencedCompat(config)) {
            return false
        }
        return when (config.clientAudioSource) {
            MediaRecorder.AudioSource.DEFAULT,
            MediaRecorder.AudioSource.MIC,
            MediaRecorder.AudioSource.CAMCORDER,
            MediaRecorder.AudioSource.VOICE_RECOGNITION,
            MediaRecorder.AudioSource.VOICE_COMMUNICATION,
            MediaRecorder.AudioSource.UNPROCESSED,
            MediaRecorder.AudioSource.VOICE_PERFORMANCE -> true
            MediaRecorder.AudioSource.REMOTE_SUBMIX,
            MediaRecorder.AudioSource.VOICE_CALL,
            MediaRecorder.AudioSource.VOICE_UPLINK,
            MediaRecorder.AudioSource.VOICE_DOWNLINK -> false
            else -> false
        }
    }

    private fun audioSourceName(source: Int): String =
        when (source) {
            MediaRecorder.AudioSource.DEFAULT -> "default"
            MediaRecorder.AudioSource.MIC -> "mic"
            MediaRecorder.AudioSource.CAMCORDER -> "camcorder"
            MediaRecorder.AudioSource.VOICE_RECOGNITION -> "voice_recognition"
            MediaRecorder.AudioSource.VOICE_COMMUNICATION -> "voice_communication"
            MediaRecorder.AudioSource.UNPROCESSED -> "unprocessed"
            MediaRecorder.AudioSource.VOICE_PERFORMANCE -> "voice_performance"
            MediaRecorder.AudioSource.REMOTE_SUBMIX -> "remote_submix"
            MediaRecorder.AudioSource.VOICE_CALL -> "voice_call"
            MediaRecorder.AudioSource.VOICE_UPLINK -> "voice_uplink"
            MediaRecorder.AudioSource.VOICE_DOWNLINK -> "voice_downlink"
            else -> "source_$source"
        }

    private fun isClientSilencedCompat(config: AudioRecordingConfiguration): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && config.isClientSilenced

    private companion object {
        const val ACTIVE_HEARTBEAT_MS = 10_000L
    }
}
