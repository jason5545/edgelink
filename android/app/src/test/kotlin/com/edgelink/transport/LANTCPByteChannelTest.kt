package com.edgelink.transport

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.io.DataInputStream
import java.net.ServerSocket
import java.net.Socket

class LANTCPByteChannelTest {
    private fun loopbackChannel(block: (LANTCPByteChannel, Socket) -> Unit) {
        ServerSocket(0).use { server ->
            val client = Socket("127.0.0.1", server.localPort)
            val peer = server.accept()
            try {
                block(LANTCPByteChannel(client, "127.0.0.1", server.localPort), peer)
            } finally {
                runCatching { client.close() }
                runCatching { peer.close() }
            }
        }
    }

    @Test
    fun sendWritesLengthHeaderAndFullPayloadOnTheWire() = loopbackChannel { channel, peer ->
        val payload = ByteArray(252) { (it * 7 % 251).toByte() }

        runBlocking { channel.send(payload) }

        val reader = DataInputStream(peer.getInputStream())
        val length = reader.readInt()
        val received = ByteArray(length)
        reader.readFully(received)
        assertArrayEquals(payload, received)
    }

    @Test
    fun sendEmptyFrameWritesZeroLengthHeader() = loopbackChannel { channel, peer ->
        runBlocking { channel.send(ByteArray(0)) }

        val reader = DataInputStream(peer.getInputStream())
        org.junit.Assert.assertEquals(0, reader.readInt())
    }

    @Test
    fun receiveReadsFrameWrittenByPeer() = loopbackChannel { channel, peer ->
        val payload = byteArrayOf(1, 2, 3, 4, 5)
        LanFraming.writeFrame(peer.getOutputStream(), payload)

        val received = runBlocking { channel.receive() }

        assertArrayEquals(payload, received)
    }

    @Test
    fun receiveReturnsNullWhenPeerCloses() = loopbackChannel { channel, peer ->
        peer.close()

        assertNull(runBlocking { channel.receive() })
    }
}
