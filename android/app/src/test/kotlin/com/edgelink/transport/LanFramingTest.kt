package com.edgelink.transport

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.ByteArrayOutputStream

class LanFramingTest {
    @Test
    fun writeFrameEmitsLengthHeaderFollowedByPayload() {
        val payload = ByteArray(252) { it.toByte() }
        val output = ByteArrayOutputStream()

        LanFraming.writeFrame(output, payload)

        val written = output.toByteArray()
        assertEquals(256, written.size)
        assertArrayEquals(byteArrayOf(0x00, 0x00, 0x00, 0xFC.toByte()), written.copyOfRange(0, 4))
        assertArrayEquals(payload, written.copyOfRange(4, written.size))
    }

    @Test
    fun writeFrameHandlesEmptyPayload() {
        val output = ByteArrayOutputStream()

        LanFraming.writeFrame(output, ByteArray(0))

        assertArrayEquals(byteArrayOf(0, 0, 0, 0), output.toByteArray())
    }

    @Test
    fun writeFrameEncodesLargeLengthBigEndian() {
        val payload = ByteArray(0x01020304) { 0 }
        val output = ByteArrayOutputStream()

        LanFraming.writeFrame(output, payload)

        val header = output.toByteArray().copyOfRange(0, 4)
        assertArrayEquals(byteArrayOf(0x01, 0x02, 0x03, 0x04), header)
    }
}
