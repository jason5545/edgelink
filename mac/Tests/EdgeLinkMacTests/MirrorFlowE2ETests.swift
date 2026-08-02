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
        trustManager.statusRetryDelay = 0.1
        trustManager.maxStatusRetries = 3
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

    // Phone keeps its RTSP listener down for ~1s after OPEN (the real phone
    // RSTs early dials; observed live 2026-08-02). NWConnection parks in
    // .waiting on ECONNREFUSED, so the client must retry official-fast
    // (~250ms) instead of waiting out the 6s watchdog.
    func testWFDConnectRetriesFastWhenPhoneRTSPListenerStartsLate() async throws {
        try makeEnvironment(locked: false)
        phone.wfdServerStartupDelay = 1.0
        session.start()
        controller.start()

        try await waitFor("OPEN_MIRROR_SCREEN sent") { [self] in
            self.phone.openMirrorScreenCount >= 1
        }
        let openAt = Date()
        try await waitFor("WFD session established") { [self] in
            self.phone.wfdSessionEstablished
        }
        let elapsed = Date().timeIntervalSince(openAt)
        XCTAssertLessThan(
            elapsed, 3.5,
            "OPEN→established took \(elapsed)s; the old 6s watchdog + 1s backoff budget is ~7s"
        )
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

    // The live phone reports BOTH disabledBySetting and then success with
    // enable=0 + keyguard valid while actually locked (its getSupportStatus
    // timed out and returned defaults). Those placeholders carry no keyguard
    // info: the Mac must retry the query official-style, must never clear
    // the lock mask on them, falls back to the locked mask when the phone
    // never answers truthfully, and 解除鎖定 must still run Touch ID + 562.
    func testUnlockWorksWhenPhoneReportsConflictingStatus() async throws {
        try makeEnvironment(locked: true)
        phone.conflictingStatus = true
        session.start()
        controller.start()

        try await waitFor("status query issued") { [self] in
            self.phone.statusActionCount >= 1
        }
        // Give the placeholder sequence a beat to (incorrectly, if buggy)
        // clear the mask.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNotNil(controller.mask, "placeholder answers must not clear the mask")
        try await waitFor("official-style status retries happened") { [self] in
            self.phone.statusActionCount >= 2
        }
        try await waitFor("lock mask after retry-budget fallback") { [self] in
            self.controller.mask == .locked
        }
        XCTAssertFalse(trustManager.keyguardInfoConfirmed)

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

    // Regression (2026-08-02 live): with the fast WFD retry the first frame
    // now lands BEFORE the duo.screen status resolves, and the old
    // notifyVideoFrame cleared the .loading mask immediately — the phone's
    // lock screen flashed on the Mac for ~0.5s before the 手機已鎖定 mask.
    // The mask must stay up until the trust state resolves.
    func testVideoFrameKeepsLoadingMaskUntilLockStatusResolves() async throws {
        try makeEnvironment(locked: true)
        phone.conflictingStatus = true
        trustManager.statusRetryDelay = 1.0
        session.start()
        controller.start()

        try await waitFor("WFD session established while status unresolved") { [self] in
            self.phone.wfdSessionEstablished
        }
        XCTAssertFalse(trustManager.keyguardInfoConfirmed)
        XCTAssertNotNil(controller.mask, "first frame must not clear the mask before the lock status resolves")
        try await waitFor("lock mask after retry-budget fallback") { [self] in
            self.controller.mask == .locked
        }
    }

    // Companion to the locked case above: an UNLOCKED phone whose status is
    // also slow (placeholders first, truthful answer later) must keep the
    // mask only until the truthful answer, then stream directly — no lock
    // mask, no Touch ID.
    func testVideoFrameClearsMaskWhenUnlockedStatusResolves() async throws {
        try makeEnvironment(locked: false)
        phone.conflictingStatus = true
        phone.truthfulAfterQueries = 1
        trustManager.statusRetryDelay = 1.0
        session.start()
        controller.start()

        try await waitFor("WFD established before status resolves") { [self] in
            self.phone.wfdSessionEstablished
        }
        XCTAssertFalse(trustManager.keyguardInfoConfirmed)
        XCTAssertNotNil(controller.mask, "mask must stay until the status resolves")
        try await waitFor("truthful unlocked status") { [self] in
            self.trustManager.keyguardInfoConfirmed
        }
        try await waitFor("mask cleared, streaming directly") { [self] in
            self.controller.mask == nil && self.controller.stage == .streaming
        }
        XCTAssertEqual(biometricCallCount, 0, "unlocked phone must not require Touch ID")
    }

    // A fresh KeyguardManager push from the Android app is truthful while
    // duo.screen polls only ever yield placeholders on this device — resolve
    // on the first placeholder instead of burning the full retry budget
    // (~5s of black 正在連接 over an already-playing stream).
    func testExternalLockReportShortcutsPlaceholderRetries() async throws {
        try makeEnvironment(locked: false)
        phone.conflictingStatus = true
        trustManager.externalLockState = { false }
        trustManager.statusRetryDelay = 30
        session.start()
        controller.start()

        try await waitFor("resolved unlocked without waiting out retries", timeout: 5) { [self] in
            if case .ready(let locked) = self.trustManager.state { return !locked }
            return false
        }
        try await waitFor("streaming directly") { [self] in
            self.controller.mask == nil && self.controller.stage == .streaming
        }
    }

    // Scenario 1 (2026-08-02 live): phone genuinely unlocked, but its first
    // status answers are the same placeholder sequence as the locked case
    // (disabledBySetting, then success with enable=0 + keyguard valid). Once
    // the phone's getSupportStatus resolves it answers truthfully
    // (enable=1, keyguard valid). The mask must clear on the truthful answer
    // alone — no Touch ID, no 解除鎖定 detour.
    func testUnlockedPhoneClearsMaskAfterTruthfulStatus() async throws {
        establishedNotifiesVideoFrame = false
        try makeEnvironment(locked: false)
        phone.conflictingStatus = true
        phone.truthfulAfterQueries = 2
        session.start()
        controller.start()

        // Placeholder rounds: mask stays up, no keyguard info yet.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNotNil(controller.mask, "placeholders must not clear the mask")
        XCTAssertFalse(trustManager.keyguardInfoConfirmed)

        try await waitFor("retries reached the truthful answer") { [self] in
            self.phone.statusActionCount >= 3 && self.trustManager.keyguardInfoConfirmed
        }
        try await waitFor("video flowing") { [self] in
            self.videoDatagramsReceived >= 2
        }
        try await waitFor("mask cleared without Touch ID") { [self] in
            self.controller.mask == nil && self.controller.stage == .streaming
        }
        XCTAssertEqual(biometricCallCount, 0, "unlocked phone must not require Touch ID")
        XCTAssertEqual(phone.authActionCount, 0, "no 562 needed when the phone is already unlocked")
    }

    // Scenario 2 (2026-08-02 live): unlock once, re-lock the phone,
    // reconnect — the Mac sat at 正在連線. Covers both compounding causes:
    // the reconnected PLAY joins the phone's still-running encoder mid-GOP
    // (no decodable frame until the official-style IDR one-shot), and the
    // previous flow's unlockConfirmed must not leak into the new flow.
    func testReconnectAfterRelockRecoversViaIDRRequest() async throws {
        wfdIDRRequestDelay = 1.0
        try makeEnvironment(locked: true)
        session.start()
        controller.start()

        // Flow A: locked → unlock → streaming.
        try await waitFor("flow A lock mask + OPEN + WFD") { [self] in
            self.controller.mask == .locked
                && self.phone.openMirrorScreenCount == 1
                && self.phone.wfdSessionEstablished
        }
        controller.unlockRequested()
        try await waitFor("flow A unlock completed") { [self] in
            self.phone.mitrustUnlockCount == 1
        }
        try await waitFor("flow A streaming") { [self] in
            self.controller.stage == .streaming && self.controller.mask == nil
        }

        // User locks the phone again and reconnects (close + reopen window).
        // The phone keeps its encoder running and tears down its RTSP server
        // on the duplicate OPEN, so flow B's PLAY joins mid-GOP.
        phone.setLocked(true)
        phone.withholdVideoUntilIDRRequest = true
        establishedNotifiesVideoFrame = false
        controller.stop()
        controller.start()

        try await waitFor("flow B OPEN re-sent once + WFD re-established") { [self] in
            self.phone.openMirrorScreenCount == 2 && self.phone.wfdSessionEstablished
        }
        try await waitFor("flow B lock mask from truthful locked poll") { [self] in
            self.controller.mask == .locked
        }
        XCTAssertFalse(trustManager.unlockConfirmed, "relock must reset unlockConfirmed")

        controller.unlockRequested()
        try await waitFor("flow B unlock completed") { [self] in
            self.phone.mitrustUnlockCount == 2
        }
        try await waitFor("flow B IDR one-shot sent") { [self] in
            self.phone.idrRequestCount >= 1
        }
        try await waitFor("flow B streaming after IDR") { [self] in
            self.controller.stage == .streaming && self.controller.mask == nil
        }
        XCTAssertEqual(phone.openMirrorScreenCount, 2, "OPEN must be sent exactly once per flow")
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

    // Unpaired phone: the status event reports bindStatus=notBound, so the
    // flow surfaces the bind mask instead of streaming; 開始配對 sends the
    // duo.screen bindAction, the phone completes its verification (bindEvent
    // success + truthful bound status), and the flow auto-resumes all the
    // way to streaming without any further user action.
    func testUnpairedPhoneBindsThenAutoResumesStreaming() async throws {
        try makeEnvironment(locked: false)
        phone.bound = false
        session.start()
        controller.start()

        try await waitFor("bind mask on notBound status") { [self] in
            self.session.isChannelReady && self.controller.mask == .bind
        }
        try await waitFor("OPEN still sent (official keeps channel alive)") { [self] in
            self.phone.openMirrorScreenCount >= 1
        }

        controller.bindRequested()

        try await waitFor("phone received duo.screen bindAction") { [self] in
            self.phone.bindActionCount >= 1
        }
        try await waitFor("flow auto-resumed to streaming, mask cleared") { [self] in
            self.controller.stage == .streaming && self.controller.mask == nil
        }
        try await waitFor("video datagrams flowing") { [self] in
            self.videoDatagramsReceived >= 3
        }
        XCTAssertEqual(phone.openMirrorScreenCount, 1, "bind must not re-send OPEN_MIRROR_SCREEN")
        XCTAssertEqual(biometricCallCount, 0, "bind flow must not trigger Touch ID")
    }

    // 開始配對 on an already-bound phone must be a no-op — only a truthful
    // notBound status (state == .needsBind) may trigger the bind action.
    func testBindRequestIgnoredWhenAlreadyBound() async throws {
        try makeEnvironment(locked: false)
        session.start()
        controller.start()

        try await waitFor("streaming on bound phone") { [self] in
            self.controller.stage == .streaming
        }
        controller.bindRequested()
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(phone.bindActionCount, 0)
    }

    // Phone-initiated pair request (xiaomi.trustBind): with auto-bind armed,
    // the first truthful notBound status immediately starts the official
    // bind flow — no Mac-side button press — and the flow resumes to
    // streaming once the phone completes its verification.
    func testPhoneInitiatedBindAutoStartsOnNotBound() async throws {
        try makeEnvironment(locked: false)
        phone.bound = false
        trustManager.autoBindOnNeedsBind = true
        session.start()
        controller.start()

        try await waitFor("phone received bindAction without Mac button") { [self] in
            self.phone.bindActionCount >= 1
        }
        try await waitFor("flow auto-resumed to streaming") { [self] in
            self.controller.stage == .streaming && self.controller.mask == nil
        }
        XCTAssertEqual(biometricCallCount, 0)
    }

    // The Android app's own KeyguardManager report (phone.lockState push) is
    // the fallback truth when duo.screen polls only produce placeholders:
    // an external "unlocked" clears the mask without Touch ID…
    func testExternalUnlockReportClearsMaskWhenStatusLies() async throws {
        establishedNotifiesVideoFrame = false
        try makeEnvironment(locked: false)
        phone.conflictingStatus = true
        trustManager.externalLockState = { false }
        session.start()
        controller.start()

        try await waitFor("fallback used the external report") { [self] in
            if case .ready(let locked) = self.trustManager.state { return !locked }
            return false
        }
        try await waitFor("mask cleared without Touch ID") { [self] in
            self.controller.mask == nil && self.controller.stage == .streaming
        }
        XCTAssertEqual(biometricCallCount, 0)
        XCTAssertEqual(phone.authActionCount, 0)
    }

    // …and an external "locked" keeps the lock mask (and Mac-driven unlock
    // still works) even while the polls claim unlocked.
    func testExternalLockedReportKeepsMaskWhenStatusLies() async throws {
        try makeEnvironment(locked: true)
        phone.conflictingStatus = true
        trustManager.externalLockState = { true }
        session.start()
        controller.start()

        try await waitFor("lock mask via external report") { [self] in
            self.controller.mask == .locked
        }

        controller.unlockRequested()

        try await waitFor("unlock completed") { [self] in
            self.phone.mitrustUnlockCompleted
        }
        try await waitFor("mask cleared via confirmed unlock") { [self] in
            self.controller.mask == nil
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

    // Keyboard rides the same cast channel as OPEN_MIRROR_SCREEN (official
    // route, wire type 4 = duo.screen ProtoKeyboard): once the mirror session
    // is established, key events must reach the phone as well-formed
    // ProtoKeyboard frames carrying the mirror sessionId and Android
    // keyCode/meta. Verified live 2026-08-02 that the phone decodes this
    // natively for a paired PC (no Android-app hook round trip).
    func testKeyboardEventsFlowOnCastChannelAfterMirrorOpens() async throws {
        try makeEnvironment(locked: false)
        session.start()
        controller.start()

        try await waitFor("controller streaming, mask cleared") { [self] in
            self.controller.stage == .streaming && self.controller.mask == nil
        }

        let sessionId = UInt64(Date().timeIntervalSince1970 * 1000)
        session.sendKeyboard(.key(sessionId: sessionId, androidKeyCode: 29, metaInfo: 0, down: true))
        session.sendKeyboard(.key(sessionId: sessionId, androidKeyCode: 29, metaInfo: 0, down: false))
        session.sendKeyboard(.key(sessionId: sessionId, androidKeyCode: 66, metaInfo: 0, down: true))
        session.sendKeyboard(.key(sessionId: sessionId, androidKeyCode: 67, metaInfo: 0, down: true))
        session.sendKeyboard(.key(sessionId: sessionId, androidKeyCode: 29, metaInfo: 1, down: true))
        session.sendKeyboard(.committedText(sessionId: sessionId, text: "你好"))

        try await waitFor("phone received keyboard frames") { [self] in
            self.phone.keyboardMessages.count >= 6
        }
        let messages = phone.keyboardMessages
        XCTAssertEqual(messages[0], .key(sessionId: sessionId, androidKeyCode: 29, metaInfo: 0, down: true))
        XCTAssertEqual(messages[1], .key(sessionId: sessionId, androidKeyCode: 29, metaInfo: 0, down: false))
        XCTAssertEqual(messages[2].keyEvent?.code, 66, "ENTER keyCode")
        XCTAssertEqual(messages[3].keyEvent?.code, 67, "DEL keyCode")
        XCTAssertEqual(messages[4].keyEvent?.metaInfo, 1, "shift meta passes through")
        XCTAssertTrue(messages[0].isAndroidKey)
        XCTAssertEqual(messages[5].text, "你好")
        XCTAssertNil(messages[5].keyEvent)
        for message in messages {
            XCTAssertEqual(message.sessionId, sessionId)
            XCTAssertEqual(message.screenId, 0)
        }
    }

    // Pointer rides the same cast channel (wire type 3 = duo.screen
    // ProtoMouse). Hover MOVE events with no button state are what the
    // official client uses to keep the phone's synergy input state alive
    // (mSynergyStatus=1 → IME stays suppressed), so they must flow even
    // without clicks.
    func testMouseEventsFlowOnCastChannelAfterMirrorOpens() async throws {
        try makeEnvironment(locked: false)
        session.start()
        controller.start()

        try await waitFor("controller streaming, mask cleared") { [self] in
            self.controller.stage == .streaming && self.controller.mask == nil
        }

        let sessionId = UInt64(Date().timeIntervalSince1970 * 1000)
        func mouse(_ action: LyraCastMouse.Action, x: Int32, y: Int32, state: UInt32 = 0, scroll: Int32 = 0) -> LyraCastMouse {
            var message = LyraCastMouse()
            message.sessionId = sessionId
            message.action = action
            message.x = x
            message.y = y
            message.state = state
            message.scrollDelta = scroll
            return message
        }
        session.sendMouse(mouse(.move, x: 500, y: 300))
        session.sendMouse(mouse(.leftDown, x: 500, y: 300, state: LyraCastMouse.stateLeftHold))
        session.sendMouse(mouse(.move, x: 520, y: 320, state: LyraCastMouse.stateLeftHold))
        session.sendMouse(mouse(.leftUp, x: 520, y: 320))
        session.sendMouse(mouse(.rightDown, x: 100, y: 100, state: LyraCastMouse.stateRightHold))
        session.sendMouse(mouse(.rightUp, x: 100, y: 100))
        session.sendMouse(mouse(.wheelForward, x: 500, y: 300, scroll: 30))
        session.sendMouse(mouse(.wheelBackward, x: 500, y: 300, scroll: 30))

        try await waitFor("phone received mouse frames") { [self] in
            self.phone.mouseMessages.count >= 8
        }
        let messages = phone.mouseMessages
        XCTAssertEqual(messages[0].action, .move)
        XCTAssertEqual(messages[0].state, 0, "hover move carries no button state")
        XCTAssertEqual(messages[1].action, .leftDown)
        XCTAssertEqual(messages[1].state, LyraCastMouse.stateLeftHold)
        XCTAssertEqual(messages[2].action, .move)
        XCTAssertEqual(messages[2].state, LyraCastMouse.stateLeftHold, "drag move keeps left hold")
        XCTAssertEqual(messages[2].x, 520)
        XCTAssertEqual(messages[2].y, 320)
        XCTAssertEqual(messages[3].action, .leftUp)
        XCTAssertEqual(messages[3].state, 0)
        XCTAssertEqual(messages[4].action, .rightDown)
        XCTAssertEqual(messages[5].action, .rightUp)
        XCTAssertEqual(messages[6].action, .wheelForward)
        XCTAssertEqual(messages[6].scrollDelta, 30)
        XCTAssertEqual(messages[7].action, .wheelBackward)
        for message in messages {
            XCTAssertEqual(message.sessionId, sessionId)
            XCTAssertEqual(message.screenId, 0)
        }
    }
}
