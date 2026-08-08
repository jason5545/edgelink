package com.edgelink.app

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

// No-hook call-uplink inject. Runs inside the root Shizuku service process
// (uid 0) for the duration of a relayed call: takes the Mac mic PCM over TCP
// (4-byte "ELMA" magic + raw 16k s16le mono framing) and writes it into a
// VOICE_COMMUNICATION AudioTrack pinned at the TYPE_TELEPHONY sink — the
// exact terminal path audiomonitor's DistAudioStream.createAudioDownlinkStream
// uses (same usage/flags/sample rate, same setPreferredDevice(TYPE_TELEPHONY)).
// audiomonitor can do this because it runs as android.uid.system with
// MODIFY_PHONE_STATE; this process is uid 0, which framework permission
// checks also grant, so no LSPosed hook and no active distaudio session are
// required.
//
// Every gate is logged (device presence, track state, setPreferredDevice
// result, head position) so a failed route is evidence, not silence. There
// is no fallback anymore (the audiomonitor LSPosed feed is gone): if the
// route is refused the injector retries every 2s for the whole call with a
// periodic heartbeat log, so a MIUI update breaking the route shows up in
// the logs instead of being papered over.
internal class CallUplinkInjector {
    private companion object {
        const val TAG = "EdgeLinkShizuku"
        const val PORT = 19_307
        const val READ_BUFFER_BYTES = 8_192
        const val SAMPLE_RATE = 16_000
        const val TELEPHONY_DEVICE_TYPE = 18 // AudioDeviceInfo.TYPE_TELEPHONY
        // Mirrors DistAudioStream.createAudioDownlinkStream: flags 2304
        // (FLAG_LOW_LATENCY | FLAG_CONTENT_IS_SPATIALIZED).
        const val AUDIO_ATTRIBUTE_FLAGS = 2304
        const val RETRY_DELAY_MS = 2_000L
        const val HEARTBEAT_ATTEMPTS = 15 // one log line every ~30s of retrying
        const val PROGRESS_LOG_BYTES = 320_000L
    }

    private val running = AtomicBoolean(false)

    @Volatile
    private var serverThread: Thread? = null

    @Volatile
    private var serverSocket: ServerSocket? = null

    @Volatile
    private var activeClient: Socket? = null

    // A client becomes the active sender only after its ELMA magic checks
    // out. Live evidence 2026-08-07: AndroidDistAudioUplinkForwarder (this
    // app) also connects to 19307 — immediately, silently, and without the
    // magic — and a connect-time eviction let that empty connection displace
    // the Mac's validated sender 500ms after handshake, resetting the Mac's
    // NWConnection and leaving the whole call without a PCM source.
    @Volatile
    private var hasActiveSender = false

    fun start() {
        if (!running.compareAndSet(false, true)) {
            return
        }
        serverThread = thread(name = "edgelink-call-inject", isDaemon = true) { runServer() }
    }

    fun stop() {
        if (!running.compareAndSet(true, false)) {
            return
        }
        runCatching { activeClient?.close() }
        runCatching { serverSocket?.close() }
        serverThread?.interrupt()
        serverThread = null
        android.util.Log.i(TAG, "call inject (shizuku) stopped")
    }

    private fun runServer() {
        android.util.Log.i(
            TAG,
            "call inject (shizuku) starting uid=${android.os.Process.myUid()}"
        )
        val server = bindServer() ?: return
        serverSocket = server
        android.util.Log.i(TAG, "call inject (shizuku) listening port=$PORT")
        try {
            while (running.get()) {
                val client = runCatching { server.accept() }.getOrElse { error ->
                    if (!running.get()) {
                        return
                    }
                    android.util.Log.w(
                        TAG,
                        "call inject (shizuku) accept failed: ${error.javaClass.simpleName}: ${error.message}"
                    )
                    return
                }
                runCatching { client.tcpNoDelay = true }
                thread(name = "edgelink-call-inject-client", isDaemon = true) {
                    try {
                        runClient(client)
                    } catch (error: Throwable) {
                        android.util.Log.w(
                            TAG,
                            "call inject (shizuku) client error: ${error.javaClass.simpleName}: ${error.message}"
                        )
                    } finally {
                        runCatching { client.close() }
                        if (activeClient === client) {
                            activeClient = null
                            hasActiveSender = false
                        }
                    }
                    android.util.Log.i(TAG, "call inject (shizuku) client disconnected")
                }
            }
        } finally {
            runCatching { server.close() }
            serverSocket = null
        }
    }

    // Nothing else binds this port anymore (the audiomonitor hook is gone),
    // so contention can only be transient. Never give up: sleep 2s and retry
    // for the whole call, with a heartbeat so a stuck bind stays visible.
    private fun bindServer(): ServerSocket? {
        var attempt = 0
        while (running.get()) {
            attempt += 1
            val server = runCatching {
                ServerSocket(PORT, 4, InetAddress.getByName("0.0.0.0"))
            }.getOrElse { error ->
                if (attempt == 1 || attempt % HEARTBEAT_ATTEMPTS == 0) {
                    android.util.Log.w(
                        TAG,
                        "call inject (shizuku) bind attempt=$attempt failed: " +
                            "${error.javaClass.simpleName}: ${error.message}"
                    )
                }
                null
            }
            if (server != null) {
                return server
            }
            try {
                Thread.sleep(RETRY_DELAY_MS)
            } catch (_: InterruptedException) {
                return null
            }
        }
        return null
    }

    private fun runClient(socket: Socket) {
        val input = socket.inputStream
        val magic = ByteArray(CallInjectProtocol.MAGIC.size)
        var magicRead = 0
        while (magicRead < magic.size) {
            val n = input.read(magic, magicRead, magic.size - magicRead)
            if (n < 0) {
                return
            }
            magicRead += n
        }
        if (!CallInjectProtocol.hasMagic(magic)) {
            // Not a valid sender (e.g. the app's own dist_uplink forwarder
            // connects here without the magic). Drop it without touching the
            // active sender.
            android.util.Log.w(TAG, "call inject (shizuku) bad magic, dropping connection")
            return
        }
        if (hasActiveSender && activeClient != null) {
            // A validated sender is already streaming (the Mac mic). Two
            // validated senders only happen across a stale connection whose
            // FIN has not arrived yet; keep the incumbent, the stale side
            // dies on its next write.
            android.util.Log.w(TAG, "call inject (shizuku) duplicate validated sender, refusing")
            return
        }
        activeClient = socket
        hasActiveSender = true
        android.util.Log.i(TAG, "call inject (shizuku) client accepted")
        var track: AudioTrack? = null
        val buffer = ByteArray(READ_BUFFER_BYTES)
        var bytesInjected = 0L
        var lastLogBytes = 0L
        var bytesDropped = 0L
        var sinkFailures = 0
        while (running.get()) {
            val read = input.read(buffer)
            if (read < 0) {
                break
            }
            if (read == 0) {
                continue
            }
            var activeTrack = track
            if (activeTrack == null || activeTrack.playState != AudioTrack.PLAYSTATE_PLAYING) {
                if (activeTrack != null) {
                    android.util.Log.w(TAG, "call inject (shizuku) track lost, rebuilding")
                    releaseTrack(activeTrack)
                    activeTrack = null
                    track = null
                    sinkFailures = 0
                }
                activeTrack = buildTelephonyTrack()
                if (activeTrack == null) {
                    sinkFailures += 1
                    bytesDropped += read
                    // No fallback exists: keep retrying for the whole call
                    // (2s cadence) and keep logging so a refused route is
                    // evidence, not silence.
                    if (sinkFailures == 1 || sinkFailures % HEARTBEAT_ATTEMPTS == 0 ||
                        bytesDropped % PROGRESS_LOG_BYTES < read
                    ) {
                        android.util.Log.w(
                            TAG,
                            "call inject (shizuku) no telephony sink yet, retrying " +
                                "attempt=$sinkFailures dropped=$bytesDropped"
                        )
                    }
                    try {
                        Thread.sleep(RETRY_DELAY_MS)
                    } catch (_: InterruptedException) {
                        break
                    }
                    continue
                }
                sinkFailures = 0
                track = activeTrack
            }
            val written = runCatching { activeTrack.write(buffer, 0, read) }.getOrElse { error ->
                android.util.Log.w(
                    TAG,
                    "call inject (shizuku) write failed: ${error.javaClass.simpleName}: ${error.message}"
                )
                -1
            }
            if (written < 0) {
                android.util.Log.w(TAG, "call inject (shizuku) write result=$written, rebuilding track")
                releaseTrack(activeTrack)
                track = null
                bytesDropped += read
                continue
            }
            bytesInjected += written
            if (bytesInjected - lastLogBytes >= PROGRESS_LOG_BYTES) {
                lastLogBytes = bytesInjected
                android.util.Log.i(
                    TAG,
                    "call inject (shizuku) injected=$bytesInjected dropped=$bytesDropped " +
                        "head=${activeTrack.playbackHeadPosition}"
                )
            }
        }
        releaseTrack(track)
        android.util.Log.i(
            TAG,
            "call inject (shizuku) client done injected=$bytesInjected dropped=$bytesDropped"
        )
    }

    // Mirrors DistAudioStream.createAudioDownlinkStream: USAGE_VOICE_COMMUNICATION
    // 16k mono s16 track pinned at the TYPE_TELEPHONY output. Returns null
    // (with evidence logged) when the device is absent or the route is
    // refused — callers keep retrying for the whole call.
    private fun buildTelephonyTrack(): AudioTrack? {
        val context = resolveContext()
        if (context == null) {
            android.util.Log.w(TAG, "call inject (shizuku) no context for AudioManager")
            return null
        }
        val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
        if (audioManager == null) {
            android.util.Log.w(TAG, "call inject (shizuku) no AudioManager")
            return null
        }
        val outputs = runCatching {
            audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
        }.getOrDefault(emptyArray())
        val telephony = outputs.firstOrNull { it.type == TELEPHONY_DEVICE_TYPE }
        if (telephony == null) {
            android.util.Log.w(
                TAG,
                "call inject (shizuku) no TYPE_TELEPHONY output among ${outputs.size} outputs " +
                    "types=${outputs.joinToString(",") { it.type.toString() }}"
            )
            // No evidence yet that routing is impossible — the device appears
            // once the call is fully active. Let the caller retry.
            return null
        }
        android.util.Log.i(TAG, "call inject (shizuku) telephony device=$telephony")
        val minBuffer = AudioTrack.getMinBufferSize(
            SAMPLE_RATE,
            AudioFormat.CHANNEL_OUT_MONO,
            AudioFormat.ENCODING_PCM_16BIT
        )
        val track = runCatching {
            AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setFlags(AUDIO_ATTRIBUTE_FLAGS)
                        .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build()
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(SAMPLE_RATE)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                        .build()
                )
                .setBufferSizeInBytes(maxOf(minBuffer * 2, READ_BUFFER_BYTES * 2))
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build()
        }.getOrElse { error ->
            android.util.Log.w(
                TAG,
                "call inject (shizuku) track build failed: ${error.javaClass.simpleName}: ${error.message}"
            )
            return null
        }
        if (track.state != AudioTrack.STATE_INITIALIZED) {
            android.util.Log.w(TAG, "call inject (shizuku) track not initialized state=${track.state}")
            releaseTrack(track)
            return null
        }
        val routed = runCatching { track.setPreferredDevice(telephony) }.getOrElse { error ->
            android.util.Log.w(
                TAG,
                "call inject (shizuku) setPreferredDevice threw: ${error.javaClass.simpleName}: ${error.message}"
            )
            false
        }
        android.util.Log.i(TAG, "call inject (shizuku) setPreferredDevice=$routed")
        if (!routed) {
            // uid 0 was refused the telephony route. There is no fallback
            // anymore; release and let the caller retry so the refusal stays
            // visible in the logs for the whole call.
            releaseTrack(track)
            return null
        }
        track.play()
        android.util.Log.i(TAG, "call inject (shizuku) track playing")
        return track
    }

    private fun releaseTrack(track: AudioTrack?) {
        if (track == null) {
            return
        }
        runCatching { track.stop() }
        runCatching { track.release() }
    }

    private fun resolveContext(): Context? {
        val current = runCatching {
            Class.forName("android.app.ActivityThread")
                .getMethod("currentApplication")
                .invoke(null) as? Context
        }.getOrNull()
        if (current != null) {
            return current
        }
        return runCatching {
            val activityThread = Class.forName("android.app.ActivityThread")
                .getMethod("systemMain")
                .invoke(null)
            activityThread.javaClass.getMethod("getSystemContext").invoke(activityThread) as? Context
        }.getOrNull()
    }
}

// Shared framing constants for the 19307 call-inject endpoint (Mac sends a
// 4-byte "ELMA" magic followed by raw 16k s16le mono PCM).
internal object CallInjectProtocol {
    const val PORT = 19_307
    const val SAMPLE_RATE = 16_000
    val MAGIC = byteArrayOf(
        'E'.code.toByte(),
        'L'.code.toByte(),
        'M'.code.toByte(),
        'A'.code.toByte()
    )

    fun hasMagic(bytes: ByteArray): Boolean {
        if (bytes.size < MAGIC.size) {
            return false
        }
        for (index in MAGIC.indices) {
            if (bytes[index] != MAGIC[index]) {
                return false
            }
        }
        return true
    }
}
