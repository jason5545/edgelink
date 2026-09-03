import CryptoKit
import EdgeLinkKit
import Foundation
import LyraServerKit
import Network
import XCTest

// Mirror-call relay (call uplink via the phone's own Mirror.apk
// CallRelayAudioManager, the only writer of IMirrorOption 0x100707 /
// Business_IsPhoneRelay). Research: docs/distaudio-uplink-no-hook-notes.md +
// captures/xiaomi-mirror-device (Mirror.apk CallRelayAudioManager /
// MirrorCallService G) + libCastService-jni TSPacketizer disasm.
//
// The mock phone role (LyraMirrorCallRelayRole) plays MirrorCallService:
// event 23 KeyData exchange (ECDH P-256), event 24/31 sink start, RTSP
// client, and AAC/AESPART media validation.
//
// Production answers event 23 with its own KeyData and drives event
// 24/31/25 from call state; testMockSinkNegotiatesWithDistAudioWFDServer
// is the GREEN control: the mock sink speaks the exact miplaycast dialect
// the production LyraDistAudioWFDServer serves, proving the harness.
@MainActor
final class LyraMirrorCallRelayTests: XCTestCase {
    private static let defaultsKeys = [
        "xiaomiTrustIdentityPrivHex",
        "xiaomiTrustIdentityPubB64",
        "xiaomiTrustPeerIdentityPubB64",
        "xiaomiTrustPeerAccountPubB64",
        "xiaomiTrustDeviceUUID",
        "xiaomiTrustSessionKeyHex",
        "xiaomiTrustTicketHex",
    ]

    private static var portBlockIndex: UInt16 = 0
    private var meshPort: UInt16!

    private var savedValues: [String: Any?] = [:]
    private let macIdentity = P256.Signing.PrivateKey()
    private var phone: LyraPhoneServer?
    private var relay: LyraMirrorCallRelayRole?
    private var session: LyraCastTrustSession?
    private var trustManager: MacTrustManager?

    override func setUp() {
        super.setUp()
        Self.portBlockIndex += 1
        meshPort = 31_101 + Self.portBlockIndex * 10
        continueAfterFailure = false
        LyraMirrorCallRelaySession.resetPendingCallState()
        LyraMirrorCallRelaySession.phoneMirrorCallEngaged = false
        let defaults = UserDefaults.standard
        for key in Self.defaultsKeys {
            savedValues[key] = defaults.object(forKey: key)
        }
        defaults.set(UUID().uuidString, forKey: "xiaomiTrustDeviceUUID")
        defaults.set(macIdentity.rawRepresentation.map { String(format: "%02x", $0) }.joined(),
                     forKey: "xiaomiTrustIdentityPrivHex")
        defaults.set(macIdentity.publicKey.x963Representation.base64EncodedString(),
                     forKey: "xiaomiTrustIdentityPubB64")
        defaults.set(LyraPhoneIdentity.fixtureAccountPubB64, forKey: "xiaomiTrustPeerAccountPubB64")
        defaults.removeObject(forKey: "xiaomiTrustSessionKeyHex")
        defaults.removeObject(forKey: "xiaomiTrustTicketHex")
    }

    override func tearDown() {
        session?.cancel()
        session = nil
        phone?.stop()
        phone = nil
        relay = nil
        LyraMirrorCallRelaySession.resetPendingCallState()
        LyraMirrorCallRelaySession.phoneMirrorCallEngaged = false
        LyraMirrorCallRelaySession.onPhoneSourceEndpointChanged = nil
        let defaults = UserDefaults.standard
        for key in Self.defaultsKeys {
            if let value = savedValues[key] ?? nil {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        savedValues = [:]
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

    // Brings up the mock phone + the production cast trust session until the
    // cast channel is negotiated (the phone passively accepts the Mac's
    // DeviceChannel — live: "passive onChannelConfirm channelId:157").
    private func bringUpCastChannel() throws {
        let phone = LyraPhoneServer(identity: LyraPhoneIdentity.generate())
        phone.cast.setLocked(false)
        let relay = LyraMirrorCallRelayRole()
        relay.attach(cast: phone.cast)
        relay.onEvent = { print("[mirrorcall] \($0)") }
        self.relay = relay
        self.phone = phone
        try phone.start(port: meshPort)

        let trustManager = MacTrustManager()
        trustManager.statusRetryDelay = 0.1
        trustManager.maxStatusRetries = 3
        self.trustManager = trustManager
        let session = LyraCastTrustSession(
            endpoints: [("127.0.0.1", meshPort)],
            deviceIdHex: "721572C3",
            displayName: "EdgeLinkMacTests",
            trustManager: trustManager
        )
        self.session = session
        session.start()
        waitFor("cast channel ready") { session.isChannelReady }
    }

    // The phone's MirrorCallService sends MIRROR_CALL_KEY (event 23)
    // with its ECDH KeyData the moment the cast DeviceChannel comes up
    // (live: "MirrorCallService: sendKeyBytes" → "sendMsg ... channel:157,
    // SimpleEventMessage{ TYPE_MIRROR_CALL_KEY }"). The Mac must answer with
    // its own event-23 KeyData so the phone can startSink with
    // Business_IsPhoneRelay=1 later.
    func testMacAnswersMirrorCallKeyWithKeyData() throws {
        try bringUpCastChannel()
        let relay = try XCTUnwrap(relay)

        // The phone's source endpoint (its KeyData p2pIp/port) must surface
        // through the callback — the Android bridge's source pull depends on
        // it when MirrorCallService's getUnUsedPort walk leaves 7102.
        let endpointBox = LockedBox<(host: String, port: Int)?>(nil)
        LyraMirrorCallRelaySession.onPhoneSourceEndpointChanged = { host, port in
            endpointBox.with { $0 = (host, port) }
        }

        relay.sendMirrorCallKey()

        waitFor("Mac KeyData reply + ECDH") { relay.state == .keyExchanged }
        let macKeyData = try XCTUnwrap(relay.macKeyData)
        XCTAssertEqual(macKeyData.keyBytes.count, 91)  // X.509 SPKI P-256
        XCTAssertNotEqual(macKeyData.port, 0)
        XCTAssertFalse(macKeyData.p2pIp.isEmpty)
        XCTAssertEqual(relay.sharedSecret?.count, 32)
        XCTAssertEqual(relay.aesKey?.count, 16)
        XCTAssertEqual(relay.aesIV?.count, 16)

        waitFor("phone source endpoint surfaced") { endpointBox.value != nil }
        let endpoint = try XCTUnwrap(endpointBox.value)
        XCTAssertEqual(endpoint.port, relay.phoneSourcePort)
        XCTAssertEqual(endpoint.host, relay.phoneP2PIp)
    }

    // Full uplink flow: key exchange → call active (event 24 + 31) → the
    // phone sinks our audio source → RTSP M1-PLAY → encrypted AAC media that
    // the phone validates with the ECDH key/IV. Drives the production seam
    // (LyraCastTrustSession.notifyMirrorCallActive) and feeds synthetic PCM
    // through the production audio source's write(pcm:).
    func testCallActiveStartsPhoneRelaySinkWithAACUplink() throws {
        try bringUpCastChannel()
        let relay = try XCTUnwrap(relay)
        let session = try XCTUnwrap(session)

        relay.sendMirrorCallKey()
        waitFor("key exchange") { relay.state == .keyExchanged }

        session.notifyMirrorCallActive(true)
        waitFor("sink start event") { relay.callStartCount > 0 && relay.sinkStartPort != nil }
        waitFor("RTSP established") { relay.state == .established }
        waitFor("M4 selects LPCM 8k") { relay.m4SelectsLPCM8k }

        let source = try XCTUnwrap(session.mirrorCallRelay?.audioSource)
        // 8 kHz mono s16 sine; 640 bytes = two 20 ms frames per write.
        var phase = 0.0
        for _ in 0..<40 {
            var pcm = Data(count: 640)
            pcm.withUnsafeMutableBytes { raw in
                let samples = raw.bindMemory(to: Int16.self)
                for i in 0..<320 {
                    phase += 2 * .pi * 440 / 8000
                    samples[i] = Int16(sin(phase) * 8000)
                }
            }
            source.write(pcm: pcm)
        }
        waitFor("PCM frames decrypted by the phone") { relay.aacFrames >= 3 }
        XCTAssertGreaterThan(relay.decryptedAACBytes, 0)
        XCTAssertGreaterThan(relay.pesIVsSeen, 0)
        XCTAssertNil(relay.lastError)

        session.notifyMirrorCallActive(false)
        waitFor("call stop event") { relay.callStopCount > 0 }
    }

    // GREEN control: the mock sink's RTSP dialect against the CURRENT
    // production LyraDistAudioWFDServer (distaudio uplink, live-verified
    // against the real phone 2026-08-06/07). Negotiation must complete M1 →
    // M4 → SETUP. The M4 codec selection documents the Phase 3 delta: the
    // distaudio server picks LPCM ("wfd_audio_codecs_v2: 0 4"); the
    // PHONERELAY audio source must select the AAC offer instead.
    func testMockSinkNegotiatesWithDistAudioWFDServer() throws {
        var keyBytes = Data(count: 16)
        keyBytes.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress { arc4random_buf(base, 16) }
        }
        let server = LyraDistAudioWFDServer(mediaKeyBase64: keyBytes.base64EncodedString())
        try server.start()
        defer { server.stop() }
        // NWListener reports port 0 until bound; the server's start() only
        // waits for non-nil.
        waitFor("server listener bound") { (server.port ?? 0) != 0 }
        let serverPort = try XCTUnwrap(server.port)

        let relay = LyraMirrorCallRelayRole()
        relay.onEvent = { print("[mirrorcall-distaudio] \($0)") }
        relay.startSinkForTesting(host: "127.0.0.1", port: serverPort)

        waitFor("SETUP completed") { relay.setupCompleted }
        let m4 = try XCTUnwrap(relay.m4Body)
        XCTAssertTrue(
            m4.contains("wfd_audio_codecs_v2: 0 4"),
            "current distaudio server selects LPCM mode 4, got: \(m4)"
        )
        XCTAssertFalse(relay.m4SelectsAAC)
    }

    // Cloud-relay media route: when the advertise endpoint is set to the
    // phone-local sink server (AndroidCallRelayBridge's
    // LocalMiLinkRTSPSinkServer, 127.0.0.1:15550), KeyData must advertise
    // it, the local audio source listener must not run (the uplink rides
    // the secure-session envelope chain instead), and event 31 must carry
    // the advertised port.
    func testRelayAdvertiseEndpointSendsLoopbackKeyDataAndSinkPort() throws {
        try bringUpCastChannel()
        let relay = try XCTUnwrap(relay)
        let session = try XCTUnwrap(session)
        let mirrorCall = try XCTUnwrap(session.mirrorCallRelay)
        let relayPort = LyraMirrorCallRelaySession.relaySinkAdvertisePort

        mirrorCall.setAdvertiseEndpoint(("127.0.0.1", relayPort))
        // Deterministic ordering: the endpoint must be stored (and the
        // start()-time listener torn down) before the phone's KeyData
        // arrives, so the event-23 reply advertises the relay endpoint.
        waitFor("local audio source torn down") { session.mirrorCallRelay?.audioSource == nil }

        relay.sendMirrorCallKey()
        // The proactive start() KeyData (en0) already put the role in
        // .keyExchanged, so wait on the advertised fields themselves.
        waitFor("Mac KeyData reply advertises the relay endpoint") {
            relay.macKeyData?.p2pIp == "127.0.0.1" && relay.macKeyData?.port == Int(relayPort)
        }
        let macKeyData = try XCTUnwrap(relay.macKeyData)
        XCTAssertEqual(macKeyData.p2pIp, "127.0.0.1")
        XCTAssertEqual(macKeyData.port, Int(relayPort))
        XCTAssertEqual(relay.state, .keyExchanged)
        XCTAssertNil(session.mirrorCallRelay?.audioSource)

        session.notifyMirrorCallActive(true)
        waitFor("sink start at the advertised relay port") {
            relay.sinkStartPort == UInt32(relayPort) && relay.callStartCount > 0
        }

        session.notifyMirrorCallActive(false)
        waitFor("call stop event") { relay.callStopCount > 0 }
    }

    // The cloud bridge engages mid-call (the phone's LAN probe of the Mac
    // failed after the channel was already up): the advertised endpoint
    // must flip from the LAN source port to 127.0.0.1:15550 — event 23 is
    // re-sent (the phone re-ECDHs against the unchanged key) and event
    // 24/31 are re-sent with the new port — and the local listener is
    // torn down.
    func testCloudBridgeEngageFlipsAdvertisedEndpoint() throws {
        try bringUpCastChannel()
        let relay = try XCTUnwrap(relay)
        let session = try XCTUnwrap(session)
        let relayPort = LyraMirrorCallRelaySession.relaySinkAdvertisePort

        relay.sendMirrorCallKey()
        waitFor("key exchange") { relay.state == .keyExchanged }
        let lanKeyData = try XCTUnwrap(relay.macKeyData)
        XCTAssertNotEqual(lanKeyData.p2pIp, "127.0.0.1")
        XCTAssertNotEqual(lanKeyData.port, Int(relayPort))

        session.notifyMirrorCallActive(true)
        waitFor("sink start at the LAN source port") {
            relay.sinkStartPort != nil && relay.callStartCount > 0
        }
        let lanPort = try XCTUnwrap(session.mirrorCallRelay?.audioSource?.port)
        XCTAssertEqual(relay.sinkStartPort, UInt32(lanPort))

        session.mirrorCallRelay?.setAdvertiseEndpoint(("127.0.0.1", relayPort))

        waitFor("KeyData re-sent with the relay endpoint") {
            relay.macKeyData?.p2pIp == "127.0.0.1" && relay.macKeyData?.port == Int(relayPort)
        }
        waitFor("sink start re-sent with the relay port") {
            relay.sinkStartPort == UInt32(relayPort)
        }
        XCTAssertGreaterThan(relay.callStartCount, 1)
        XCTAssertNil(session.mirrorCallRelay?.audioSource)
    }

    // The call went active BEFORE the cast channel finished negotiating
    // (live 2026-09-02: the driver's exactly-once gate fired into a nil
    // activeSession and the whole call stayed silent): the pending drive
    // must be applied when the session starts, so event 24/31 go out as
    // soon as the keys land — no re-drive from the driver needed.
    func testPendingCallActiveBeforeSessionStartDrivesSinkStart() throws {
        LyraMirrorCallRelaySession.pendingCallActive = true
        try bringUpCastChannel()
        let relay = try XCTUnwrap(relay)

        relay.sendMirrorCallKey()
        waitFor("key exchange") { relay.state == .keyExchanged }
        waitFor("sink start from the pending active drive") {
            relay.callStartCount > 0 && relay.sinkStartPort != nil
        }
    }

    // The cloud bridge engaged while no session existed (its
    // sink_rtsp_listening beat the cast channel negotiation): the relay
    // advertise preference must survive until start() — the KeyData
    // advertises 127.0.0.1:15550 and no local listener is created.
    func testPreferRelayAdvertiseBeforeSessionStartAdvertisesLoopback() throws {
        LyraMirrorCallRelaySession.preferRelayAdvertise = true
        try bringUpCastChannel()
        let relay = try XCTUnwrap(relay)
        let session = try XCTUnwrap(session)
        let relayPort = LyraMirrorCallRelaySession.relaySinkAdvertisePort

        relay.sendMirrorCallKey()
        waitFor("Mac KeyData advertises the relay endpoint") {
            relay.macKeyData?.p2pIp == "127.0.0.1" && relay.macKeyData?.port == Int(relayPort)
        }
        // start() ran (it sent the KeyData above) and skipped the listener.
        XCTAssertNil(session.mirrorCallRelay?.audioSource)
    }

    // The exact live-2026-09-02 wedge combined: the call went active AND the
    // cloud bridge engaged before the cast channel finished negotiating.
    // start() applies the pending drive; the sink start must advertise the
    // phone-local relay port from preferRelayAdvertise — reading only the
    // instance advertiseEndpoint/audioSource found no port and silently
    // dropped event 24/31, so the phone's MirrorCallService never started.
    func testPendingActivePlusRelayAdvertiseBeforeStartSendsSinkStartAtRelayPort() throws {
        LyraMirrorCallRelaySession.pendingCallActive = true
        LyraMirrorCallRelaySession.preferRelayAdvertise = true
        try bringUpCastChannel()
        let relay = try XCTUnwrap(relay)
        let relayPort = LyraMirrorCallRelaySession.relaySinkAdvertisePort

        relay.sendMirrorCallKey()
        waitFor("key exchange") { relay.state == .keyExchanged }
        waitFor("sink start at the relay port from pending state alone") {
            relay.callStartCount > 0 && relay.sinkStartPort == UInt32(relayPort)
        }
    }

    // A session that sent 24/31 but never got to send 25 (channel released
    // at call end) leaves the phone's MirrorCallService source running and
    // wedged — live 2026-09-03: the next call's RTSP SETUP got 400 Bad
    // Request. The NEXT session's start() sends a stop-first resync (event
    // 25, sent before the KeyData/24/31 sequence by construction on the
    // same queue) and then re-runs the still-pending active drive.
    func testOrphanedPhoneSessionGetsStopFirstResyncOnNextStart() throws {
        try bringUpCastChannel()
        let relayA = try XCTUnwrap(self.relay)
        let session = try XCTUnwrap(session)

        relayA.sendMirrorCallKey()
        waitFor("key exchange") { relayA.state == .keyExchanged }
        session.notifyMirrorCallActive(true)
        waitFor("sink start on the first session") {
            relayA.callStartCount > 0 && relayA.sinkStartPort != nil
        }
        waitFor("engaged") { LyraMirrorCallRelaySession.phoneMirrorCallEngaged }

        // The call is STILL active (no terminal drive) but the channel dies:
        // the relay session is torn down without an event 25.
        session.cancel()
        phone?.stop()

        meshPort += 1
        // The driver still holds pendingCallActive=true for the ongoing call.
        LyraMirrorCallRelaySession.pendingCallActive = true
        try bringUpCastChannel()
        let relayB = try XCTUnwrap(self.relay)

        waitFor("orphan stop on the fresh channel") { relayB.callStopCount > 0 }
        relayB.sendMirrorCallKey()
        waitFor("active drive re-sent after the resync") {
            relayB.callStartCount > 0 && relayB.sinkStartPort != nil
        }
    }

    // A phone re-key on a redialed channel (MirrorCallService re-sends
    // event 23) must re-arm the sink start for an active call — the sticky
    // sinkStartSent flag used to silently drop it.
    func testPhoneRekeyRearmSinkStart() throws {
        try bringUpCastChannel()
        let relay = try XCTUnwrap(relay)
        let session = try XCTUnwrap(session)

        relay.sendMirrorCallKey()
        waitFor("key exchange") { relay.state == .keyExchanged }

        session.notifyMirrorCallActive(true)
        waitFor("first sink start") { relay.callStartCount == 1 && relay.sinkStartPort != nil }
        let firstSinkPort = relay.sinkStartPort

        session.notifyMirrorCallActive(false)
        waitFor("call stop") { relay.callStopCount == 1 }

        session.notifyMirrorCallActive(true)
        waitFor("second sink start") { relay.callStartCount == 2 }

        relay.sendMirrorCallKey()
        waitFor("sink start re-armed after the re-key") { relay.callStartCount == 3 }
        XCTAssertEqual(relay.sinkStartPort, firstSinkPort)
    }

    // Live 2026-09-03 (relay call, no audio — the user hung up 7s after
    // answer): the phone idle-released the cast channel mid-call and the
    // driver's redialCastChannel dialed an ENCRYPTED logi request on a fresh
    // logiConnId with no preceding sync_info — the phone has no key state
    // for that connId and can never answer (the dial also rode the
    // freshly-adopted mitrustservice conn via adoptedSend — a different phys
    // conn with different keys). 3/3 redials that morning blackholed for the
    // full 6s redial timeout — one on a phys conn still receiving keepalive
    // frames — and every working recovery came from the fresh-session
    // rebuild AFTER the timeout (00:33:05→00:33:07, ready in 2s).
    // redialCastChannel must fail fast so the rebuild starts immediately;
    // the teardown must still release the adopted mitrustservice conn (the
    // 52011 zombie-unlock fix).
    func testChannelRedialFailsFastSoRuntimeRebuildsFreshSession() throws {
        try bringUpCastChannel()
        let phone = try XCTUnwrap(self.phone)
        let firstSession = try XCTUnwrap(self.session)

        // The phone's trustservice adopts mitrustservice into the session
        // (score-based reuse onto its own dialed conn — the announcer adopt
        // path); the session's sends now ride the adopted conn.
        let adoptedConnId: UInt32 = 0x5EDE_0001
        var peerCred = Data()
        var peerConnIdBytes = Data(count: 8)
        peerConnIdBytes.withUnsafeMutableBytes { raw in
            if let base = raw.baseAddress { arc4random_buf(base, 8) }
        }
        LyraProtoWriter.appendLengthDelimitedField(1, value: peerConnIdBytes, to: &peerCred)
        LyraProtoWriter.appendLengthDelimitedField(
            2, value: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation, to: &peerCred
        )
        var syncInfo = Data()
        LyraProtoWriter.appendVarintField(1, value: 10000, to: &syncInfo)
        LyraProtoWriter.appendVarintField(2, value: 48, to: &syncInfo)
        LyraProtoWriter.appendVarintField(3, value: 1, to: &syncInfo)
        LyraProtoWriter.appendLengthDelimitedField(
            4, value: Data("com.xiaomi.trustservice:mitrustservice".utf8), to: &syncInfo
        )
        LyraProtoWriter.appendLengthDelimitedField(5, value: peerCred, to: &syncInfo)
        let adoptedSends = LockedBox<[LyraMeshPack.Frame]>([])
        firstSession.adoptMitrustSyncInfo(
            syncInfoData: syncInfo,
            logiConn: LogiConnFrame(logiConnId: adoptedConnId, localNetId: 2, remoteNetId: 1),
            endpoint: NWEndpoint.hostPort(
                host: "127.0.0.1", port: NWEndpoint.Port(rawValue: meshPort)!
            ),
            viaRelay: false
        ) { frame in
            adoptedSends.with { $0.append(frame) }
        }

        // The Mirror app's idle auto-release of the cast channel (live ~7s).
        phone.cast.releaseCastChannel()
        waitFor("channel released by the phone") { !firstSession.isChannelReady }
        XCTAssertTrue(firstSession.channelWasEstablishedBefore)

        // The driver's redialChannel path.
        let finished = LockedBox(false)
        firstSession.onFinish = { finished.with { $0 = true } }
        firstSession.redialCastChannel()

        // Pre-fix this stalled the full redial timeout (the dialed
        // logi_request can never be answered); the fail must be immediate.
        waitFor("redial fails fast so the runtime rebuilds", timeout: 3) { finished.value }

        // No cast-service dial may leak into the adopted conn: every frame
        // on it targets the mitrustservice connId, and the teardown still
        // releases that conn (frameType 4 disconnect, the 52011 precedent)
        // so the phone's mitrust channel client never goes zombie.
        for frame in adoptedSends.value {
            guard let miFrame = MiConnectFrame(parsing: frame.payload) else { continue }
            for logiConn in miFrame.logiConnFrames {
                XCTAssertEqual(
                    logiConn.logiConnId, adoptedConnId,
                    "a cast-service dial leaked into the adopted mitrustservice conn"
                )
            }
        }
        let sawMitrustRelease = adoptedSends.value.contains { frame in
            guard let miFrame = MiConnectFrame(parsing: frame.payload),
                  let logiConn = miFrame.logiConnFrames.first(where: { $0.logiConnId == adoptedConnId }),
                  let inner = LogiConnInnerFrame(parsing: logiConn.inner)
            else { return false }
            return inner.frameType == 4
        }
        XCTAssertTrue(sawMitrustRelease, "teardown must still release the adopted mitrustservice conn")

        // The runtime's recovery (handleSessionFinished → ensureChannel): a
        // fresh session — the only dial the current firmware answers.
        meshPort += 1
        try bringUpCastChannel()
        let relayB = try XCTUnwrap(self.relay)
        relayB.sendMirrorCallKey()
        waitFor("mirror-call key exchange on the rebuilt channel") {
            relayB.state == .keyExchanged
        }
    }
}
