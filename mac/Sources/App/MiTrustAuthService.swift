import CryptoKit
import Foundation
import Security

final class MiTrustAuthService {
    enum Event {
        static let tlsServerHello = 593
        static let tlsClientHello = 594
        static let tlsServerKeyAck = 595
        static let bindRequest = 546
        static let bindResponse = 547
        static let statusReply = 577
        static let statusRequest = 578
        static let usingChallenge = 562
        static let usingResponse = 563
        static let usingCancel = 560
    }

    var onStatus: ((String) -> Void)?

    private let deviceIdHex: String
    private let queue = DispatchQueue(label: "edgelink.mitrust.auth", qos: .userInitiated)
    private var sessionKeyHex: String?
    private var clientHelloAt: Date?
    private var bindRequestSeen = false
    private var bindResponseSent = false
    private let sendRawJSON: (Data) -> Void

    init(deviceIdHex: String, sendRawJSON: @escaping (Data) -> Void) {
        self.deviceIdHex = deviceIdHex
        self.sendRawJSON = sendRawJSON
        dumpRegisteredPubkeys()
    }

    private func dumpRegisteredPubkeys() {
        queue.async { [weak self] in
            guard let self else { return }
            let query: [String: Any] = [
                kSecClass as String: kSecClassKey,
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
                kSecReturnAttributes as String: true,
                kSecReturnRef as String: true,
                kSecMatchLimit as String: kSecMatchLimitAll
            ]
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                  let items = result as? [[String: Any]]
            else { return }
            for item in items {
                guard let label = item[kSecAttrLabel as String] as? String,
                      label.hasPrefix("hyperconnect.trust.v2.private:\(self.deviceIdHex):"),
                      let priv = item[kSecValueRef as String] as! SecKey?,
                      let pub = SecKeyCopyPublicKey(priv),
                      let ext = SecKeyCopyExternalRepresentation(pub, nil) as Data?,
                      ext.count == 0x10E
                else { continue }
                var pubData = Data()
                Self.appendUInt32LE(&pubData, 0x100)
                pubData.append(ext[0x09..<0x109])
                Self.appendUInt32LE(&pubData, 3)
                pubData.append(ext[0x10B..<0x10E])
                var blob = Data()
                Self.appendUInt32LE(&blob, 0x33)
                Self.appendUInt32LE(&blob, UInt32(pubData.count))
                blob.append(pubData)
                let hash = SHA256.hash(data: pubData)
                DiagnosticsLog.info(
                    "xiaomi.mitrust.registered_pubkey said_prefix=\(label.suffix(16)) " +
                        "pub=\(blob.hexString) hash=\(Data(hash).hexString)"
                )
            }
        }
    }

    func handleChannelPayload(_ payload: Data) {
        queue.async { [weak self] in
            self?.handleChannelPayloadLocked(payload)
        }
    }

    private func handleChannelPayloadLocked(_ payload: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: payload),
              let message = object as? [String: Any]
        else {
            DiagnosticsLog.warn(
                "xiaomi.mitrust.rx_non_json bytes=\(payload.count) " +
                    "head=\(payload.prefix(32).map { String(format: "%02x", $0) }.joined())"
            )
            return
        }
        let errorCode = (message["error_code"] as? NSNumber)?.intValue ?? 0
        var eventName = (message["event_name"] as? NSNumber)?.intValue ?? 0
        if eventName == 0, let overrideName = (message["override_event_name"] as? NSNumber)?.intValue {
            eventName = overrideName
        }
        DiagnosticsLog.info("xiaomi.mitrust.rx event=\(eventName) error=\(errorCode) keys=\(message.keys.sorted())")
        if eventName == 0, let text = String(data: payload, encoding: .utf8) {
            DiagnosticsLog.info("xiaomi.mitrust.rx_event0_body \(text.prefix(300))")
        }
        guard errorCode == 0 else { return }
        switch eventName {
        case Event.tlsServerHello:
            handleTLSServerHello(message)
        case Event.tlsServerKeyAck:
            handleTLSClientHello(message)
        case Event.tlsClientHello:
            handleTLSServerKeyAck(message)
        case Event.bindRequest:
            handleBindRequest(message)
        case Event.bindResponse:
            DiagnosticsLog.info("xiaomi.mitrust.bind_response_rx keys=\(message.keys.sorted())")
        case Event.statusRequest:
            handleStatusRequest(message)
        case Event.usingChallenge:
            handleUsingChallenge(message)
        case Event.usingCancel:
            DiagnosticsLog.info("xiaomi.mitrust.using_cancel")
        default:
            if message["client_hello"] != nil {
                handleTLSClientHello(message)
            } else {
                DiagnosticsLog.info("xiaomi.mitrust.rx_unhandled event=\(eventName)")
            }
        }
    }

    private func handleTLSServerHello(_ message: [String: Any]) {
        guard let key = message["sessionkey"] as? String, !key.isEmpty else {
            DiagnosticsLog.warn("xiaomi.mitrust.server_hello_missing_key")
            return
        }
        sessionKeyHex = key
        DiagnosticsLog.info("xiaomi.mitrust.server_hello_rx")
        sendJSON([
            "event_name": Event.tlsClientHello,
            "sessionkey": key,
            "client_key_exchange": "client_key_exchange"
        ])
    }

    private func handleTLSClientHello(_ message: [String: Any]) {
        // The phone retransmits 595 on a short timer while our 593 is still in
        // flight. Answer those transport-level retries with the SAME session
        // key; only start a fresh session once a bind attempt (546) intervened
        // (the phone restarts the whole flow after a bind-stage reset).
        if let existing = sessionKeyHex, !bindRequestSeen,
           let at = clientHelloAt, Date().timeIntervalSince(at) < 10
        {
            DiagnosticsLog.info("xiaomi.mitrust.tls_server_hello_tx dedupe=true")
            sendJSON([
                "event_name": Event.tlsServerHello,
                "sessionkey": existing,
                "server_done": "server_done"
            ])
            return
        }
        clientHelloAt = Date()
        bindRequestSeen = false
        bindResponseSent = false
        let keyHex = Self.randomHexString(byteCount: 32)
        sessionKeyHex = keyHex
        DiagnosticsLog.info("xiaomi.mitrust.tls_server_hello_tx")
        sendJSON([
            "event_name": Event.tlsServerHello,
            "sessionkey": keyHex,
            "server_done": "server_done"
        ])
    }

    private func handleTLSServerKeyAck(_ message: [String: Any]) {
        if let key = message["sessionkey"] as? String, !key.isEmpty {
            sessionKeyHex = key
            DiagnosticsLog.info("xiaomi.mitrust.tls_sessionkey_rx")
        }
    }

    private func handleBindRequest(_ message: [String: Any]) {
        guard let saidB = message["shared_auth_id_B"] as? String, !saidB.isEmpty else {
            DiagnosticsLog.warn("xiaomi.mitrust.bind_missing_said")
            return
        }
        // The phone retransmits 546 on a short timer while our 547 is still in
        // flight. Re-answering advances a phantom bind on our side and the
        // duplicate 547 hits the phone's post-bind stage as "illegal remote
        // stage" (error 24 + full reset). Answer only the first 546 per
        // session; a genuine restart re-runs 595 first and clears this.
        bindRequestSeen = true
        guard !bindResponseSent else {
            DiagnosticsLog.info("xiaomi.mitrust.bind_request_dedupe said_prefix=\(saidB.prefix(8))")
            return
        }
        guard let sessionKeyHex, let aesKey = Self.data(fromHex: sessionKeyHex) else {
            DiagnosticsLog.warn("xiaomi.mitrust.bind_missing_session_key")
            return
        }
        guard let privateKey = generateRSAKeypair(said: saidB),
              let publicKey = SecKeyCopyPublicKey(privateKey),
              let publicExt = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?,
              publicExt.count == 0x10E
        else {
            DiagnosticsLog.error("xiaomi.mitrust.bind_keygen_failed", nil)
            return
        }
        let modulus = publicExt[0x09..<0x109]
        let exponent = publicExt[0x10B..<0x10E]
        var pub = Data()
        Self.appendUInt32LE(&pub, 0x100)
        pub.append(modulus)
        Self.appendUInt32LE(&pub, UInt32(exponent.count))
        pub.append(exponent)
        var identityPubkey = Data()
        Self.appendUInt32LE(&identityPubkey, 0x33)
        Self.appendUInt32LE(&identityPubkey, UInt32(pub.count))
        identityPubkey.append(pub)

        let plaintext: [String: Any] = [
            "shared_auth_id_A": localSaidHex(),
            "identityPubkeyA": identityPubkey.hexString,
            "pubkey_signer": "apple"
        ]
        guard let plainData = try? JSONSerialization.data(withJSONObject: plaintext) else { return }
        do {
            let cipher = try MiTrustCryptoBridge.aes256ECBEncrypt(plainData, key: aesKey)
            let cipherHex = cipher.hexString
            let hmac = HMAC<SHA256>.authenticationCode(
                for: Data(cipherHex.utf8),
                using: SymmetricKey(data: aesKey)
            )
            DiagnosticsLog.info("xiaomi.mitrust.bind_response_tx said_prefix=\(saidB.prefix(8))")
            bindResponseSent = true
            sendJSON([
                "event_name": Event.bindResponse,
                "ciphertext": cipherHex,
                "hmac": Data(hmac).hexString
            ])
        } catch {
            DiagnosticsLog.error("xiaomi.mitrust.bind_encrypt_failed", error)
        }
    }

    private func handleStatusRequest(_ message: [String: Any]) {
        let saidB = message["shared_auth_id_B"] as? String ?? ""
        if !saidB.isEmpty, let existing = rsaPrivateKey(said: saidB) {
            // One-off migration: protect an already phone-bound key that
            // predates the backup mechanism.
            if let url = rsaKeyBackupURL(said: saidB), !FileManager.default.fileExists(atPath: url.path) {
                backupRSAKeypair(existing, said: saidB)
            }
        } else if !saidB.isEmpty {
            _ = generateRSAKeypair(said: saidB)
        }
        let hasKey = saidB.isEmpty ? false : (rsaPrivateKey(said: saidB) != nil)
        var reply: [String: Any] = [
            "event_name": Event.statusReply,
            "quick_auth_version_max": 2,
            "quick_auth_version_min": 2,
            "shared_auth_id_A": localSaidHex(),
            "shared_auth_status_A": hasKey,
            "auth_support_A": true,
            "locksetting_password_type": true,
            "locksetting_strength_A": 2,
            "finger_status_A": true,
            "finger_strength_A": 2,
            "remote_password_is_support": false
        ]
        if hasKey {
            if let privateKey = rsaPrivateKey(said: saidB) {
                if let publicKey = SecKeyCopyPublicKey(privateKey) {
                    var exportError: Unmanaged<CFError>?
                    if let publicExt = SecKeyCopyExternalRepresentation(publicKey, &exportError) as Data? {
                        if publicExt.count == 0x10E {
                            var pub = Data()
                            Self.appendUInt32LE(&pub, 0x100)
                            pub.append(publicExt[0x09..<0x109])
                            Self.appendUInt32LE(&pub, 3)
                            pub.append(publicExt[0x10B..<0x10E])
                            let hash = SHA256.hash(data: pub)
                            reply["pubkey_hash_A"] = Data(hash).hexString
                            var blob = Data()
                            Self.appendUInt32LE(&blob, 0x33)
                            Self.appendUInt32LE(&blob, UInt32(pub.count))
                            blob.append(pub)
                            DiagnosticsLog.info(
                                "xiaomi.mitrust.status_reply_pubkey said_prefix=\(saidB.prefix(16)) " +
                                    "pub=\(blob.hexString) hash=\(Data(hash).hexString)"
                            )
                        } else {
                            DiagnosticsLog.warn("xiaomi.mitrust.status_pubkey_bad_size count=\(publicExt.count)")
                        }
                    } else {
                        DiagnosticsLog.error("xiaomi.mitrust.status_pubkey_export_err", exportError?.takeRetainedValue())
                    }
                } else {
                    DiagnosticsLog.warn("xiaomi.mitrust.status_pubkey_copy_failed")
                }
            } else {
                DiagnosticsLog.warn("xiaomi.mitrust.status_pubkey_no_key")
            }
        }
        DiagnosticsLog.info("xiaomi.mitrust.status_reply_tx hasKey=\(hasKey)")
        sendJSON(reply)
    }

    private func handleUsingChallenge(_ message: [String: Any]) {
        guard let saidB = message["shared_auth_id_B"] as? String, !saidB.isEmpty,
              let tokenBHex = message["auth_token_B"] as? String,
              let tokenB = Self.data(fromHex: tokenBHex),
              let challenge = Self.extractTLVEntry(tokenB, tag: 0x12)
        else {
            DiagnosticsLog.warn("xiaomi.mitrust.using_bad_challenge")
            return
        }
        guard let privateKey = rsaPrivateKey(said: saidB) else {
            DiagnosticsLog.warn("xiaomi.mitrust.using_no_keypair said_prefix=\(saidB.prefix(8))")
            DiagnosticsLog.info("xiaomi.mitrust.client_hello_tx")
            sendJSON(["event_name": Event.tlsServerKeyAck, "client_hello": "client_hello"])
            return
        }
        let authType = (message["auth_type"] as? NSNumber)?.intValue ?? -1
        let authLevel = (message["auth_level"] as? NSNumber)?.intValue ?? -1
        DiagnosticsLog.info("xiaomi.mitrust.using_challenge_rx auth_type=\(authType) auth_level=\(authLevel)")

        sendJSON(["event_name": Event.usingResponse, "flash_timestamp": true])

        var token = Data([0x05])
        Self.appendTLV(&token, tag: 0x10, value: localSaidRaw())
        Self.appendTLV(&token, tag: 0x11, value: Data([0x02]))
        Self.appendTLV(&token, tag: 0x12, value: challenge)
        Self.appendTLV(&token, tag: 0x13, value: Data([0x30]))
        var signError: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            token as CFData,
            &signError
        ) as Data? else {
            DiagnosticsLog.error("xiaomi.mitrust.using_sign_failed", signError?.takeRetainedValue())
            return
        }
        Self.appendTLV(&token, tag: 0x01, value: signature)
        DiagnosticsLog.info("xiaomi.mitrust.using_token_a_tx token_bytes=\(token.count)")
        sendJSON(["event_name": Event.usingResponse, "auth_token_A": token.hexString])
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        sendRawJSON(data)
    }

    private func localSaidRaw() -> Data {
        let material = trustDeviceUUID() + "61F2" + deviceIdHex
        return Data(SHA256.hash(data: Data(material.utf8)))
    }

    private func localSaidHex() -> String {
        localSaidRaw().hexString
    }

    private func trustDeviceUUID() -> String {
        if let override = UserDefaults.standard.string(forKey: "xiaomiTrustDeviceUUID"),
           !override.isEmpty
        {
            return override
        }
        let service = "com.edgelink.mac"
        let account = "trust_service.mi.device_key"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true
        ]
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data,
           let uuid = String(data: data, encoding: .utf8)
        {
            return uuid
        }
        let uuid = UUID().uuidString
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(uuid.utf8)
        ]
        SecItemAdd(add as CFDictionary, nil)
        return uuid
    }

    private func rsaKeyLabel(said: String, isPrivate: Bool) -> String {
        let kind = isPrivate ? "private" : "public"
        return "hyperconnect.trust.v2.\(kind):\(deviceIdHex):\(said.prefix(16))"
    }

    private func rsaPrivateKey(said: String) -> SecKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrLabel as String: rsaKeyLabel(said: said, isPrivate: true),
            kSecReturnRef as String: true
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return (result as! SecKey)
    }

    // The phone binds this pubkey into its TA at TDIF bind time. Regenerating
    // on a transient keychain miss (rebuild/reinstall changing the item's
    // effective ACL) silently changes the pubkey and the phone starts killing
    // the mirror ~1s after OPEN (2026-08-03 incident). Keep an exported copy
    // in the app container and restore it instead of rolling the key.
    private func rsaKeyBackupURL(said: String) -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base
            .appendingPathComponent("EdgeLink/trust-keys", isDirectory: true)
            .appendingPathComponent("\(rsaKeyLabel(said: said, isPrivate: true)).key")
    }

    private func restoreRSAKeypairFromBackup(said: String) -> SecKey? {
        guard let url = rsaKeyBackupURL(said: said),
              let data = try? Data(contentsOf: url)
        else { return nil }
        for isPrivate in [true, false] {
            let delete: [String: Any] = [
                kSecClass as String: kSecClassKey,
                kSecAttrLabel as String: rsaKeyLabel(said: said, isPrivate: isPrivate)
            ]
            SecItemDelete(delete as CFDictionary)
        }
        let add: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 2048,
            kSecAttrIsPermanent as String: true,
            kSecAttrLabel as String: rsaKeyLabel(said: said, isPrivate: true),
            kSecValueData as String: data
        ]
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess,
              let restored = rsaPrivateKey(said: said)
        else { return nil }
        DiagnosticsLog.info("xiaomi.mitrust.rsa_key_restored_from_backup said_prefix=\(said.prefix(8))")
        return restored
    }

    private func backupRSAKeypair(_ key: SecKey, said: String) {
        guard let url = rsaKeyBackupURL(said: said) else { return }
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(key, &error) as? Data else {
            DiagnosticsLog.error("xiaomi.mitrust.rsa_key_backup_export_failed", error?.takeRetainedValue())
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            DiagnosticsLog.error("xiaomi.mitrust.rsa_key_backup_write_failed", error)
        }
    }

    private func generateRSAKeypair(said: String) -> SecKey? {
        if rsaPrivateKey(said: said) == nil,
           let restored = restoreRSAKeypairFromBackup(said: said)
        {
            return restored
        }
        for isPrivate in [true, false] {
            let delete: [String: Any] = [
                kSecClass as String: kSecClassKey,
                kSecAttrLabel as String: rsaKeyLabel(said: said, isPrivate: isPrivate)
            ]
            SecItemDelete(delete as CFDictionary)
        }
        let privateAttrs: [String: Any] = [
            kSecAttrIsPermanent as String: true,
            kSecAttrLabel as String: rsaKeyLabel(said: said, isPrivate: true)
        ]
        let publicAttrs: [String: Any] = [
            kSecAttrIsPermanent as String: true,
            kSecAttrLabel as String: rsaKeyLabel(said: said, isPrivate: false)
        ]
        let params: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: privateAttrs,
            kSecPublicKeyAttrs as String: publicAttrs
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(params as CFDictionary, &error) else {
            DiagnosticsLog.error("xiaomi.mitrust.keygen_failed", error?.takeRetainedValue())
            return nil
        }
        var signError: Unmanaged<CFError>?
        _ = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data("warmup".utf8) as CFData, &signError)
        backupRSAKeypair(key, said: said)
        return key
    }

    private static func appendUInt32LE(_ data: inout Data, _ value: UInt32) {
        var le = value.littleEndian
        data.append(Data(bytes: &le, count: 4))
    }

    private static func appendTLV(_ data: inout Data, tag: UInt8, value: Data) {
        data.append(tag)
        appendUInt32LE(&data, UInt32(value.count))
        data.append(value)
    }

    private static func extractTLVEntry(_ tlv: Data, tag: UInt8) -> Data? {
        guard tlv.count > 1 else { return nil }
        let count = Int(tlv[tlv.startIndex])
        var offset = tlv.index(after: tlv.startIndex)
        for _ in 0..<count {
            guard tlv.distance(from: offset, to: tlv.endIndex) >= 5 else { return nil }
            let entryTag = tlv[offset]
            let lengthOffset = tlv.index(after: offset)
            let length = Int(tlv[lengthOffset])
                | Int(tlv[tlv.index(after: lengthOffset)]) << 8
                | Int(tlv[tlv.index(lengthOffset, offsetBy: 2)]) << 16
                | Int(tlv[tlv.index(lengthOffset, offsetBy: 3)]) << 24
            let valueStart = tlv.index(lengthOffset, offsetBy: 4)
            guard tlv.distance(from: valueStart, to: tlv.endIndex) >= length else { return nil }
            let valueEnd = tlv.index(valueStart, offsetBy: length)
            if entryTag == tag {
                return Data(tlv[valueStart..<valueEnd])
            }
            offset = valueEnd
        }
        return nil
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

    private static func randomHexString(byteCount: Int) -> String {
        var data = Data(count: byteCount)
        data.withUnsafeMutableBytes { buffer in
            if let baseAddress = buffer.baseAddress {
                arc4random_buf(baseAddress, byteCount)
            }
        }
        return data.hexString
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
