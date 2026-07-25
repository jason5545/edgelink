package com.edgelink.core

import java.security.MessageDigest
import java.util.Base64

object ClipboardBlobTransfer {
    const val MAX_CHUNK_SIZE = 32 * 1024
    const val MAX_BLOB_BYTES = 8 * 1024 * 1024
    const val RECEIVE_TIMEOUT_MS = 10_000L

    data class OutgoingChunk(
        val seq: Int,
        val fin: Boolean,
        val payloadBase64: String
    )

    fun sha256Hex(data: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(data).joinToString("") { "%02x".format(it) }

    fun chunk(data: ByteArray): List<OutgoingChunk> {
        if (data.isEmpty()) {
            return listOf(OutgoingChunk(seq = 0, fin = true, payloadBase64 = ""))
        }
        val chunks = mutableListOf<OutgoingChunk>()
        var offset = 0
        var seq = 0
        while (offset < data.size) {
            val end = minOf(offset + MAX_CHUNK_SIZE, data.size)
            val slice = data.copyOfRange(offset, end)
            chunks.add(
                OutgoingChunk(
                    seq = seq,
                    fin = end >= data.size,
                    payloadBase64 = Base64.getEncoder().encodeToString(slice)
                )
            )
            offset = end
            seq += 1
        }
        return chunks
    }

    fun payloadFromBase64(base64: String): ByteArray? =
        runCatching { Base64.getDecoder().decode(base64) }.getOrNull()
}

class ClipboardBlobReassembler {
    data class Result(
        val data: ByteArray,
        val mime: String?
    ) {
        override fun equals(other: Any?): Boolean =
            other is Result && data.contentEquals(other.data) && mime == other.mime

        override fun hashCode(): Int = 31 * data.contentHashCode() + (mime?.hashCode() ?: 0)
    }

    sealed interface AppendOutcome {
        data object Pending : AppendOutcome
        data class Complete(val result: Result) : AppendOutcome
        data object NotAvailable : AppendOutcome
        data object HashMismatch : AppendOutcome
        data object InvalidChunk : AppendOutcome
    }

    private class Buffer {
        val chunks = mutableMapOf<Int, ByteArray>()
        var nextSeq = 0
        var expectedHash: String? = null
        var mime: String? = null
    }

    private var buffer: Buffer? = null

    fun reset() {
        buffer = null
    }

    fun append(
        id: String,
        seq: Int,
        fin: Boolean,
        hash: String?,
        mime: String?,
        payloadBase64: String
    ): AppendOutcome {
        if (fin && seq == 0 && payloadBase64.isEmpty()) {
            buffer = null
            return AppendOutcome.NotAvailable
        }
        val data = ClipboardBlobTransfer.payloadFromBase64(payloadBase64)
            ?: return AppendOutcome.InvalidChunk
        val current = buffer ?: Buffer().also { buffer = it }
        if (seq == 0) {
            current.expectedHash = hash
            current.mime = mime
        }
        if (seq == current.nextSeq) {
            current.chunks[seq] = data
            current.nextSeq += 1
            while (current.chunks.containsKey(current.nextSeq)) {
                current.nextSeq += 1
            }
        } else {
            current.chunks[seq] = data
        }

        if (!fin) return AppendOutcome.Pending
        val parts = mutableListOf<ByteArray>()
        var total = 0
        for (index in 0 until current.nextSeq) {
            val part = current.chunks[index] ?: run {
                buffer = null
                return AppendOutcome.InvalidChunk
            }
            parts.add(part)
            total += part.size
        }
        buffer = null
        val merged = ByteArray(total)
        var position = 0
        for (part in parts) {
            part.copyInto(merged, position)
            position += part.size
        }
        val expected = current.expectedHash
        if (expected != null && ClipboardBlobTransfer.sha256Hex(merged) != expected) {
            return AppendOutcome.HashMismatch
        }
        return AppendOutcome.Complete(Result(data = merged, mime = current.mime))
    }
}
