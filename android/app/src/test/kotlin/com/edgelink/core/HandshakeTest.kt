package com.edgelink.core

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test
import java.util.Base64

class HandshakeTest {
    @Test
    fun handshakeVectorV1() {
        val clientPeer = HandshakePeer(
            deviceId = "137245816",
            ephemeralPublicKey = b64("YFpyXSpK3+6xop4X7dYhwbdZPujNvESsbEq24vgF0jw="),
            nonce = b64("4OHi4+Tl5ufo6err7O3u7/Dx8vP09fb3+Pn6+/z9/v8=")
        )
        val hostPeer = HandshakePeer(
            deviceId = "949758990",
            ephemeralPublicKey = b64("ST6C/HRGSlkmiBdiPSBTxeuOLMSpiLT+4XnsawENUx0="),
            nonce = b64("wMHCw8TFxsfIycrLzM3Oz9DR0tPU1dbX2Nna29zd3t8=")
        )

        assertEquals(
            "00093133373234353831360020605a725d2a4adfeeb1a29e17edd621c1b7593ee8cdbc44ac6c4ab6e2f805d23c0020e0e1e2e3e4e5e6e7e8e9eaebecedeeeff0f1f2f3f4f5f6f7f8f9fafbfcfdfeff",
            HandshakeEncoding.peerRecord(clientPeer).hex()
        )
        assertEquals(
            "00093934393735383939300020493e82fc74464a59268817623d2053c5eb8e2cc4a988b4fee179ec6b010d531d0020c0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedf",
            HandshakeEncoding.peerRecord(hostPeer).hex()
        )

        val helloSignature = b64("m/A8bxR+o8B8VqjoTHUnvYuFOP9+RDWNgDbBjthMiqbLYSWa5up+LEoRn45yaZcQOTEOr/kI+ri1EaHv0Tl3Bg==")
        val ackSignature = b64("3LH5/RUiKuMfwkfWVC7L/xHTSsuN/AbSrmr+hycD+1slWwdo5+y7I2t4whL8dynqImE2c6LfD37ibuD/gogVAw==")
        val confirmSignature = b64("1zz4Id0wNY0Du6sQ7RTlfcrNuycMB8Z+VS4HIcWaIVED4MNiI/OKebsQkH9+XPJcTr+x5m2ZW5Gt7AdRCG15Cg==")
        val transcript = HandshakeTranscript(clientPeer, hostPeer, helloSignature, ackSignature, confirmSignature)

        assertEquals(
            "d3e644a6176792c74704762e7afb801ca60b2780836a147c4378ee511daffc40",
            transcript.transcriptHash.hex()
        )

        val keys = HandshakeKeySchedule.deriveKeys(
            sharedSecret = hex("c6dea8dd115ef27b7e0953539b2b19e59b7abf3ffd57985ec76de86ec31d1b42"),
            transcriptHash = transcript.transcriptHash
        )
        assertEquals("84f1d1b229d59758326024a9124c2ad39e5d9ae2adf0a0a66be0808b028e73b7", keys.initiatorToResponder.hex())
        assertEquals("b3101fc48f69c8c67deee3492347da54870971942b1bf5cb65753ff5d93f6fb2", keys.responderToInitiator.hex())
    }

    @Test
    fun secureFrameVectorV1() {
        val key = hex("84f1d1b229d59758326024a9124c2ad39e5d9ae2adf0a0a66be0808b028e73b7")
        val plaintext = """{"t":"status.ping","b":{}}""".encodeToByteArray()
        val frame = SecureFrame.seal(
            plaintext = plaintext,
            key = key,
            direction = SecureChannelDirection.INITIATOR_TO_RESPONDER,
            counter = 0
        )

        assertEquals(
            "0000002a7f9dbb3859fc024e439d8e3c8e2d56f8b4670ae4066ac1b84db0887b466a60f2de30a3895e3b7b31b90d",
            frame.hex()
        )
        assertArrayEquals(
            plaintext,
            SecureFrame.open(frame, key, SecureChannelDirection.INITIATOR_TO_RESPONDER, 0)
        )
    }

    @Test
    fun secureChannelCountersAndDirections() {
        val keys = SecureChannelKeys(
            initiatorToResponder = hex("84f1d1b229d59758326024a9124c2ad39e5d9ae2adf0a0a66be0808b028e73b7"),
            responderToInitiator = hex("b3101fc48f69c8c67deee3492347da54870971942b1bf5cb65753ff5d93f6fb2")
        )
        val initiator = SecureChannel(keys, SecureChannelRole.INITIATOR)
        val responder = SecureChannel(keys, SecureChannelRole.RESPONDER)
        val ping = """{"t":"status.ping","b":{}}""".encodeToByteArray()
        val pong = """{"t":"status.pong","b":{}}""".encodeToByteArray()

        assertArrayEquals(ping, responder.open(initiator.seal(ping)))
        assertArrayEquals(pong, initiator.open(responder.seal(pong)))
    }

    @Test
    fun handshakeWireRoundTrip() {
        val peer = HandshakePeer(
            deviceId = "137245816",
            ephemeralPublicKey = b64("YFpyXSpK3+6xop4X7dYhwbdZPujNvESsbEq24vgF0jw="),
            nonce = b64("4OHi4+Tl5ufo6err7O3u7/Dx8vP09fb3+Pn6+/z9/v8=")
        )
        val signature = b64("m/A8bxR+o8B8VqjoTHUnvYuFOP9+RDWNgDbBjthMiqbLYSWa5up+LEoRn45yaZcQOTEOr/kI+ri1EaHv0Tl3Bg==")
        val decodedHello = HandshakeWire.decodeSignedPeer(HandshakeWire.encodeHello(peer, signature))

        assertEquals(HandshakeTypes.HELLO, decodedHello.t)
        assertEquals(peer.deviceId, decodedHello.b.peer().deviceId)
        assertArrayEquals(peer.ephemeralPublicKey, decodedHello.b.peer().ephemeralPublicKey)
        assertArrayEquals(peer.nonce, decodedHello.b.peer().nonce)
        assertArrayEquals(signature, decodedHello.b.signature())

        val decodedConfirm = HandshakeWire.decodeConfirm(HandshakeWire.encodeConfirm(signature))
        assertEquals(HandshakeTypes.CONFIRM, decodedConfirm.t)
        assertArrayEquals(signature, decodedConfirm.b.signature())
    }

    @Test
    fun handshakeSessionVectorFlow() {
        val crypto = VectorHandshakeCrypto()
        val clientIdentity = LocalIdentity(
            deviceId = "137245816",
            name = "Pixel 9",
            publicKey = b64("Kay64UG8yvCyLhqU000LxzYeUm0L/hLIl5S8kyKWbdc="),
            privateKeySeed = hex("202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f")
        )
        val hostIdentity = LocalIdentity(
            deviceId = "949758990",
            name = "Jason's Mac",
            publicKey = b64("A6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg="),
            privateKeySeed = hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
        )
        val clientEphemeral = X25519KeyPair(
            publicKey = b64("YFpyXSpK3+6xop4X7dYhwbdZPujNvESsbEq24vgF0jw="),
            secretKey = hex("a0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebf")
        )
        val hostEphemeral = X25519KeyPair(
            publicKey = b64("ST6C/HRGSlkmiBdiPSBTxeuOLMSpiLT+4XnsawENUx0="),
            secretKey = hex("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f")
        )

        val start = HandshakeSession.startInitiator(
            identity = clientIdentity,
            crypto = crypto,
            ephemeralKeyPair = clientEphemeral,
            nonce = b64("4OHi4+Tl5ufo6err7O3u7/Dx8vP09fb3+Pn6+/z9/v8=")
        )
        val ack = HandshakeSession.acceptHello(
            hello = start.hello,
            identity = hostIdentity,
            pinnedClientPublicKey = clientIdentity.publicKey,
            crypto = crypto,
            ephemeralKeyPair = hostEphemeral,
            nonce = b64("wMHCw8TFxsfIycrLzM3Oz9DR0tPU1dbX2Nna29zd3t8=")
        )
        val (confirm, clientEstablished) = HandshakeSession.finishInitiator(
            state = start.state,
            ack = ack.ack,
            identity = clientIdentity,
            pinnedHostPublicKey = hostIdentity.publicKey,
            crypto = crypto
        )
        val hostEstablished = HandshakeSession.finishResponder(
            state = ack.state,
            confirm = confirm,
            pinnedClientPublicKey = clientIdentity.publicKey,
            crypto = crypto
        )

        assertEquals("d3e644a6176792c74704762e7afb801ca60b2780836a147c4378ee511daffc40", clientEstablished.transcript.transcriptHash.hex())
        assertEquals(clientEstablished.keys.initiatorToResponder.hex(), hostEstablished.keys.initiatorToResponder.hex())
        assertEquals(clientEstablished.keys.responderToInitiator.hex(), hostEstablished.keys.responderToInitiator.hex())

        val ping = EnvelopeCodec.encode(EnvelopeTypes.STATUS_PING, EmptyBody)
        assertArrayEquals(ping, hostEstablished.channel.open(clientEstablished.channel.seal(ping)))
    }

    private fun b64(value: String): ByteArray = Base64.getDecoder().decode(value)

    private fun hex(value: String): ByteArray {
        require(value.length % 2 == 0)
        return value.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
    }

    private fun ByteArray.hex(): String = joinToString("") { "%02x".format(it.toInt() and 0xff) }

    private class VectorHandshakeCrypto : HandshakeCrypto {
        private val helloInput = "456467654c696e6b2068732e76312068656c6c6f0a00093133373234353831360020605a725d2a4adfeeb1a29e17edd621c1b7593ee8cdbc44ac6c4ab6e2f805d23c0020e0e1e2e3e4e5e6e7e8e9eaebecedeeeff0f1f2f3f4f5f6f7f8f9fafbfcfdfeff"
        private val ackInput = "456467654c696e6b2068732e76312061636b0a00093133373234353831360020605a725d2a4adfeeb1a29e17edd621c1b7593ee8cdbc44ac6c4ab6e2f805d23c0020e0e1e2e3e4e5e6e7e8e9eaebecedeeeff0f1f2f3f4f5f6f7f8f9fafbfcfdfeff00093934393735383939300020493e82fc74464a59268817623d2053c5eb8e2cc4a988b4fee179ec6b010d531d0020c0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedf"
        private val confirmInput = "456467654c696e6b2068732e763120636f6e6669726d0a00093133373234353831360020605a725d2a4adfeeb1a29e17edd621c1b7593ee8cdbc44ac6c4ab6e2f805d23c0020e0e1e2e3e4e5e6e7e8e9eaebecedeeeff0f1f2f3f4f5f6f7f8f9fafbfcfdfeff00093934393735383939300020493e82fc74464a59268817623d2053c5eb8e2cc4a988b4fee179ec6b010d531d0020c0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedf9bf03c6f147ea3c07c56a8e84c7527bd8b8538ff7e44358d8036c18ed84c8aa6cb61259ae6ea7e2c4a119f8e7269971039310eaff908fab8b511a1efd1397706dcb1f9fd15222ae31fc247d6542ecbff11d34acb8dfc06d2ae6afe872703fb5b255b0768e7ecbb236b78c212fc7729ea22613673a2df0f7ee26ee0ff82881503"
        private val signatures = mapOf(
            helloInput to Base64.getDecoder().decode("m/A8bxR+o8B8VqjoTHUnvYuFOP9+RDWNgDbBjthMiqbLYSWa5up+LEoRn45yaZcQOTEOr/kI+ri1EaHv0Tl3Bg=="),
            ackInput to Base64.getDecoder().decode("3LH5/RUiKuMfwkfWVC7L/xHTSsuN/AbSrmr+hycD+1slWwdo5+y7I2t4whL8dynqImE2c6LfD37ibuD/gogVAw=="),
            confirmInput to Base64.getDecoder().decode("1zz4Id0wNY0Du6sQ7RTlfcrNuycMB8Z+VS4HIcWaIVED4MNiI/OKebsQkH9+XPJcTr+x5m2ZW5Gt7AdRCG15Cg==")
        )

        override fun randomBytes(size: Int): ByteArray = error("Vector test passes explicit nonces.")

        override fun signIdentity(message: ByteArray, identity: LocalIdentity): ByteArray =
            signatures.getValue(message.hex())

        override fun verifyIdentity(signature: ByteArray, message: ByteArray, publicKey: ByteArray): Boolean =
            signatures[message.hex()]?.contentEquals(signature) == true

        override fun x25519KeyPair(): X25519KeyPair = error("Vector test passes explicit ephemeral keys.")

        override fun x25519SharedSecret(secretKey: ByteArray, publicKey: ByteArray): ByteArray =
            hex("c6dea8dd115ef27b7e0953539b2b19e59b7abf3ffd57985ec76de86ec31d1b42")

        private fun hex(value: String): ByteArray {
            require(value.length % 2 == 0)
            return value.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
        }

        private fun ByteArray.hex(): String = joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }
}
