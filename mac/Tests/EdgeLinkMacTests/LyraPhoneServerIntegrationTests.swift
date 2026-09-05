import CryptoKit
import EdgeLinkKit
import Foundation
import LyraServerKit
import XCTest

// Loopback integration: the real LyraMeshAnnouncer + LyraRelayCallSession
// (production code) against LyraPhoneServer (the mock phone). Drives the
// full native-calls registration chain with no device: phys sync → cookie →
// sync auth → AuthHandshake → logi → announce → sync push cred checks →
// online → relayCall dial → channel → ring.
final class LyraPhoneServerIntegrationTests: XCTestCase {
    private static let defaultsKeys = [
        "xiaomiTrustIdentityPrivHex",
        "xiaomiTrustIdentityPubB64",
        "xiaomiTrustPeerIdentityPubB64",
        "xiaomiTrustPeerAccountPubB64",
        "xiaomiTrustSessionKeyHex",
        "xiaomiTrustTicketHex",
        "xiaomiTrustUidHashB64",
        "xiaomiTrustLyraKeyIndex",
        "xiaomiTrustDeviceKeyHex",
        "xiaomiTrustCredCertHex",
        "xiaomiTrustCredPrivHex",
        "xiaomiRelayCallAdvertise",
        "xiaomiTrustCloneDeviceId",
        "xiaomiTrustLocalNodeIdHex",
        "xiaomiMeshRegion",
        "xiaomiMeshAnnounceDisabled",
        "xiaomiDeviceTypeOverride",
    ]

    private var savedValues: [String: Any?] = [:]
    private let macIdentity = P256.Signing.PrivateKey()
    private let credKey = P256.Signing.PrivateKey()
    private let certBytes = Data("edgelink-loopback-test-cert".utf8)
    private var phone: LyraPhoneServer!
    private var announcer: LyraMeshAnnouncer?

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
        defaults.removeObject(forKey: "xiaomiTrustSessionKeyHex")
        defaults.removeObject(forKey: "xiaomiTrustTicketHex")
        defaults.set(Data(SHA256.hash(data: Data("loopback-uid".utf8))).base64EncodedString(),
                     forKey: "xiaomiTrustUidHashB64")
        defaults.set(certBytes.map { String(format: "%02x", $0) }.joined(),
                     forKey: "xiaomiTrustCredCertHex")
        defaults.set(credKey.rawRepresentation.map { String(format: "%02x", $0) }.joined(),
                     forKey: "xiaomiTrustCredPrivHex")
        // relayCall advertise is the production default now (the pin
        // experiment 2026-09-05); resolve() must see it ON with no flag set.
        defaults.removeObject(forKey: "xiaomiRelayCallAdvertise")
        // The mock phone signs AuthHandshake client_finished with its account
        // identity (Mijia cert fixture) — seed it like the production default.
        defaults.set(
            LyraPhoneIdentity.fixtureAccountPubB64, forKey: "xiaomiTrustPeerAccountPubB64"
        )
        MiTrustTicketStore.lastAuthSessionKeyData = nil
    }

    override func tearDown() {
        announcer?.stop()
        announcer = nil
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

    private func makePhone() throws -> LyraPhoneServer {
        let phone = LyraPhoneServer(identity: LyraPhoneIdentity.generate())
        phone.pair(withMacIdentityPubKey: macIdentity.publicKey.x963Representation)
        phone.oracle.trustedCerts[certBytes] = credKey.publicKey.x963Representation
        try phone.start(port: 0)
        waitFor("phone listener ready") { phone.boundPort != nil }
        return phone
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

    // The announce flow with full cred material: the Mac's push carries f13
    // + the f15 cert cred, the oracle stamps trusted type, and the device
    // goes online with the relayCall service visible.
    func testAnnounceFlowRegistersMacOnline() throws {
        phone = try makePhone()
        let phonePort = try XCTUnwrap(phone.boundPort)

        announcer = LyraMeshAnnouncer(
            deviceIdHexProvider: { "721572C3" },
            displayNameProvider: { "MacBook Pro" }
        )
        announcer?.start(host: "127.0.0.1", port: phonePort)

        waitFor("announce authenticated") {
            if case .some = self.phone.mesh.peer.sessionKey { return true }
            return false
        }
        waitFor("Mac online in oracle") {
            self.phone.oracle.onlineDevices().contains { $0.device.hasService("relayCall") }
        }
        let record = try XCTUnwrap(phone.oracle.relayServiceDevice())
        XCTAssertNotEqual(record.trustedType, 0)
        XCTAssertTrue(record.rejectionReasons.isEmpty)
        XCTAssertNotNil(record.device.deviceKey)
        announcer?.stop()
        announcer = nil
    }

    // Without the cred cert registered, the phone's cred checks fail and the
    // Mac never leaves trusted_type 0 — the AddOnlineDevice rejection the
    // real phone logs.
    func testUnregisteredCertKeepsMacOffline() throws {
        phone = try makePhone()
        phone.oracle.trustedCerts.removeAll()
        let phonePort = try XCTUnwrap(phone.boundPort)

        announcer = LyraMeshAnnouncer(
            deviceIdHexProvider: { "721572C3" },
            displayNameProvider: { "MacBook Pro" }
        )
        announcer?.start(host: "127.0.0.1", port: phonePort)

        waitFor("Mac record exists") { !self.phone.oracle.records.isEmpty }
        // Give the push exchange a moment to settle, then assert the gate.
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(phone.oracle.onlineDevices().isEmpty)
        let record = try XCTUnwrap(phone.oracle.records.values.first)
        XCTAssertEqual(record.trustedType, 0)
        XCTAssertFalse(phone.dialRelayCallIfOnline())
        announcer?.stop()
        announcer = nil
    }

    // Full chain: announce online → relayCall dial → channel → ring → 200.
    func testRelayCallRingEndToEnd() throws {
        phone = try makePhone()
        let phonePort = try XCTUnwrap(phone.boundPort)

        announcer = LyraMeshAnnouncer(
            deviceIdHexProvider: { "721572C3" },
            displayNameProvider: { "MacBook Pro" }
        )
        announcer?.start(host: "127.0.0.1", port: phonePort)

        waitFor("Mac online in oracle") {
            self.phone.oracle.onlineDevices().contains { $0.device.hasService("relayCall") }
        }
        XCTAssertTrue(phone.dialRelayCallIfOnline())
        waitFor("relayCall channel up") {
            self.phone.relayCall.state == .channelUp
        }
        phone.relayCall.sendRing(number: "0912345678")
        waitFor("ring response") {
            self.phone.relayCall.lastRingResponse?.contains("\"code\":200") == true
        }
        announcer?.stop()
        announcer = nil
    }

    // 2026-09-05: the phone never switches call-audio routing for us because
    // our deviceType 14 fails TeleService's relay filter (2/4/11) — the only
    // exemption is the pref_device_answered pin, written ONLY by
    // handleRelayOperate(operateType=0) when a relayed call is answered on
    // the device. Reproduce: ring the Mac over the relayCall channel, answer
    // the call Mac-side, and the phone must receive relay://operate
    // {operateType:0} and pin our deviceId.
    func testIncomingCallAnswerSendsOperateAnswerAndPhonePinsDevice() throws {
        phone = try makePhone()
        let phonePort = try XCTUnwrap(phone.boundPort)

        announcer = LyraMeshAnnouncer(
            deviceIdHexProvider: { "721572C3" },
            displayNameProvider: { "MacBook Pro" }
        )
        announcer?.start(host: "127.0.0.1", port: phonePort)

        waitFor("Mac online in oracle") {
            self.phone.oracle.onlineDevices().contains { $0.device.hasService("relayCall") }
        }
        XCTAssertTrue(phone.dialRelayCallIfOnline())
        waitFor("relayCall channel up") {
            self.phone.relayCall.state == .channelUp
        }
        phone.relayCall.sendRing(number: "0912345678")
        waitFor("ring answered, connection relayed") {
            self.phone.relayCall.relayedNumbers.contains("0912345678")
        }

        // The user answers the incoming call on the Mac UI.
        LyraRelayCallSession.noteIncomingCallAnswered(address: "0912345678")

        waitFor("operate(0) received by phone") {
            self.phone.relayCall.operateRequests.contains(
                LyraRelayCallRole.OperateRequest(
                    operateType: 0, address: "0912345678", requestDeviceId: "721572C3"
                )
            )
        }
        waitFor("phone pins answered device") {
            self.phone.relayCall.answeredDeviceId == "721572C3"
        }
        waitFor("operate response 200 back at the Mac") {
            LyraRelayCallSession.activeRelaySession?.lastOperateResponseCode == 200
        }
        announcer?.stop()
        announcer = nil
    }

    // The phone's gate: operate(0) without a relayed connection (no ring was
    // ever sent, e.g. a fresh phone whose filter never included us) fails
    // with 500 and must NOT pin. Sending it is still harmless — this is the
    // bootstrap dead-end documented in AGENTS.md.
    func testOperateAnswerWithoutRingRejectedAndNotPinned() throws {
        phone = try makePhone()
        let phonePort = try XCTUnwrap(phone.boundPort)

        announcer = LyraMeshAnnouncer(
            deviceIdHexProvider: { "721572C3" },
            displayNameProvider: { "MacBook Pro" }
        )
        announcer?.start(host: "127.0.0.1", port: phonePort)

        waitFor("Mac online in oracle") {
            self.phone.oracle.onlineDevices().contains { $0.device.hasService("relayCall") }
        }
        XCTAssertTrue(phone.dialRelayCallIfOnline())
        waitFor("relayCall channel up") {
            self.phone.relayCall.state == .channelUp
        }

        LyraRelayCallSession.noteIncomingCallAnswered(address: "0912345678")

        waitFor("operate(0) received by phone") {
            !self.phone.relayCall.operateRequests.isEmpty
        }
        waitFor("operate rejected 500") {
            LyraRelayCallSession.activeRelaySession?.lastOperateResponseCode == 500
        }
        XCTAssertNil(phone.relayCall.answeredDeviceId)
        announcer?.stop()
        announcer = nil
    }

    // Regression pin for the 2026-09-05 change: relayCall must be advertised
    // by DEFAULT (no xiaomiRelayCallAdvertise flag) or the phone's filtered
    // relay map never contains us and the whole call-relay chain is dead.
    func testRelayCallAdvertisedByDefault() throws {
        UserDefaults.standard.removeObject(forKey: "xiaomiRelayCallAdvertise")
        phone = try makePhone()
        let phonePort = try XCTUnwrap(phone.boundPort)

        announcer = LyraMeshAnnouncer(
            deviceIdHexProvider: { "721572C3" },
            displayNameProvider: { "MacBook Pro" }
        )
        announcer?.start(host: "127.0.0.1", port: phonePort)

        waitFor("Mac online with relayCall by default") {
            self.phone.oracle.onlineDevices().contains { $0.device.hasService("relayCall") }
        }
        announcer?.stop()
        announcer = nil
    }
}
