package com.edgelink.app

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.AudioTimestamp
import android.media.projection.MediaProjection
import android.os.Build
import android.os.SystemClock
import org.webrtc.audio.JavaAudioDeviceModule
import java.nio.ByteBuffer

/** Feeds Android playback audio into WebRTC's existing audio encoder. */
internal class AndroidPlaybackAudioCapture(
    context: Context,
    private val mediaProjection: MediaProjection
) : JavaAudioDeviceModule.AudioBufferCallback {
    private val appContext = context.applicationContext

    @Volatile
    private var audioRecord: AudioRecord? = null
    private var lastReadErrorLogMs = 0L
    private var didLogFormatMismatch = false

    fun start(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            EdgeLinkLog.info("screen.android.audio_unavailable api=${Build.VERSION.SDK_INT}")
            return false
        }
        if (appContext.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            EdgeLinkLog.warn("screen.android.audio_unavailable missing_record_audio_permission")
            return false
        }

        return runCatching {
            val format = AudioFormat.Builder()
                .setEncoding(AUDIO_ENCODING)
                .setSampleRate(AUDIO_SAMPLE_RATE)
                .setChannelMask(AUDIO_CHANNEL_MASK)
                .build()
            val captureConfiguration = AudioPlaybackCaptureConfiguration.Builder(mediaProjection)
                .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
                .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
                .addMatchingUsage(AudioAttributes.USAGE_GAME)
                .build()
            val minimumBufferSize = AudioRecord.getMinBufferSize(
                AUDIO_SAMPLE_RATE,
                AUDIO_CHANNEL_MASK,
                AUDIO_ENCODING
            )
            check(minimumBufferSize > 0) {
                "AudioRecord returned invalid minimum buffer size $minimumBufferSize."
            }
            val record = AudioRecord.Builder()
                .setAudioFormat(format)
                .setBufferSizeInBytes(maxOf(minimumBufferSize, WEBRTC_FRAME_BYTES * BUFFERED_FRAMES))
                .setAudioPlaybackCaptureConfig(captureConfiguration)
                .build()
            check(record.state == AudioRecord.STATE_INITIALIZED) {
                "Playback AudioRecord was not initialized."
            }
            record.startRecording()
            check(record.recordingState == AudioRecord.RECORDSTATE_RECORDING) {
                "Playback AudioRecord did not enter recording state."
            }
            audioRecord = record
            EdgeLinkLog.info(
                "screen.android.audio_capture_started sampleRate=$AUDIO_SAMPLE_RATE channels=$AUDIO_CHANNEL_COUNT"
            )
            true
        }.getOrElse { error ->
            EdgeLinkLog.warn("screen.android.audio_capture_start_failed", error)
            stop()
            false
        }
    }

    fun stop() {
        val record = audioRecord
        audioRecord = null
        if (record != null) {
            runCatching { record.stop() }
                .onFailure { error -> EdgeLinkLog.warn("screen.android.audio_capture_stop_failed", error) }
            record.release()
            EdgeLinkLog.info("screen.android.audio_capture_stopped")
        }
    }

    override fun onBuffer(
        buffer: ByteBuffer,
        audioFormat: Int,
        channelCount: Int,
        sampleRate: Int,
        bytesRead: Int,
        captureTimeNs: Long
    ): Long {
        if (!didLogFormatMismatch &&
            (audioFormat != AUDIO_ENCODING || channelCount != AUDIO_CHANNEL_COUNT || sampleRate != AUDIO_SAMPLE_RATE)
        ) {
            didLogFormatMismatch = true
            EdgeLinkLog.warn(
                "screen.android.audio_format_mismatch encoding=$audioFormat channels=$channelCount sampleRate=$sampleRate"
            )
        }

        val record = audioRecord
        if (record == null) {
            silence(buffer, 0)
            SystemClock.sleep(WEBRTC_FRAME_DURATION_MS)
            return 0L
        }

        buffer.clear()
        val read = runCatching {
            record.read(buffer, buffer.capacity(), AudioRecord.READ_BLOCKING)
        }.getOrElse { error ->
            logReadFailure(error)
            AudioRecord.ERROR_INVALID_OPERATION
        }
        if (read <= 0) {
            silence(buffer, 0)
            SystemClock.sleep(WEBRTC_FRAME_DURATION_MS)
            return 0L
        }
        silence(buffer, read.coerceAtMost(buffer.capacity()))

        val timestamp = AudioTimestamp()
        return if (
            record.getTimestamp(timestamp, AudioTimestamp.TIMEBASE_MONOTONIC) == AudioRecord.SUCCESS
        ) {
            timestamp.nanoTime
        } else {
            captureTimeNs
        }
    }

    private fun silence(buffer: ByteBuffer, fromIndex: Int) {
        for (index in fromIndex until buffer.capacity()) {
            buffer.put(index, 0)
        }
    }

    private fun logReadFailure(error: Throwable? = null) {
        val now = SystemClock.elapsedRealtime()
        if (now - lastReadErrorLogMs < READ_ERROR_LOG_INTERVAL_MS) {
            return
        }
        lastReadErrorLogMs = now
        if (error != null) {
            EdgeLinkLog.warn("screen.android.audio_capture_read_failed", error)
        } else {
            EdgeLinkLog.warn("screen.android.audio_capture_read_failed")
        }
    }

    companion object {
        const val AUDIO_SAMPLE_RATE = 48_000
        const val AUDIO_CHANNEL_COUNT = 2
        private const val AUDIO_ENCODING = AudioFormat.ENCODING_PCM_16BIT
        private const val AUDIO_CHANNEL_MASK = AudioFormat.CHANNEL_IN_STEREO
        private const val WEBRTC_FRAME_DURATION_MS = 10L
        private const val BYTES_PER_SAMPLE = 2
        private const val WEBRTC_FRAME_BYTES =
            AUDIO_SAMPLE_RATE * AUDIO_CHANNEL_COUNT * BYTES_PER_SAMPLE / (1_000 / WEBRTC_FRAME_DURATION_MS.toInt())
        private const val BUFFERED_FRAMES = 8
        private const val READ_ERROR_LOG_INTERVAL_MS = 5_000L
    }
}
