import CryptoKit
import EdgeLinkKit
import Foundation
import Security

// Clean-room Mijia identity-cert enrollment (replaces the injected official-Mac
// cert3). Reverse-engineered from the official client's GetMiJiaThirdClassCert
// (micontinuity_sdk) and the phone's Java signer (MiConnectService r3/b.java),
// then proven live against the real server 2026-08-05 (see
// edgelink-cleanroom-cert-enrollment-breakthrough-2026-08-05):
//
//   POST https://idm.api.io.mi.com/app/appgateway/miot/miconnect_server/MiconnectService/common/lyra/getCert
//   body (AES-GCM encrypted JSON): {did, deviceType, csr, uniDid, preDid, preUid}
//   CSR subject: CN=lyra.<uid>.<did>.<deviceType> where
//     did = base64url(32-byte full device id)
//     uid = base64url(SHA256(did + numericAccountId))   (no padding)
//   The phone's CheckCertCred recomputes uid from our cert's did the same way,
//   so an enrolled cert passes with zero phone-side changes.
//
// Xiaomi rejects CN through openssl/RFC-compliant builders (>64 chars); the CSR
// DER is hand-assembled like the official client's mbedtls path.

// MARK: - Account token (sid "miconnect")

struct MijiaAccountToken: Codable, Equatable, Sendable {
    var cUserId: String
    var serviceToken: String
    var ssecurity: String
    var accountNumericId: String
    var fetchedAt: Date

    var isComplete: Bool {
        !cUserId.isEmpty && !serviceToken.isEmpty && !ssecurity.isEmpty && !accountNumericId.isEmpty
    }
}

// Keychain-first token store. UserDefaults keys act as the harvest-injection
// path (tools/harvest-miconnect-token.sh writes them from the phone's
// accounts_ce.db via adb root); a Keychain copy wins when present.
enum MijiaAccountTokenStore {
    private static let service = "com.edgelink.mijia.account"
    private static let account = "miconnect-token"

    static func load(defaults: UserDefaults = .standard) -> MijiaAccountToken? {
        if let stored = loadKeychain() { return stored }
        return loadDefaults(defaults)
    }

    static func save(_ token: MijiaAccountToken) throws {
        let data = try JSONEncoder().encode(token)
        let base = baseQuery()
        SecItemDelete(base as CFDictionary)
        var query = base
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw MijiaEnrollmentError.keychain(status) }
    }

    static func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    static func importFromDefaults(_ defaults: UserDefaults = .standard) throws -> MijiaAccountToken? {
        guard let token = loadDefaults(defaults) else { return nil }
        try save(token)
        return token
    }

    private static func loadKeychain() -> MijiaAccountToken? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let token = try? JSONDecoder().decode(MijiaAccountToken.self, from: data),
              token.isComplete
        else { return nil }
        return token
    }

    private static func loadDefaults(_ defaults: UserDefaults) -> MijiaAccountToken? {
        guard let cUserId = defaults.string(forKey: "xiaomiMijiaCUserId"), !cUserId.isEmpty,
              let serviceToken = defaults.string(forKey: "xiaomiMijiaServiceToken"), !serviceToken.isEmpty,
              let ssecurity = defaults.string(forKey: "xiaomiMijiaSSecurity"), !ssecurity.isEmpty
        else { return nil }
        let numericId = defaults.string(forKey: "xiaomiMijiaAccountNumericId") ?? ""
        return MijiaAccountToken(
            cUserId: cUserId,
            serviceToken: serviceToken,
            ssecurity: ssecurity,
            accountNumericId: numericId,
            fetchedAt: Date(timeIntervalSince1970: defaults.double(forKey: "xiaomiMijiaTokenFetchedAt"))
        )
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

// MARK: - Enrolled cert store

struct MijiaEnrolledCert: Codable, Equatable, Sendable {
    var certDERBase64: String
    var privateKeyBase64: String
    var did: String
    var enrolledAt: Date

    var certDER: Data? { Data(base64Encoded: certDERBase64) }
    var privateKeyRaw: Data? { Data(base64Encoded: privateKeyBase64) }
}

enum MijiaEnrolledCertStore {
    private static let service = "com.edgelink.mijia.account"
    private static let account = "enrolled-cert"

    static func load() -> MijiaEnrolledCert? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let cert = try? JSONDecoder().decode(MijiaEnrolledCert.self, from: data)
        else { return nil }
        return cert
    }

    static func save(_ cert: MijiaEnrolledCert) throws {
        let data = try JSONEncoder().encode(cert)
        let base = baseQuery()
        SecItemDelete(base as CFDictionary)
        var query = base
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw MijiaEnrollmentError.keychain(status) }
    }

    static func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    // The enrolled cert is usable when it parses, is inside its validity
    // window (with margin), and its did still matches our current full device
    // id (identity key or clone id rotation requires re-enrollment).
    static func usableCert(forDid did: String, now: Date = Date()) -> MijiaEnrolledCert? {
        guard let stored = load(), stored.did == did, let der = stored.certDER,
              let secCert = SecCertificateCreateWithData(nil, der as CFData)
        else { return nil }
        if let notAfter = MijiaCertEnrollment.certNotAfter(secCert), notAfter.timeIntervalSince(now) < 14 * 86400 {
            return nil
        }
        return stored
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

// MARK: - Errors

enum MijiaEnrollmentError: Error, Equatable {
    case tokenIncomplete
    case badResponse(String)
    case httpStatus(Int, String)
    case serverError(Int, String)
    case certMissing
    case keychain(OSStatus)
    case csrFailed
}

// MARK: - CSR + uid/did derivation

enum MijiaCSR {
    // did = base64url(32-byte full device id), no padding.
    static func did(fullDeviceId: Data) -> String {
        base64URLEncode(fullDeviceId)
    }

    // uid = base64url(SHA256(did + numericAccountId)), no padding. Verified
    // against both live certs: Mac (hoht3Zns...) and phone (WF4nEgxA...).
    static func uid(did: String, accountNumericId: String) -> String {
        base64URLEncode(Data(SHA256.hash(data: Data((did + accountNumericId).utf8))))
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // PKCS#10 with subject CN=lyra.<uid>.<did>.<deviceType>, ECDSA-SHA256.
    static func build(uid: String, did: String, deviceType: UInt32, key: P256.Signing.PrivateKey) throws -> Data {
        let cn = "lyra.\(uid).\(did).\(deviceType)"
        let pub = key.publicKey.x963Representation
        var spkiInner = Data()
        spkiInner.append(contentsOf: [0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]) // ecPublicKey
        spkiInner.append(contentsOf: [0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]) // prime256v1
        let spki = derSeq(derSeq(spkiInner) + derBitString(pub))
        let atv = derSeq(Data([0x06, 0x03, 0x55, 0x04, 0x03]) + derUTF8(cn))
        let subject = derSeq(derSet(atv))
        var cri = Data()
        cri.append(derInteger(0))
        cri.append(subject)
        cri.append(spki)
        cri.append(contentsOf: [0xA0, 0x00]) // attributes [0] empty
        let criSeq = derSeq(cri)
        let signature = try key.signature(for: criSeq)
        var csr = Data()
        csr.append(criSeq)
        csr.append(derSeq(Data([0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02]))) // ecdsa-with-SHA256
        csr.append(derBitString(signature.derRepresentation))
        return derSeq(csr)
    }

    static func pem(der: Data) -> String {
        let b64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        let terminated = b64.hasSuffix("\n") ? b64 : b64 + "\n"
        return "-----BEGIN CERTIFICATE REQUEST-----\n" + terminated + "-----END CERTIFICATE REQUEST-----\n"
    }

    static func derLength(_ n: Int) -> Data {
        if n < 0x80 { return Data([UInt8(n)]) }
        var bytes = [UInt8]()
        var value = n
        while value > 0 { bytes.insert(UInt8(value & 0xFF), at: 0); value >>= 8 }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    static func der(_ tag: UInt8, _ content: Data) -> Data {
        Data([tag]) + derLength(content.count) + content
    }

    static func derSeq(_ content: Data) -> Data { der(0x30, content) }
    static func derSet(_ content: Data) -> Data { der(0x31, content) }
    static func derInteger(_ value: UInt8) -> Data { der(0x02, Data([value])) }
    static func derUTF8(_ string: String) -> Data { der(0x0C, Data(string.utf8)) }
    static func derBitString(_ data: Data) -> Data { der(0x03, Data([0x00]) + data) }
}

// MARK: - IDM request signing/encryption (miot style)

struct MijiaIDMRequest {
    var formFields: [String: String]
    var sessionKey: Data
}

enum MijiaIDMSigner {
    static let getCertPath = "/appgateway/miot/miconnect_server/MiconnectService/common/lyra/getCert"
    static let getCertURL = "https://idm.api.io.mi.com/app" + getCertPath

    static func randomNonce(now: Date = Date()) -> (bytes: Data, b64: String) {
        var bytes = Data(count: 12)
        bytes.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress { arc4random_buf(base, 12) }
        }
        var minutes = UInt32(now.timeIntervalSince1970 / 60).bigEndian
        withUnsafeBytes(of: &minutes) { bytes.replaceSubrange(8..<12, with: $0) }
        return (bytes, bytes.base64EncodedString())
    }

    static func sessionKey(ssecurity: String, nonceBytes: Data) -> Data? {
        guard let secret = Data(base64Encoded: ssecurity) else { return nil }
        return Data(SHA256.hash(data: secret + nonceBytes))
    }

    static func randomRC4Hash() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0..<10).compactMap { _ in alphabet.randomElement() })
    }

    // signature = base64(SHA256("POST&"+path+"&data="+data+"&rc4_hash__="+rc4+"&"+sessionSecurityB64))
    static func signature(path: String, data: String, rc4Hash: String, sessionKey: Data) -> String {
        let sessionSecurity = sessionKey.base64EncodedString()
        let content = "POST&\(path)&data=\(data)&rc4_hash__=\(rc4Hash)&\(sessionSecurity)"
        return Data(SHA256.hash(data: Data(content.utf8))).base64EncodedString()
    }

    // Builds the encrypted/signed form fields for a JSON body. nonce/iv/rc4 are
    // injectable for tests.
    static func buildRequest(
        path: String,
        jsonBody: String,
        ssecurity: String,
        nonceBytes: Data? = nil,
        iv: Data? = nil,
        rc4Hash: String? = nil
    ) -> MijiaIDMRequest? {
        let nonce = nonceBytes.map { (bytes: $0, b64: $0.base64EncodedString()) } ?? randomNonce()
        guard let sessionKey = sessionKey(ssecurity: ssecurity, nonceBytes: nonce.bytes) else { return nil }
        let gcmNonce = (iv ?? Data((0..<12).map { _ in UInt8.random(in: 0...255) }))
        guard let sealed = try? AES.GCM.seal(
            Data(jsonBody.utf8),
            using: SymmetricKey(data: sessionKey),
            nonce: AES.GCM.Nonce(data: gcmNonce)
        ) else { return nil }
        let data = (gcmNonce + sealed.ciphertext + sealed.tag).base64EncodedString()
        let rc4 = rc4Hash ?? randomRC4Hash()
        let sign = signature(path: path, data: data, rc4Hash: rc4, sessionKey: sessionKey)
        return MijiaIDMRequest(
            formFields: [
                "data": data,
                "_nonce": nonce.b64,
                "signature": sign,
                "rc4_hash__": rc4
            ],
            sessionKey: sessionKey
        )
    }

    static func decryptResponse(_ body: Data, sessionKey: Data) -> Data? {
        guard let decoded = Data(base64Encoded: body), decoded.count > 28 else { return nil }
        let nonce = decoded.prefix(12)
        let tag = decoded.suffix(16)
        let ciphertext = decoded.dropFirst(12).dropLast(16)
        guard let box = try? AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: Data(nonce)),
            ciphertext: Data(ciphertext),
            tag: Data(tag)
        ) else { return nil }
        return try? AES.GCM.open(box, using: SymmetricKey(data: sessionKey))
    }
}

// MARK: - HTTP layer (injectable for tests)

protocol MijiaIDMHTTPClient: Sendable {
    func post(url: URL, headers: [String: String], formFields: [String: String]) async throws -> (status: Int, body: Data)
}

struct MijiaURLSessionHTTPClient: MijiaIDMHTTPClient {
    func post(url: URL, headers: [String: String], formFields: [String: String]) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let encoded = formFields
            .map { key, value in
                "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value)"
            }
            .sorted()
            .joined(separator: "&")
        request.httpBody = Data(encoded.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        return (status, data)
    }
}

// MARK: - Enrollment orchestrator

enum MijiaCertEnrollment {
    static let deviceType: UInt32 = 14

    struct Outcome: Equatable, Sendable {
        var certDER: Data
        var certSubject: String
        var notAfter: Date?
    }

    // Full enrollment round: new P-256 key, CSR, signed/encrypted POST, cert
    // parse + sanity checks. Returns the issued cert; caller persists.
    static func enroll(
        token: MijiaAccountToken,
        did: String,
        devName: String,
        http: MijiaIDMHTTPClient = MijiaURLSessionHTTPClient(),
        keyGenerator: () -> P256.Signing.PrivateKey = { P256.Signing.PrivateKey() }
    ) async throws -> (outcome: Outcome, privateKey: P256.Signing.PrivateKey) {
        guard token.isComplete else { throw MijiaEnrollmentError.tokenIncomplete }
        let key = keyGenerator()
        let uid = MijiaCSR.uid(did: did, accountNumericId: token.accountNumericId)
        let csrDER = try MijiaCSR.build(uid: uid, did: did, deviceType: deviceType, key: key)
        // Field order matches the proven live request (JSON objects are
        // unordered, but stay byte-close to the official client).
        let bodyString = "{\"did\":\"\(did)\",\"deviceType\":\(deviceType),\"csr\":\(jsonString(MijiaCSR.pem(der: csrDER))),\"uniDid\":\"\",\"preDid\":\"\",\"preUid\":0}"
        guard let request = MijiaIDMSigner.buildRequest(
            path: MijiaIDMSigner.getCertPath,
            jsonBody: bodyString,
            ssecurity: token.ssecurity
        )
        else { throw MijiaEnrollmentError.badResponse("request build failed") }
        let headers = [
            "User-Agent": "IDM",
            "Content-Type": "application/x-www-form-urlencoded",
            "X-XIAOMI-PROTOCAL-FLAG": "PROTOCAL-HTTPS",
            "MIOT-ENCRYPT-ALGORITHM": "ENCRYPT-AES",
            "SHA-ALGORITHM": "HASH-SHA256",
            "Cookie": "cUserId=\(token.cUserId);serviceToken=\(token.serviceToken)"
        ]
        guard let url = URL(string: MijiaIDMSigner.getCertURL) else {
            throw MijiaEnrollmentError.badResponse("bad url")
        }
        let response = try await http.post(url: url, headers: headers, formFields: request.formFields)
        guard response.status == 200 else {
            let text = String(data: response.body, encoding: .utf8) ?? ""
            if let code = extractCode(text) {
                throw MijiaEnrollmentError.serverError(code, String(text.prefix(160)))
            }
            throw MijiaEnrollmentError.httpStatus(response.status, String(text.prefix(160)))
        }
        guard let plaintext = MijiaIDMSigner.decryptResponse(response.body, sessionKey: request.sessionKey),
              let json = try? JSONSerialization.jsonObject(with: plaintext) as? [String: Any],
              let code = json["code"] as? Int
        else { throw MijiaEnrollmentError.badResponse("decrypt/parse failed") }
        guard code == 0,
              let result = json["result"] as? [String: Any],
              let certPEM = result["cert"] as? String,
              let certDER = derFromPEM(certPEM)
        else {
            let message = (json["message"] as? String) ?? "no cert"
            throw MijiaEnrollmentError.serverError(code, String(message.prefix(160)))
        }
        guard let secCert = SecCertificateCreateWithData(nil, certDER as CFData),
              let publicKey = SecCertificateCopyKey(secCert),
              let x963 = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?,
              x963 == key.publicKey.x963Representation
        else { throw MijiaEnrollmentError.badResponse("cert key mismatch") }
        let subject = SecCertificateCopySubjectSummary(secCert) as String? ?? ""
        return (Outcome(certDER: certDER, certSubject: subject, notAfter: certNotAfter(secCert)), key)
    }

    static func certNotAfter(_ cert: SecCertificate) -> Date? {
        var error: Unmanaged<CFError>?
        guard let values = SecCertificateCopyValues(cert, [kSecOIDX509V1ValidityNotAfter] as CFArray, &error) as? [CFString: Any],
              let entry = values[kSecOIDX509V1ValidityNotAfter] as? [String: Any],
              let seconds = entry[kSecPropertyKeyValue as String] as? Double
        else { return nil }
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    static func derFromPEM(_ pem: String) -> Data? {
        let lines = pem.split(separator: "\n").map(String.init)
        guard lines.first?.contains("BEGIN CERTIFICATE") == true else { return nil }
        let base64 = lines.filter { !$0.hasPrefix("-") }.joined()
        return Data(base64Encoded: base64)
    }

    static func jsonString(_ value: String) -> String {
        var escaped = ""
        for character in value {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default: escaped.append(character)
            }
        }
        return "\"\(escaped)\""
    }

    private static func extractCode(_ text: String) -> Int? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["code"] as? Int
    }

    // did for the current app identity (clone short id + identity pubkey).
    static func currentDid(shortDeviceIdHex: String) -> String? {
        let fullHex = LyraSyncReply.fullDeviceIdHex(shortDeviceIdHex: shortDeviceIdHex)
        guard fullHex.count == 64, let bytes = MiTrustTicketStore.data(fromHex: fullHex) else { return nil }
        return MijiaCSR.did(fullDeviceId: bytes)
    }

    static var currentShortDeviceIdHex: String {
        UserDefaults.standard.string(forKey: "xiaomiTrustCloneDeviceId") ?? "721572C3"
    }

    // Startup/periodic refresh: enroll only when the stored cert is missing,
    // near expiry, or bound to a stale did. No-op without a provisioned token
    // (UserDefaults injection stays the fallback path in that case).
    @discardableResult
    static func refreshIfNeeded(
        devName: String,
        http: MijiaIDMHTTPClient = MijiaURLSessionHTTPClient()
    ) async -> Bool {
        let shortId = currentShortDeviceIdHex
        guard let did = currentDid(shortDeviceIdHex: shortId) else {
            DiagnosticsLog.info("mijia.enroll.skip reason=no-did")
            return false
        }
        if MijiaEnrolledCertStore.usableCert(forDid: did) != nil {
            return false
        }
        guard let token = MijiaAccountTokenStore.load(), token.isComplete else {
            DiagnosticsLog.info("mijia.enroll.skip reason=no-token")
            return false
        }
        do {
            let (outcome, key) = try await enroll(token: token, did: did, devName: devName, http: http)
            try MijiaEnrolledCertStore.save(MijiaEnrolledCert(
                certDERBase64: outcome.certDER.base64EncodedString(),
                privateKeyBase64: key.rawRepresentation.base64EncodedString(),
                did: did,
                enrolledAt: Date()
            ))
            DiagnosticsLog.info("mijia.enroll.ok subject=\(outcome.certSubject)")
            return true
        } catch {
            DiagnosticsLog.error("mijia.enroll.failed", error)
            return false
        }
    }
}
