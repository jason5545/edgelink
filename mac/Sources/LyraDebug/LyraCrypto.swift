import CryptoKit
import Foundation

enum LyraCrypto {
    static let keyAgreeSessionSalt = Data([
        0x5E, 0xD5, 0xA3, 0xF8, 0x36, 0xF6, 0xB5, 0x4F,
        0x7B, 0x1E, 0xFA, 0xD0, 0x27, 0x14, 0xD5, 0x17,
        0x7B, 0x8A, 0x1F, 0x0F, 0x19, 0xE3, 0x69, 0xCC,
        0x0B, 0xE8, 0xD9, 0x8B, 0xA6, 0x29, 0x73, 0x17
    ])
    static let authTicketSalt = Data([
        0x0A, 0x5B, 0x87, 0x72, 0x08, 0xD4, 0xA1, 0xCF,
        0x76, 0xD3, 0x08, 0x09, 0x51, 0xDD, 0x1B, 0xB8,
        0x6B, 0x4E, 0x9E, 0xE2, 0x57, 0x92, 0x4B, 0xAF,
        0xDB, 0xA6, 0x2C, 0x5A, 0x67, 0x06, 0xE6, 0x18
    ])
    static let compareNumSalt = Data([
        0x4E, 0x23, 0xED, 0x67, 0x88, 0x13, 0xEA, 0x9F,
        0x6E, 0x28, 0xAA, 0xB1, 0x6C, 0x90, 0x0B, 0xC0,
        0x6E, 0xD4, 0x10, 0x27, 0x04, 0x8C, 0xCE, 0x0B,
        0x19, 0x7A, 0xF1, 0xE9, 0xDD, 0x7E, 0xEC, 0x9A
    ])

    static func hkdf(ikm: Data, salt: Data, info: Data, bytes: Int = 32) -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: salt,
            info: info,
            outputByteCount: bytes
        )
        return key.withUnsafeBytes { Data($0) }
    }

    static func aesGcmDecrypt(key: Data, blob: Data) -> Data? {
        guard blob.count > 28, key.count == 32 else { return nil }
        do {
            let nonce = try AES.GCM.Nonce(data: blob.prefix(12))
            let box = try AES.GCM.SealedBox(
                nonce: nonce,
                ciphertext: blob.subdata(in: 12..<(blob.count - 16)),
                tag: blob.suffix(16)
            )
            return try AES.GCM.open(box, using: SymmetricKey(data: key))
        } catch {
            return nil
        }
    }

    static func ecdh(privateKeyData: Data, peerPublicKeyX963: Data) -> Data? {
        do {
            let priv = try P256.KeyAgreement.PrivateKey(rawRepresentation: privateKeyData)
            let pub = try P256.KeyAgreement.PublicKey(x963Representation: peerPublicKeyX963)
            let secret = try priv.sharedSecretFromKeyAgreement(with: pub)
            return secret.withUnsafeBytes { Data($0) }
        } catch {
            return nil
        }
    }

    static func verifyECDSA(derSignature: Data, publicKeyX963: Data, message: Data) -> Bool {
        do {
            let pub = try P256.Signing.PublicKey(x963Representation: publicKeyX963)
            let sig = try P256.Signing.ECDSASignature(derRepresentation: derSignature)
            return pub.isValidSignature(sig, for: SHA256.hash(data: message))
        } catch {
            return false
        }
    }

    static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    static func compareNum(z: Data, clientRandom: Data, serverRandom: Data) -> String {
        let out = hkdf(ikm: z, salt: compareNumSalt, info: clientRandom + serverRandom)
        let b64 = out.base64EncodedString()
        return String(b64.prefix(6)).uppercased()
    }
}

extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    init?(hexString: String) {
        let cleaned = hexString.filter { $0.isHexDigit }
        guard cleaned.count % 2 == 0, !cleaned.isEmpty else { return nil }
        var data = Data(capacity: cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}

struct KeyEntry: Codable {
    var label: String
    var key: String
}

struct Keyring: Codable {
    var sessionKeys: [KeyEntry] = []
    var ticketKeys: [KeyEntry] = []
    var ephemeralPrivKeys: [KeyEntry] = []
    var identityPubKeys: [KeyEntry] = []
    var identityPrivKeys: [KeyEntry] = []
    var uidHashes: [KeyEntry] = []

    mutating func addSessionKey(label: String, key: Data) {
        let hex = key.hexString
        guard !sessionKeys.contains(where: { $0.key == hex }) else { return }
        sessionKeys.append(KeyEntry(label: label, key: hex))
    }

    var decryptionCandidates: [(label: String, key: Data)] {
        var out: [(String, Data)] = []
        for entry in sessionKeys + ticketKeys {
            if let data = Data(hexString: entry.key), data.count == 32 {
                out.append((entry.label, data))
            }
        }
        return out
    }

    func identityPub(labelContaining needle: String? = nil) -> [(label: String, key: Data)] {
        identityPubKeys.compactMap { entry in
            guard let data = Data(hexString: entry.key), data.count == 65 else { return nil }
            if let needle, !entry.label.localizedCaseInsensitiveContains(needle) { return nil }
            return (entry.label, data)
        }
    }

    static func load(path: String) throws -> Keyring {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Keyring.self, from: data)
    }

    func save(path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

enum LyraStoreError: Error, CustomStringConvertible {
    case badMagic
    case badLength
    case crcMismatch
    case decryptFailed
    case keychainKeyNotFound

    var description: String {
        switch self {
        case .badMagic: return "storage file missing LYRA magic"
        case .badLength: return "storage file truncated"
        case .crcMismatch: return "storage CRC32 mismatch"
        case .decryptFailed: return "storage AES-GCM decrypt failed (wrong key?)"
        case .keychainKeyNotFound: return "keychain item com.xiaomi.hyperConnect.storage not readable; pass --key-hex"
        }
    }
}

enum LyraStoreExtractor {
    static func extract(storagePath: String, keyHex: String?) throws -> (keyring: Keyring, entries: [(String, Int)]) {
        let keyData: Data
        if let keyHex, let parsed = Data(hexString: keyHex), parsed.count == 32 {
            keyData = parsed
        } else if let fromKeychain = readKeychainKey() {
            keyData = fromKeychain
        } else {
            throw LyraStoreError.keychainKeyNotFound
        }
        let fileData = try Data(contentsOf: URL(fileURLWithPath: storagePath))
        let plaintext = try decryptStore(fileData, key: keyData)
        let entries = try parseStoreMap(plaintext)
        var keyring = Keyring()
        var summary: [(String, Int)] = []
        for (name, value) in entries {
            summary.append((name, value.count))
            ingestEntry(name: name, value: value, into: &keyring)
        }
        return (keyring, summary)
    }

    static func decryptStore(_ data: Data, key: Data) throws -> Data {
        guard data.count >= 21 else { throw LyraStoreError.badLength }
        guard data.prefix(4) == Data("LYRA".utf8) else { throw LyraStoreError.badMagic }
        var cursor = 4
        cursor += 1
        let nonceLen = Int(readBE32(data, cursor)); cursor += 4
        let crc = readBE32(data, cursor); cursor += 4
        let encLen = Int(readBE32(data, cursor)); cursor += 4
        guard data.count >= cursor + encLen, encLen >= nonceLen + 16 else { throw LyraStoreError.badLength }
        let enc = data.subdata(in: cursor..<(cursor + encLen))
        guard crc32(enc) == crc else { throw LyraStoreError.crcMismatch }
        guard let plain = LyraCrypto.aesGcmDecrypt(key: key, blob: enc) else {
            throw LyraStoreError.decryptFailed
        }
        return plain
    }

    static func parseStoreMap(_ plaintext: Data) throws -> [(String, Data)] {
        guard plaintext.count >= 4 else { throw LyraStoreError.badLength }
        var cursor = 0
        let count = Int(readBE32(plaintext, cursor)); cursor += 4
        var entries: [(String, Data)] = []
        for _ in 0..<count {
            guard plaintext.count >= cursor + 4 else { throw LyraStoreError.badLength }
            let klen = Int(readBE32(plaintext, cursor)); cursor += 4
            guard plaintext.count >= cursor + klen + 4 else { throw LyraStoreError.badLength }
            let keyData = plaintext.subdata(in: cursor..<(cursor + klen)); cursor += klen
            let vlen = Int(readBE32(plaintext, cursor)); cursor += 4
            guard plaintext.count >= cursor + vlen else { throw LyraStoreError.badLength }
            let value = plaintext.subdata(in: cursor..<(cursor + vlen)); cursor += vlen
            let name = String(data: keyData, encoding: .utf8) ?? keyData.hexString
            entries.append((name, value))
        }
        return entries
    }

    private static func ingestEntry(name: String, value: Data, into keyring: inout Keyring) {
        guard let object = try? JSONSerialization.jsonObject(with: value) as? [String: Any] else {
            return
        }
        if name.hasPrefix("identity-ticket:") {
            let device = String(name.dropFirst("identity-ticket:".count))
            if let b64 = object["key"] as? String, let raw = Data(base64Encoded: b64), raw.count == 32 {
                keyring.ticketKeys.append(KeyEntry(label: "ticket \(device)", key: raw.hexString))
            }
        } else if name.hasPrefix("identity-cred:") {
            let device = String(name.dropFirst("identity-cred:".count))
            if let account = object["account"] as? [String: Any] {
                if let uidB64 = account["uid"] as? String, let uid = Data(base64Encoded: uidB64) {
                    keyring.uidHashes.append(KeyEntry(label: "uid \(device)", key: uid.hexString))
                }
                if let pubB64 = account["pub_key"] as? String, let pub = Data(base64Encoded: pubB64), pub.count == 65 {
                    keyring.identityPubKeys.append(KeyEntry(label: "account-pub \(device)", key: pub.hexString))
                }
            }
        } else if name == "identity-keypair" || name.hasPrefix("identity-ecdsa:") {            let label = name == "identity-keypair" ? "local identity" : "local identity (\(name))"
            if let privB64 = object["priv_key"] as? String ?? object["private_key"] as? String ?? object["priv"] as? String ?? object["privateKey"] as? String,
               let priv = Data(base64Encoded: privB64) {
                keyring.identityPrivKeys.append(KeyEntry(label: label, key: priv.hexString))
                if let privKey = try? P256.Signing.PrivateKey(rawRepresentation: priv) {
                    keyring.identityPubKeys.append(KeyEntry(label: label, key: privKey.publicKey.x963Representation.hexString))
                }
            }
            if let pubB64 = object["pub_key"] as? String ?? object["public_key"] as? String ?? object["pub"] as? String ?? object["publicKey"] as? String,
               let pub = Data(base64Encoded: pubB64), pub.count == 65 {
                keyring.identityPubKeys.append(KeyEntry(label: "\(label) (stored)", key: pub.hexString))
            }
        }
    }

    private static func readKeychainKey() -> Data? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "find-generic-password",
            "-s", "com.xiaomi.hyperConnect.storage",
            "-a", "com.xiaomi.hyperConnect.key",
            "-g"
        ]
        process.standardError = pipe
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard let range = output.range(of: "password: 0x") else { return nil }
        let tail = output[range.upperBound...]
        let hexPart = tail.prefix(while: { $0.isHexDigit || $0 == " " })
        let hex = String(hexPart).replacingOccurrences(of: " ", with: "")
        guard let data = Data(hexString: hex), data.count == 32 else { return nil }
        return data
    }

    private static func readBE32(_ data: Data, _ offset: Int) -> UInt32 {
        let b0 = UInt32(data[data.startIndex + offset])
        let b1 = UInt32(data[data.startIndex + offset + 1])
        let b2 = UInt32(data[data.startIndex + offset + 2])
        let b3 = UInt32(data[data.startIndex + offset + 3])
        return b0 << 24 | b1 << 16 | b2 << 8 | b3
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (crc & 1 != 0 ? 0xEDB88320 : 0)
            }
        }
        return crc ^ 0xFFFFFFFF
    }
}
