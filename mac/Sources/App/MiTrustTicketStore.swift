import CryptoKit
import EdgeLinkKit
import Foundation
import Security

struct MiTrustTicketStore {
    var ticketKey: SymmetricKey?
    var sessionKey: SymmetricKey?
    var identityPrivateKey: P256.Signing.PrivateKey?
    var identityPubKey: Data
    var peerIdentityPubKey: Data
    var peerAccountPubKey: Data
    var uidHashRaw: Data
    var myKeyIndex: UInt64
    var deviceKeyData: Data?

    // Identity keys the phone signs AuthHandshake messages with, account
    // identity (from its Mijia cert, auth_type 4 flows) first, then the
    // pairing identity. Live 2026-08-05: the sync task's client_finished
    // verifies as ECDSA-SHA256(clientEph||serverEph) under the account key,
    // not the pairing key.
    var peerSigningPubKeys: [Data] {
        var keys: [Data] = []
        for key in [peerAccountPubKey, peerIdentityPubKey] where !key.isEmpty && !keys.contains(key) {
            keys.append(key)
        }
        return keys
    }

    var deviceKey: SymmetricKey? {
        guard let deviceKeyData, deviceKeyData.count == 32 else { return nil }
        return SymmetricKey(data: deviceKeyData)
    }

    var isEnabled: Bool { ticketKey != nil && identityPrivateKey != nil && uidHashRaw.count == 32 }

    private static let defaultTicketHex = "ff86e4d9c93e1dbf02dee28117aa8cc0ba176f64eb9a5db3724caa98a6488035"
    private static let defaultIdentityPrivHex = "3c223f0237c0cdc80a273821f388bf4d9f12c05d30246baece2dbe35ec8d66ac"
    private static let defaultIdentityPubB64 = "BL/434ltP50le6fDe3X0Q3iXPo4fcf0+7H9c3P87N06fseKWnSjnsq12p22w5oZV/nLrtQyeRenyVOOdVUQqxh4="
    private static let defaultPeerIdentityPubB64 = "BOMwUyQxPI0I8U3hu4lgsVuriQYrGzfHOraILCbIEJh+KxmzF60/FF7Eby8T96F0xJTOFE8b1aLirmUTGsOcq6I="
    private static let defaultPeerAccountPubB64 = "BKIsluyxd6HMPgN8hZcr0EghStRCwbUgTubsTNXmBfsQfbaf0+2WLL+Hf5xeb4XfVzED0MxC7rvMC9fP0CSkRhs="
    private static let defaultUidHashB64 = "YfJQtjvnAuNXhZmXZ8IhFjr3I4mVdX9ZgDS3U+OvBzM="

    static func current() -> MiTrustTicketStore {
        let defaults = UserDefaults.standard
        let ticketHex = defaults.string(forKey: "xiaomiTrustTicketHex") ?? defaultTicketHex
        let sessionHex = defaults.string(forKey: "xiaomiTrustSessionKeyHex") ?? ""
        let privHex = defaults.string(forKey: "xiaomiTrustIdentityPrivHex") ?? defaultIdentityPrivHex
        let pubB64 = defaults.string(forKey: "xiaomiTrustIdentityPubB64") ?? defaultIdentityPubB64
        let peerPubB64 = defaults.string(forKey: "xiaomiTrustPeerIdentityPubB64") ?? defaultPeerIdentityPubB64
        let peerAccountB64 = defaults.string(forKey: "xiaomiTrustPeerAccountPubB64") ?? defaultPeerAccountPubB64
        let uidB64 = defaults.string(forKey: "xiaomiTrustUidHashB64") ?? defaultUidHashB64
        let storedIndex = defaults.object(forKey: "xiaomiTrustLyraKeyIndex") as? Int ?? 1

        var ticketKey: SymmetricKey?
        if let ticketData = data(fromHex: ticketHex), ticketData.count == 32 {
            ticketKey = SymmetricKey(data: ticketData)
        }
        var sessionKey: SymmetricKey?
        if let sessionData = data(fromHex: sessionHex), sessionData.count == 32 {
            sessionKey = SymmetricKey(data: sessionData)
        }
        var privateKey: P256.Signing.PrivateKey?
        if let privData = data(fromHex: privHex), let key = try? P256.Signing.PrivateKey(rawRepresentation: privData) {
            privateKey = key
        }
        return MiTrustTicketStore(
            ticketKey: ticketKey,
            sessionKey: sessionKey,
            identityPrivateKey: privateKey,
            identityPubKey: Data(base64Encoded: pubB64) ?? Data(),
            peerIdentityPubKey: Data(base64Encoded: peerPubB64) ?? Data(),
            peerAccountPubKey: Data(base64Encoded: peerAccountB64) ?? Data(),
            uidHashRaw: Data(base64Encoded: uidB64) ?? Data(),
            myKeyIndex: UInt64(max(1, storedIndex)),
            deviceKeyData: deviceKeyData(defaults: defaults)
        )
    }

    // Harvests the phone's account identity pubkey from an inbound sync
    // payload (its TrustedDeviceInfo f15 cert cred carries the Mijia-issued
    // identity cert). Persisted under xiaomiTrustPeerAccountPubB64.
    @discardableResult
    static func harvestPeerAccountPubKey(fromSyncPayload payload: Data) -> Bool {
        guard let pub = LyraIdentityCert.pubKey(fromSyncPayload: payload),
              pub != current().peerAccountPubKey
        else { return false }
        UserDefaults.standard.set(pub.base64EncodedString(), forKey: "xiaomiTrustPeerAccountPubB64")
        DiagnosticsLog.info("xiaomi.trust.peer_account_pub_harvested bytes=\(pub.count)")
        return true
    }

    // Persistent 32-byte device key, advertised as TrustedDeviceInfo f13 (the
    // officially paired Mac and the phone both carry one in their DevRepo
    // entries). The phone's DeviceKeyManager resolves it for auth reuse —
    // without it the sync task's quick-conn dial dies at "key is null" and the
    // full-handshake fallback at "client not have device key".
    private static func deviceKeyData(defaults: UserDefaults) -> Data? {
        if let hex = defaults.string(forKey: "xiaomiTrustDeviceKeyHex"),
           let data = data(fromHex: hex), data.count == 32 {
            return data
        }
        var generated = Data(count: 32)
        generated.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress { arc4random_buf(base, 32) }
        }
        defaults.set(generated.map { String(format: "%02x", $0) }.joined(), forKey: "xiaomiTrustDeviceKeyHex")
        return generated
    }

    static func recordAuthSession(sessionKey: Data, ticket: Data) {
        lastAuthSessionKeyData = sessionKey
        let defaults = UserDefaults.standard
        defaults.set(sessionKey.map { String(format: "%02x", $0) }.joined(), forKey: "xiaomiTrustSessionKeyHex")
        defaults.set(ticket.map { String(format: "%02x", $0) }.joined(), forKey: "xiaomiTrustTicketHex")
        DiagnosticsLog.info("xiaomi.cast.mitrust_auth_session_saved")
    }

    // Most recent AuthHandshake session key, shared in-process so the mesh
    // responder can decrypt quick-conn private_data addressed to us.
    static var lastAuthSessionKeyData: Data?

    // Test hook: overrides the enrolled-cert lookup in certCredBlock().
    static var enrolledCertOverride: (() -> MijiaEnrolledCert?)?

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
        decryptCredBlobWithKey(blob)?.plaintext
    }

    func decryptCredBlobWithKey(_ blob: Data) -> (plaintext: Data, key: SymmetricKey)? {
        for key in [sessionKey, ticketKey, deviceKey].compactMap({ $0 }) {
            if let plain = decrypt(blob, with: key) { return (plain, key) }
        }
        return nil
    }

    // TrustedDeviceInfo f15 cert-cred block, mirroring the phone's own sync
    // push: two entries, each {f1:3, f4:{nonce32, cert DER, ECDSA-SHA256
    // sig(nonce)}} carrying the device identity cert. The phone's
    // HandleSyncDevMsg only runs CheckSharedCred/CheckCertCred (which stamps
    // the conn trusted type) when f15 is present. Cert provenance: our own
    // Mijia-enrolled cert (MijiaEnrolledCertStore, did must match the current
    // full device id) first; the UserDefaults injection of officially issued
    // material (xiaomiTrustCredCertHex / xiaomiTrustCredPrivHex) is the
    // fallback until enrollment has proven out on-device.
    func certCredBlock() -> Data? {
        let cert: Data
        let priv: P256.Signing.PrivateKey
        let shortId = MijiaCertEnrollment.currentShortDeviceIdHex
        let enrolledLookup = MiTrustTicketStore.enrolledCertOverride ?? {
            guard let did = MijiaCertEnrollment.currentDid(shortDeviceIdHex: shortId) else { return nil }
            return MijiaEnrolledCertStore.usableCert(forDid: did)
        }
        if let enrolled = enrolledLookup(),
           let enrolledCert = enrolled.certDER,
           let enrolledPrivRaw = enrolled.privateKeyRaw,
           let enrolledPriv = try? P256.Signing.PrivateKey(rawRepresentation: enrolledPrivRaw) {
            cert = enrolledCert
            priv = enrolledPriv
        } else {
            let defaults = UserDefaults.standard
            guard let certHex = defaults.string(forKey: "xiaomiTrustCredCertHex"),
                  let injectedCert = MiTrustTicketStore.data(fromHex: certHex),
                  let privHex = defaults.string(forKey: "xiaomiTrustCredPrivHex"),
                  let privData = MiTrustTicketStore.data(fromHex: privHex),
                  let injectedPriv = try? P256.Signing.PrivateKey(rawRepresentation: privData)
            else { return nil }
            cert = injectedCert
            priv = injectedPriv
        }
        var block = Data()
        LyraProtoWriter.appendVarintField(1, value: 9, to: &block)
        for fieldNumber in [3, 5] {
            var nonce = Data(count: 32)
            nonce.withUnsafeMutableBytes { buffer in
                if let base = buffer.baseAddress { arc4random_buf(base, 32) }
            }
            guard let signature = try? priv.signature(for: nonce) else { return nil }
            var cred = Data()
            LyraProtoWriter.appendLengthDelimitedField(1, value: nonce, to: &cred)
            LyraProtoWriter.appendLengthDelimitedField(2, value: cert, to: &cred)
            LyraProtoWriter.appendLengthDelimitedField(3, value: signature.derRepresentation, to: &cred)
            var entry = Data()
            LyraProtoWriter.appendVarintField(1, value: 3, to: &entry)
            LyraProtoWriter.appendLengthDelimitedField(4, value: cred, to: &entry)
            LyraProtoWriter.appendLengthDelimitedField(fieldNumber, value: entry, to: &block)
        }
        return block
    }

    func decrypt(_ blob: Data, with key: SymmetricKey) -> Data? {
        guard blob.count > 28 else { return nil }
        let nonce = blob.prefix(12)
        let tag = blob.suffix(16)
        let ciphertext = blob.dropFirst(12).dropLast(16)
        guard let box = try? AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: Data(nonce)),
            ciphertext: Data(ciphertext),
            tag: Data(tag)
        ) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }

    func encryptLocalCred() -> Data? {
        guard let identityPrivateKey else { return nil }
        let key = sessionKey ?? ticketKey
        guard let key else { return nil }
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
            let sealed = try AES.GCM.seal(frame, using: key, nonce: nonce)
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

// Extracts the device identity cert's P-256 public key from a sync payload:
// scans for DER-encoded X.509 certs (30 82 <len16>) and returns the first
// cert's key in x9.63 form (65 bytes, 0x04 prefix).
enum LyraIdentityCert {
    static func pubKey(fromSyncPayload payload: Data) -> Data? {
        var index = payload.startIndex
        while index + 4 <= payload.endIndex {
            defer { index += 1 }
            guard payload[index] == 0x30, payload[index + 1] == 0x82 else { continue }
            let length = (Int(payload[index + 2]) << 8) | Int(payload[index + 3])
            let end = index + 4 + length
            guard length > 0, end <= payload.endIndex else { continue }
            let der = payload[index..<end]
            guard let cert = SecCertificateCreateWithData(nil, Data(der) as CFData),
                  let key = SecCertificateCopyKey(cert),
                  let rep = SecKeyCopyExternalRepresentation(key, nil) as? Data,
                  rep.count == 65, rep.first == 0x04
            else { continue }
            return rep
        }
        return nil
    }
}
