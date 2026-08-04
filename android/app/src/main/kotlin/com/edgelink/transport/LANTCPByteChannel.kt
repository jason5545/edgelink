package com.edgelink.transport

import com.edgelink.app.EdgeLinkLog
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.DataInputStream
import java.io.EOFException
import java.net.Socket

internal class LANTCPByteChannel(
    private val socket: Socket,
    private val host: String,
    private val port: Int
) : ByteChannel {
    private val input = DataInputStream(socket.getInputStream())
    private val output = socket.getOutputStream()
    private val sendLock = Any()

    override suspend fun send(bytes: ByteArray) = withContext(Dispatchers.IO) {
        synchronized(sendLock) {
            LanFraming.writeFrame(output, bytes)
        }
    }

    override suspend fun receive(): ByteArray? = withContext(Dispatchers.IO) {
        try {
            val length = input.readInt()
            if (length < 0 || length > MAX_FRAME_BYTES) {
                EdgeLinkLog.warn("lan.android.frame_invalid host=$host port=$port length=$length")
                close()
                return@withContext null
            }
            val payload = ByteArray(length)
            input.readFully(payload)
            payload
        } catch (error: EOFException) {
            null
        } catch (error: Throwable) {
            EdgeLinkLog.info("lan.android.receive_ended host=$host port=$port error=${error.javaClass.simpleName}")
            null
        }
    }

    override fun close() {
        runCatching { socket.close() }
    }

    private companion object {
        const val MAX_FRAME_BYTES = 4 * 1024 * 1024
    }
}
