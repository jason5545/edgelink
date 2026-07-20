package com.edgelink.app

import android.media.MediaCodec
import android.media.MediaFormat
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.atomic.AtomicBoolean

object AndroidDistAudioUplinkForwarder {
    private const val SOCKET_HOST = "127.0.0.1"
    private const val SOCKET_PORT = 19_307
    private const val SOCKET_CONNECT_TIMEOUT_MS = 1_500
    private const val TS_PACKET_SIZE = 188
    private const val TS_SYNC_BYTE = 0x47
    private const val AUDIO_TS_PID = 0x1100
    private const val AAC_SAMPLE_RATE = 48_000
    private const val AAC_CHANNELS = 1
    private const val OUTPUT_SAMPLE_RATE = 16_000
    private const val RESAMPLE_RATIO = AAC_SAMPLE_RATE / OUTPUT_SAMPLE_RATE
    private const val QUEUE_CAPACITY = 128
    private const val CODEC_TIMEOUT_US = 10_000L
    private const val RECONNECT_DELAY_MS = 1_000L

    private val running = AtomicBoolean(false)
    private var workerThread: Thread? = null
    private var packetQueue = ArrayBlockingQueue<ByteArray>(QUEUE_CAPACITY)

    @Volatile private var packetsReceived = 0L
    @Volatile private var aacFramesDecoded = 0L
    @Volatile private var pcmBytesDecoded = 0L
    @Volatile private var pcmBytesSent = 0L

    fun start(reason: String) {
        if (!running.compareAndSet(false, true)) {
            return
        }
        packetQueue.clear()
        packetsReceived = 0
        aacFramesDecoded = 0
        pcmBytesSent = 0
        workerThread = Thread({ runWorker() }, "EdgeLinkDistAudioUplink").apply { start() }
        EdgeLinkLog.info("callrelay.android.dist_uplink_start reason=$reason")
    }

    fun stop(reason: String) {
        if (!running.compareAndSet(true, false)) {
            return
        }
        val thread = workerThread
        workerThread = null
        if (thread != null) {
            runCatching { thread.join(1_000) }
        }
        EdgeLinkLog.info(
            "callrelay.android.dist_uplink_stop reason=$reason packets=$packetsReceived " +
                "aacFrames=$aacFramesDecoded pcmDecoded=$pcmBytesDecoded pcmBytesSent=$pcmBytesSent"
        )
    }

    fun handleSourceRTP(packet: ByteArray) {
        if (!running.get()) {
            return
        }
        packetsReceived += 1
        if (!packetQueue.offer(packet.copyOf()) && packetsReceived % 100 == 0L) {
            EdgeLinkLog.warn("callrelay.android.dist_uplink_queue_full packets=$packetsReceived")
        }
    }

    private fun runWorker() {
        var socket: Socket? = null
        var decoder: MediaCodec? = null
        val tsAssembler = TsAssembler()
        val adtsParser = AdtsParser()
        val resampler = DecimatingResampler()
        val pendingFrames = ArrayDeque<ByteArray>()
        try {
            while (running.get()) {
                val activeSocket = socket
                if (activeSocket == null) {
                    socket = runCatching {
                        Socket().apply {
                            connect(
                                InetSocketAddress(SOCKET_HOST, SOCKET_PORT),
                                SOCKET_CONNECT_TIMEOUT_MS
                            )
                            tcpNoDelay = true
                        }
                    }.getOrElse { error ->
                        if (packetsReceived > 0 && packetsReceived % 500 == 1L) {
                            EdgeLinkLog.warn(
                                "callrelay.android.dist_uplink_socket_retry " +
                                    "error=${error.javaClass.simpleName}:${error.message.orEmpty()}"
                            )
                        }
                        null
                    }
                    if (socket == null) {
                        drainQueueWithoutSocket()
                        Thread.sleep(RECONNECT_DELAY_MS)
                        continue
                    }
                    EdgeLinkLog.info("callrelay.android.dist_uplink_socket_connected")
                }
                val currentSocket = socket ?: continue
                try {
                    val packet = packetQueue.poll()
                    if (packet == null) {
                        val currentDecoder = decoder
                        if (currentDecoder != null) {
                            drainDecoder(currentDecoder, resampler, currentSocket)
                        }
                        Thread.sleep(5)
                        continue
                    }
                    val aacChunks = tsAssembler.feed(extractRtpPayload(packet) ?: continue)
                    for (chunk in aacChunks) {
                        adtsParser.feed(chunk)
                    }
                    var frame = adtsParser.nextFrame()
                    while (frame != null) {
                        pendingFrames.add(frame)
                        frame = adtsParser.nextFrame()
                    }
                    if (decoder == null) {
                        decoder = createDecoder(adtsParser.audioSpecificConfig())
                        if (decoder == null) {
                            pendingFrames.clear()
                            Thread.sleep(RECONNECT_DELAY_MS)
                            continue
                        }
                    }
                    val currentDecoder = decoder ?: continue
                    while (pendingFrames.isNotEmpty()) {
                        feedDecoder(currentDecoder, pendingFrames.removeFirst())
                        aacFramesDecoded += 1
                    }
                    drainDecoder(currentDecoder, resampler, currentSocket)
                } catch (error: java.io.IOException) {
                    EdgeLinkLog.warn(
                        "callrelay.android.dist_uplink_socket_lost " +
                            "error=${error.javaClass.simpleName}:${error.message.orEmpty()}"
                    )
                    runCatching { currentSocket.close() }
                    socket = null
                }
            }
        } catch (error: Throwable) {
            EdgeLinkLog.warn(
                "callrelay.android.dist_uplink_worker_error " +
                    "error=${error.javaClass.simpleName}:${error.message.orEmpty()}"
            )
        } finally {
            runCatching { decoder?.stop() }
            runCatching { decoder?.release() }
            runCatching { socket?.close() }
        }
    }

    private fun drainQueueWithoutSocket() {
        while (packetQueue.poll() != null) {
        }
    }

    private fun createDecoder(asc: ByteArray?): MediaCodec? {
        if (asc == null) {
            return null
        }
        return runCatching {
            val format = MediaFormat.createAudioFormat(
                MediaFormat.MIMETYPE_AUDIO_AAC,
                AAC_SAMPLE_RATE,
                AAC_CHANNELS
            )
            format.setByteBuffer("csd-0", java.nio.ByteBuffer.wrap(asc))
            val codec = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
            codec.configure(format, null, null, 0)
            codec.start()
            EdgeLinkLog.info("callrelay.android.dist_uplink_decoder_started asc=${asc.toHex()}")
            codec
        }.getOrElse { error ->
            EdgeLinkLog.warn(
                "callrelay.android.dist_uplink_decoder_failed " +
                    "error=${error.javaClass.simpleName}:${error.message.orEmpty()}"
            )
            null
        }
    }

    private fun ByteArray.toHex(): String =
        joinToString("") { "%02x".format(it) }

    private fun feedDecoder(decoder: MediaCodec, frame: ByteArray) {
        val inputIndex = decoder.dequeueInputBuffer(CODEC_TIMEOUT_US)
        if (inputIndex < 0) {
            return
        }
        val buffer = decoder.getInputBuffer(inputIndex) ?: return
        buffer.clear()
        buffer.put(frame)
        decoder.queueInputBuffer(inputIndex, 0, frame.size, 0, 0)
    }

    private fun drainDecoder(decoder: MediaCodec, resampler: DecimatingResampler, socket: Socket) {
        val info = MediaCodec.BufferInfo()
        while (running.get()) {
            val outputIndex = decoder.dequeueOutputBuffer(info, 0)
            if (outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                EdgeLinkLog.info(
                    "callrelay.android.dist_uplink_decoder_format format=${decoder.outputFormat}"
                )
                continue
            }
            if (outputIndex < 0) {
                return
            }
            val buffer = decoder.getOutputBuffer(outputIndex)
            if (buffer != null && info.size > 0) {
                val pcm = ByteArray(info.size)
                buffer.position(info.offset)
                buffer.get(pcm, 0, info.size)
                pcmBytesDecoded += pcm.size
                if (pcmBytesDecoded == pcm.size.toLong() || pcmBytesDecoded % 960_000L < pcm.size) {
                    EdgeLinkLog.info("callrelay.android.dist_uplink_pcm_decoded bytes=$pcmBytesDecoded")
                }
                val resampled = resampler.process(pcm)
                if (resampled.isNotEmpty()) {
                    writeToSocket(socket, resampled)
                }
            }
            decoder.releaseOutputBuffer(outputIndex, false)
            if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                return
            }
        }
    }

    private fun writeToSocket(socket: Socket, pcm: ByteArray) {
        runCatching {
            socket.outputStream.write(pcm)
            socket.outputStream.flush()
            pcmBytesSent += pcm.size
            if (pcmBytesSent == pcm.size.toLong() || pcmBytesSent % 320_000L < pcm.size) {
                EdgeLinkLog.info("callrelay.android.dist_uplink_pcm_sent bytes=$pcmBytesSent")
            }
        }.onFailure { error ->
            EdgeLinkLog.warn(
                "callrelay.android.dist_uplink_socket_write_failed " +
                    "error=${error.javaClass.simpleName}:${error.message.orEmpty()}"
            )
            throw error
        }
    }

    private fun extractRtpPayload(packet: ByteArray): ByteArray? {
        if (packet.size < 12) {
            return null
        }
        if (packet[0].toInt() and 0xC0 != 0x80) {
            return null
        }
        val hasExtension = packet[0].toInt() and 0x10 != 0
        val csrcCount = packet[0].toInt() and 0x0F
        var offset = 12 + csrcCount * 4
        if (packet.size < offset) {
            return null
        }
        if (hasExtension) {
            if (packet.size < offset + 4) {
                return null
            }
            val length = (packet[offset + 2].toInt() and 0xff shl 8) or (packet[offset + 3].toInt() and 0xff)
            offset += 4 + length * 4
            if (packet.size < offset) {
                return null
            }
        }
        return packet.copyOfRange(offset, packet.size)
    }

    private class TsAssembler {
        private var pending = ByteArray(0)

        fun feed(payload: ByteArray): List<ByteArray> {
            val combined = ByteArray(pending.size + payload.size)
            System.arraycopy(pending, 0, combined, 0, pending.size)
            System.arraycopy(payload, 0, combined, pending.size, payload.size)
            val chunks = mutableListOf<ByteArray>()
            var offset = 0
            while (offset + TS_PACKET_SIZE <= combined.size) {
                if (combined[offset].toInt() and 0xff != TS_SYNC_BYTE) {
                    offset += 1
                    continue
                }
                val packetStart = offset
                val packetEnd = offset + TS_PACKET_SIZE
                val payloadUnitStart = combined[packetStart + 1].toInt() and 0x40 != 0
                val pid = (combined[packetStart + 1].toInt() and 0x1f shl 8) or
                    (combined[packetStart + 2].toInt() and 0xff)
                val adaptationFieldControl = combined[packetStart + 3].toInt() shr 4 and 0x03
                var payloadStart = packetStart + 4
                if (adaptationFieldControl == 2 || adaptationFieldControl == 3) {
                    if (payloadStart >= packetEnd) {
                        offset = packetEnd
                        continue
                    }
                    payloadStart += 1 + (combined[payloadStart].toInt() and 0xff)
                }
                if ((adaptationFieldControl == 1 || adaptationFieldControl == 3) &&
                    pid == AUDIO_TS_PID && payloadStart < packetEnd
                ) {
                    if (payloadUnitStart && payloadStart + 9 <= packetEnd &&
                        combined[payloadStart].toInt() and 0xff == 0x00 &&
                        combined[payloadStart + 1].toInt() and 0xff == 0x00 &&
                        combined[payloadStart + 2].toInt() and 0xff == 0x01
                    ) {
                        val headerLength = combined[payloadStart + 8].toInt() and 0xff
                        val esStart = payloadStart + 9 + headerLength
                        if (esStart < packetEnd) {
                            chunks.add(combined.copyOfRange(esStart, packetEnd))
                        }
                    } else {
                        chunks.add(combined.copyOfRange(payloadStart, packetEnd))
                    }
                }
                offset = packetEnd
            }
            pending = combined.copyOfRange(offset, combined.size)
            return chunks
        }
    }

    private class AdtsParser {
        private var buffer = ByteArray(0)
        private var asc: ByteArray? = null

        fun feed(data: ByteArray) {
            val combined = ByteArray(buffer.size + data.size)
            System.arraycopy(buffer, 0, combined, 0, buffer.size)
            System.arraycopy(data, 0, combined, buffer.size, data.size)
            buffer = combined
        }

        fun audioSpecificConfig(): ByteArray? = asc

        fun nextFrame(): ByteArray? {
            while (true) {
                if (buffer.size < 7) {
                    return null
                }
                val b0 = buffer[0].toInt() and 0xff
                val b1 = buffer[1].toInt() and 0xff
                if (b0 != 0xFF || b1 and 0xF0 != 0xF0) {
                    buffer = buffer.copyOfRange(1, buffer.size)
                    continue
                }
                val frameLength = (buffer[3].toInt() and 0x03 shl 11) or
                    (buffer[4].toInt() and 0xff shl 3) or
                    (buffer[5].toInt() and 0xE0 shr 5)
                if (frameLength < 7) {
                    buffer = buffer.copyOfRange(1, buffer.size)
                    continue
                }
                if (buffer.size < frameLength) {
                    return null
                }
                if (asc == null) {
                    asc = buildAudioSpecificConfig(buffer)
                }
                val protectionAbsent = b1 and 0x01
                val headerSize = if (protectionAbsent == 1) 7 else 9
                val payload = if (frameLength > headerSize) {
                    buffer.copyOfRange(headerSize, frameLength)
                } else {
                    ByteArray(0)
                }
                buffer = buffer.copyOfRange(frameLength, buffer.size)
                if (payload.isEmpty()) {
                    continue
                }
                return payload
            }
        }

        private fun buildAudioSpecificConfig(header: ByteArray): ByteArray? {
            if (header.size < 7) {
                return null
            }
            val b2 = header[2].toInt() and 0xff
            val b3 = header[3].toInt() and 0xff
            val profile = (b2 shr 6 and 0x03) + 1
            val frequencyIndex = b2 shr 2 and 0x0F
            val channelConfig = (b2 and 0x01 shl 2) or (b3 shr 6 and 0x03)
            if (frequencyIndex >= 13) {
                return null
            }
            val bits = (profile shl 11) or (frequencyIndex shl 7) or (channelConfig shl 3)
            return byteArrayOf((bits shr 8 and 0xff).toByte(), (bits and 0xff).toByte())
        }
    }

    private class DecimatingResampler {
        private val taps = floatArrayOf(
            -0.00409f, 0.00769f, 0.08927f, 0.24333f, 0.32760f,
            0.24333f, 0.08927f, 0.00769f, -0.00409f
        )
        private var history = ShortArray(taps.size)
        private var historyFilled = 0
        private var phase = 0

        fun process(pcm: ByteArray): ByteArray {
            val sampleCount = pcm.size / 2
            if (sampleCount == 0) {
                return ByteArray(0)
            }
            val output = java.io.ByteArrayOutputStream(pcm.size / RESAMPLE_RATIO + 8)
            var index = 0
            while (index < sampleCount) {
                val sample = (pcm[index * 2].toInt() and 0xff) or
                    (pcm[index * 2 + 1].toInt() shl 8)
                shiftIn(sample.toShort())
                index += 1
                phase += 1
                if (phase >= RESAMPLE_RATIO) {
                    phase = 0
                    if (historyFilled >= taps.size) {
                        writeSample(output, convolve())
                    }
                }
            }
            return output.toByteArray()
        }

        private fun shiftIn(sample: Short) {
            System.arraycopy(history, 1, history, 0, history.size - 1)
            history[history.size - 1] = sample
            if (historyFilled < history.size) {
                historyFilled += 1
            }
        }

        private fun convolve(): Short {
            var sum = 0f
            for (tap in taps.indices) {
                sum += taps[tap] * history[tap]
            }
            val value = sum.toInt().coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())
            return value.toShort()
        }

        private fun writeSample(output: java.io.ByteArrayOutputStream, sample: Short) {
            val value = sample.toInt()
            output.write(value and 0xff)
            output.write(value shr 8 and 0xff)
        }
    }
}
