package com.edgelink.core

interface HandshakeCrypto {
    fun randomBytes(size: Int): ByteArray
    fun signIdentity(message: ByteArray, identity: LocalIdentity): ByteArray
    fun verifyIdentity(signature: ByteArray, message: ByteArray, publicKey: ByteArray): Boolean
    fun x25519KeyPair(): X25519KeyPair
    fun x25519SharedSecret(secretKey: ByteArray, publicKey: ByteArray): ByteArray
}

data class InitiatorHandshakeState(
    val clientPeer: HandshakePeer,
    val ephemeralSecretKey: ByteArray,
    val helloSignature: ByteArray
)

data class ResponderHandshakeState(
    val clientPeer: HandshakePeer,
    val hostPeer: HandshakePeer,
    val ephemeralSecretKey: ByteArray,
    val helloSignature: ByteArray,
    val ackSignature: ByteArray
)

data class InitiatorHandshakeStart(
    val state: InitiatorHandshakeState,
    val hello: ByteArray
)

data class ResponderHandshakeAck(
    val state: ResponderHandshakeState,
    val ack: ByteArray
)

data class EstablishedHandshake(
    val transcript: HandshakeTranscript,
    val keys: SecureChannelKeys,
    val channel: SecureChannel
)

object HandshakeSession {
    fun startInitiator(
        identity: LocalIdentity,
        crypto: HandshakeCrypto,
        ephemeralKeyPair: X25519KeyPair = crypto.x25519KeyPair(),
        nonce: ByteArray = crypto.randomBytes(32)
    ): InitiatorHandshakeStart {
        require(nonce.size == 32) { "Handshake nonce must be 32 bytes." }
        val clientPeer = HandshakePeer(identity.deviceId, ephemeralKeyPair.publicKey, nonce)
        val helloSignature = crypto.signIdentity(HandshakeEncoding.helloInput(clientPeer), identity)
        return InitiatorHandshakeStart(
            state = InitiatorHandshakeState(clientPeer, ephemeralKeyPair.secretKey, helloSignature),
            hello = HandshakeWire.encodeHello(clientPeer, helloSignature)
        )
    }

    fun acceptHello(
        hello: ByteArray,
        identity: LocalIdentity,
        pinnedClientPublicKey: ByteArray,
        crypto: HandshakeCrypto,
        ephemeralKeyPair: X25519KeyPair = crypto.x25519KeyPair(),
        nonce: ByteArray = crypto.randomBytes(32)
    ): ResponderHandshakeAck {
        require(nonce.size == 32) { "Handshake nonce must be 32 bytes." }
        val decodedHello = HandshakeWire.decodeSignedPeer(hello)
        require(decodedHello.t == HandshakeTypes.HELLO) { "Expected hs.hello." }
        val clientPeer = decodedHello.b.peer()
        val helloSignature = decodedHello.b.signature()
        require(
            crypto.verifyIdentity(
                signature = helloSignature,
                message = HandshakeEncoding.helloInput(clientPeer),
                publicKey = pinnedClientPublicKey
            )
        ) { "Invalid hs.hello signature." }

        val hostPeer = HandshakePeer(identity.deviceId, ephemeralKeyPair.publicKey, nonce)
        val ackSignature = crypto.signIdentity(HandshakeEncoding.ackInput(clientPeer, hostPeer), identity)
        return ResponderHandshakeAck(
            state = ResponderHandshakeState(
                clientPeer = clientPeer,
                hostPeer = hostPeer,
                ephemeralSecretKey = ephemeralKeyPair.secretKey,
                helloSignature = helloSignature,
                ackSignature = ackSignature
            ),
            ack = HandshakeWire.encodeAck(hostPeer, ackSignature)
        )
    }

    fun finishInitiator(
        state: InitiatorHandshakeState,
        ack: ByteArray,
        identity: LocalIdentity,
        pinnedHostPublicKey: ByteArray,
        crypto: HandshakeCrypto
    ): Pair<ByteArray, EstablishedHandshake> {
        val decodedAck = HandshakeWire.decodeSignedPeer(ack)
        require(decodedAck.t == HandshakeTypes.ACK) { "Expected hs.ack." }
        val hostPeer = decodedAck.b.peer()
        val ackSignature = decodedAck.b.signature()
        require(
            crypto.verifyIdentity(
                signature = ackSignature,
                message = HandshakeEncoding.ackInput(state.clientPeer, hostPeer),
                publicKey = pinnedHostPublicKey
            )
        ) { "Invalid hs.ack signature." }

        val confirmInput = HandshakeEncoding.confirmInput(
            clientPeer = state.clientPeer,
            hostPeer = hostPeer,
            helloSignature = state.helloSignature,
            ackSignature = ackSignature
        )
        val confirmSignature = crypto.signIdentity(confirmInput, identity)
        val transcript = HandshakeTranscript(
            clientPeer = state.clientPeer,
            hostPeer = hostPeer,
            helloSignature = state.helloSignature,
            ackSignature = ackSignature,
            confirmSignature = confirmSignature
        )
        val sharedSecret = crypto.x25519SharedSecret(state.ephemeralSecretKey, hostPeer.ephemeralPublicKey)
        val keys = HandshakeKeySchedule.deriveKeys(sharedSecret, transcript.transcriptHash)
        return HandshakeWire.encodeConfirm(confirmSignature) to EstablishedHandshake(
            transcript = transcript,
            keys = keys,
            channel = SecureChannel(keys, SecureChannelRole.INITIATOR)
        )
    }

    fun finishResponder(
        state: ResponderHandshakeState,
        confirm: ByteArray,
        pinnedClientPublicKey: ByteArray,
        crypto: HandshakeCrypto
    ): EstablishedHandshake {
        val decodedConfirm = HandshakeWire.decodeConfirm(confirm)
        require(decodedConfirm.t == HandshakeTypes.CONFIRM) { "Expected hs.confirm." }
        val confirmSignature = decodedConfirm.b.signature()
        require(
            crypto.verifyIdentity(
                signature = confirmSignature,
                message = HandshakeEncoding.confirmInput(
                    clientPeer = state.clientPeer,
                    hostPeer = state.hostPeer,
                    helloSignature = state.helloSignature,
                    ackSignature = state.ackSignature
                ),
                publicKey = pinnedClientPublicKey
            )
        ) { "Invalid hs.confirm signature." }

        val transcript = HandshakeTranscript(
            clientPeer = state.clientPeer,
            hostPeer = state.hostPeer,
            helloSignature = state.helloSignature,
            ackSignature = state.ackSignature,
            confirmSignature = confirmSignature
        )
        val sharedSecret = crypto.x25519SharedSecret(state.ephemeralSecretKey, state.clientPeer.ephemeralPublicKey)
        val keys = HandshakeKeySchedule.deriveKeys(sharedSecret, transcript.transcriptHash)
        return EstablishedHandshake(
            transcript = transcript,
            keys = keys,
            channel = SecureChannel(keys, SecureChannelRole.RESPONDER)
        )
    }
}
