import CryptoKit
import EdgeLinkKit
import Foundation
import LyraServerKit
import XCTest

// Loopback: the phone's reverse sync task (LyraSyncTaskRole) against the
// real LyraMeshResponder + LyraSyncTaskServer — phys sync with embedded
// private_data, full AuthHandshake, payload push, and the Mac's reply.
final class LyraSyncTaskLoopbackTests: XCTestCase {
    private static let defaultsKeys = [
        "xiaomiTrustIdentityPrivHex",
        "xiaomiTrustIdentityPubB64",
        "xiaomiTrustPeerIdentityPubB64",
        "xiaomiTrustPeerAccountPubB64",
        "xiaomiTrustSessionKeyHex",
        "xiaomiTrustTicketHex",
        "xiaomiTrustUidHashB64",
        "xiaomiTrustDeviceKeyHex",
    ]

    private var savedValues: [String: Any?] = [:]
    private let macIdentity = P256.Signing.PrivateKey()
    private var phone: LyraPhoneServer!
    private var responderSocket: LyraMeshSocket?
    private var responder: LyraMeshResponder?

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        for key in Self.defaultsKeys {
            savedValues[key] = defaults.object(forKey: key)
        }
        defaults.set(macIdentity.rawRepresentation.map { String(format: "%02x", $0) }.joined(),
                     forKey: "xiaomiTrustIdentityPrivHex")
        defaults.set(macIdentity.publicKey.x963Representation.base64EncodedString(),
                     forKey: "xiaomiTrustIdentityPubB64")
        defaults.removeObject(forKey: "xiaomiTrustPeerIdentityPubB64")
        defaults.removeObject(forKey: "xiaomiTrustSessionKeyHex")
        defaults.removeObject(forKey: "xiaomiTrustTicketHex")
        MiTrustTicketStore.lastAuthSessionKeyData = nil
    }

    override func tearDown() {
        responder = nil
        responderSocket?.stop()
        responderSocket = nil
        phone?.stop()
        phone = nil
        let defaults = UserDefaults.standard
        for key in Self.defaultsKeys {
            if let value = savedValues[key] ?? nil {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        MiTrustTicketStore.lastAuthSessionKeyData = nil
        super.tearDown()
    }

    private func waitFor(
        _ description: String, timeout: TimeInterval = 15,
        _ predicate: @escaping () -> Bool
    ) {
        let expectation = XCTestExpectation(description: description)
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler {
            if predicate() {
                expectation.fulfill()
                timer.cancel()
            }
        }
        timer.resume()
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        timer.cancel()
        XCTAssertEqual(result, .completed, "timed out waiting for: \(description)")
    }

    private func startResponder() throws -> UInt16 {
        let socket = LyraMeshSocket()
        let responder = LyraMeshResponder(
            socket: socket,
            deviceIdHexProvider: { "721572C3" },
            displayNameProvider: { "MacBook Pro" }
        )
        try socket.start()
        responder.attach()
        self.responderSocket = socket
        self.responder = responder
        waitFor("responder listener ready") { socket.boundPort != nil }
        return try XCTUnwrap(socket.boundPort)
    }

    private func makePhone() throws -> LyraPhoneServer {
        let identity = LyraPhoneIdentity.generate()
        let phone = LyraPhoneServer(identity: identity)
        // The Mac verifies client_finished against our identity.
        UserDefaults.standard.set(
            identity.identityPubB64, forKey: "xiaomiTrustPeerIdentityPubB64"
        )
        // …and on auth_type 4 dials the phone signs with its ACCOUNT identity
        // (Mijia cert key) — seed it like the production default does.
        UserDefaults.standard.set(
            identity.accountPubB64, forKey: "xiaomiTrustPeerAccountPubB64"
        )
        try phone.start(port: 0)
        waitFor("phone listener ready") { phone.boundPort != nil }
        return phone
    }

    func testSyncTaskFullHandshakePushesPayloadAndGetsReply() throws {
        let responderPort = try startResponder()
        phone = try makePhone()

        phone.runSyncTask(host: "127.0.0.1", port: responderPort)

        waitFor("sync task established") {
            self.phone.syncTask.state == .established
        }
        waitFor("Mac payload reply parsed") {
            self.phone.syncTask.peerDevice != nil
        }
        let peer = try XCTUnwrap(phone.syncTask.peerDevice)
        XCTAssertEqual(peer.shortDeviceIdHex, "721572C3")
        // The Mac's reply landed in the phone's DevRepo (reply path: no
        // trusted-type stamping).
        let record = try XCTUnwrap(phone.oracle.records[peer.fullDeviceIdHex])
        XCTAssertFalse(record.online)
        XCTAssertEqual(record.trustedType, 0)
    }

    func testSyncTaskAuthReuseSkipsHandshake() throws {
        let responderPort = try startResponder()
        phone = try makePhone()

        phone.runSyncTask(host: "127.0.0.1", port: responderPort)
        waitFor("first dial established") {
            self.phone.syncTask.state == .established
        }
        waitFor("first reply") { self.phone.syncTask.peerDevice != nil }

        // The phone records the session key (its DeviceKeyManager); the Mac
        // persists it the same way recordAuthSession does in production.
        let reuseKey = try XCTUnwrap(phone.syncTask.reuseKey)
        let keyData = reuseKey.withUnsafeBytes { Data($0) }
        UserDefaults.standard.set(
            keyData.map { String(format: "%02x", $0) }.joined(),
            forKey: "xiaomiTrustSessionKeyHex"
        )

        let second = LyraSyncTaskRole(identity: phone.identity, oracle: phone.oracle)
        second.reuseKey = reuseKey
        var events: [String] = []
        second.onEvent = { events.append($0) }
        second.dial(server: phone.mesh, host: "127.0.0.1", port: responderPort)

        waitFor("reuse dial pushes payload") {
            events.contains("sync task payload pushed")
        }
        XCTAssertEqual(second.state, .established)
        waitFor("reuse reply parsed") { second.peerDevice != nil }
    }
}
