import CryptoKit
import Foundation

public struct InitiatorHandshakeState: Sendable {
    public let clientPeer: HandshakePeer
    public let ephemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey
    public let helloSignature: Data
}

public struct ResponderHandshakeState: Sendable {
    public let clientPeer: HandshakePeer
    public let hostPeer: HandshakePeer
    public let ephemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey
    public let helloSignature: Data
    public let ackSignature: Data
}

public struct InitiatorHandshakeStart: Sendable {
    public let state: InitiatorHandshakeState
    public let hello: Data
}

public struct ResponderHandshakeAck: Sendable {
    public let state: ResponderHandshakeState
    public let ack: Data
}

public struct EstablishedHandshake: Sendable {
    public let transcript: HandshakeTranscript
    public let keys: SecureChannelKeys
    public var channel: SecureChannel
}

public enum HandshakeSession {
    public static func startInitiator(
        identity: LocalIdentity,
        ephemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey = Curve25519.KeyAgreement.PrivateKey(),
        nonce: Data = randomNonce()
    ) throws -> InitiatorHandshakeStart {
        precondition(nonce.count == 32)
        let clientPeer = HandshakePeer(
            deviceId: identity.deviceId,
            ephemeralPublicKey: ephemeralPrivateKey.publicKey.rawRepresentation,
            nonce: nonce
        )
        let helloSignature = try identity.signingKey.signature(for: HandshakeEncoding.helloInput(clientPeer: clientPeer))
        return InitiatorHandshakeStart(
            state: InitiatorHandshakeState(
                clientPeer: clientPeer,
                ephemeralPrivateKey: ephemeralPrivateKey,
                helloSignature: helloSignature
            ),
            hello: try HandshakeWire.encodeHello(peer: clientPeer, signature: helloSignature)
        )
    }

    public static func acceptHello(
        _ hello: Data,
        identity: LocalIdentity,
        pinnedClientPublicKey: Data,
        ephemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey = Curve25519.KeyAgreement.PrivateKey(),
        nonce: Data = randomNonce()
    ) throws -> ResponderHandshakeAck {
        precondition(nonce.count == 32)
        let decodedHello = try HandshakeWire.decodeSignedPeer(hello)
        guard decodedHello.t == HandshakeType.hello else {
            throw HandshakeSessionError.unexpectedMessage
        }
        let clientPeer = try decodedHello.b.peer()
        let helloSignature = try decodedHello.b.signature()
        let clientPublicKey = try Curve25519.Signing.PublicKey(rawRepresentation: pinnedClientPublicKey)
        guard clientPublicKey.isValidSignature(helloSignature, for: HandshakeEncoding.helloInput(clientPeer: clientPeer)) else {
            throw HandshakeSessionError.invalidSignature
        }

        let hostPeer = HandshakePeer(
            deviceId: identity.deviceId,
            ephemeralPublicKey: ephemeralPrivateKey.publicKey.rawRepresentation,
            nonce: nonce
        )
        let ackSignature = try identity.signingKey.signature(for: HandshakeEncoding.ackInput(clientPeer: clientPeer, hostPeer: hostPeer))
        return ResponderHandshakeAck(
            state: ResponderHandshakeState(
                clientPeer: clientPeer,
                hostPeer: hostPeer,
                ephemeralPrivateKey: ephemeralPrivateKey,
                helloSignature: helloSignature,
                ackSignature: ackSignature
            ),
            ack: try HandshakeWire.encodeAck(peer: hostPeer, signature: ackSignature)
        )
    }

    public static func finishInitiator(
        state: InitiatorHandshakeState,
        ack: Data,
        identity: LocalIdentity,
        pinnedHostPublicKey: Data
    ) throws -> (confirm: Data, established: EstablishedHandshake) {
        let decodedAck = try HandshakeWire.decodeSignedPeer(ack)
        guard decodedAck.t == HandshakeType.ack else {
            throw HandshakeSessionError.unexpectedMessage
        }
        let hostPeer = try decodedAck.b.peer()
        let ackSignature = try decodedAck.b.signature()
        let hostPublicKey = try Curve25519.Signing.PublicKey(rawRepresentation: pinnedHostPublicKey)
        guard hostPublicKey.isValidSignature(
            ackSignature,
            for: HandshakeEncoding.ackInput(clientPeer: state.clientPeer, hostPeer: hostPeer)
        ) else {
            throw HandshakeSessionError.invalidSignature
        }

        let confirmSignature = try identity.signingKey.signature(
            for: HandshakeEncoding.confirmInput(
                clientPeer: state.clientPeer,
                hostPeer: hostPeer,
                helloSignature: state.helloSignature,
                ackSignature: ackSignature
            )
        )
        let transcript = HandshakeTranscript(
            clientPeer: state.clientPeer,
            hostPeer: hostPeer,
            helloSignature: state.helloSignature,
            ackSignature: ackSignature,
            confirmSignature: confirmSignature
        )
        let sharedSecret = try state.ephemeralPrivateKey.sharedSecretFromKeyAgreement(
            with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: hostPeer.ephemeralPublicKey)
        )
        let keys = HandshakeKeySchedule.deriveKeys(sharedSecret: sharedSecret, transcriptHash: transcript.transcriptHash)
        return (
            confirm: try HandshakeWire.encodeConfirm(signature: confirmSignature),
            established: EstablishedHandshake(
                transcript: transcript,
                keys: keys,
                channel: SecureChannel(keys: keys, role: .initiator)
            )
        )
    }

    public static func finishResponder(
        state: ResponderHandshakeState,
        confirm: Data,
        pinnedClientPublicKey: Data
    ) throws -> EstablishedHandshake {
        let decodedConfirm = try HandshakeWire.decodeConfirm(confirm)
        guard decodedConfirm.t == HandshakeType.confirm else {
            throw HandshakeSessionError.unexpectedMessage
        }
        let confirmSignature = try decodedConfirm.b.signature()
        let clientPublicKey = try Curve25519.Signing.PublicKey(rawRepresentation: pinnedClientPublicKey)
        guard clientPublicKey.isValidSignature(
            confirmSignature,
            for: HandshakeEncoding.confirmInput(
                clientPeer: state.clientPeer,
                hostPeer: state.hostPeer,
                helloSignature: state.helloSignature,
                ackSignature: state.ackSignature
            )
        ) else {
            throw HandshakeSessionError.invalidSignature
        }

        let transcript = HandshakeTranscript(
            clientPeer: state.clientPeer,
            hostPeer: state.hostPeer,
            helloSignature: state.helloSignature,
            ackSignature: state.ackSignature,
            confirmSignature: confirmSignature
        )
        let sharedSecret = try state.ephemeralPrivateKey.sharedSecretFromKeyAgreement(
            with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: state.clientPeer.ephemeralPublicKey)
        )
        let keys = HandshakeKeySchedule.deriveKeys(sharedSecret: sharedSecret, transcriptHash: transcript.transcriptHash)
        return EstablishedHandshake(
            transcript: transcript,
            keys: keys,
            channel: SecureChannel(keys: keys, role: .responder)
        )
    }

    public static func randomNonce() -> Data {
        Data((0..<32).map { _ in UInt8.random(in: UInt8.min...UInt8.max) })
    }
}

public enum HandshakeSessionError: Error {
    case unexpectedMessage
    case invalidSignature
}
