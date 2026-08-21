import CryptoKit
import EdgeLinkKit
import Foundation
import LyraServerKit
import XCTest

// Phone→Mac MiShare receive: the phone's gallery share dials the Mac's
// miLyraShareTransfer service (sync_info → P256 upgrade → encrypted conn
// request → responseAck → requestOfPeerPort → responseOfPeerPort).
//
// Live 2026-08-21: the phone's score-based phys-conn reuse dialed the service
// on the MAC's announcer conn; the announcer had no route for it
// (announcer_stray_conn) and the phone's 15s kcp timeout surfaced as
// 「連線失敗」. The first test is the baseline dial on the responder's own
// socket; the second recreates the announcer-conn dial and times out without
// the responder-adoption fix.
final class LyraMiShareReceiveTests: XCTestCase {
    private static let defaultsKeys = [
        "xiaomiTrustIdentityPrivHex",
        "xiaomiTrustIdentityPubB64",
        "xiaomiTrustPeerIdentityPubB64",
        "xiaomiTrustPeerAccountPubB64",
        "xiaomiTrustSessionKeyHex",
        "xiaomiTrustTicketHex",
        "xiaomiTrustUidHashB64",
        "lanLastPhoneIP",
    ]

    private var savedValues: [String: Any?] = [:]
    private let macIdentity = P256.Signing.PrivateKey()
    private var phone: LyraPhoneServer?
    private var responderSocket: LyraMeshSocket?
    private var responder: LyraMeshResponder?
    private var announcer: LyraMeshAnnouncer?

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        let defaults = UserDefaults.standard
        for key in Self.defaultsKeys {
            savedValues[key] = defaults.object(forKey: key)
        }
        defaults.set(macIdentity.rawRepresentation.map { String(format: "%02x", $0) }.joined(),
                     forKey: "xiaomiTrustIdentityPrivHex")
        defaults.set(macIdentity.publicKey.x963Representation.base64EncodedString(),
                     forKey: "xiaomiTrustIdentityPubB64")
        defaults.removeObject(forKey: "xiaomiTrustSessionKeyHex")
        defaults.removeObject(forKey: "xiaomiTrustTicketHex")
        // Endpoint learning must not be gated by a pinned LAN IP from the
        // developer machine's real defaults (loopback host is 127.0.0.1).
        defaults.removeObject(forKey: "lanLastPhoneIP")
        MiTrustTicketStore.lastAuthSessionKeyData = nil
    }

    override func tearDown() {
        announcer?.stop()
        announcer = nil
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
        UserDefaults.standard.set(
            identity.identityPubB64, forKey: "xiaomiTrustPeerIdentityPubB64"
        )
        UserDefaults.standard.set(
            identity.accountPubB64, forKey: "xiaomiTrustPeerAccountPubB64"
        )
        try phone.start(port: 0)
        waitFor("phone listener ready") { phone.boundPort != nil }
        return phone
    }

    // Baseline: the dial lands on the responder's published mesh socket (the
    // phone's own mesh conn winning the score). Validates the mock speaks the
    // receive flow the responder expects.
    func testMiShareReceiveOverMeshResponderConn() throws {
        let responderPort = try startResponder()
        let phone = try makePhone()
        self.phone = phone

        let sender = LyraMiShareSenderRole(identity: phone.identity)
        phone.mesh.register(sender)
        sender.dial(server: phone.mesh, toHost: "127.0.0.1", port: responderPort)

        waitFor("responseOfPeerPort received") { sender.receivedChannelPort != nil }
        XCTAssertEqual(sender.state, .channelReady)
    }

    // Regression: the phone's score-based reuse dials miLyraShareTransfer on
    // the MAC's announcer phys conn. Pre-fix the sync_info fell into
    // announcer_stray_conn and the phone timed out (live 2026-08-21
    // 「連線失敗」); the responder must adopt the conn off the announcer's
    // socket, like the 2026-08-12 mitrustservice adoption.
    func testMiShareReceiveWhenPhoneDialsOnAnnouncerConn() throws {
        _ = try startResponder()
        let phone = try makePhone()
        self.phone = phone

        let announcer = LyraMeshAnnouncer(
            deviceIdHexProvider: { "721572C3" },
            displayNameProvider: { "MacBook Pro" }
        )
        self.announcer = announcer
        announcer.start(host: "127.0.0.1", port: try XCTUnwrap(phone.boundPort))
        // The phone learned the announcer's endpoint from its phys sync;
        // sendToPeer now rides the announcer conn.
        waitFor("announcer endpoint learned by phone") {
            !phone.mesh.peer.endpointDescription.isEmpty
        }

        let sender = LyraMiShareSenderRole(identity: phone.identity)
        phone.mesh.register(sender)
        sender.dial(server: phone.mesh)

        waitFor("responseOfPeerPort received over announcer conn") {
            sender.receivedChannelPort != nil
        }
        XCTAssertEqual(sender.state, .channelReady)
    }
}
