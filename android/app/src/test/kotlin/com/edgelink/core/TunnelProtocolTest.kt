package com.edgelink.core

import org.junit.Assert.*
import org.junit.Test

class TunnelProtocolTest {
    @Test
    fun chunkSmallData() {
        val data = "hello".toByteArray()
        val chunks = TunnelChunker.chunk(data)
        assertEquals(1, chunks.size)
        assertEquals(0, chunks[0].seq)
        assertArrayEquals(data, chunks[0].data)
        assertTrue(chunks[0].isLast)
    }

    @Test
    fun chunkEmptyData() {
        val chunks = TunnelChunker.chunk(ByteArray(0))
        assertEquals(1, chunks.size)
        assertTrue(chunks[0].isLast)
        assertTrue(chunks[0].data.isEmpty())
    }

    @Test
    fun chunkLargeData() {
        val data = ByteArray(TunnelChunker.MAX_CHUNK_SIZE * 3 + 100)
        val chunks = TunnelChunker.chunk(data)
        assertEquals(4, chunks.size)
        assertEquals(0, chunks[0].seq)
        assertEquals(3, chunks[3].seq)
        assertFalse(chunks[0].isLast)
        assertTrue(chunks[3].isLast)
        assertEquals(TunnelChunker.MAX_CHUNK_SIZE, chunks[0].data.size)
        assertEquals(100, chunks[3].data.size)
    }

    @Test
    fun chunkReassembly() {
        val original = ByteArray(100_000) { (it % 256).toByte() }
        val chunks = TunnelChunker.chunk(original)
        val reassembled = chunks.fold(ByteArray(0)) { acc, chunk -> acc + chunk.data }
        assertArrayEquals(original, reassembled)
    }

    @Test
    fun payloadBase64RoundTrip() {
        val data = byteArrayOf(0x00, 0xFF.toByte(), 0x80.toByte(), 0x7F, 0x01)
        val base64 = TunnelChunker.payloadBase64(data)
        val decoded = TunnelChunker.payloadFromBase64(base64)
        assertArrayEquals(data, decoded)
    }

    @Test
    fun payloadFromInvalidBase64() {
        assertNull(TunnelChunker.payloadFromBase64("not valid!!!"))
    }

    @Test
    fun reassemblerInOrder() {
        val reassembler = TunnelReassembler()
        val result = reassembler.append("t1", 1, 0, "hello".toByteArray(), true)
        assertArrayEquals("hello".toByteArray(), result)
    }

    @Test
    fun reassemblerMultiChunk() {
        val reassembler = TunnelReassembler()
        assertNull(reassembler.append("t1", 1, 0, "hel".toByteArray(), false))
        assertNull(reassembler.append("t1", 1, 1, "lo".toByteArray(), false))
        val result = reassembler.append("t1", 1, 2, "!".toByteArray(), true)
        assertArrayEquals("hello!".toByteArray(), result)
    }

    @Test
    fun reassemblerMultipleStreams() {
        val reassembler = TunnelReassembler()
        assertNull(reassembler.append("t1", 1, 0, "a".toByteArray(), false))
        assertNull(reassembler.append("t1", 2, 0, "x".toByteArray(), false))
        val r1 = reassembler.append("t1", 1, 1, "b".toByteArray(), true)
        val r2 = reassembler.append("t1", 2, 1, "y".toByteArray(), true)
        assertArrayEquals("ab".toByteArray(), r1)
        assertArrayEquals("xy".toByteArray(), r2)
    }

    @Test
    fun reassemblerReset() {
        val reassembler = TunnelReassembler()
        reassembler.append("t1", 1, 0, "a".toByteArray(), false)
        reassembler.reset("t1", 1)
        val result = reassembler.append("t1", 1, 0, "fresh".toByteArray(), true)
        assertArrayEquals("fresh".toByteArray(), result)
    }

    @Test
    fun allowlistLoopbackAllowed() {
        val allowlist = TunnelAllowlist()
        assertTrue(allowlist.isAllowed("127.0.0.1", 5555))
        assertTrue(allowlist.isAllowed("::1", 8080))
        assertTrue(allowlist.isAllowed("localhost", 22))
    }

    @Test
    fun allowlistPublicDenied() {
        val allowlist = TunnelAllowlist()
        assertFalse(allowlist.isAllowed("8.8.8.8", 53))
        assertFalse(allowlist.isAllowed("192.168.1.1", 80))
    }

    @Test
    fun allowlistCustomRule() {
        val allowlist = TunnelAllowlist()
        assertFalse(allowlist.isAllowed("192.168.1.100", 22))
        allowlist.addRule(TunnelAllowlistRule("192.168.1.100", 22))
        assertTrue(allowlist.isAllowed("192.168.1.100", 22))
        assertFalse(allowlist.isAllowed("192.168.1.100", 80))
    }

    @Test
    fun allowlistWildcardPort() {
        val allowlist = TunnelAllowlist()
        allowlist.addRule(TunnelAllowlistRule("10.0.0.5", null))
        assertTrue(allowlist.isAllowed("10.0.0.5", 1))
        assertTrue(allowlist.isAllowed("10.0.0.5", 65535))
    }

    @Test
    fun envelopeTypeConstants() {
        assertEquals("tunnel.open", TunnelEnvelopeTypes.OPEN)
        assertEquals("tunnel.open.result", TunnelEnvelopeTypes.OPEN_RESULT)
        assertEquals("tunnel.data", TunnelEnvelopeTypes.DATA)
        assertEquals("tunnel.close", TunnelEnvelopeTypes.CLOSE)
        assertEquals("tunnel.error", TunnelEnvelopeTypes.ERROR)
        assertEquals("tunnel.flow", TunnelEnvelopeTypes.FLOW)
    }

    @Test
    fun constants() {
        assertEquals(64 * 1024, TunnelConstants.INITIAL_CREDIT)
        assertEquals(60_000L, TunnelConstants.STREAM_IDLE_TIMEOUT_MS)
        assertEquals(300_000L, TunnelConstants.TUNNEL_IDLE_TIMEOUT_MS)
        assertEquals(48 * 1024, TunnelChunker.MAX_CHUNK_SIZE)
    }

    @Test
    fun adbPort() {
        assertEquals(5555, TunnelAllowlist.ADB_PORT)
    }
}
