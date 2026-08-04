import CryptoKit
import EdgeLinkKit
import Foundation

// Virtual phone identity for the LyraServer replica. Everything the real
// phone carries in its lyra identity store: the P-256 identity keypair (signs
// AuthHandshake proofs and cred features), the 32-byte device key advertised
// as TrustedDeviceInfo f13, the uid hash behind sync_info f5, and the account
// fields the phone stamps into its own TrustedDeviceInfo.
public struct LyraPhoneIdentity: Codable, Sendable {
    public var deviceIdHex: String
    public var fullDeviceIdHex: String
    public var displayName: String
    public var identityPrivHex: String
    public var identityPubB64: String
    public var uidHashB64: String
    public var deviceKeyHex: String
    public var accountNumericId: String
    public var model: String
    public var romVersion: String
    public var netId: UInt32

    public init(
        deviceIdHex: String,
        fullDeviceIdHex: String,
        displayName: String,
        identityPrivHex: String,
        identityPubB64: String,
        uidHashB64: String,
        deviceKeyHex: String,
        accountNumericId: String = "32717118",
        model: String = "2410DPN6CC",
        romVersion: String = "5.1.208.10.fullCnRelease.0512164",
        netId: UInt32 = 2
    ) {
        self.deviceIdHex = deviceIdHex
        self.fullDeviceIdHex = fullDeviceIdHex
        self.displayName = displayName
        self.identityPrivHex = identityPrivHex
        self.identityPubB64 = identityPubB64
        self.uidHashB64 = uidHashB64
        self.deviceKeyHex = deviceKeyHex
        self.accountNumericId = accountNumericId
        self.model = model
        self.romVersion = romVersion
        self.netId = netId
    }

    public static func generate(displayName: String = "Xiaomi 15 Ultra") -> LyraPhoneIdentity {
        let identity = P256.Signing.PrivateKey()
        var deviceId = Self.randomBytes(4)
        var fullDeviceId = Self.randomBytes(28)
        fullDeviceId.insert(contentsOf: deviceId, at: 0)
        return LyraPhoneIdentity(
            deviceIdHex: deviceId.map { String(format: "%02X", $0) }.joined(),
            fullDeviceIdHex: fullDeviceId.map { String(format: "%02X", $0) }.joined(),
            displayName: displayName,
            identityPrivHex: identity.rawRepresentation.map { String(format: "%02x", $0) }.joined(),
            identityPubB64: identity.publicKey.x963Representation.base64EncodedString(),
            uidHashB64: Data(Self.randomBytes(32)).base64EncodedString(),
            deviceKeyHex: Self.randomBytes(32).map { String(format: "%02x", $0) }.joined()
        )
    }

    public var identityPrivateKey: P256.Signing.PrivateKey? {
        guard let raw = Self.data(fromHex: identityPrivHex) else { return nil }
        return try? P256.Signing.PrivateKey(rawRepresentation: raw)
    }

    public var identityPubKeyData: Data {
        Data(base64Encoded: identityPubB64) ?? Data()
    }

    public var uidHashRaw: Data {
        Data(base64Encoded: uidHashB64) ?? Data()
    }

    public var uidHash: String {
        uidHashRaw.map { String(format: "%02X", $0) }.joined()
    }

    public var deviceKey: SymmetricKey? {
        guard let raw = Self.data(fromHex: deviceKeyHex), raw.count == 32 else { return nil }
        return SymmetricKey(data: raw)
    }

    public var deviceKeyData: Data? {
        Self.data(fromHex: deviceKeyHex)
    }

    // sync_info f5 uid feature: {f1: nonce8, f2: sha256(nonce || uidHash)} —
    // same construction as MiTrustTicketStore.uidFeatureInfo().
    public func uidFeatureInfo() -> Data {
        var nonce = Data(count: 8)
        nonce.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress { arc4random_buf(base, 8) }
        }
        var feature = Data(SHA256.hash(data: nonce + uidHashRaw))
        var info = Data()
        LyraProtoWriter.appendLengthDelimitedField(1, value: nonce, to: &info)
        LyraProtoWriter.appendLengthDelimitedField(2, value: feature, to: &info)
        return info
    }

    // Encrypted local cred (sync_info f6): the {f1:1, f3:CredFeature{f2:
    // pubKeyCred{nonce, sig(nonce)}}} frame AES-GCM'd with the given key.
    public func encryptedLocalCred(using key: SymmetricKey) -> Data? {
        guard let identityPrivateKey else { return nil }
        var nonce32 = Data(count: 32)
        nonce32.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress { arc4random_buf(base, 32) }
        }
        guard let signature = try? identityPrivateKey.signature(for: SHA256.hash(data: nonce32)) else {
            return nil
        }
        var pubKeyCred = Data()
        LyraProtoWriter.appendLengthDelimitedField(1, value: nonce32, to: &pubKeyCred)
        LyraProtoWriter.appendLengthDelimitedField(2, value: signature.derRepresentation, to: &pubKeyCred)
        var credFeature = Data()
        LyraProtoWriter.appendLengthDelimitedField(2, value: pubKeyCred, to: &credFeature)
        var frame = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &frame)
        LyraProtoWriter.appendLengthDelimitedField(3, value: credFeature, to: &frame)
        guard let sealed = try? AES.GCM.seal(frame, using: key) else { return nil }
        var blob = Data()
        blob.append(contentsOf: sealed.nonce.withUnsafeBytes { Data($0) })
        blob.append(sealed.ciphertext)
        blob.append(sealed.tag)
        return blob
    }

    // MARK: - Persistence

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url)
    }

    public static func load(from url: URL) throws -> LyraPhoneIdentity {
        try JSONDecoder().decode(LyraPhoneIdentity.self, from: Data(contentsOf: url))
    }

    public static func loadOrGenerate(at url: URL, displayName: String = "Xiaomi 15 Ultra") -> LyraPhoneIdentity {
        if let existing = try? load(from: url) {
            return existing
        }
        let generated = generate(displayName: displayName)
        try? generated.save(to: url)
        return generated
    }

    // MARK: - Helpers

    static func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress { arc4random_buf(base, count) }
        }
        return data
    }

    public static func data(fromHex hex: String) -> Data? {
        var data = Data()
        data.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
}
