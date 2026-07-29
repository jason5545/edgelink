import CryptoKit
import EdgeLinkKit
import Foundation

struct MiTrustTicketStore {
    var ticketKey: SymmetricKey?
    var identityPrivateKey: P256.Signing.PrivateKey?
    var identityPubKey: Data
    var uidHashRaw: Data
    var myKeyIndex: UInt64

    var isEnabled: Bool { ticketKey != nil && identityPrivateKey != nil && uidHashRaw.count == 32 }

    private static let defaultTicketHex = "ff86e4d9c93e1dbf02dee28117aa8cc0ba176f64eb9a5db3724caa98a6488035"
    private static let defaultIdentityPrivHex = "3c223f0237c0cdc80a273821f388bf4d9f12c05d30246baece2dbe35ec8d66ac"
    private static let defaultIdentityPubB64 = "BL/434ltP50le6fDe3X0Q3iXPo4fcf0+7H9c3P87N06fseKWnSjnsq12p22w5oZV/nLrtQyeRenyVOOdVUQqxh4="
    private static let defaultUidHashB64 = "YfJQtjvnAuNXhZmXZ8IhFjr3I4mVdX9ZgDS3U+OvBzM="

    static func current() -> MiTrustTicketStore {
        let defaults = UserDefaults.standard
        let ticketHex = defaults.string(forKey: "xiaomiTrustTicketHex") ?? defaultTicketHex
        let privHex = defaults.string(forKey: "xiaomiTrustIdentityPrivHex") ?? defaultIdentityPrivHex
        let pubB64 = defaults.string(forKey: "xiaomiTrustIdentityPubB64") ?? defaultIdentityPubB64
        let uidB64 = defaults.string(forKey: "xiaomiTrustUidHashB64") ?? defaultUidHashB64
        let storedIndex = defaults.object(forKey: "xiaomiTrustLyraKeyIndex") as? Int ?? 1

        var ticketKey: SymmetricKey?
        if let ticketData = data(fromHex: ticketHex), ticketData.count == 32 {
            ticketKey = SymmetricKey(data: ticketData)
        }
        var privateKey: P256.Signing.PrivateKey?
        if let privData = data(fromHex: privHex), let key = try? P256.Signing.PrivateKey(rawRepresentation: privData) {
            privateKey = key
        }
        return MiTrustTicketStore(
            ticketKey: ticketKey,
            identityPrivateKey: privateKey,
            identityPubKey: Data(base64Encoded: pubB64) ?? Data(),
            uidHashRaw: Data(base64Encoded: uidB64) ?? Data(),
            myKeyIndex: UInt64(max(1, storedIndex))
        )
    }

    func uidFeatureInfo() -> Data {
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

    func decryptCredBlob(_ blob: Data) -> Data? {
        guard let ticketKey, blob.count > 28 else { return nil }
        let nonce = blob.prefix(12)
        let tag = blob.suffix(16)
        let ciphertext = blob.dropFirst(12).dropLast(16)
        guard let box = try? AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: Data(nonce)),
            ciphertext: Data(ciphertext),
            tag: Data(tag)
        ) else { return nil }
        return try? AES.GCM.open(box, using: ticketKey)
    }

    func encryptLocalCred() -> Data? {
        guard let ticketKey, let identityPrivateKey else { return nil }
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
        do {
            let nonce = AES.GCM.Nonce()
            let sealed = try AES.GCM.seal(frame, using: ticketKey, nonce: nonce)
            var blob = Data()
            blob.append(contentsOf: nonce.withUnsafeBytes { Data($0) })
            blob.append(sealed.ciphertext)
            blob.append(sealed.tag)
            return blob
        } catch {
            DiagnosticsLog.error("xiaomi.cast.mitrust_cred_encrypt_failed", error)
            return nil
        }
    }

    static func data(fromHex hex: String) -> Data? {
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
