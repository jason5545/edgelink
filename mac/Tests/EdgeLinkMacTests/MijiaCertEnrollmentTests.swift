import CryptoKit
import Foundation
import XCTest

// Covers the clean-room Mijia enrollment client (protocol proven live against
// idm.api.io.mi.com on 2026-08-05): CSR assembly, uid/did derivation, miot
// request signing/encryption, response handling, and the certCredBlock
// provenance switch (enrolled cert first, UserDefaults injection as fallback).
final class MijiaCertEnrollmentTests: XCTestCase {
    private static let certHexKey = "xiaomiTrustCredCertHex"
    private static let privHexKey = "xiaomiTrustCredPrivHex"

    private var savedCert: String?
    private var savedPriv: String?

    override func setUp() {
        super.setUp()
        savedCert = UserDefaults.standard.string(forKey: Self.certHexKey)
        savedPriv = UserDefaults.standard.string(forKey: Self.privHexKey)
        MiTrustTicketStore.enrolledCertOverride = nil
    }

    override func tearDown() {
        restore(savedCert, forKey: Self.certHexKey)
        restore(savedPriv, forKey: Self.privHexKey)
        MiTrustTicketStore.enrolledCertOverride = nil
        super.tearDown()
    }

    private func restore(_ value: String?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: uid/did derivation (vectors from the live Mac + phone certs)

    func testUidDerivationMatchesLiveCerts() {
        XCTAssertEqual(
            MijiaCSR.uid(did: "F4DHQISuCun7OBYoguT_99G-AZmyLxy8p9AYtbca6lk", accountNumericId: "32717118"),
            "hoht3ZnsPCV6pVs-qmpKOJBwGJGc_cbrk1aPDHgRs8c"
        )
        XCTAssertEqual(
            MijiaCSR.uid(did: "SZUWP2zTgh7lllYbX0sUDSvvnRc_9FV9OrZd-LXrHKQ", accountNumericId: "32717118"),
            "WF4nEgxA7fS45nKkzbTR8rvkEoKKZgLI_OV5poeZHg0"
        )
    }

    func testDidIsBase64URLFullDeviceId() {
        let full = Data([
            0x17, 0x80, 0xC7, 0x40, 0x84, 0xAE, 0x0A, 0xE9, 0xFB, 0x38, 0x16, 0x28, 0x82, 0xE4, 0xFF, 0xF7,
            0xD1, 0xBE, 0x01, 0x99, 0xB2, 0x2F, 0x1C, 0xBC, 0xA7, 0xD0, 0x18, 0xB5, 0xB7, 0x1A, 0xEA, 0x59
        ])
        XCTAssertEqual(MijiaCSR.did(fullDeviceId: full), "F4DHQISuCun7OBYoguT_99G-AZmyLxy8p9AYtbca6lk")
    }

    // MARK: CSR assembly

    func testCSRContainsLongCNAndSignatureVerifies() throws {
        let key = P256.Signing.PrivateKey()
        let did = "chVyw6PZM-GNVNVcdUeHx1eraKCRA-MrcCGPlEyRiPQ"
        let uid = MijiaCSR.uid(did: did, accountNumericId: "32717118")
        let der = try MijiaCSR.build(uid: uid, did: did, deviceType: 14, key: key)
        let expectedCN = "lyra.\(uid).\(did).14"
        XCTAssertGreaterThan(expectedCN.count, 64)
        XCTAssertTrue(der.range(of: Data(expectedCN.utf8)) != nil)

        // Walk the DER: seq { cri, alg, sig } (readTLV returns TLV content)
        var reader = DERReader(der)
        let csrSeq = try reader.readTLV(expectedTag: 0x30)
        var inner = DERReader(csrSeq)
        let cri = try inner.readTLV(expectedTag: 0x30)
        let alg = try inner.readTLV(expectedTag: 0x30)
        let sigBits = try inner.readTLV(expectedTag: 0x03)
        XCTAssertEqual(hex(alg), "06082a8648ce3d040302")
        let signature = try P256.Signing.ECDSASignature(derRepresentation: sigBits.dropFirst())
        XCTAssertTrue(key.publicKey.isValidSignature(signature, for: MijiaCSR.derSeq(cri)))
    }

    // MARK: miot signing golden vector (captured from the proven live run)

    func testSignerMatchesGoldenVector() {
        let nonceBytes = Data([0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0x01, 0xC6, 0x2B, 0x80])
        let ssecurity = "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA="
        let iv = Data(repeating: 0x11, count: 12)
        let body = "{\"did\":\"DID\",\"deviceType\":14,\"csr\":\"CSRPEM\",\"uniDid\":\"\",\"preDid\":\"\",\"preUid\":0}"
        let request = MijiaIDMSigner.buildRequest(
            path: MijiaIDMSigner.getCertPath,
            jsonBody: body,
            ssecurity: ssecurity,
            nonceBytes: nonceBytes,
            iv: iv,
            rc4Hash: "AbCdEfGhIj"
        )
        XCTAssertNotNil(request)
        XCTAssertEqual(hex(request!.sessionKey), "f1e8fd4a9efb58bcd0796f9767b960e57afeeb4f31003fcfbd84dbf8bb165bb4")
        XCTAssertEqual(request!.formFields["_nonce"], "qqqqqqqqqqoBxiuA")
        XCTAssertEqual(
            request!.formFields["data"],
            "ERERERERERERERERHnNviTC2loGp6IBDXsKcdSjszHXQ3ZMBsrMgum27RB27ZlwTRTt2EEsIV+0dpwvpFpFOzO+SSJmO9DOA26DbEV8Om1l6s/Mr8Pan97bjswYdi47jzPlzkC3ZvAe4ntE="
        )
        XCTAssertEqual(request!.formFields["signature"], "u6W83Kd1UPhHE9yxWoIt6jcIqEQpjOY3VNAK5vjN6ok=")
    }

    // MARK: enroll E2E with a fake IDM server

    private final class FakeIDMServer: MijiaIDMHTTPClient, @unchecked Sendable {
        let ssecurityB64: String
        var capturedHeaders: [String: String]?
        var capturedForm: [String: String]?
        var capturedBodyJSON: [String: Any]?

        init(ssecurityB64: String) {
            self.ssecurityB64 = ssecurityB64
        }

        func post(url: URL, headers: [String: String], formFields: [String: String]) async throws -> (status: Int, body: Data) {
            capturedHeaders = headers
            capturedForm = formFields
            func fail(_ step: String) -> (Int, Data) { (500, Data("bad request: \(step)".utf8)) }
            guard let nonceB64 = formFields["_nonce"] else { return fail("nonce") }
            guard let nonceBytes = Data(base64Encoded: nonceB64),
                  let sessionKey = MijiaIDMSigner.sessionKey(ssecurity: ssecurityB64, nonceBytes: nonceBytes)
            else { return fail("sessionKey") }
            guard let dataB64 = formFields["data"],
                  let dataBytes = Data(base64Encoded: dataB64),
                  dataBytes.count > 28
            else { return fail("data") }
            guard let plaintext = openGCM(dataBytes, sessionKey: sessionKey) else { return fail("gcm") }
            guard let bodyJSON = try? JSONSerialization.jsonObject(with: plaintext) as? [String: Any]
            else { return fail("json") }
            guard let csrPEM = bodyJSON["csr"] as? String else { return fail("csr field") }
            guard let csrDER = MijiaCertEnrollment.derFromPEM(csrPEM) else { return fail("csr pem") }
            guard let pubX963 = extractCSRPublicKey(csrDER) else {
                return fail("csr pub len=\(csrDER.count) head=\(csrDER.prefix(12).map { String(format: "%02x", $0) }.joined())")
            }
            capturedBodyJSON = bodyJSON

            // Verify the request signature the same way the server would.
            let sessionSecurity = sessionKey.base64EncodedString()
            let expected = "POST&\(MijiaIDMSigner.getCertPath)&data=\(dataB64)&rc4_hash__=\(formFields["rc4_hash__"] ?? "")&\(sessionSecurity)"
            let expectedSig = Data(SHA256.hash(data: Data(expected.utf8))).base64EncodedString()
            guard formFields["signature"] == expectedSig else {
                return (401, Data("{\"code\":11,\"message\":\"invalid signature\"}".utf8))
            }

            let certDER = makeSelfSignedCert(pubX963: pubX963, cn: "lyra.test-uid.test-did.14")
            var certB64 = certDER.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
            if !certB64.hasSuffix("\n") { certB64 += "\n" }
            let certPEM = "-----BEGIN CERTIFICATE-----\n" + certB64 + "-----END CERTIFICATE-----\n"
            let response = "{\"code\":0,\"message\":\"ok\",\"result\":{\"cert\":\(MijiaCertEnrollment.jsonString(certPEM))}}"
            let sealed = try AES.GCM.seal(
                Data(response.utf8),
                using: SymmetricKey(data: sessionKey),
                nonce: AES.GCM.Nonce(data: Data(repeating: 0x22, count: 12))
            )
            var blob = Data(repeating: 0x22, count: 12)
            blob.append(sealed.ciphertext)
            blob.append(sealed.tag)
            return (200, blob.base64EncodedData())
        }

        private func openGCM(_ blob: Data, sessionKey: Data) -> Data? {
            let nonce = blob.prefix(12)
            let tag = blob.suffix(16)
            let ciphertext = blob.dropFirst(12).dropLast(16)
            guard let box = try? AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: Data(nonce)),
                ciphertext: Data(ciphertext),
                tag: Data(tag)
            ) else { return nil }
            return try? AES.GCM.open(box, using: SymmetricKey(data: sessionKey))
        }

        private func extractCSRPublicKey(_ der: Data) -> Data? {
            var top = DERReader(der)
            guard let csrSeq = try? top.readTLV(expectedTag: 0x30) else { return nil }
            var criReader = DERReader(csrSeq)
            guard let cri = try? criReader.readTLV(expectedTag: 0x30) else { return nil }
            var inner = DERReader(cri)
            _ = try? inner.readTLV(expectedTag: 0x02) // version
            _ = try? inner.readTLV(expectedTag: 0x30) // subject
            guard let spki = try? inner.readTLV(expectedTag: 0x30) else { return nil }
            var spkiReader = DERReader(spki)
            _ = try? spkiReader.readTLV(expectedTag: 0x30) // alg
            guard let bits = try? spkiReader.readTLV(expectedTag: 0x03), bits.count == 66 else { return nil }
            return bits.dropFirst()
        }

        private func makeSelfSignedCert(pubX963: Data, cn: String) -> Data {
            let alg = MijiaCSR.derSeq(Data([0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02]))
            let ecAlg = MijiaCSR.derSeq(
                Data([0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01])
                    + Data([0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07])
            )
            func name(_ cn: String, org: String) -> Data {
                let orgATV = MijiaCSR.derSeq(Data([0x06, 0x03, 0x55, 0x04, 0x0A]) + MijiaCSR.derUTF8(org))
                let cnATV = MijiaCSR.derSeq(Data([0x06, 0x03, 0x55, 0x04, 0x03]) + MijiaCSR.derUTF8(cn))
                return MijiaCSR.derSeq(MijiaCSR.derSet(orgATV) + MijiaCSR.derSet(cnATV))
            }
            func time(_ date: Date) -> Data {
                let fmt = DateFormatter()
                fmt.dateFormat = "yyMMddHHmmss'Z'"
                fmt.timeZone = TimeZone(identifier: "UTC")
                return MijiaCSR.der(0x17, Data(fmt.string(from: date).utf8))
            }
            var tbs = Data()
            tbs.append(MijiaCSR.der(0xA0, MijiaCSR.derInteger(2))) // v3
            tbs.append(MijiaCSR.derInteger(1)) // serial
            tbs.append(alg)
            tbs.append(name("", org: "Mijia Cloud"))
            tbs.append(MijiaCSR.derSeq(time(Date().addingTimeInterval(-3600)) + time(Date().addingTimeInterval(180 * 86400))))
            tbs.append(name(cn, org: ""))
            tbs.append(MijiaCSR.derSeq(ecAlg + MijiaCSR.derBitString(pubX963)))
            let tbsSeq = MijiaCSR.derSeq(tbs)
            // Signature over tbs with a throwaway key — the client only parses
            // the cert, it does not chain-verify.
            let signingKey = P256.Signing.PrivateKey()
            let sig = (try? signingKey.signature(for: tbsSeq).derRepresentation) ?? Data(repeating: 0, count: 70)
            return MijiaCSR.derSeq(tbsSeq + alg + MijiaCSR.derBitString(sig))
        }
    }

    func testEnrollE2EWithFakeServer() async throws {
        let ssecurity = "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA="
        let token = MijiaAccountToken(
            cUserId: "cuid",
            serviceToken: "st",
            ssecurity: ssecurity,
            accountNumericId: "32717118",
            fetchedAt: Date()
        )
        let server = FakeIDMServer(ssecurityB64: ssecurity)
        let did = "chVyw6PZM-GNVNVcdUeHx1eraKCRA-MrcCGPlEyRiPQ"
        let (outcome, key) = try await MijiaCertEnrollment.enroll(
            token: token, did: did, devName: "Test Mac", http: server
        )

        XCTAssertEqual(server.capturedHeaders?["User-Agent"], "IDM")
        XCTAssertEqual(server.capturedHeaders?["SHA-ALGORITHM"], "HASH-SHA256")
        XCTAssertEqual(server.capturedHeaders?["MIOT-ENCRYPT-ALGORITHM"], "ENCRYPT-AES")
        XCTAssertEqual(server.capturedHeaders?["Cookie"], "cUserId=cuid;serviceToken=st")
        XCTAssertEqual(server.capturedBodyJSON?["did"] as? String, did)
        XCTAssertEqual(server.capturedBodyJSON?["deviceType"] as? Int, 14)
        XCTAssertEqual(server.capturedBodyJSON?["preUid"] as? Int, 0)
        XCTAssertTrue(outcome.certSubject.contains("lyra.test-uid"))
        // The issued cert's pubkey must be the enrollment key's (enroll() checks).
        XCTAssertNotNil(outcome.notAfter)
        _ = key
    }

    func testEnrollRejectsServerErrorCode() async {
        struct ErrorServer: MijiaIDMHTTPClient {
            func post(url: URL, headers: [String: String], formFields: [String: String]) async throws -> (status: Int, body: Data) {
                (401, Data("{\"code\":11,\"message\":\"auth error: invalid signature\"}".utf8))
            }
        }
        let token = MijiaAccountToken(
            cUserId: "cuid", serviceToken: "st",
            ssecurity: "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA=",
            accountNumericId: "32717118", fetchedAt: Date()
        )
        do {
            _ = try await MijiaCertEnrollment.enroll(token: token, did: "did", devName: "x", http: ErrorServer())
            XCTFail("expected throw")
        } catch MijiaEnrollmentError.serverError(let code, _) {
            XCTAssertEqual(code, 11)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: certCredBlock provenance

    func testCertCredBlockPrefersEnrolledCert() throws {
        let enrolledKey = P256.Signing.PrivateKey()
        let injectedKey = P256.Signing.PrivateKey()
        let enrolledCert = Data("enrolled-cert-der".utf8)
        let injectedCert = Data("injected-cert-der".utf8)
        UserDefaults.standard.set(hex(injectedCert), forKey: Self.certHexKey)
        UserDefaults.standard.set(hex(injectedKey.rawRepresentation), forKey: Self.privHexKey)
        MiTrustTicketStore.enrolledCertOverride = {
            MijiaEnrolledCert(
                certDERBase64: enrolledCert.base64EncodedString(),
                privateKeyBase64: enrolledKey.rawRepresentation.base64EncodedString(),
                did: "did",
                enrolledAt: Date()
            )
        }

        let block = MiTrustTicketStore.current().certCredBlock()
        XCTAssertNotNil(block)
        XCTAssertTrue(block!.range(of: enrolledCert) != nil)
        XCTAssertTrue(block!.range(of: injectedCert) == nil)
    }

    func testCertCredBlockFallsBackToInjection() throws {
        let injectedKey = P256.Signing.PrivateKey()
        let injectedCert = Data("injected-cert-der".utf8)
        UserDefaults.standard.set(hex(injectedCert), forKey: Self.certHexKey)
        UserDefaults.standard.set(hex(injectedKey.rawRepresentation), forKey: Self.privHexKey)
        MiTrustTicketStore.enrolledCertOverride = { nil }

        let block = MiTrustTicketStore.current().certCredBlock()
        XCTAssertNotNil(block)
        XCTAssertTrue(block!.range(of: injectedCert) != nil)
    }
}

// Minimal DER TLV walker for structure assertions.
struct DERReader {
    private var data: Data

    init(_ data: Data) {
        self.data = data
    }

    mutating func readTLV(expectedTag: UInt8) throws -> Data {
        guard data.count >= 2, data[data.startIndex] == expectedTag else {
            throw DERError.unexpectedTag
        }
        var offset = 1
        let firstLen = data[data.startIndex + 1]
        var length = 0
        if firstLen & 0x80 == 0 {
            length = Int(firstLen)
            offset = 2
        } else {
            let lenBytes = Int(firstLen & 0x7F)
            guard data.count >= 2 + lenBytes else { throw DERError.truncated }
            for i in 0..<lenBytes {
                length = length << 8 | Int(data[data.startIndex + 2 + i])
            }
            offset = 2 + lenBytes
        }
        guard data.count >= offset + length else { throw DERError.truncated }
        let content = data[(data.startIndex + offset)..<(data.startIndex + offset + length)]
        data = data[(data.startIndex + offset + length)...]
        return Data(content)
    }

    enum DERError: Error {
        case unexpectedTag, truncated
    }
}
