import CryptoKit
import EdgeLinkKit
import Foundation
import LyraServerKit
import Network
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
        LyraRelayCallSession.pendingBridgeDialAddress = nil
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

    // MARK: - Outgoing dial (2026-09-05: pin coverage for the 90% case)

    // Full chain for an outgoing call: Mac dials relayPhoneCall → phone
    // records DIAL + sets deviceInRelay + placeCall extras → return
    // relayCall channel comes up → update_call_state(4) ACTIVE flows back.
    //
    // Assertions: Mac sends ZERO operate requests during the entire dial
    // chain (DIAL itself sets all the relay state — operate(0) during a
    // dial hits the already-in-relay branch and is actively harmful);
    // the answeredDeviceId pin is not touched (it was set once by the
    // initial bootstrap and stays permanent).
    func testOutgoingDialFullChainNoOperateSent() throws {
        phone = try makePhone()
        let role = LyraRelayPhoneCallRole()
        role.releaseDelayAfterCallEnd = 0.5
        role.onEvent = { print("[relaydial-mock] \($0)") }
        phone.mesh.register(role)
        let phonePort = try XCTUnwrap(phone.boundPort)

        announcer = LyraMeshAnnouncer(
            deviceIdHexProvider: { "721572C3" },
            displayNameProvider: { "MacBook Pro" }
        )
        announcer?.start(host: "127.0.0.1", port: phonePort)

        waitFor("Mac online in oracle") {
            self.phone.oracle.onlineDevices().contains { $0.device.hasService("relayCall") }
        }

        let dialer = LyraRelayCallDialer(
            deviceIdHexProvider: { "721572C3" },
            displayNameProvider: { "MacBook Pro" }
        )
        dialer.dial(number: "0987654321", host: "127.0.0.1", ports: [phonePort])

        waitFor("dial request received") {
            role.dialRequests.count == 1 && dialer.state == .done
        }

        // TeleService handleRelayDialRequest: placeCall with relay extras.
        XCTAssertEqual(role.dialRequests.first?.address, "0987654321")
        XCTAssertEqual(role.dialRequests.first?.requestDeviceId, "721572C3")
        XCTAssertEqual(role.deviceInRelay, "721572C3")
        XCTAssertNotNil(role.placeCallExtras)
        XCTAssertEqual(role.placeCallExtras?["EXTRA_CALL_RELAYED"] as? Bool, true)
        XCTAssertEqual(role.placeCallExtras?["EXTRA_RELAY_ANSWERED"] as? Bool, true)

        // Phone dials return relayCall channel on the dial session key.
        let sessionKey = try XCTUnwrap(role.sessionKey)
        phone.relayCall.hangup(server: phone.mesh)
        phone.relayCall.dial(server: phone.mesh, sessionKey: sessionKey)
        waitFor("return channel up") { self.phone.relayCall.state == .channelUp }

        // Call goes ACTIVE → phone pushes update_call_state(4).
        role.noteCallActive()
        phone.relayCall.sendUpdateCallState(4)
        waitFor("update_call_state(4) acked") {
            self.phone.relayCall.lastRingResponse?.contains("\"code\":200") == true
        }

        // The Mac's relay session must exist and see the call as active.
        XCTAssertNotNil(LyraRelayCallSession.activeRelaySession)
        XCTAssertTrue(LyraRelayCallSession.activeRelaySession?.isCallActive == true)

        // CRITICAL: no operate requests were sent during the entire dial
        // chain. operate(0) during a dial hits the already-in-relay branch
        // (deviceInRelay already set by DIAL) and releases extras → 500.
        XCTAssertTrue(
            phone.relayCall.operateRequests.isEmpty,
            "Mac must never send operate during a dial: \(phone.relayCall.operateRequests)"
        )
        // The answered device pin was not overwritten.
        XCTAssertNil(phone.relayCall.answeredDeviceId)

        dialer.stop()
        announcer?.stop()
        announcer = nil
    }

    // Bridge-fallback dial completion (live 2026-09-06 08:31): the LAN dial
    // timed out on a stale endpoint, the cloud-bridge dial placed the call
    // with relay extras (isCallRelayed=true) but handleRelayDialRequest
    // never ran → deviceInRelay stayed empty → "connectRelayAudio:false" at
    // ACTIVE → no distaudio routing for the whole call. The relayCall
    // session must send operate(0) on the phone's first update_call_state
    // for the dialed number: the not-in-relay branch then sets
    // EXTRA_RELAY_ANSWERED + deviceInRelay and refreshes the answered pin.
    func testBridgeDialFallbackSendsOperateOnFirstCallState() throws {
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

        // The extras-dialed call exists phone-side as a relayed connection
        // (getLocalConnectionWithNumber + isCallRelayed gate) but
        // deviceInRelay is empty — the bridge-dial half-state.
        phone.relayCall.relayedNumbers.insert("800")
        LyraRelayCallSession.pendingBridgeDialAddress = "800"

        phone.relayCall.sendUpdateCallState(3, address: "800")

        waitFor("operate(0) completes the bridge dial") {
            self.phone.relayCall.operateRequests.contains(
                LyraRelayCallRole.OperateRequest(
                    operateType: 0, address: "800", requestDeviceId: "721572C3"
                )
            )
        }
        waitFor("phone enters relay + pins device") {
            self.phone.relayCall.deviceInRelay == "721572C3" &&
                self.phone.relayCall.answeredDeviceId == "721572C3"
        }
        waitFor("operate response 200 back at the Mac") {
            LyraRelayCallSession.activeRelaySession?.lastOperateResponseCode == 200
        }

        // Exactly once: the update_call_state churn mid-call must not
        // re-send (pending was consumed by the first send).
        let sentCount = phone.relayCall.operateRequests.count
        phone.relayCall.sendUpdateCallState(4, address: "800")
        phone.relayCall.sendUpdateCallState(4, address: "800")
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(phone.relayCall.operateRequests.count, sentCount)

        announcer?.stop()
        announcer = nil
    }

    // already-in-relay branch (deviceInRelay was set by DIAL) → returns 500
    // and releaseRelayExtra drops EXTRA_CALL_RELAYED for that address.
    // Subsequent operate(0) for the same address also fails because the
    // relayed connection no longer exists.
    //
    // This test proves the production code must NEVER send operate(0) from
    // the dial path (LyraRelayCallDialer).
    func testOperateDuringDialRejectedAndReleasesExtras() throws {
        phone = try makePhone()
        let role = LyraRelayPhoneCallRole()
        role.releaseDelayAfterCallEnd = 0.5
        role.onEvent = { print("[relaydial-mock] \($0)") }
        phone.mesh.register(role)
        let phonePort = try XCTUnwrap(phone.boundPort)

        announcer = LyraMeshAnnouncer(
            deviceIdHexProvider: { "721572C3" },
            displayNameProvider: { "MacBook Pro" }
        )
        announcer?.start(host: "127.0.0.1", port: phonePort)

        waitFor("Mac online in oracle") {
            self.phone.oracle.onlineDevices().contains { $0.device.hasService("relayCall") }
        }

        let dialer = LyraRelayCallDialer(
            deviceIdHexProvider: { "721572C3" },
            displayNameProvider: { "MacBook Pro" }
        )
        dialer.dial(number: "0987654321", host: "127.0.0.1", ports: [phonePort])

        waitFor("dial complete") {
            role.dialRequests.count == 1 && dialer.state == .done
        }
        XCTAssertEqual(role.deviceInRelay, "721572C3")

        // Bring up return relayCall channel.
        let sessionKey = try XCTUnwrap(role.sessionKey)
        phone.relayCall.hangup(server: phone.mesh)
        phone.relayCall.dial(server: phone.mesh, sessionKey: sessionKey)
        waitFor("return channel up") { self.phone.relayCall.state == .channelUp }

        role.noteCallActive()

        // Model the relayed connection that DIAL established: in production
        // placeCall sets EXTRA_CALL_RELAYED which makes isCallRelayed true;
        // the mock relayCall role tracks this in relayedNumbers.
        phone.relayCall.relayedNumbers.insert("0987654321")
        // TeleService shares deviceInRelay across all relay handlers; the
        // DIAL set it on the relayPhoneCall role, model the same on relayCall.
        phone.relayCall.deviceInRelay = "721572C3"

        // Mac (incorrectly) sends operate(0) during the outgoing call.
        LyraRelayCallSession.noteIncomingCallAnswered(address: "0987654321")

        waitFor("operate(0) received by phone") {
            !self.phone.relayCall.operateRequests.isEmpty
        }
        waitFor("phone rejected 500 (already-in-relay)") {
            LyraRelayCallSession.activeRelaySession?.lastOperateResponseCode == 500
        }

        // releaseRelayExtra cleared the relayed connection for this address.
        XCTAssertFalse(
            phone.relayCall.relayedNumbers.contains("0987654321"),
            "relayedNumbers must be cleared after already-in-relay rejection"
        )
        // A subsequent operate(0) for the same address also fails: the
        // relayed connection no longer exists (isCallRelayed is false).
        LyraRelayCallSession.noteIncomingCallAnswered(address: "0987654321")
        waitFor("second operate(0) also rejected") {
            self.phone.relayCall.operateRequests.count == 2
        }
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(
            LyraRelayCallSession.activeRelaySession?.lastOperateResponseCode, 500,
            "second operate must also fail after extras released"
        )
        // Pin was never refreshed (both rejections skipped saveDeviceAnswered).
        XCTAssertNil(phone.relayCall.answeredDeviceId)

        dialer.stop()
        announcer?.stop()
        announcer = nil
    }

    // 2026-09-05 19:35 live: the phone's score-based phys-conn reuse dialed
    // com.miui.audiomonitor:DistAudioService on a socket owned by the cast
    // trust session. The trust session's sync_info dispatch only knew
    // mitrust/synctask/relayCall and the catch-all swallowed the foreign
    // sync_info — the DistAudio channel never established, the call audio
    // route stayed EARPIECE and the far end heard only the phone's room mic
    // (nothing). The cast socket must adopt these dials exactly like the
    // announcer socket does.
    func testDistAudioDialOnCastTrustSocketAdoptsRpcSession() throws {
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
        // The announce handshake seeds the ticket-store session key that the
        // DistAudio RPC session decrypts quickConns with.
        XCTAssertNotNil(MiTrustTicketStore.current().sessionKey)

        let session = LyraCastTrustSession(
            endpoints: [("127.0.0.1", 9)],
            deviceIdHex: "721572C3",
            displayName: "MacBook Pro",
            trustManager: MacTrustManager()
        )
        session.start()
        waitFor("cast trust socket bound") { session.meshSocketBoundPort != nil }
        let castPort = try XCTUnwrap(session.meshSocketBoundPort)

        let distAudio = LyraRelayCallRole(identity: LyraPhoneIdentity.generate())
        distAudio.dialServiceNameOverride = LyraDistAudioRpcSession.serviceName
        distAudio.dialServicePackageOverride = LyraDistAudioRpcSession.servicePackage
        let sessionKey = try XCTUnwrap(phone.mesh.peer.sessionKey)
        // Aim the dial at the cast trust session's own socket (the live
        // 19:35 retry rode the rebuilt session's phys conn); without the
        // target override the mock would send to the announcer's endpoint,
        // whose adoption branch already exists.
        distAudio.dial(
            server: phone.mesh, sessionKey: sessionKey, toHost: "127.0.0.1", toPort: castPort
        )

        // Pre-fix this waits forever: the trust session ignored the
        // sync_info (trust_sync_info_ignored) so no sync-auth reply, no
        // logi response, no responseOfPeerPort, no channel.
        waitFor("DistAudio channel up via cast trust socket") { distAudio.state == .channelUp }
        XCTAssertTrue(LyraDistAudioRpcSession.activeSession != nil)

        LyraDistAudioRpcSession.activeSession?.teardown()
        session.cancel()
        announcer?.stop()
        announcer = nil
    }

    // 2026-09-06 11:49 live: the phone's DistAudio dial rode the phys conn
    // the cast trust session had DIALED — the sync_info arrived from the
    // phone's mesh port on the session's own outbound connection (score-
    // based reuse), not on an inbound listener connection. The adoption's
    // send closure was hardcoded to sendInboundAsync: no inbound connection
    // matched the phone's mesh port, so every reply (sync_info, logi
    // response, responseOfPeerPort) was silently dropped, the phone hit its
    // ~15s kcp timeout and redialed twice, and the connected distaudio route
    // (connectDistAudioDevice route=721572C3 fired) never carried audio.
    // The send must fall back to the session's own outbound conn when the
    // arrival endpoint isn't an inbound connection.
    func testDistAudioDialRidingCastSessionOutboundConnEstablishesChannel() throws {
        phone = try makePhone()
        let phonePort = try XCTUnwrap(phone.boundPort)

        // Seed the ticket-store session key the quickConn decrypt uses.
        let sharedKey = SymmetricKey(size: .bits256)
        let keyHex = sharedKey.withUnsafeBytes { Data($0).map { String(format: "%02x", $0) }.joined() }
        UserDefaults.standard.set(keyHex, forKey: "xiaomiTrustSessionKeyHex")
        MiTrustTicketStore.lastAuthSessionKeyData = nil

        let session = LyraCastTrustSession(
            endpoints: [("127.0.0.1", phonePort)],
            deviceIdHex: "721572C3",
            displayName: "MacBook Pro",
            trustManager: MacTrustManager()
        )
        session.start()
        // The session's phys sync makes the mock phone record the MAC-side
        // source port of the session's outbound connection as its peer.
        waitFor("phone saw cast session phys sync") {
            !self.phone.mesh.peer.endpointDescription.isEmpty
        }

        let distAudio = LyraRelayCallRole(identity: LyraPhoneIdentity.generate())
        distAudio.dialServiceNameOverride = LyraDistAudioRpcSession.serviceName
        distAudio.dialServicePackageOverride = LyraDistAudioRpcSession.servicePackage
        // No toHost/toPort override: the mock sends from its mesh listener
        // port to the session's outbound-conn source port (sendToPeer over
        // the inbound conn the session's phys sync created) — exactly the
        // wire shape of the phone reusing OUR dialed phys conn. Pre-fix the
        // replies black-holed (sendInboundAsync found no inbound connection
        // for the phone's mesh port) and this wait never completed.
        distAudio.dial(server: phone.mesh, sessionKey: sharedKey)

        waitFor("DistAudio channel up via outbound-ridden dial") { distAudio.state == .channelUp }
        XCTAssertTrue(LyraDistAudioRpcSession.activeSession != nil)

        LyraDistAudioRpcSession.activeSession?.teardown()
        session.cancel()
    }

    // 2026-09-05 20:01 live: a relay-fed adoption makes the phone's channel
    // client dial the bridge's reverse listener (127.0.0.1:<port>) — the
    // RPC session must host the channel on the bridge pipe and announce the
    // listener before responseOfPeerPort, or the RPC bind dies on phys
    // heartbeat timeouts and openSpeaker/openMic are dropped ("rpc service
    // is null"), leaving the phone mic muted and the far end deaf.
    func testDistAudioAdoptOnRelayFedConnHostsChannelOnBridgePipe() throws {
        // Seed the ticket-store session key the quickConn decrypt uses.
        let sharedKey = SymmetricKey(size: .bits256)
        let keyHex = sharedKey.withUnsafeBytes { Data($0).map { String(format: "%02x", $0) }.joined() }
        UserDefaults.standard.set(keyHex, forKey: "xiaomiTrustSessionKeyHex")
        MiTrustTicketStore.lastAuthSessionKeyData = nil

        var sentEnvelopes: [Data] = []
        let bridge = LyraRelayTransportBridge(sendHandler: { envelope in
            sentEnvelopes.append(envelope)
        })

        let transKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        var peerPortRequest = Data()
        LyraProtoWriter.appendVarintField(1, value: 7, to: &peerPortRequest)
        LyraProtoWriter.appendLengthDelimitedField(4, value: transKey, to: &peerPortRequest)
        var userInfo = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &userInfo)
        LyraProtoWriter.appendLengthDelimitedField(2, value: Data("com.miui.audiomonitor".utf8), to: &userInfo)
        LyraProtoWriter.appendLengthDelimitedField(10, value: peerPortRequest, to: &userInfo)
        var request = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &request)
        LyraProtoWriter.appendLengthDelimitedField(
            2, value: Data("com.miui.audiomonitor:DistAudioService".utf8), to: &request
        )
        LyraProtoWriter.appendLengthDelimitedField(3, value: userInfo, to: &request)
        var connRequest = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &connRequest)
        LyraProtoWriter.appendLengthDelimitedField(2, value: request, to: &connRequest)
        let quickConn = try XCTUnwrap(LyraAuthHandshake.gcmSeal(connRequest, using: sharedKey))

        var syncInfo = Data()
        LyraProtoWriter.appendVarintField(1, value: 10000, to: &syncInfo)
        LyraProtoWriter.appendLengthDelimitedField(4, value: Data(LyraDistAudioRpcSession.serviceName.utf8), to: &syncInfo)
        LyraProtoWriter.appendLengthDelimitedField(8, value: quickConn, to: &syncInfo)
        let connId: UInt32 = 0x1122_3344
        let syncFrame = LogiConnFrame(
            logiConnId: connId, localNetId: 1, remoteNetId: 2, inner: syncInfo
        )

        var sentFrames: [(LyraMeshPack.Frame, String)] = []
        _ = LyraDistAudioRpcSession.adopt(
            syncInfoData: syncInfo, logiConn: syncFrame,
            endpoint: NWEndpoint.hostPort(host: .ipv4(.loopback), port: 40_000),
            sessionKey: sharedKey, deviceIdHex: "721572C3", deviceName: "Mac",
            channelBridge: bridge
        ) { frame, label in
            sentFrames.append((frame, label))
        }
        let session = try XCTUnwrap(LyraDistAudioRpcSession.activeSession)
        XCTAssertTrue(sentFrames.contains { $0.1 == "distrpc_sync_info" })

        // responseAck clears peerPortAwaitingAck → the listener announce goes
        // out ahead of responseOfPeerPort.
        let ackInner = LogiConnInnerFrame(frameType: 3, payload: .responseAck(Data()))
        let ackSealed = try XCTUnwrap(LyraAuthHandshake.gcmSeal(ackInner.serialized(), using: sharedKey))
        session.handleFrame(
            LogiConnFrame(logiConnId: connId, localNetId: 1, remoteNetId: 2, flag: true, inner: ackSealed)
        )
        // The announce envelope rides an ordered async Task chain — wait for
        // it, then assert the port came from the bridge allocator
        // (20_000...60_999), not an OS ephemeral port.
        waitFor("relay.channel.listen envelope sent") {
            !self.listenEnvelopePorts(from: sentEnvelopes).isEmpty
        }
        let listenPort = try XCTUnwrap(
            self.listenEnvelopePorts(from: sentEnvelopes).first, "relay.channel.listen envelope missing"
        )
        XCTAssertTrue((20_000...60_999).contains(listenPort), "bridge-allocated port expected, got \(listenPort)")
        XCTAssertTrue(sentFrames.contains { $0.1 == "distrpc_peer_port_response" })
        session.teardown()
        UserDefaults.standard.removeObject(forKey: "xiaomiTrustSessionKeyHex")
    }

    private func listenEnvelopePorts(from envelopes: [Data]) -> [Int] {
        envelopes.compactMap { data in
            (try? JSONDecoder().decode(Envelope<RelayChannelListenBody>.self, from: data))?.b.p
        }
    }
}
