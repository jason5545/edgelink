import EdgeLinkKit
import Foundation
import Network
import XCTest

// End-to-end mirror flow tests: the REAL LyraCastTrustSession +
// MacTrustManager + XiaomiMirrorFlowController + XiaomiMirrorWFDClient run
// against FakeXiaomiPhone on loopback. A test passes only when the whole
// flow completes: channel → 577 status → OPEN_MIRROR_SCREEN → WFD M1-M8 →
// UDP video — and for the locked case, the full 595/546/562 mitrust unlock
// with the duo.screen auth event driving the mask.
@MainActor
final class MirrorFlowE2ETests: XCTestCase {
    private var phone: FakeXiaomiPhone!
    private var session: LyraCastTrustSession!
    private var trustManager: MacTrustManager!
    private var controller: XiaomiMirrorFlowController!
    private var wfdClient: XiaomiMirrorWFDClient?
    private var videoListener: NWListener?
    private var videoDatagramsReceived = 0
    private var videoConnection: NWConnection?
    private var biometricCallCount = 0
    // Tests default to the official 20s IDR one-shot; the mid-GOP test
    // shortens it. The established→notifyVideoFrame shortcut stays on for the
    // happy-path tests but is disabled when video starvation is the point.
    private var wfdIDRRequestDelay: TimeInterval = 20
    private var establishedNotifiesVideoFrame = true

    private let meshPort: UInt16 = 29_101
    private let castChannelPort: UInt16 = 29_102
    private let wfdPort: UInt16 = 29_103
    private let clientVideoPort: UInt16 = 29_104

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    override func tearDown() {
        wfdClient?.stop(reason: "teardown")
        videoListener?.cancel()
        videoConnection?.cancel()
        session?.cancel()
        phone?.stop()
        super.tearDown()
    }

    private func makeEnvironment(locked: Bool) throws {
        // trustDeviceUUID() reads a generic-password item owned by the real
        // app — in the test process that keychain read blocks on an ACL
        // prompt. Override it so tests never touch that item.
        UserDefaults.standard.set(UUID().uuidString, forKey: "xiaomiTrustDeviceUUID")
        phone = FakeXiaomiPhone(
            meshPort: meshPort,
            castChannelPort: castChannelPort,
            wfdPort: wfdPort,
            clientVideoPort: clientVideoPort,
            locked: locked
        )
        phone.log = { print("[fakephone] \($0)") }
        try phone.start()

        trustManager = MacTrustManager()
        session = LyraCastTrustSession(
            endpoints: [("127.0.0.1", meshPort)],
            deviceIdHex: "721572C3",
            displayName: "EdgeLinkMacTests",
            trustManager: trustManager
        )
        session.retainPhysAfterAuth = true
        session.duoScreenStatusEnabled = true

        controller = XiaomiMirrorFlowController(trustManager: trustManager)
        controller.sessionProvider = { [weak self] in self?.session }
        controller.sessionFactory = { _ in }
        controller.biometricEvaluate = { [weak self] in
            self?.biometricCallCount += 1
        }
        controller.openMirrorScreen = { [weak self] session in
            guard let self else { return }
            let sessionId = UInt64(Date().timeIntervalSince1970 * 1000)
            session.sendScreenAction(.openMirrorScreen(sessionId: sessionId))
            self.startWFDClient()
        }
        controller.hasRemoteVideo = { [weak self] in
            (self?.videoDatagramsReceived ?? 0) > 0
        }
        session.onChannelReady = { [weak self] in
            Task { @MainActor in
                self?.controller.notifyChannelReady()
            }
        }
        startVideoListener()
    }

    private func startWFDClient() {
        wfdClient?.stop(reason: "replace")
        let client = XiaomiMirrorWFDClient()
        client.idrRequestDelay = wfdIDRRequestDelay
        client.onSessionEstablished = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.establishedNotifiesVideoFrame else { return }
                self.controller.notifyVideoFrame()
            }
        }
        wfdClient = client
        client.start(host: "127.0.0.1", rtspPort: wfdPort, clientRTPPort: clientVideoPort)
    }

    private func startVideoListener() {
        let listener = try? NWListener(using: .udp, on: NWEndpoint.Port(rawValue: clientVideoPort)!)
        listener?.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global())
            Task { @MainActor in
                self?.videoConnection = connection
            }
            self?.receiveVideo(on: connection)
        }
        listener?.start(queue: .global())
        videoListener = listener
    }

    private nonisolated func receiveVideo(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            if data != nil {
                Task { @MainActor in
                    guard let self else { return }
                    self.videoDatagramsReceived += 1
                    if self.videoDatagramsReceived == 1 {
                        self.controller.notifyVideoFrame()
                    }
                }
            }
            if error == nil {
                self?.receiveVideo(on: connection)
            }
        }
    }

    private func waitFor(
        _ description: String,
        timeout: TimeInterval = 20,
        condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("timeout waiting for: \(description)")
    }

    // Phone unlocked: channel comes up, status says unlocked, OPEN goes out,
    // WFD dialog completes, video datagrams flow, mask clears, streaming.
    func testMirrorFlowPhoneUnlocked() async throws {
        try makeEnvironment(locked: false)
        session.start()
        controller.start()

        try await waitFor("channel ready + status") { [self] in
            self.session.isChannelReady && self.phone.statusActionCount >= 1
        }
        try await waitFor("OPEN_MIRROR_SCREEN sent") { [self] in
            self.phone.openMirrorScreenCount >= 1
        }
        try await waitFor("WFD session established") { [self] in
            self.phone.wfdSessionEstablished
        }
        try await waitFor("video datagrams flowing") { [self] in
            self.videoDatagramsReceived >= 3
        }
        try await waitFor("controller streaming, mask cleared") { [self] in
            self.controller.stage == .streaming && self.controller.mask == nil
        }
    }

    // Phone locked: OPEN still goes out immediately (official behavior keeps
    // the channel alive), lock mask shows; 解除鎖定 runs Touch ID → 562 → the
    // phone drives 595/546/562 on the mitrustservice channel → auth event →
    // mask clears → video.
    func testMirrorFlowPhoneLockedThenUnlock() async throws {
        try makeEnvironment(locked: true)
        session.start()
        controller.start()

        try await waitFor("channel ready + status + lock mask") { [self] in
            self.session.isChannelReady
                && self.phone.statusActionCount >= 1
                && self.controller.mask == .locked
        }
        try await waitFor("OPEN sent even while locked (official)") { [self] in
            self.phone.openMirrorScreenCount >= 1
        }
        try await waitFor("WFD session established while locked") { [self] in
            self.phone.wfdSessionEstablished
        }

        controller.unlockRequested()

        try await waitFor("phone received duo.screen authAction") { [self] in
            self.phone.authActionCount >= 1
        }
        try await waitFor("phone completed 546 bind exchange") { [self] in
            self.phone.mitrustBindCompleted
        }
        try await waitFor("phone verified auth_token_A (562/563)") { [self] in
            self.phone.mitrustUnlockCompleted && self.phone.lastAuthTokenA != nil
        }
        try await waitFor("mask cleared after auth event") { [self] in
            self.controller.mask == nil || self.controller.mask == .loading
        }
        try await waitFor("video datagrams flowing") { [self] in
            self.videoDatagramsReceived >= 3
        }
        try await waitFor("controller streaming") { [self] in
            self.controller.stage == .streaming && self.controller.mask == nil
        }
    }

    // The live phone reports BOTH disabledBySetting and then success/unlocked
    // while actually locked. The lock mask must survive the conflicting poll,
    // and 解除鎖定 must still run Touch ID + 562 (no early return on the
    // polled "unlocked" state).
    func testUnlockWorksWhenPhoneReportsConflictingStatus() async throws {
        try makeEnvironment(locked: true)
        phone.conflictingStatus = true
        session.start()
        controller.start()

        try await waitFor("lock mask shown") { [self] in
            self.controller.mask == .locked
        }
        try await waitFor("conflicting 'unlocked' poll delivered") { [self] in
            if case .ready(let locked) = self.trustManager.state, !locked {
                return true
            }
            return false
        }
        // Give the controller a beat to (incorrectly, if buggy) clear the mask.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(controller.mask, .locked, "flaky unlocked poll must not clear the lock mask")

        controller.unlockRequested()

        try await waitFor("Touch ID prompt ran") { [self] in
            self.biometricCallCount >= 1
        }
        try await waitFor("phone received duo.screen authAction (562)") { [self] in
            self.phone.authActionCount >= 1
        }
        try await waitFor("phone verified auth_token_A (562/563)") { [self] in
            self.phone.mitrustUnlockCompleted && self.phone.lastAuthTokenA != nil
        }
        try await waitFor("mask cleared via confirmed unlock") { [self] in
            self.controller.mask == nil
        }
    }

    // Regression (2026-08-02 live): after the unlock authEvent the controller
    // re-sent OPEN_MIRROR_SCREEN (stage was .unlocking, slipping past the dup
    // guard) — the phone tore down its RTSP server mid-dialog ("Connection
    // reset by peer") and the stream died. OPEN must be sent at most once
    // per flow, and the confirmed unlock must leave the session alone.
    func testUnlockDoesNotResendOpenMirrorScreen() async throws {
        try makeEnvironment(locked: true)
        session.start()
        controller.start()

        try await waitFor("lock mask + OPEN sent once + WFD up") { [self] in
            self.controller.mask == .locked
                && self.phone.openMirrorScreenCount == 1
                && self.phone.wfdSessionEstablished
        }
        try await waitFor("video flowing before unlock") { [self] in
            self.videoDatagramsReceived >= 2
        }

        controller.unlockRequested()

        try await waitFor("unlock completed") { [self] in
            self.phone.mitrustUnlockCompleted
        }
        try await waitFor("mask cleared") { [self] in
            self.controller.mask == nil
        }
        XCTAssertEqual(phone.openMirrorScreenCount, 1, "unlock must not re-send OPEN_MIRROR_SCREEN")
        let received = videoDatagramsReceived
        try await waitFor("video still flowing after unlock") { [self] in
            self.videoDatagramsReceived >= received + 2
        }
    }

    // Regression (2026-08-02 live, scenario 3): fresh app, phone's stale
    // encoder outlived the previous app instance, so our PLAY joined mid-GOP.
    // The low-latency HEVC encoder only emits VPS/SPS/PPS with an IDR, so
    // datagrams flowed but nothing decoded — the mask sat at 正在連線
    // forever. The official sink sends a one-shot SET_PARAMETER
    // wfd_idr_request exactly 20s after PLAY (five live captures,
    // 2026-07-31); the phone answers with an IDR and the stream becomes
    // decodable. Modelled here as the phone withholding decodable video
    // until the IDR request arrives.
    func testIDRRequestRescuesMidGOPJoin() async throws {
        wfdIDRRequestDelay = 1.0
        establishedNotifiesVideoFrame = false
        try makeEnvironment(locked: false)
        phone.withholdVideoUntilIDRRequest = true
        session.start()
        controller.start()

        try await waitFor("WFD session established") { [self] in
            self.phone.wfdSessionEstablished
        }
        // Before the IDR one-shot fires: no decodable video, mask stays at
        // 正在連線 (loading), no IDR request sent early.
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(videoDatagramsReceived, 0, "mid-GOP join must not yield decodable video")
        XCTAssertEqual(phone.idrRequestCount, 0, "IDR request must not fire before the official delay")
        XCTAssertEqual(controller.mask, .loading)

        try await waitFor("Mac sent wfd_idr_request (official PLAY+delay one-shot)") { [self] in
            self.phone.idrRequestCount >= 1
        }
        XCTAssertEqual(
            phone.lastIDRRequestLine,
            "SET_PARAMETER rtsp://localhost/wfd1.0/streamid=0 RTSP/1.0",
            "IDR request must match the official target verbatim"
        )
        try await waitFor("video flows after phone serves IDR") { [self] in
            self.videoDatagramsReceived >= 3
        }
        try await waitFor("controller streaming, mask cleared") { [self] in
            self.controller.stage == .streaming && self.controller.mask == nil
        }
    }
}
