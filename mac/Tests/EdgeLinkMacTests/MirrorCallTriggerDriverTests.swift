import Foundation
import XCTest

// The phone.call_status → mirror-call PHONERELAY trigger: channel ensure
// while a call is ongoing, event 24/31 drive on active, event 25 on the
// last call's end, mid-call channel-release recovery, and the cloud-bridge
// advertise-endpoint flip. Pure spies; the wire-level behavior is covered
// by LyraMirrorCallRelayTests.
@MainActor
final class MirrorCallTriggerDriverTests: XCTestCase {
    private final class Spies {
        var hasCastSession = false
        var needsRedial = false
        var mirrorBusy = false
        var ensureReasons: [String] = []
        var setCallActiveValues: [Bool] = []
        var redialCount = 0
        var relayAdvertiseCount = 0
        var clearPendingCount = 0
    }

    private var spies: Spies!
    private var driver: MirrorCallTriggerDriver!
    private var currentDate = Date(timeIntervalSince1970: 100_000)

    override func setUp() {
        super.setUp()
        let spies = Spies()
        self.spies = spies
        let driver = MirrorCallTriggerDriver()
        driver.hasCastSession = { spies.hasCastSession }
        driver.castChannelNeedsRedial = { spies.needsRedial }
        driver.isMirrorFlowBusy = { spies.mirrorBusy }
        driver.ensureChannel = { spies.ensureReasons.append($0) }
        driver.setCallActive = { spies.setCallActiveValues.append($0) }
        driver.redialChannel = { spies.redialCount += 1 }
        driver.setRelayAdvertiseEndpoint = { spies.relayAdvertiseCount += 1 }
        driver.clearPendingState = { spies.clearPendingCount += 1 }
        driver.now = { [weak self] in self?.currentDate ?? .distantPast }
        self.driver = driver
    }

    // A burst of ongoing statuses (dialing/connecting/ringing arrive within
    // a second of each other on a real call) collapses into one channel
    // ensure per throttle window.
    func testOngoingStatesEnsureChannelOncePerThrottleWindow() {
        driver.handleCallStatus(state: "dialing", ongoingCallCount: 1)
        driver.handleCallStatus(state: "connecting", ongoingCallCount: 1)
        driver.handleCallStatus(state: "ringing", ongoingCallCount: 1)
        XCTAssertEqual(spies.ensureReasons, ["call_audio"])

        currentDate.addTimeInterval(driver.ensureMinInterval + 1)
        driver.handleCallStatus(state: "held", ongoingCallCount: 1)
        XCTAssertEqual(spies.ensureReasons, ["call_audio", "call_audio"])
    }

    func testOngoingStatesDoNotEnsureWhenCastSessionHealthy() {
        spies.hasCastSession = true
        driver.handleCallStatus(state: "dialing", ongoingCallCount: 1)
        driver.handleCallStatus(state: "ringing", ongoingCallCount: 1)
        XCTAssertTrue(spies.ensureReasons.isEmpty)
        XCTAssertEqual(spies.redialCount, 0)
    }

    // Mid-call channel release with the cast session still around: a fresh
    // logi dial on the same session brings the channel (and the mirror-call
    // relay) back — ensuring would no-op on the existing session (live
    // 2026-09-02: the channel stayed dead for the rest of the call).
    func testOngoingStatesRedialWhenChannelReleasedMidCall() {
        spies.hasCastSession = true
        spies.needsRedial = true
        driver.handleCallStatus(state: "active", ongoingCallCount: 1)
        XCTAssertEqual(spies.redialCount, 1)
        XCTAssertTrue(spies.ensureReasons.isEmpty)

        // Throttled against repeated statuses while the redial is in flight.
        driver.handleCallStatus(state: "active", ongoingCallCount: 1)
        XCTAssertEqual(spies.redialCount, 1)
        currentDate.addTimeInterval(driver.ensureMinInterval + 1)
        driver.handleCallStatus(state: "active", ongoingCallCount: 1)
        XCTAssertEqual(spies.redialCount, 2)
    }

    // details_changed lands as repeated "active" statuses; the driver
    // forwards every one — the closure writes the session's pending state
    // (which a late-built session applies in start()) and the session
    // dedupes no-change drives. An exactly-once gate used to drop the drive
    // entirely when it fired into a nil session (live 2026-09-02).
    func testActiveForwardsEveryStatus() {
        spies.hasCastSession = true
        driver.handleCallStatus(state: "active", ongoingCallCount: 1)
        driver.handleCallStatus(state: "active", ongoingCallCount: 1)
        driver.handleCallStatus(state: "active", ongoingCallCount: 1)
        XCTAssertEqual(spies.setCallActiveValues, [true, true, true])
    }

    func testTerminalWithNoOngoingCallsDrivesCallStop() {
        spies.hasCastSession = true
        driver.handleCallStatus(state: "active", ongoingCallCount: 1)
        driver.handleCallStatus(state: "disconnected", ongoingCallCount: 0)
        XCTAssertEqual(spies.setCallActiveValues, [true, false])
    }

    // The runtime's callId=="all" early-return path is terminal too.
    func testAllStatusDrivesCallStop() {
        spies.hasCastSession = true
        driver.handleCallStatus(state: "active", ongoingCallCount: 1)
        driver.handleCallStatus(state: "all", ongoingCallCount: 0)
        XCTAssertEqual(spies.setCallActiveValues, [true, false])
    }

    // stopPhoneCallRelayAudio resets the driver BEFORE the terminal status
    // reaches it inside handlePhoneCallStatus, so the stop drive must fire
    // even when this driver never saw an active — the session dedupes a
    // stop for a call that never went active.
    func testTerminalDrivesCallStopEvenWhenActiveWasNeverDriven() {
        driver.handleCallStatus(state: "disconnected", ongoingCallCount: 0)
        XCTAssertEqual(spies.setCallActiveValues, [false])
    }

    // Multiple simultaneous calls: the stop drive fires only when none
    // remain.
    func testSecondCallKeepsCallActiveUntilAllEnd() {
        spies.hasCastSession = true
        driver.handleCallStatus(state: "active", ongoingCallCount: 2)
        driver.handleCallStatus(state: "disconnected", ongoingCallCount: 1)
        XCTAssertEqual(spies.setCallActiveValues, [true])
        driver.handleCallStatus(state: "ended", ongoingCallCount: 0)
        XCTAssertEqual(spies.setCallActiveValues, [true, false])
    }

    func testNewCallAfterTerminalRedrives() {
        spies.hasCastSession = true
        driver.handleCallStatus(state: "active", ongoingCallCount: 1)
        driver.handleCallStatus(state: "disconnected", ongoingCallCount: 0)
        driver.handleCallStatus(state: "active", ongoingCallCount: 1)
        XCTAssertEqual(spies.setCallActiveValues, [true, false, true])
    }

    func testChannelReleasedWithoutCallDoesNothing() {
        driver.handleChannelReleased(callOngoing: false)
        XCTAssertTrue(spies.ensureReasons.isEmpty)
        XCTAssertEqual(spies.redialCount, 0)
    }

    // The mirror flow restarts itself on release; never double-redial.
    func testChannelReleasedWhileMirrorBusyDoesNothing() {
        spies.mirrorBusy = true
        spies.hasCastSession = true
        driver.handleChannelReleased(callOngoing: true)
        XCTAssertTrue(spies.ensureReasons.isEmpty)
        XCTAssertEqual(spies.redialCount, 0)
    }

    // The release event redials on the still-existing cast session: the
    // teardown cleared the mirror-call relay together with the channel, so
    // keying this on the relay session's existence (the old behavior) took
    // the ensure branch, which no-ops on the existing session (live
    // 2026-09-02).
    func testChannelReleasedWithCastSessionRedials() {
        spies.hasCastSession = true
        driver.handleChannelReleased(callOngoing: true)
        XCTAssertEqual(spies.redialCount, 1)
        XCTAssertTrue(spies.ensureReasons.isEmpty)
    }

    func testChannelReleasedWithoutCastSessionEnsuresChannel() {
        driver.handleChannelReleased(callOngoing: true)
        XCTAssertEqual(spies.ensureReasons, ["call_audio_released"])
        XCTAssertEqual(spies.redialCount, 0)
    }

    // phone.call_status is NOT a heartbeat: the per-second details_changed
    // stream stops once the call is stably active, so a session that dies
    // mid-call (redial_timeout after a release — the phone goes deaf to
    // redialed logi requests on a torn-down phys conn) must trigger the
    // replacement ensure from the finish event itself, or the channel is
    // never rebuilt for the rest of the call (live 2026-09-03).
    func testSessionFinishedMidCallEnsuresFreshChannel() {
        driver.handleSessionFinished(callOngoing: true)
        XCTAssertEqual(spies.ensureReasons, ["call_audio_session_finished"])
    }

    func testSessionFinishedWithoutCallDoesNothing() {
        driver.handleSessionFinished(callOngoing: false)
        XCTAssertTrue(spies.ensureReasons.isEmpty)
    }

    func testSessionFinishedWhileMirrorBusyDoesNothing() {
        spies.mirrorBusy = true
        driver.handleSessionFinished(callOngoing: true)
        XCTAssertTrue(spies.ensureReasons.isEmpty)
    }

    // Another ensure already won the race and owns a live session.
    func testSessionFinishedWithExistingSessionDoesNothing() {
        spies.hasCastSession = true
        driver.handleSessionFinished(callOngoing: true)
        XCTAssertTrue(spies.ensureReasons.isEmpty)
    }

    func testCloudBridgeEngagedIsIdempotentUntilReset() {
        driver.handleCloudBridgeEngaged()
        driver.handleCloudBridgeEngaged()
        XCTAssertEqual(spies.relayAdvertiseCount, 1)
        driver.reset()
        driver.handleCloudBridgeEngaged()
        XCTAssertEqual(spies.relayAdvertiseCount, 2)
    }

    // Per-call teardown clears the session's pending call state so the next
    // call starts clean (no stale active drive, LAN advertise until the
    // cloud bridge re-engages).
    func testResetClearsPendingState() {
        driver.reset()
        XCTAssertEqual(spies.clearPendingCount, 1)
    }
}
