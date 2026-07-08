import CryptoKit
import EdgeLinkKit
import Foundation
import Security

final class KeychainIdentityStore: IdentityStore, @unchecked Sendable {
    private let service = "com.edgelink.identity"
    private let account = "local"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func loadIdentity() throws -> LocalIdentity? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw LocalStoreError.keychain(status)
        }

        let stored = try decoder.decode(StoredIdentity.self, from: data)
        guard let keyData = Data(base64Encoded: stored.signingKey) else {
            throw LocalStoreError.invalidIdentityData
        }
        return try LocalIdentity(
            deviceId: stored.deviceId,
            name: stored.name,
            signingKey: Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
        )
    }

    func saveIdentity(_ identity: LocalIdentity) throws {
        let stored = StoredIdentity(
            deviceId: identity.deviceId,
            name: identity.name,
            signingKey: identity.signingKey.rawRepresentation.base64EncodedString()
        )
        let data = try encoder.encode(stored)
        SecItemDelete(baseQuery() as CFDictionary)

        var query = baseQuery()
        query[kSecValueData as String] = data
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw LocalStoreError.keychain(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

final class ApplicationSupportPairingStore: PairingStore, @unchecked Sendable {
    private let url: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileManager: FileManager = .default) throws {
        let directory = try Self.directory(fileManager: fileManager)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("pinned-peers.json")
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func loadPeer(deviceId: String) throws -> PinnedPeer? {
        try loadPeers().first { $0.deviceId == deviceId }
    }

    func loadPeers() throws -> [PinnedPeer] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }
        let data = try Data(contentsOf: url)
        return try decoder.decode(PeerFile.self, from: data).peers
    }

    func savePeer(_ peer: PinnedPeer) throws {
        var peers = try loadPeers().filter { $0.deviceId != peer.deviceId }
        peers.append(peer)
        try encoder.encode(PeerFile(peers: peers)).write(to: url, options: .atomic)
    }

    private static func directory(fileManager: FileManager) throws -> URL {
        guard let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw LocalStoreError.missingApplicationSupportDirectory
        }
        return base.appendingPathComponent("EdgeLink", isDirectory: true)
    }
}

private struct StoredIdentity: Codable {
    let deviceId: String
    let name: String
    let signingKey: String
}

private struct PeerFile: Codable {
    let peers: [PinnedPeer]
}

enum LocalStoreError: Error {
    case keychain(OSStatus)
    case invalidIdentityData
    case missingApplicationSupportDirectory
}
