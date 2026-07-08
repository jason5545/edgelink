import CryptoKit
import XCTest
@testable import EdgeLinkKit

final class HandshakeTests: XCTestCase {
    func testHandshakeVectorV1() throws {
        let clientPeer = HandshakePeer(
            deviceId: "137245816",
            ephemeralPublicKey: Data(base64Encoded: "YFpyXSpK3+6xop4X7dYhwbdZPujNvESsbEq24vgF0jw=")!,
            nonce: Data(base64Encoded: "4OHi4+Tl5ufo6err7O3u7/Dx8vP09fb3+Pn6+/z9/v8=")!
        )
        let hostPeer = HandshakePeer(
            deviceId: "949758990",
            ephemeralPublicKey: Data(base64Encoded: "ST6C/HRGSlkmiBdiPSBTxeuOLMSpiLT+4XnsawENUx0=")!,
            nonce: Data(base64Encoded: "wMHCw8TFxsfIycrLzM3Oz9DR0tPU1dbX2Nna29zd3t8=")!
        )

        XCTAssertEqual(HandshakeEncoding.peerRecord(clientPeer).hexString, "00093133373234353831360020605a725d2a4adfeeb1a29e17edd621c1b7593ee8cdbc44ac6c4ab6e2f805d23c0020e0e1e2e3e4e5e6e7e8e9eaebecedeeeff0f1f2f3f4f5f6f7f8f9fafbfcfdfeff")
        XCTAssertEqual(HandshakeEncoding.peerRecord(hostPeer).hexString, "00093934393735383939300020493e82fc74464a59268817623d2053c5eb8e2cc4a988b4fee179ec6b010d531d0020c0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedf")

        let helloSignature = Data(base64Encoded: "m/A8bxR+o8B8VqjoTHUnvYuFOP9+RDWNgDbBjthMiqbLYSWa5up+LEoRn45yaZcQOTEOr/kI+ri1EaHv0Tl3Bg==")!
        let ackSignature = Data(base64Encoded: "3LH5/RUiKuMfwkfWVC7L/xHTSsuN/AbSrmr+hycD+1slWwdo5+y7I2t4whL8dynqImE2c6LfD37ibuD/gogVAw==")!
        let confirmSignature = Data(base64Encoded: "1zz4Id0wNY0Du6sQ7RTlfcrNuycMB8Z+VS4HIcWaIVED4MNiI/OKebsQkH9+XPJcTr+x5m2ZW5Gt7AdRCG15Cg==")!

        XCTAssertEqual(HandshakeEncoding.helloInput(clientPeer: clientPeer).hexString, "456467654c696e6b2068732e76312068656c6c6f0a00093133373234353831360020605a725d2a4adfeeb1a29e17edd621c1b7593ee8cdbc44ac6c4ab6e2f805d23c0020e0e1e2e3e4e5e6e7e8e9eaebecedeeeff0f1f2f3f4f5f6f7f8f9fafbfcfdfeff")
        XCTAssertEqual(HandshakeEncoding.ackInput(clientPeer: clientPeer, hostPeer: hostPeer).hexString, "456467654c696e6b2068732e76312061636b0a00093133373234353831360020605a725d2a4adfeeb1a29e17edd621c1b7593ee8cdbc44ac6c4ab6e2f805d23c0020e0e1e2e3e4e5e6e7e8e9eaebecedeeeff0f1f2f3f4f5f6f7f8f9fafbfcfdfeff00093934393735383939300020493e82fc74464a59268817623d2053c5eb8e2cc4a988b4fee179ec6b010d531d0020c0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedf")
        XCTAssertEqual(HandshakeEncoding.confirmInput(clientPeer: clientPeer, hostPeer: hostPeer, helloSignature: helloSignature, ackSignature: ackSignature).hexString, "456467654c696e6b2068732e763120636f6e6669726d0a00093133373234353831360020605a725d2a4adfeeb1a29e17edd621c1b7593ee8cdbc44ac6c4ab6e2f805d23c0020e0e1e2e3e4e5e6e7e8e9eaebecedeeeff0f1f2f3f4f5f6f7f8f9fafbfcfdfeff00093934393735383939300020493e82fc74464a59268817623d2053c5eb8e2cc4a988b4fee179ec6b010d531d0020c0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedf9bf03c6f147ea3c07c56a8e84c7527bd8b8538ff7e44358d8036c18ed84c8aa6cb61259ae6ea7e2c4a119f8e7269971039310eaff908fab8b511a1efd1397706dcb1f9fd15222ae31fc247d6542ecbff11d34acb8dfc06d2ae6afe872703fb5b255b0768e7ecbb236b78c212fc7729ea22613673a2df0f7ee26ee0ff82881503")

        let clientSigningKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(hexString: "202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f"))
        let hostSigningKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(hexString: "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"))
        XCTAssertEqual(clientSigningKey.publicKey.rawRepresentation.base64EncodedString(), "Kay64UG8yvCyLhqU000LxzYeUm0L/hLIl5S8kyKWbdc=")
        XCTAssertEqual(hostSigningKey.publicKey.rawRepresentation.base64EncodedString(), "A6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg=")
        let helloInput = HandshakeEncoding.helloInput(clientPeer: clientPeer)
        let ackInput = HandshakeEncoding.ackInput(clientPeer: clientPeer, hostPeer: hostPeer)
        let confirmInput = HandshakeEncoding.confirmInput(clientPeer: clientPeer, hostPeer: hostPeer, helloSignature: helloSignature, ackSignature: ackSignature)
        XCTAssertTrue(clientSigningKey.publicKey.isValidSignature(helloSignature, for: helloInput))
        XCTAssertTrue(hostSigningKey.publicKey.isValidSignature(ackSignature, for: ackInput))
        XCTAssertTrue(clientSigningKey.publicKey.isValidSignature(confirmSignature, for: confirmInput))
        XCTAssertTrue(clientSigningKey.publicKey.isValidSignature(try clientSigningKey.signature(for: helloInput), for: helloInput))
        XCTAssertTrue(hostSigningKey.publicKey.isValidSignature(try hostSigningKey.signature(for: ackInput), for: ackInput))
        XCTAssertTrue(clientSigningKey.publicKey.isValidSignature(try clientSigningKey.signature(for: confirmInput), for: confirmInput))

        let transcript = HandshakeTranscript(
            clientPeer: clientPeer,
            hostPeer: hostPeer,
            helloSignature: helloSignature,
            ackSignature: ackSignature,
            confirmSignature: confirmSignature
        )
        XCTAssertEqual(transcript.transcriptHash.hexString, "d3e644a6176792c74704762e7afb801ca60b2780836a147c4378ee511daffc40")

        let clientEphemeralKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(hexString: "a0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebf"))
        let hostEphemeralKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(hexString: "808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f"))
        XCTAssertEqual(clientEphemeralKey.publicKey.rawRepresentation, clientPeer.ephemeralPublicKey)
        XCTAssertEqual(hostEphemeralKey.publicKey.rawRepresentation, hostPeer.ephemeralPublicKey)
        let sharedSecret = try clientEphemeralKey.sharedSecretFromKeyAgreement(with: hostEphemeralKey.publicKey)
        XCTAssertEqual(sharedSecret.hexString, "c6dea8dd115ef27b7e0953539b2b19e59b7abf3ffd57985ec76de86ec31d1b42")
        let keys = HandshakeKeySchedule.deriveKeys(sharedSecret: sharedSecret, transcriptHash: transcript.transcriptHash)
        XCTAssertEqual(keys.initiatorToResponder.hexString, "84f1d1b229d59758326024a9124c2ad39e5d9ae2adf0a0a66be0808b028e73b7")
        XCTAssertEqual(keys.responderToInitiator.hexString, "b3101fc48f69c8c67deee3492347da54870971942b1bf5cb65753ff5d93f6fb2")
    }

    func testSecureFrameVectorV1() throws {
        let key = Data(hexString: "84f1d1b229d59758326024a9124c2ad39e5d9ae2adf0a0a66be0808b028e73b7")
        let plaintext = Data(#"{"t":"status.ping","b":{}}"#.utf8)
        let frame = try SecureFrame.seal(
            plaintext: plaintext,
            key: key,
            direction: .initiatorToResponder,
            counter: 0
        )

        XCTAssertEqual(frame.hexString, "0000002a7f9dbb3859fc024e439d8e3c8e2d56f8b4670ae4066ac1b84db0887b466a60f2de30a3895e3b7b31b90d")
        XCTAssertEqual(try SecureFrame.open(frame: frame, key: key, direction: .initiatorToResponder, counter: 0), plaintext)
    }

    func testSecureChannelCountersAndDirections() throws {
        let keys = SecureChannelKeys(
            initiatorToResponder: Data(hexString: "84f1d1b229d59758326024a9124c2ad39e5d9ae2adf0a0a66be0808b028e73b7"),
            responderToInitiator: Data(hexString: "b3101fc48f69c8c67deee3492347da54870971942b1bf5cb65753ff5d93f6fb2")
        )
        var initiator = SecureChannel(keys: keys, role: .initiator)
        var responder = SecureChannel(keys: keys, role: .responder)

        let ping = Data(#"{"t":"status.ping","b":{}}"#.utf8)
        let pong = Data(#"{"t":"status.pong","b":{}}"#.utf8)
        XCTAssertEqual(try responder.open(try initiator.seal(ping)), ping)
        XCTAssertEqual(try initiator.open(try responder.seal(pong)), pong)
    }

    func testHandshakeWireRoundTrip() throws {
        let peer = HandshakePeer(
            deviceId: "137245816",
            ephemeralPublicKey: Data(base64Encoded: "YFpyXSpK3+6xop4X7dYhwbdZPujNvESsbEq24vgF0jw=")!,
            nonce: Data(base64Encoded: "4OHi4+Tl5ufo6err7O3u7/Dx8vP09fb3+Pn6+/z9/v8=")!
        )
        let signature = Data(base64Encoded: "m/A8bxR+o8B8VqjoTHUnvYuFOP9+RDWNgDbBjthMiqbLYSWa5up+LEoRn45yaZcQOTEOr/kI+ri1EaHv0Tl3Bg==")!
        let decodedHello = try HandshakeWire.decodeSignedPeer(try HandshakeWire.encodeHello(peer: peer, signature: signature))

        XCTAssertEqual(decodedHello.t, HandshakeType.hello)
        XCTAssertEqual(try decodedHello.b.peer(), peer)
        XCTAssertEqual(try decodedHello.b.signature(), signature)

        let decodedConfirm = try HandshakeWire.decodeConfirm(try HandshakeWire.encodeConfirm(signature: signature))
        XCTAssertEqual(decodedConfirm.t, HandshakeType.confirm)
        XCTAssertEqual(try decodedConfirm.b.signature(), signature)
    }

    func testHandshakeSessionFlow() throws {
        let clientIdentity = LocalIdentity(
            deviceId: "137245816",
            name: "Pixel 9",
            signingKey: try Curve25519.Signing.PrivateKey(rawRepresentation: Data(hexString: "202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f"))
        )
        let hostIdentity = LocalIdentity(
            deviceId: "949758990",
            name: "Jason's Mac",
            signingKey: try Curve25519.Signing.PrivateKey(rawRepresentation: Data(hexString: "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"))
        )
        let start = try HandshakeSession.startInitiator(
            identity: clientIdentity,
            ephemeralPrivateKey: try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(hexString: "a0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebf")),
            nonce: Data(base64Encoded: "4OHi4+Tl5ufo6err7O3u7/Dx8vP09fb3+Pn6+/z9/v8=")!
        )
        let ack = try HandshakeSession.acceptHello(
            start.hello,
            identity: hostIdentity,
            pinnedClientPublicKey: clientIdentity.publicKey,
            ephemeralPrivateKey: try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(hexString: "808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f")),
            nonce: Data(base64Encoded: "wMHCw8TFxsfIycrLzM3Oz9DR0tPU1dbX2Nna29zd3t8=")!
        )
        let finishedInitiator = try HandshakeSession.finishInitiator(
            state: start.state,
            ack: ack.ack,
            identity: clientIdentity,
            pinnedHostPublicKey: hostIdentity.publicKey
        )
        var clientEstablished = finishedInitiator.established
        var hostEstablished = try HandshakeSession.finishResponder(
            state: ack.state,
            confirm: finishedInitiator.confirm,
            pinnedClientPublicKey: clientIdentity.publicKey
        )

        XCTAssertEqual(clientEstablished.keys.initiatorToResponder, hostEstablished.keys.initiatorToResponder)
        XCTAssertEqual(clientEstablished.keys.responderToInitiator, hostEstablished.keys.responderToInitiator)
        let ping = Data(#"{"t":"status.ping","b":{}}"#.utf8)
        XCTAssertEqual(try hostEstablished.channel.open(try clientEstablished.channel.seal(ping)), ping)
    }
}

private extension SharedSecret {
    var hexString: String {
        withUnsafeBytes { Data($0).hexString }
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    init(hexString: String) {
        precondition(hexString.count.isMultiple(of: 2))
        var bytes = [UInt8]()
        bytes.reserveCapacity(hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            bytes.append(UInt8(hexString[index..<next], radix: 16)!)
            index = next
        }
        self = Data(bytes)
    }
}
