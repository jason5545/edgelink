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
// testMacAnswersMirrorCallKeyWithKeyData is RED against current production
// (the cast session only logs event 23 today) and defines the Phase 3
// production change. testMockSinkNegotiatesWithDistAudioWFDServer is the
// GREEN control: the mock sink speaks the exact miplaycast dialect the
// current production LyraDistAudioWFDServer serves, proving the harness.
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

    // RED: the phone's MirrorCallService sends MIRROR_CALL_KEY (event 23)
    // with its ECDH KeyData the moment the cast DeviceChannel comes up
    // (live: "MirrorCallService: sendKeyBytes" → "sendMsg ... channel:157,
    // SimpleEventMessage{ TYPE_MIRROR_CALL_KEY }"). The Mac must answer with
    // its own event-23 KeyData so the phone can startSink with
    // Business_IsPhoneRelay=1 later. Today the Mac only logs the event, so
    // this times out — that is the Phase 3 production change.
    func testMacAnswersMirrorCallKeyWithKeyData() throws {
        try bringUpCastChannel()
        let relay = try XCTUnwrap(relay)

        relay.sendMirrorCallKey()

        waitFor("Mac KeyData reply + ECDH") { relay.state == .keyExchanged }
        let macKeyData = try XCTUnwrap(relay.macKeyData)
        XCTAssertEqual(macKeyData.keyBytes.count, 91)  // X.509 SPKI P-256
        XCTAssertNotEqual(macKeyData.port, 0)
        XCTAssertFalse(macKeyData.p2pIp.isEmpty)
        XCTAssertEqual(relay.sharedSecret?.count, 32)
        XCTAssertEqual(relay.aesKey?.count, 16)
        XCTAssertEqual(relay.aesIV?.count, 16)
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
}
