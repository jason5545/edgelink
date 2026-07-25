package com.edgelink.app

import com.edgelink.core.ClipboardBlobReassembler
import com.edgelink.core.ClipboardBlobTransfer
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ClipboardBlobTransferTest {

    @Test
    fun chunkRoundTrip() {
        val data = ByteArray(100_000) { (it % 251).toByte() }
        val chunks = ClipboardBlobTransfer.chunk(data)
        assertEquals(4, chunks.size)
        assertTrue(chunks.dropLast(1).all { !it.fin })
        assertTrue(chunks.last().fin)
        chunks.forEachIndexed { index, chunk -> assertEquals(index, chunk.seq) }

        val reassembler = ClipboardBlobReassembler()
        var outcome: ClipboardBlobReassembler.AppendOutcome =
            ClipboardBlobReassembler.AppendOutcome.Pending
        val hash = ClipboardBlobTransfer.sha256Hex(data)
        for (chunk in chunks) {
            outcome = reassembler.append(
                id = "id-1",
                seq = chunk.seq,
                fin = chunk.fin,
                hash = if (chunk.seq == 0) hash else null,
                mime = if (chunk.seq == 0) "image/png" else null,
                payloadBase64 = chunk.payloadBase64
            )
        }
        assertTrue(outcome is ClipboardBlobReassembler.AppendOutcome.Complete)
        val result = (outcome as ClipboardBlobReassembler.AppendOutcome.Complete).result
        assertArrayEquals(data, result.data)
        assertEquals("image/png", result.mime)
    }

    @Test
    fun singleChunkBlob() {
        val data = ByteArray(1_000) { 7 }
        val chunks = ClipboardBlobTransfer.chunk(data)
        assertEquals(1, chunks.size)
        assertTrue(chunks[0].fin)
    }

    @Test
    fun emptyChunkMeansNotAvailable() {
        val reassembler = ClipboardBlobReassembler()
        val outcome = reassembler.append(
            id = "id-1", seq = 0, fin = true, hash = null, mime = null, payloadBase64 = ""
        )
        assertTrue(outcome is ClipboardBlobReassembler.AppendOutcome.NotAvailable)
    }

    @Test
    fun hashMismatchDetected() {
        val data = ByteArray(2_000) { 3 }
        val chunk = ClipboardBlobTransfer.chunk(data).first()
        val reassembler = ClipboardBlobReassembler()
        val outcome = reassembler.append(
            id = "id-1",
            seq = 0,
            fin = true,
            hash = "0".repeat(64),
            mime = null,
            payloadBase64 = chunk.payloadBase64
        )
        assertTrue(outcome is ClipboardBlobReassembler.AppendOutcome.HashMismatch)
    }

    @Test
    fun outOfOrderChunksReassemble() {
        val data = ByteArray(70_000) { (it % 13).toByte() }
        val chunks = ClipboardBlobTransfer.chunk(data)
        assertEquals(3, chunks.size)
        val reassembler = ClipboardBlobReassembler()
        val hash = ClipboardBlobTransfer.sha256Hex(data)
        val order = listOf(chunks[1], chunks[0], chunks[2])
        var outcome: ClipboardBlobReassembler.AppendOutcome =
            ClipboardBlobReassembler.AppendOutcome.Pending
        for (chunk in order) {
            outcome = reassembler.append(
                id = "id-1",
                seq = chunk.seq,
                fin = chunk.fin,
                hash = if (chunk.seq == 0) hash else null,
                mime = null,
                payloadBase64 = chunk.payloadBase64
            )
        }
        assertTrue(outcome is ClipboardBlobReassembler.AppendOutcome.Complete)
        val result = (outcome as ClipboardBlobReassembler.AppendOutcome.Complete).result
        assertArrayEquals(data, result.data)
    }

    @Test
    fun invalidBase64Rejected() {
        val reassembler = ClipboardBlobReassembler()
        val outcome = reassembler.append(
            id = "id-1", seq = 0, fin = false, hash = null, mime = null, payloadBase64 = "!!!not-base64!!!"
        )
        assertTrue(outcome is ClipboardBlobReassembler.AppendOutcome.InvalidChunk)
    }
}
