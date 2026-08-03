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
}
