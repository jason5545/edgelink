import Foundation

public struct PairStartRequest: Codable, Sendable {
    public let hostId: String
    public let hostPk: String
    public let name: String

    public init(hostId: String, hostPk: String, name: String) {
        self.hostId = hostId
        self.hostPk = hostPk
        self.name = name
    }
}

public struct PairConfirmRequest: Codable, Sendable {
    public let role: String
    public let hostId: String
    public let clientId: String
    public let hostPk: String
    public let clientPk: String
    public let hostName: String
    public let clientName: String

    public init(role: String, hostId: String, clientId: String, hostPk: String, clientPk: String, hostName: String, clientName: String) {
        self.role = role
        self.hostId = hostId
        self.clientId = clientId
        self.hostPk = hostPk
        self.clientPk = clientPk
        self.hostName = hostName
        self.clientName = clientName
    }
}

public struct PairReadyBody: Codable, Sendable {
    public let deviceId: String
}

public struct PairCommitBody: Codable, Sendable {
    public let commit: String
}

public struct PairRevealClientBody: Codable, Sendable {
    public let clientId: String
    public let clientPk: String
    public let nonceC: String
    public let name: String
}

public struct PairRevealHostBody: Codable, Sendable {
    public let hostId: String
    public let hostPk: String
    public let nonceH: String
    public let name: String
}

public struct PairCompleteBody: Codable, Sendable {
    public let hostId: String
    public let clientId: String
}

public enum PairingType {
    public static let ready = "pair.ready"
    public static let commit = "pair.commit"
    public static let revealClient = "pair.reveal_client"
    public static let revealHost = "pair.reveal_host"
    public static let complete = "pair.complete"
}

public enum PairingWire {
    public static func encodeCommit(_ commitment: Data) throws -> String {
        try encode(Envelope(t: PairingType.commit, b: PairCommitBody(commit: commitment.base64EncodedString())))
    }

    public static func encodeRevealHost(identity: LocalIdentity, nonce: Data) throws -> String {
        try encode(
            Envelope(
                t: PairingType.revealHost,
                b: PairRevealHostBody(
                    hostId: identity.deviceId,
                    hostPk: identity.publicKey.base64EncodedString(),
                    nonceH: nonce.base64EncodedString(),
                    name: identity.name
                )
            )
        )
    }

    public static func decodeRevealClient(_ text: String) throws -> PairRevealClientBody {
        try JSONDecoder().decode(Envelope<PairRevealClientBody>.self, from: Data(text.utf8)).b
    }

    public static func decodeComplete(_ text: String) throws -> PairCompleteBody {
        try JSONDecoder().decode(Envelope<PairCompleteBody>.self, from: Data(text.utf8)).b
    }

    public static func type(_ text: String) throws -> String {
        try JSONDecoder().decode(EnvelopeHeader.self, from: Data(text.utf8)).t
    }

    private static func encode<Body: Codable & Sendable>(_ envelope: Envelope<Body>) throws -> String {
        String(data: try JSONEncoder().encode(envelope), encoding: .utf8) ?? ""
    }
}

private struct EnvelopeHeader: Codable {
    let t: String
}
