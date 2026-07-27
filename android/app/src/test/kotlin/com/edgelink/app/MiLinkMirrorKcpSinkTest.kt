package com.edgelink.app

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MiLinkMirrorKcpSinkTest {
    private val sent = mutableListOf<ByteArray>()
    private val payloads = mutableListOf<ByteArray>()

    private fun newSink(): MiLinkMirrorKcpSink = MiLinkMirrorKcpSink(
        sessionId = "test",
        receiveWindow = { 128 },
        onSendDatagram = { sent.add(it) },
        onPayload = { payloads.add(it) },
        logInfo = {},
        logWarn = {}
    )

    private fun push(conv: Long, ts: Long, sn: Long, payload: ByteArray): ByteArray {
        val packet = ByteArray(24 + payload.size)
        writeLE(packet, 0, conv)
        packet[4] = 0x51
        packet[5] = 0
        packet[6] = 0; packet[7] = 0
        writeLE(packet, 8, ts)
        writeLE(packet, 12, sn)
        writeLE(packet, 16, 0)
        writeLE(packet, 20, payload.size.toLong())
        payload.copyInto(packet, 24)
        return packet
    }

    private fun wask(conv: Long, ts: Long, sn: Long): ByteArray {
        val packet = ByteArray(24)
        writeLE(packet, 0, conv)
        packet[4] = 0x53
        writeLE(packet, 8, ts)
        writeLE(packet, 12, sn)
        return packet
    }

    private fun writeLE(data: ByteArray, offset: Int, value: Long) {
        data[offset] = (value and 0xFF).toByte()
        data[offset + 1] = ((value shr 8) and 0xFF).toByte()
        data[offset + 2] = ((value shr 16) and 0xFF).toByte()
        data[offset + 3] = ((value shr 24) and 0xFF).toByte()
    }

    private fun readLE(data: ByteArray, offset: Int): Long =
        (data[offset].toLong() and 0xFF) or
            ((data[offset + 1].toLong() and 0xFF) shl 8) or
            ((data[offset + 2].toLong() and 0xFF) shl 16) or
            ((data[offset + 3].toLong() and 0xFF) shl 24)

    @Test
    fun inOrderPushDeliversPayloadAndAcks() {
        val sink = newSink()
        sink.receiveDatagram(push(0x1234, ts = 111, sn = 7, payload = byteArrayOf(1, 2, 3)))
        sink.receiveDatagram(push(0x1234, ts = 222, sn = 8, payload = byteArrayOf(4, 5)))

        assertEquals(2, payloads.size)
        assertArrayEquals(byteArrayOf(1, 2, 3), payloads[0])
        assertArrayEquals(byteArrayOf(4, 5), payloads[1])
        assertEquals(2, sent.size)
        val ack = sent[1]
        assertEquals(24, ack.size)
        assertEquals(0x1234L, readLE(ack, 0))
        assertEquals(0x52, ack[4].toInt() and 0xFF)
        assertEquals(222L, readLE(ack, 8))
        assertEquals(8L, readLE(ack, 12))
        assertEquals(9L, readLE(ack, 16))
        assertEquals(0L, readLE(ack, 20))
    }

    @Test
    fun duplicatePushDroppedButAcked() {
        val sink = newSink()
        sink.receiveDatagram(push(0x1234, ts = 1, sn = 3, payload = byteArrayOf(9)))
        sink.receiveDatagram(push(0x1234, ts = 1, sn = 3, payload = byteArrayOf(9)))
        assertEquals(1, payloads.size)
        assertEquals(2, sent.size)
        assertEquals(1L, sink.duplicateDropped)
    }

    @Test
    fun outOfOrderBufferedThenDrainedInOrder() {
        val sink = newSink()
        sink.receiveDatagram(push(0x1234, ts = 1, sn = 10, payload = byteArrayOf(1)))
        sink.receiveDatagram(push(0x1234, ts = 2, sn = 12, payload = byteArrayOf(3)))
        assertEquals(1, payloads.size)
        sink.receiveDatagram(push(0x1234, ts = 3, sn = 11, payload = byteArrayOf(2)))
        assertEquals(3, payloads.size)
        assertArrayEquals(byteArrayOf(1), payloads[0])
        assertArrayEquals(byteArrayOf(2), payloads[1])
        assertArrayEquals(byteArrayOf(3), payloads[2])
    }

    @Test
    fun waskGetsWinsReply() {
        val sink = newSink()
        sink.receiveDatagram(push(0x1234, ts = 1, sn = 5, payload = byteArrayOf(1)))
        sink.receiveDatagram(wask(0x1234, ts = 99, sn = 0))
        val wins = sent.last()
        assertEquals(0x54, wins[4].toInt() and 0xFF)
        assertEquals(99L, readLE(wins, 8))
        assertEquals(128L, readLE(wins, 6) and 0xFFFF)
        assertEquals(1L, sink.winsSent)
    }

    @Test
    fun foreignConversationIgnored() {
        val sink = newSink()
        sink.receiveDatagram(push(0x1234, ts = 1, sn = 5, payload = byteArrayOf(1)))
        sink.receiveDatagram(push(0x7777, ts = 1, sn = 5, payload = byteArrayOf(2)))
        assertEquals(1, payloads.size)
    }

    @Test
    fun malformedDatagramIgnored() {
        val sink = newSink()
        sink.receiveDatagram(byteArrayOf(1, 2, 3))
        sink.receiveDatagram(ByteArray(0))
        assertTrue(payloads.isEmpty())
        assertTrue(sent.isEmpty())
        assertEquals(1L, sink.malformed)
    }

    @Test
    fun multipleSegmentsInOneDatagram() {
        val sink = newSink()
        val first = push(0x1234, ts = 1, sn = 4, payload = byteArrayOf(1))
        val second = push(0x1234, ts = 2, sn = 5, payload = byteArrayOf(2))
        sink.receiveDatagram(first + second)
        assertEquals(2, payloads.size)
        assertEquals(2, sent.size)
    }
}
