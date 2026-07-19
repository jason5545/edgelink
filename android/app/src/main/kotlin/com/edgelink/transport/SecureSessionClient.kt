package com.edgelink.transport

import com.edgelink.app.EdgeLinkLog
import com.edgelink.core.EstablishedHandshake
import com.edgelink.core.HandshakeSession
import com.edgelink.core.HandshakeTypes
import com.edgelink.core.HandshakeWire
import com.edgelink.core.LocalIdentity
import com.edgelink.core.PinnedPeer
import com.edgelink.core.SodiumHandshakeCrypto
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

class SecureSessionClient(
    private val channel: ByteChannel,
    private val identity: LocalIdentity,
    private val peer: PinnedPeer,
    private val crypto: SodiumHandshakeCrypto = SodiumHandshakeCrypto()
) {
    private val secureMutex = Mutex()
    private var established: EstablishedHandshake? = null
    @Volatile
    private var lastInboundElapsedMs = 0L
    private var framesSent = 0L
    private var framesReceived = 0L

    suspend fun connect() {
        EdgeLinkLog.info("hs.android.start clientId=${identity.deviceId} hostId=${peer.deviceId}")
        val start = HandshakeSession.startInitiator(identity = identity, crypto = crypto)
        EdgeLinkLog.info("hs.android.hello_out bytes=${start.hello.size}")
        channel.send(start.hello)

        val ack = receiveHandshakeAck()
        EdgeLinkLog.info("hs.android.ack_in bytes=${ack.size}")
        val (confirm, session) = HandshakeSession.finishInitiator(
            state = start.state,
            ack = ack,
            identity = identity,
            pinnedHostPublicKey = peer.publicKey,
            crypto = crypto
        )
        EdgeLinkLog.info("hs.android.confirm_out bytes=${confirm.size}")
        channel.send(confirm)
        established = session
        lastInboundElapsedMs = monotonicMilliseconds()
        EdgeLinkLog.info("hs.android.established clientId=${identity.deviceId} hostId=${peer.deviceId}")
    }

    private suspend fun receiveHandshakeAck(): ByteArray {
        while (true) {
            val frame = channel.receive() ?: error("Relay closed before hs.ack.")
            val isAck = runCatching {
                HandshakeWire.decodeSignedPeer(frame).t == HandshakeTypes.ACK
            }.getOrDefault(false)
            if (isAck) {
                return frame
            }
            EdgeLinkLog.warn("hs.android.stale_frame_ignored bytes=${frame.size}")
        }
    }

    suspend fun sendPlaintext(plaintext: ByteArray) {
        secureMutex.withLock {
            val session = established ?: error("Secure session is not established.")
            val frame = session.channel.seal(plaintext)
            framesSent += 1
            if (framesSent <= 3 || framesSent % 100L == 0L) {
                EdgeLinkLog.info("secure.android.frame_out count=$framesSent plaintext=${plaintext.size} frame=${frame.size}")
            }
            channel.send(frame)
        }
    }

    suspend fun receiveLoop(handler: suspend (ByteArray) -> ByteArray?) {
        while (true) {
            val frame = channel.receive() ?: return
            val plaintext = secureMutex.withLock {
                val session = established ?: error("Secure session is not established.")
                session.channel.open(frame)
            }
            lastInboundElapsedMs = monotonicMilliseconds()
            framesReceived += 1
            if (framesReceived <= 3 || framesReceived % 100L == 0L) {
                EdgeLinkLog.info("secure.android.frame_in count=$framesReceived frame=${frame.size} plaintext=${plaintext.size}")
            }
            val response = handler(plaintext)
            if (response != null) {
                sendPlaintext(response)
            }
        }
    }

    fun inboundIdleMilliseconds(): Long {
        val lastInbound = lastInboundElapsedMs
        return if (lastInbound <= 0L) Long.MAX_VALUE else {
            (monotonicMilliseconds() - lastInbound).coerceAtLeast(0L)
        }
    }

    fun close() {
        channel.close()
    }

    private fun monotonicMilliseconds(): Long = System.nanoTime() / 1_000_000L
}
