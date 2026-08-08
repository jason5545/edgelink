import XCTest

// MPT sink frame-watchdog verdict tests. Pins two live-observed behaviors:
// (1) a static phone screen legitimately silences the video elementary stream
// while audio keeps flowing — that is NOT a stall and must never trigger
// source recovery (over the relay the recovery command re-runs the
// phone-side mirror start path and pulled PhoneMainMirrorActivity to the
// foreground for the whole session); (2) the relay-carried stream needs a
// longer initial-sync window before the first decoded frame than the
// steady-state 2s no-frame threshold.
final class XiaomiMirrorMPTWatchdogTests: XCTestCase {
    // The production thresholds (XiaomiMirrorRTPMediaSender): 2s steady
    // state, 10s initial sync, 5s video-ES-absent.
    private func verdict(
        elapsedFrameSeconds: Double,
        decodedFrames: UInt64,
        videoESStaleSeconds: Double
    ) -> XiaomiMirrorMPTFrameWatchdogVerdict {
        xiaomiMirrorMPTFrameWatchdogVerdict(
            elapsedFrameSeconds: elapsedFrameSeconds,
            decodedFrames: decodedFrames,
            videoESStaleSeconds: videoESStaleSeconds,
            steadyStateThresholdSeconds: 2,
            initialSyncThresholdSeconds: 10,
            videoESAbsentThresholdSeconds: 5
        )
    }

    func testHealthyWithinSteadyStateThreshold() {
        XCTAssertEqual(
            verdict(elapsedFrameSeconds: 1.5, decodedFrames: 100, videoESStaleSeconds: 1.5),
            .healthy
        )
    }

    func testFrameStalledWhenESPresentButNoDecode() {
        XCTAssertEqual(
            verdict(elapsedFrameSeconds: 2.5, decodedFrames: 100, videoESStaleSeconds: 0.4),
            .frameStalled
        )
    }

    func testStaticScreenSilenceDoesNotRecover() {
        // Video ES absent beyond the 5s threshold while the stream itself is
        // alive: encoder idle on static content.
        XCTAssertEqual(
            verdict(elapsedFrameSeconds: 30, decodedFrames: 276, videoESStaleSeconds: 28),
            .staticScreenVideoSilent
        )
    }

    func testNeverObservedVideoESIsStaticNotStalled() {
        XCTAssertEqual(
            verdict(elapsedFrameSeconds: 30, decodedFrames: 0, videoESStaleSeconds: .infinity),
            .staticScreenVideoSilent
        )
    }

    func testInitialSyncGraceBeforeFirstFrame() {
        // No decoded frame yet: the relay attach burst (KCP reordering +
        // parameter-set/IDR wait) needs more than the steady-state 2s.
        XCTAssertEqual(
            verdict(elapsedFrameSeconds: 3, decodedFrames: 0, videoESStaleSeconds: 0.1),
            .healthy
        )
        XCTAssertEqual(
            verdict(elapsedFrameSeconds: 11, decodedFrames: 0, videoESStaleSeconds: 0.1),
            .frameStalled
        )
    }
}
