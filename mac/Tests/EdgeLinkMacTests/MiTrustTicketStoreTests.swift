import CryptoKit
import Foundation
import XCTest

// Pins the current MiTrustTicketStore behavior that the 2026-08-03 mirror
// incident validated live: the ticket is the durable shared secret (the phone
// persists it in storage.lyra across reboots), the session key is the
// fast-path override, and cred blobs must stay decryptable by the ticket even
// while a session key is set — that fallback is what lets a session recover
// when the phone only has its persisted ticket left.
final class MiTrustTicketStoreTests: XCTestCase {
    private static let sessionKeyKey = "xiaomiTrustSessionKeyHex"
    private static let ticketKey = "xiaomiTrustTicketHex"

    private var savedSession: String?
    private var savedTicket: String?

    override func setUp() {
        super.setUp()
        savedSession = UserDefaults.standard.string(forKey: Self.sessionKeyKey)
        savedTicket = UserDefaults.standard.string(forKey: Self.ticketKey)
    }

    override func tearDown() {
        restore(savedSession, forKey: Self.sessionKeyKey)
        restore(savedTicket, forKey: Self.ticketKey)
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

    func testRecordAuthSessionPersistsSessionKeyAndTicket() {
        let sessionKey = Data((0..<32).map { UInt8($0) })
        let ticket = Data((0..<32).map { UInt8(255 - $0) })

        MiTrustTicketStore.recordAuthSession(sessionKey: sessionKey, ticket: ticket)

        XCTAssertEqual(UserDefaults.standard.string(forKey: Self.sessionKeyKey), hex(sessionKey))
        XCTAssertEqual(UserDefaults.standard.string(forKey: Self.ticketKey), hex(ticket))
        let store = MiTrustTicketStore.current()
        XCTAssertNotNil(store.sessionKey)
        XCTAssertNotNil(store.ticketKey)
        XCTAssertTrue(store.isEnabled)
    }

    func testEncryptLocalCredPrefersSessionKeyWhenBothPresent() throws {
        let sessionKey = Data(repeating: 0xAA, count: 32)
        let ticket = Data(repeating: 0xBB, count: 32)
        MiTrustTicketStore.recordAuthSession(sessionKey: sessionKey, ticket: ticket)

        let store = MiTrustTicketStore.current()
        let blob = try XCTUnwrap(store.encryptLocalCred())

        let sessionSymmetric = SymmetricKey(data: sessionKey)
        let ticketSymmetric = SymmetricKey(data: ticket)
        XCTAssertNotNil(store.decrypt(blob, with: sessionSymmetric), "session key must open the cred blob")
        XCTAssertNil(store.decrypt(blob, with: ticketSymmetric), "ticket must not open a session-key blob")
    }

    func testEncryptLocalCredFallsBackToTicketWhenSessionKeyAbsent() throws {
        UserDefaults.standard.removeObject(forKey: Self.sessionKeyKey)
        let ticket = Data(repeating: 0xCC, count: 32)
        UserDefaults.standard.set(hex(ticket), forKey: Self.ticketKey)

        let store = MiTrustTicketStore.current()
        XCTAssertNil(store.sessionKey)
        let blob = try XCTUnwrap(store.encryptLocalCred())

        XCTAssertNotNil(
            store.decrypt(blob, with: SymmetricKey(data: ticket)),
            "ticket must open the cred blob when no session key is set"
        )
    }

    func testDecryptCredBlobAcceptsTicketEvenWhenSessionKeySet() throws {
        let sessionKey = Data(repeating: 0x11, count: 32)
        let ticket = Data(repeating: 0x22, count: 32)
        MiTrustTicketStore.recordAuthSession(sessionKey: sessionKey, ticket: ticket)

        let store = MiTrustTicketStore.current()
        let plaintext = Data("cred-payload".utf8)
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: ticket))
        var blob = Data()
        blob.append(contentsOf: sealed.nonce.withUnsafeBytes { Data($0) })
        blob.append(sealed.ciphertext)
        blob.append(sealed.tag)

        // Phone-side reboot scenario: the phone forgot the session key and
        // answers with a ticket-encrypted blob — we must still decrypt it.
        XCTAssertEqual(store.decryptCredBlob(blob), plaintext)
    }

    func testDeviceKeyIsGeneratedOnceAndPersists() {
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: "xiaomiTrustDeviceKeyHex")
        defer {
            if let saved {
                defaults.set(saved, forKey: "xiaomiTrustDeviceKeyHex")
            } else {
                defaults.removeObject(forKey: "xiaomiTrustDeviceKeyHex")
            }
        }
        defaults.removeObject(forKey: "xiaomiTrustDeviceKeyHex")

        let first = MiTrustTicketStore.current().deviceKeyData
        XCTAssertEqual(first?.count, 32)
        XCTAssertEqual(MiTrustTicketStore.current().deviceKeyData, first)
        XCTAssertEqual(
            defaults.string(forKey: "xiaomiTrustDeviceKeyHex"),
            first?.map { String(format: "%02x", $0) }.joined()
        )
    }

    // Live 2026-08-05: the phone's client_finished verifies as
    // ECDSA-SHA256(clientEph||serverEph) under the ACCOUNT identity key from
    // its Mijia cert (auth_type 4), not the pairing identity key. The account
    // key is harvested from the cert in the phone's own sync payload.
    private static let phoneAccountCertHex = "308201a53082014ca0030201020209010000019fceee7662300a06082a8648ce3d040302302331143012060355040a0c0b4d696a696120436c6f7564310b300906035504061302434e301e170d3236303830333232333932325a170d3237303230323130333932325a30693167306506035504030c5e6c7972612e5746346e4567784137665334356e4b6b7a6254523872766b456f4b4b5a674c495f4f5635706f655a4867302e535a555750327a546768376c6c6c596258307355445376766e52635f394656394f725a642d4c5872484b512e313059301306072a8648ce3d020106082a8648ce3d03010703420004a22c96ecb177a1cc3e037c85972bd048214ad442c1b5204ee6ec4cd5e605fb107db69fd3ed962cbf877f9c5e6f85df573103d0cc42eebbcc0bd7cfd024a4461ba3233021301f0603551d230418301680145a29bffb2fb7500ce9c420f23d899b6fe0803293300a06082a8648ce3d040302034700304402205a6ab8ff2a52a970d31d18ca502722aedcd177e7a69204bb4df79fcf9caf6f3a02205e135d42de94f7739f89d33b73ac3669843746eeae07cedcc1c1bc4aad5c7ba8"
    private static let phoneAccountPubB64 = "BKIsluyxd6HMPgN8hZcr0EghStRCwbUgTubsTNXmBfsQfbaf0+2WLL+Hf5xeb4XfVzED0MxC7rvMC9fP0CSkRhs="

    func testIdentityCertExtractorFindsAccountPubKeyInPayload() throws {
        let cert = try XCTUnwrap(MiTrustTicketStore.data(fromHex: Self.phoneAccountCertHex))
        var payload = Data([0x00, 0x08, 0x01, 0x2a])
        payload.append(cert)
        payload.append(Data([0x80, 0x01, 0x02]))

        let pub = try XCTUnwrap(LyraIdentityCert.pubKey(fromSyncPayload: payload))
        XCTAssertEqual(pub.count, 65)
        XCTAssertEqual(pub.base64EncodedString(), Self.phoneAccountPubB64)
    }

    func testIdentityCertExtractorIgnoresGarbage() {
        XCTAssertNil(LyraIdentityCert.pubKey(fromSyncPayload: Data()))
        XCTAssertNil(LyraIdentityCert.pubKey(fromSyncPayload: Data([0x30, 0x82, 0xFF, 0xFF, 0x00])))
        XCTAssertNil(LyraIdentityCert.pubKey(fromSyncPayload: Data(repeating: 0xAB, count: 512)))
    }

    func testHarvestPeerAccountPubKeyPersistsExtractedKey() throws {
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: "xiaomiTrustPeerAccountPubB64")
        defer { restore(saved, forKey: "xiaomiTrustPeerAccountPubB64") }
        // Seed a stale value (the default equals the harvested key, which
        // would make the harvest a no-op).
        defaults.set(Data(repeating: 7, count: 65).base64EncodedString(), forKey: "xiaomiTrustPeerAccountPubB64")

        let cert = try XCTUnwrap(MiTrustTicketStore.data(fromHex: Self.phoneAccountCertHex))
        XCTAssertTrue(MiTrustTicketStore.harvestPeerAccountPubKey(fromSyncPayload: cert))
        XCTAssertEqual(defaults.string(forKey: "xiaomiTrustPeerAccountPubB64"), Self.phoneAccountPubB64)
        // Same payload again: no rewrite.
        XCTAssertFalse(MiTrustTicketStore.harvestPeerAccountPubKey(fromSyncPayload: cert))
        XCTAssertTrue(MiTrustTicketStore.current().peerSigningPubKeys.contains(
            Data(base64Encoded: Self.phoneAccountPubB64)!
        ))
    }

    func testLyraSeedPayloadBuildsOfficialShapes() throws {
        let now = Date(timeIntervalSince1970: 1_786_000_000)
        let store = MiTrustTicketStore.current()
        let payload = try XCTUnwrap(store.lyraSeedPayload(deviceIdHex: "721572C3", now: now))

        let cred = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(payload.cred.utf8)) as? [String: Any]
        )
        XCTAssertEqual(cred["device_id"] as? String, "721572C3")
        XCTAssertEqual(cred["trusted_type"] as? Int, 1)
        let account = try XCTUnwrap(cred["account"] as? [String: Any])
        XCTAssertEqual(account["ability"] as? Int, 0)
        XCTAssertEqual(account["iot_pub_key"] as? String, "")
        XCTAssertEqual(account["pub_key"] as? String, store.identityPubKey.base64EncodedString())
        XCTAssertEqual(account["uid"] as? String, store.uidHashRaw.base64EncodedString())
        XCTAssertEqual(account["not_before"] as? Int64, Int64(now.timeIntervalSince1970) - 86_400)
        XCTAssertEqual(account["not_after"] as? Int64, Int64(now.timeIntervalSince1970) + 550 * 86_400)
        XCTAssertEqual(Data(base64Encoded: account["pub_key"] as? String ?? "")?.count, 65)

        let ticket = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(payload.ticket.utf8)) as? [String: Any]
        )
        XCTAssertEqual(ticket["algorithm"] as? Int, 0)
        XCTAssertEqual(ticket["alias"] as? String, "")
        let ticketKeyData = try XCTUnwrap(Data(base64Encoded: ticket["key"] as? String ?? ""))
        XCTAssertEqual(ticketKeyData.count, 32)
        let expectedTicket = try XCTUnwrap(store.ticketKey).withUnsafeBytes { Data($0) }
        XCTAssertEqual(ticketKeyData, expectedTicket)
    }

    func testLyraSeedPayloadDefaultsMatchLiveSeededMaterial() throws {
        // The 2026-07-30 route-C seed used these exact values; the builder
        // must keep producing them for the default (live) store.
        let keys = [
            "xiaomiTrustTicketHex",
            "xiaomiTrustIdentityPrivHex",
            "xiaomiTrustIdentityPubB64",
            "xiaomiTrustUidHashB64"
        ]
        let saved = keys.map { ($0, UserDefaults.standard.string(forKey: $0)) }
        defer { for (key, value) in saved { restore(value, forKey: key) } }
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }

        let store = MiTrustTicketStore.current()
        let payload = try XCTUnwrap(store.lyraSeedPayload(deviceIdHex: "721572C3"))
        XCTAssertTrue(payload.cred.contains(
            "\"pub_key\":\"BL/434ltP50le6fDe3X0Q3iXPo4fcf0+7H9c3P87N06fseKWnSjnsq12p22w5oZV/nLrtQyeRenyVOOdVUQqxh4=\""
        ))
        XCTAssertTrue(payload.cred.contains(
            "\"uid\":\"YfJQtjvnAuNXhZmXZ8IhFjr3I4mVdX9ZgDS3U+OvBzM=\""
        ))
        XCTAssertEqual(
            payload.ticket,
            "{\"algorithm\":0,\"alias\":\"\",\"key\":\"/4bk2ck+Hb8C3uKBF6qMwLoXb2Trml2zckyqmKZIgDU=\"}"
        )
    }
}
