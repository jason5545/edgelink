import CryptoKit
import Foundation

public struct HandshakePeer: Equatable, Sendable {
    public let deviceId: String
    public let ephemeralPublicKey: Data
    public let nonce: Data

    public init(deviceId: String, ephemeralPublicKey: Data, nonce: Data) {
        self.deviceId = deviceId
        self.ephemeralPublicKey = ephemeralPublicKey
        self.nonce = nonce
    }
}

public enum HandshakeEncoding {
    public static let helloPrefix = Data("EdgeLink hs.v1 hello\n".utf8)
    public static let ackPrefix = Data("EdgeLink hs.v1 ack\n".utf8)
    public static let confirmPrefix = Data("EdgeLink hs.v1 confirm\n".utf8)
    public static let transcriptPrefix = Data("EdgeLink hs.v1 transcript\n".utf8)
    public static let hkdfInfo = Data("EdgeLink secure channel v1".utf8)

    public static func peerRecord(_ peer: HandshakePeer) -> Data {
        var out = Data()
        appendLengthPrefixed(Data(peer.deviceId.utf8), to: &out)
        appendLengthPrefixed(peer.ephemeralPublicKey, to: &out)
        appendLengthPrefixed(peer.nonce, to: &out)
        return out
    }

    public static func helloInput(clientPeer: HandshakePeer) -> Data {
        helloPrefix + peerRecord(clientPeer)
    }

    public static func ackInput(clientPeer: HandshakePeer, hostPeer: HandshakePeer) -> Data {
        ackPrefix + peerRecord(clientPeer) + peerRecord(hostPeer)
    }

    public static func confirmInput(clientPeer: HandshakePeer, hostPeer: HandshakePeer, helloSignature: Data, ackSignature: Data) -> Data {
        confirmPrefix + peerRecord(clientPeer) + peerRecord(hostPeer) + helloSignature + ackSignature
    }

    public static func transcriptHash(clientPeer: HandshakePeer, helloSignature: Data, hostPeer: HandshakePeer, ackSignature: Data, confirmSignature: Data) -> Data {
        let transcript = transcriptPrefix + peerRecord(clientPeer) + helloSignature + peerRecord(hostPeer) + ackSignature + confirmSignature
        return Data(SHA256.hash(data: transcript))
    }

    private static func appendLengthPrefixed(_ value: Data, to output: inout Data) {
        precondition(value.count <= UInt16.max)
        output.append(UInt8((value.count >> 8) & 0xff))
        output.append(UInt8(value.count & 0xff))
        output.append(value)
    }
}

public enum HandshakeType {
    public static let hello = "hs.hello"
    public static let ack = "hs.ack"
    public static let confirm = "hs.confirm"
}

public struct HandshakeSignedPeerBody: Codable, Equatable, Sendable {
    public let deviceId: String
    public let ephPk: String
    public let nonce: String
    public let sig: String

    public init(deviceId: String, ephPk: String, nonce: String, sig: String) {
        self.deviceId = deviceId
        self.ephPk = ephPk
        self.nonce = nonce
        self.sig = sig
    }

    public init(peer: HandshakePeer, signature: Data) {
        self.deviceId = peer.deviceId
        self.ephPk = peer.ephemeralPublicKey.base64EncodedString()
        self.nonce = peer.nonce.base64EncodedString()
        self.sig = signature.base64EncodedString()
    }

    public func peer() throws -> HandshakePeer {
        guard let ephemeralPublicKey = Data(base64Encoded: ephPk),
              let nonceData = Data(base64Encoded: nonce) else {
            throw HandshakeWireError.invalidBase64
        }
        return HandshakePeer(
            deviceId: deviceId,
            ephemeralPublicKey: ephemeralPublicKey,
            nonce: nonceData
        )
    }

    public func signature() throws -> Data {
        guard let data = Data(base64Encoded: sig) else {
            throw HandshakeWireError.invalidBase64
        }
        return data
    }
}

public struct HandshakeConfirmBody: Codable, Equatable, Sendable {
    public let sig: String

    public init(signature: Data) {
        self.sig = signature.base64EncodedString()
    }

    public func signature() throws -> Data {
        guard let data = Data(base64Encoded: sig) else {
            throw HandshakeWireError.invalidBase64
        }
        return data
    }
}

public enum HandshakeWire {
    public static func encodeHello(peer: HandshakePeer, signature: Data) throws -> Data {
        try JSONEncoder().encode(Envelope(t: HandshakeType.hello, b: HandshakeSignedPeerBody(peer: peer, signature: signature)))
    }

    public static func encodeAck(peer: HandshakePeer, signature: Data) throws -> Data {
        try JSONEncoder().encode(Envelope(t: HandshakeType.ack, b: HandshakeSignedPeerBody(peer: peer, signature: signature)))
    }

    public static func encodeConfirm(signature: Data) throws -> Data {
        try JSONEncoder().encode(Envelope(t: HandshakeType.confirm, b: HandshakeConfirmBody(signature: signature)))
    }

    public static func decodeSignedPeer(_ data: Data) throws -> Envelope<HandshakeSignedPeerBody> {
        try JSONDecoder().decode(Envelope<HandshakeSignedPeerBody>.self, from: data)
    }

    public static func decodeConfirm(_ data: Data) throws -> Envelope<HandshakeConfirmBody> {
        try JSONDecoder().decode(Envelope<HandshakeConfirmBody>.self, from: data)
    }
}

public enum HandshakeWireError: Error {
    case invalidBase64
}

public struct HandshakeTranscript: Equatable, Sendable {
    public let clientPeer: HandshakePeer
    public let hostPeer: HandshakePeer
    public let helloSignature: Data
    public let ackSignature: Data
    public let confirmSignature: Data

    public init(clientPeer: HandshakePeer, hostPeer: HandshakePeer, helloSignature: Data, ackSignature: Data, confirmSignature: Data) {
        self.clientPeer = clientPeer
        self.hostPeer = hostPeer
        self.helloSignature = helloSignature
        self.ackSignature = ackSignature
        self.confirmSignature = confirmSignature
    }

    public var transcriptHash: Data {
        HandshakeEncoding.transcriptHash(
            clientPeer: clientPeer,
            helloSignature: helloSignature,
            hostPeer: hostPeer,
            ackSignature: ackSignature,
            confirmSignature: confirmSignature
        )
    }
}

public struct SecureChannelKeys: Equatable, Sendable {
    public let initiatorToResponder: Data
    public let responderToInitiator: Data

    public init(initiatorToResponder: Data, responderToInitiator: Data) {
        precondition(initiatorToResponder.count == 32)
        precondition(responderToInitiator.count == 32)
        self.initiatorToResponder = initiatorToResponder
        self.responderToInitiator = responderToInitiator
    }
}

public enum HandshakeKeySchedule {
    public static func deriveKeys(sharedSecret: SharedSecret, transcriptHash: Data) -> SecureChannelKeys {
        let material = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: transcriptHash,
            sharedInfo: HandshakeEncoding.hkdfInfo,
            outputByteCount: 64
        )
        let bytes = material.withUnsafeBytes { Data($0) }
        return SecureChannelKeys(
            initiatorToResponder: bytes.prefixData(32),
            responderToInitiator: bytes.suffixData(32)
        )
    }
}

private extension Data {
    func prefixData(_ count: Int) -> Data {
        Data(prefix(count))
    }

    func suffixData(_ count: Int) -> Data {
        Data(suffix(count))
    }
}
