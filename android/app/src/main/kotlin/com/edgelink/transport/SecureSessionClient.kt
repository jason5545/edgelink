package com.edgelink.transport

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
        val start = HandshakeSession.startInitiator(identity = identity, crypto = crypto)
        channel.send(start.hello)

        val ack = channel.receive() ?: error("Relay closed before hs.ack.")
        val (confirm, session) = HandshakeSession.finishInitiator(
            state = start.state,
            ack = ack,
            identity = identity,
            pinnedHostPublicKey = peer.publicKey,
            crypto = crypto
        )
        channel.send(confirm)
        established = session
    }

    suspend fun sendPlaintext(plaintext: ByteArray) {
        val frame = secureMutex.withLock {
            val session = established ?: error("Secure session is not established.")
            session.channel.seal(plaintext)
        }
        channel.send(frame)
    }

    suspend fun receiveLoop(handler: suspend (ByteArray) -> ByteArray?) {
        while (true) {
            val frame = channel.receive() ?: return
            val plaintext = secureMutex.withLock {
                val session = established ?: error("Secure session is not established.")
                session.channel.open(frame)
            }
            val response = handler(plaintext)
            if (response != null) {
                sendPlaintext(response)
            }
        }
    }
}
