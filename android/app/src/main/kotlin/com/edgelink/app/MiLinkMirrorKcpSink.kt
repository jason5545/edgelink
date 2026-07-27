package com.edgelink.app

import java.util.TreeMap

class MiLinkMirrorKcpSink(
    private val sessionId: () -> String,
    private val receiveWindow: () -> Int,
    private val onSendDatagram: (ByteArray) -> Unit,
    private val onPayload: (ByteArray) -> Unit,
    private val logInfo: (String) -> Unit = { EdgeLinkLog.info(it) },
    private val logWarn: (String) -> Unit = { EdgeLinkLog.warn(it) }
) {
    companion object {
        const val HEADER_LENGTH = 24
        const val COMMAND_PUSH = 0x51
        const val COMMAND_ACK = 0x52
        const val COMMAND_WASK = 0x53
        const val COMMAND_WINS = 0x54
        private const val RECEIVE_BUFFER_LIMIT = 256
        private const val RECEIVE_MAX_GAP = 512L
    }

    private var conversationId: Long = -1
    private var nextReceiveSn: Long = 0
    private var conversationSeen = false
    private val receiveBuffer = TreeMap<Long, ByteArray>()

    var pushReceived = 0L
        private set
    var acksSent = 0L
        private set
    var duplicateDropped = 0L
        private set
    var outOfOrderBuffered = 0L
        private set
    var resyncCount = 0L
        private set
    var waskReceived = 0L
        private set
    var winsSent = 0L
        private set
    var malformed = 0L
        private set

    @Synchronized
    fun receiveDatagram(data: ByteArray) {
        var offset = 0
        var parsed = 0
        while (offset + HEADER_LENGTH <= data.size) {
            val length = readUInt32LE(data, offset + 20)
            if (length < 0 || length > data.size) {
                break
            }
            val segmentLength = HEADER_LENGTH + length.toInt()
            if (offset + segmentLength > data.size) {
                malformed += 1
                logWarn(
                    "xiaomi.mirror.android.kcp_malformed sessionId=${sessionId()} " +
                        "bytes=${data.size} offset=$offset declaredLength=$length"
                )
                return
            }
            handleSegment(data, offset, length.toInt())
            offset += segmentLength
            parsed += 1
        }
        if (parsed == 0 && data.isNotEmpty()) {
            malformed += 1
            if (malformed <= 5 || malformed % 50 == 0L) {
                logWarn(
                    "xiaomi.mirror.android.kcp_malformed sessionId=${sessionId()} " +
                        "bytes=${data.size} malformed=$malformed bytes=${data.size}"
                )
            }
        }
    }

    private fun handleSegment(data: ByteArray, offset: Int, payloadLength: Int) {
        val conv = readUInt32LE(data, offset)
        val command = data[offset + 4].toInt() and 0xFF
        val ts = readUInt32LE(data, offset + 8)
        val sn = readUInt32LE(data, offset + 12)
        if (!conversationSeen) {
            if (command != COMMAND_PUSH || conv == 0L) {
                return
            }
            conversationSeen = true
            conversationId = conv
            nextReceiveSn = sn
            logInfo(
                "xiaomi.mirror.android.kcp_conversation sessionId=${sessionId()} " +
                    "conv=0x${conv.toString(16)} firstSn=$sn"
            )
        }
        if (conv != conversationId) {
            return
        }
        when (command) {
            COMMAND_PUSH -> handlePush(ts, sn, data, offset + HEADER_LENGTH, payloadLength)
            COMMAND_WASK -> {
                waskReceived += 1
                sendSegment(COMMAND_WINS, ts, sn)
                winsSent += 1
                logInfo(
                    "xiaomi.mirror.android.kcp_wask sessionId=${sessionId()} count=$waskReceived sn=$sn"
                )
            }
            COMMAND_ACK, COMMAND_WINS -> Unit
            else -> logInfo(
                "xiaomi.mirror.android.kcp_unknown sessionId=${sessionId()} " +
                    "cmd=0x${command.toString(16)} sn=$sn len=$payloadLength"
            )
        }
    }

    private fun handlePush(ts: Long, sn: Long, data: ByteArray, payloadOffset: Int, payloadLength: Int) {
        pushReceived += 1
        val delta = sequenceDelta(sn, nextReceiveSn)
        if (delta == 0L) {
            deliver(data, payloadOffset, payloadLength, sn)
            nextReceiveSn = (nextReceiveSn + 1) and 0xFFFFFFFFL
            drainBuffer()
            sendSegment(COMMAND_ACK, ts, sn)
            return
        }
        if (delta < 0) {
            duplicateDropped += 1
            sendSegment(COMMAND_ACK, ts, sn)
            if (duplicateDropped <= 5 || duplicateDropped % 50 == 0L) {
                logWarn(
                    "xiaomi.mirror.android.kcp_duplicate sessionId=${sessionId()} " +
                        "sn=$sn expected=$nextReceiveSn duplicates=$duplicateDropped"
                )
            }
            return
        }
        if (receiveBuffer.size >= RECEIVE_BUFFER_LIMIT || delta > RECEIVE_MAX_GAP) {
            resyncCount += 1
            receiveBuffer.clear()
            logWarn(
                "xiaomi.mirror.android.kcp_resync sessionId=${sessionId()} " +
                    "sn=$sn expected=$nextReceiveSn gap=$delta resyncs=$resyncCount"
            )
            nextReceiveSn = sn
            deliver(data, payloadOffset, payloadLength, sn)
            nextReceiveSn = (nextReceiveSn + 1) and 0xFFFFFFFFL
            sendSegment(COMMAND_ACK, ts, sn)
            return
        }
        if (!receiveBuffer.containsKey(sn)) {
            receiveBuffer[sn] = data.copyOfRange(payloadOffset, payloadOffset + payloadLength)
            outOfOrderBuffered += 1
            if (outOfOrderBuffered <= 5 || outOfOrderBuffered % 50 == 0L) {
                logWarn(
                    "xiaomi.mirror.android.kcp_out_of_order sessionId=${sessionId()} " +
                        "sn=$sn expected=$nextReceiveSn gap=$delta buffered=${receiveBuffer.size}"
                )
            }
        }
        sendSegment(COMMAND_ACK, ts, sn)
    }

    private fun drainBuffer() {
        while (true) {
            val payload = receiveBuffer.remove(nextReceiveSn) ?: return
            deliver(payload, 0, payload.size, nextReceiveSn)
            nextReceiveSn = (nextReceiveSn + 1) and 0xFFFFFFFFL
        }
    }

    private fun deliver(data: ByteArray, offset: Int, length: Int, sn: Long) {
        val payload = if (offset == 0 && length == data.size) {
            data
        } else {
            data.copyOfRange(offset, offset + length)
        }
        if (pushReceived <= 5 || pushReceived % 100 == 0L) {
            logInfo(
                "xiaomi.mirror.android.kcp_push sessionId=${sessionId()} sn=$sn " +
                    "payloadBytes=$length pushReceived=$pushReceived"
            )
        }
        onPayload(payload)
    }

    private fun sendSegment(command: Int, ts: Long, sn: Long) {
        val packet = ByteArray(HEADER_LENGTH)
        writeUInt32LE(packet, 0, conversationId)
        packet[4] = command.toByte()
        packet[5] = 0
        writeUInt16LE(packet, 6, receiveWindow().coerceIn(0, 0xFFFF))
        writeUInt32LE(packet, 8, ts)
        writeUInt32LE(packet, 12, sn)
        writeUInt32LE(packet, 16, nextReceiveSn)
        writeUInt32LE(packet, 20, 0)
        onSendDatagram(packet)
        if (command == COMMAND_ACK) {
            acksSent += 1
        }
    }

    private fun sequenceDelta(sn: Long, from: Long): Long {
        val diff = ((sn - from) and 0xFFFFFFFFL)
        return if (diff >= 0x80000000L) diff - 0x100000000L else diff
    }

    private fun readUInt32LE(data: ByteArray, offset: Int): Long {
        if (offset + 4 > data.size) {
            return -1
        }
        return (data[offset].toLong() and 0xFF) or
            ((data[offset + 1].toLong() and 0xFF) shl 8) or
            ((data[offset + 2].toLong() and 0xFF) shl 16) or
            ((data[offset + 3].toLong() and 0xFF) shl 24)
    }

    private fun writeUInt32LE(data: ByteArray, offset: Int, value: Long) {
        data[offset] = (value and 0xFF).toByte()
        data[offset + 1] = ((value shr 8) and 0xFF).toByte()
        data[offset + 2] = ((value shr 16) and 0xFF).toByte()
        data[offset + 3] = ((value shr 24) and 0xFF).toByte()
    }

    private fun writeUInt16LE(data: ByteArray, offset: Int, value: Int) {
        data[offset] = (value and 0xFF).toByte()
        data[offset + 1] = ((value shr 8) and 0xFF).toByte()
    }
}
