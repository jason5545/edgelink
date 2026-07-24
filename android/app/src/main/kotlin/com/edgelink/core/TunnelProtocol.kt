package com.edgelink.core

import kotlinx.serialization.Serializable
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi

// MARK: - EdgeLink TCP Tunnel Protocol (Route b)

object TunnelEnvelopeTypes {
    const val OPEN = "tunnel.open"
    const val OPEN_RESULT = "tunnel.open.result"
    const val DATA = "tunnel.data"
    const val CLOSE = "tunnel.close"
    const val ERROR = "tunnel.error"
    const val FLOW = "tunnel.flow"
}

@Serializable
enum class TunnelDirection {
    local, remote
}

@Serializable
enum class TunnelErrorCode {
    target_refused,
    target_timeout,
    not_allowed,
    tunnel_not_found,
    stream_not_found,
    flow_violation,
    internal_error
}

@Serializable
data class TunnelOpenBody(
    val tunnelId: String,
    val direction: TunnelDirection,
    val targetHost: String,
    val targetPort: Int,
    val label: String? = null
)

@Serializable
data class TunnelOpenResultBody(
    val tunnelId: String,
    val ok: Boolean,
    val error: String? = null,
    val listenPort: Int? = null
)

@Serializable
data class TunnelDataBody(
    val tunnelId: String,
    val streamId: Int,
    val seq: Int,
    val payload: String,
    val fin: Boolean = false
)

@Serializable
data class TunnelCloseBody(
    val tunnelId: String,
    val streamId: Int,
    val fin: Boolean = true,
    val reset: Boolean = false
)

@Serializable
data class TunnelErrorBody(
    val tunnelId: String,
    val streamId: Int? = null,
    val code: TunnelErrorCode,
    val message: String? = null
)

@Serializable
data class TunnelFlowBody(
    val tunnelId: String,
    val streamId: Int,
    val credit: Int
)

// MARK: - Chunking

object TunnelChunker {
    const val MAX_CHUNK_SIZE = 32 * 1024

    data class Chunk(val seq: Int, val data: ByteArray, val isLast: Boolean) {
        override fun equals(other: Any?): Boolean {
            if (this === other) return true
            if (other !is Chunk) return false
            return seq == other.seq && data.contentEquals(other.data) && isLast == other.isLast
        }

        override fun hashCode(): Int {
            var result = seq
            result = 31 * result + data.contentHashCode()
            result = 31 * result + isLast.hashCode()
            return result
        }
    }

    fun chunk(data: ByteArray): List<Chunk> {
        if (data.isEmpty()) return listOf(Chunk(0, ByteArray(0), true))
        val chunks = mutableListOf<Chunk>()
        var offset = 0
        var seq = 0
        while (offset < data.size) {
            val end = minOf(offset + MAX_CHUNK_SIZE, data.size)
            val slice = data.copyOfRange(offset, end)
            val isLast = end >= data.size
            chunks.add(Chunk(seq, slice, isLast))
            offset = end
            seq++
        }
        return chunks
    }

    @OptIn(ExperimentalEncodingApi::class)
    fun payloadBase64(data: ByteArray): String = Base64.encode(data)

    @OptIn(ExperimentalEncodingApi::class)
    fun payloadFromBase64(base64: String): ByteArray? = try {
        Base64.decode(base64)
    } catch (_: Exception) {
        null
    }
}

// MARK: - Reassembly

class TunnelReassembler {
    private data class StreamBuffer(
        val chunks: MutableMap<Int, ByteArray> = mutableMapOf(),
        var nextSeq: Int = 0,
        var complete: Boolean = false
    )

    private val buffers = mutableMapOf<String, StreamBuffer>()

    private fun key(tunnelId: String, streamId: Int) = "$tunnelId:$streamId"

    fun append(tunnelId: String, streamId: Int, seq: Int, data: ByteArray, fin: Boolean): ByteArray? {
        val k = key(tunnelId, streamId)
        val buffer = buffers.getOrPut(k) { StreamBuffer() }

        if (seq == buffer.nextSeq) {
            buffer.chunks[seq] = data
            buffer.nextSeq++
            while (buffer.chunks.containsKey(buffer.nextSeq)) {
                buffer.nextSeq++
            }
        } else {
            buffer.chunks[seq] = data
        }

        if (fin) {
            buffer.complete = true
        }

        if (buffer.complete || fin) {
            val result = java.io.ByteArrayOutputStream()
            for (i in 0 until buffer.nextSeq) {
                buffer.chunks[i]?.let { result.write(it) }
            }
            buffers.remove(k)
            return result.toByteArray()
        }

        return null
    }

    fun reset(tunnelId: String, streamId: Int) {
        buffers.remove(key(tunnelId, streamId))
    }

    fun resetAll() {
        buffers.clear()
    }
}

// MARK: - Allowlist

data class TunnelAllowlistRule(val host: String, val port: Int? = null)

class TunnelAllowlist(
    val rules: MutableList<TunnelAllowlistRule> = defaultRules.toMutableList()
) {
    companion object {
        const val ADB_PORT = 5555

        val defaultRules = listOf(
            TunnelAllowlistRule("127.0.0.1"),
            TunnelAllowlistRule("::1"),
            TunnelAllowlistRule("localhost")
        )
    }

    fun isAllowed(host: String, port: Int): Boolean {
        return rules.any { rule ->
            val hostMatch = rule.host == host ||
                (rule.host == "localhost" && (host == "127.0.0.1" || host == "::1"))
            hostMatch && (rule.port == null || rule.port == port)
        }
    }

    fun addRule(rule: TunnelAllowlistRule) {
        rules.add(rule)
    }
}

// MARK: - Constants

object TunnelConstants {
    const val INITIAL_CREDIT = 1024 * 1024
    const val STREAM_IDLE_TIMEOUT_MS = 60_000L
    const val TUNNEL_IDLE_TIMEOUT_MS = 300_000L
}
