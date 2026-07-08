package com.edgelink.transport

import com.edgelink.app.EdgeLinkLog
import com.edgelink.core.EstablishedHandshake
import com.edgelink.core.HandshakeSession
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

    suspend fun connect() {
        EdgeLinkLog.info("hs.android.start clientId=${identity.deviceId} hostId=${peer.deviceId}")
        val start = HandshakeSession.startInitiator(identity = identity, crypto = crypto)
        EdgeLinkLog.info("hs.android.hello_out bytes=${start.hello.size}")
        channel.send(start.hello)

        val ack = channel.receive() ?: error("Relay closed before hs.ack.")
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
        EdgeLinkLog.info("hs.android.established clientId=${identity.deviceId} hostId=${peer.deviceId}")
    }

    suspend fun sendPlaintext(plaintext: ByteArray) {
        val frame = secureMutex.withLock {
            val session = established ?: error("Secure session is not established.")
            session.channel.seal(plaintext)
        }
        EdgeLinkLog.info("secure.android.frame_out plaintext=${plaintext.size} frame=${frame.size}")
        channel.send(frame)
    }

    suspend fun receiveLoop(handler: suspend (ByteArray) -> ByteArray?) {
        while (true) {
            val frame = channel.receive() ?: return
            val plaintext = secureMutex.withLock {
                val session = established ?: error("Secure session is not established.")
                session.channel.open(frame)
            }
            EdgeLinkLog.info("secure.android.frame_in frame=${frame.size} plaintext=${plaintext.size}")
            val response = handler(plaintext)
            if (response != null) {
                sendPlaintext(response)
            }
        }
    }

    fun close() {
        channel.close()
    }
}
