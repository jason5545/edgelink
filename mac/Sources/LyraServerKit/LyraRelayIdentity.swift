import CryptoKit
import EdgeLinkKit
import Foundation

public struct StoredRelayIdentity: Codable, Sendable {
    public var deviceId: String
    public var name: String
    public var signingKey: String

    public init(deviceId: String, name: String, signingKey: String) {
        self.deviceId = deviceId
        self.name = name
        self.signingKey = signingKey
    }
}

public final class LyraRelayIdentityStore: Sendable {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> LocalIdentity? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let stored = try JSONDecoder().decode(StoredRelayIdentity.self, from: Data(contentsOf: url))
        guard let keyData = Data(base64Encoded: stored.signingKey) else {
            throw LyraRelayIdentityError.invalidStoredKey
        }
        return LocalIdentity(
            deviceId: stored.deviceId,
            name: stored.name,
            signingKey: try Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
        )
    }

    public func save(_ identity: LocalIdentity) throws {
        let stored = StoredRelayIdentity(
            deviceId: identity.deviceId,
            name: identity.name,
            signingKey: identity.signingKey.rawRepresentation.base64EncodedString()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(stored).write(to: url, options: .atomic)
    }

    public func loadOrRegister(
        registrar: DeviceRegistrar,
        name: String,
        platform: String
    ) async throws -> LocalIdentity {
        if let existing = try load() {
            return existing
        }
        let signingKey = Curve25519.Signing.PrivateKey()
        let deviceId = try await registrar.register(
            pubkey: signingKey.publicKey.rawRepresentation,
            name: name,
            platform: platform
        )
        let identity = LocalIdentity(deviceId: deviceId, name: name, signingKey: signingKey)
        try save(identity)
        return identity
    }
}

public enum LyraRelayIdentityError: Error {
    case invalidStoredKey
}
