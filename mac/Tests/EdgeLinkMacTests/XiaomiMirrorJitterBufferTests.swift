import Foundation
import XCTest

// PTS-paced jitter buffer clock-skew tests (2026-08-11). The phone's PTS
// clock runs ~1.75% faster than Mac wall time (measured on-device); a fixed
// PTS→wall anchor lets the buffered span grow until the 3×depth overflow
// flush fires continuously, pinning glass-to-glass latency at ~1.5s. The
// span-based early release must keep effective latency near the target
// depth without any skew estimation, and must not regress into pure
// arrival-time shifting (post-hole catch-up bursts still drain promptly).
final class XiaomiMirrorJitterBufferTests: XCTestCase {
    private static let depthMilliseconds: Double = 500
    // depth = 45000 ticks; early-release threshold = 1.2×depth = 54000.
    private static let depth90k: UInt64 = 45_000

    private final class ReleaseRecorder {
        var latestPushedPTS90k: UInt64 = 0
        var releasedCount = 0
        var latenciesMilliseconds: [Double] = []

        func notePush(pts90k: UInt64) {
            latestPushedPTS90k = pts90k
        }

        func noteRelease(pts90k: UInt64?) {
            releasedCount += 1
            guard let pts90k, latestPushedPTS90k >= pts90k else { return }
            latenciesMilliseconds.append(Double(latestPushedPTS90k - pts90k) / 90)
        }
    }

    private func soakFastClock(
        ptsTicksPerFrame: UInt64,
        wallMillisecondsPerFrame: Int,
        frames: Int
    ) -> (ReleaseRecorder, Int, Int, Int) {
        let queue = DispatchQueue(label: "XiaomiMirrorJitterBufferTests.soak")
        let recorder = ReleaseRecorder()
        let buffer = XiaomiMirrorAccessUnitJitterBuffer(
            sessionID: UUID(),
            depthMilliseconds: Self.depthMilliseconds,
            queue: queue
        ) { _, pts90k in
            recorder.noteRelease(pts90k: pts90k)
        }
        let done = expectation(description: "soak complete")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now(),
            repeating: .milliseconds(wallMillisecondsPerFrame),
            leeway: .milliseconds(1)
        )
        var nextPTS: UInt64 = 0
        var pushed = 0
        timer.setEventHandler {
            guard pushed < frames else {
                timer.cancel()
                done.fulfill()
                return
            }
            nextPTS += ptsTicksPerFrame
            pushed += 1
            recorder.notePush(pts90k: nextPTS)
            buffer.push(.videoAccessUnit([Data([0x65])]), pts90k: nextPTS)
        }
        timer.resume()
        wait(for: [done], timeout: Double(frames * wallMillisecondsPerFrame) / 1000 + 15)
        let result = queue.sync {
            (recorder, buffer.overflowFlushes, buffer.earlyReleases, pushed)
        }
        queue.sync {
            buffer.invalidate()
        }
        return result
    }

    // 1.75%-fast phone clock over 20s: without span regulation the buffered
    // span grows ~0.58ms per frame (~350ms over the soak) on top of the
    // 500ms depth; with it, latency must stay pinned at ~1.2×depth.
    func testFastSenderPTSClockKeepsLatencyBounded() {
        let (recorder, overflowFlushes, earlyReleases, pushed) = soakFastClock(
            ptsTicksPerFrame: 3_052, // 3000 × 1.0175
            wallMillisecondsPerFrame: 33,
            frames: 600 // ~20s
        )
        XCTAssertEqual(pushed, 600)
        XCTAssertGreaterThan(recorder.releasedCount, 500,
                             "the buffer must keep releasing under a fast sender clock")
        XCTAssertEqual(overflowFlushes, 0,
                       "span regulation must prevent the overflow-flush storm")
        XCTAssertGreaterThan(earlyReleases, 0,
                             "span-based early release must engage under positive skew")
        let maxLatency = recorder.latenciesMilliseconds.max() ?? 0
        XCTAssertLessThanOrEqual(maxLatency, 700,
                                 "effective latency must stay bounded near 1.2×depth (got \(maxLatency)ms)")
        let firstWindow = recorder.latenciesMilliseconds.prefix(60)
        let lastWindow = recorder.latenciesMilliseconds.suffix(60)
        XCTAssertEqual(firstWindow.count, 60)
        XCTAssertEqual(lastWindow.count, 60)
        let firstAverage = firstWindow.reduce(0, +) / 60
        let lastAverage = lastWindow.reduce(0, +) / 60
        XCTAssertLessThan(lastAverage - firstAverage, 100,
                          "latency must not drift over time (first=\(firstAverage)ms last=\(lastAverage)ms)")
    }

    // Nominal clock control: latency settles at the target depth and the
    // early-release path stays quiet.
    func testNominalClockLatencySettlesNearDepth() {
        let (recorder, overflowFlushes, _, pushed) = soakFastClock(
            ptsTicksPerFrame: 3_000,
            wallMillisecondsPerFrame: 33,
            frames: 240 // ~8s
        )
        XCTAssertEqual(pushed, 240)
        XCTAssertGreaterThan(recorder.releasedCount, 180)
        XCTAssertEqual(overflowFlushes, 0)
        let steady = recorder.latenciesMilliseconds.suffix(90)
        XCTAssertEqual(steady.count, 90)
        let average = steady.reduce(0, +) / 90
        XCTAssertGreaterThan(average, 350, "latency collapsed below depth (\(average)ms)")
        XCTAssertLessThan(average, 700, "latency exceeded depth band (\(average)ms)")
    }

    // A hole longer than the buffer depth followed by a catch-up burst must
    // not be re-delayed by the full depth: the overdue burst drains
    // immediately on arrival.
    func testCatchUpBurstAfterHoleDrainsPromptly() {
        let queue = DispatchQueue(label: "XiaomiMirrorJitterBufferTests.catchup")
        let recorder = ReleaseRecorder()
        let buffer = XiaomiMirrorAccessUnitJitterBuffer(
            sessionID: UUID(),
            depthMilliseconds: Self.depthMilliseconds,
            queue: queue
        ) { _, pts90k in
            recorder.noteRelease(pts90k: pts90k)
        }
        // Preroll: 20 frames instantly (span 570ms ≥ depth) anchors the
        // buffer; they then drain on the nominal schedule.
        queue.sync {
            for index in 1...20 {
                let pts = UInt64(index) * 3_000
                recorder.notePush(pts90k: pts)
                buffer.push(.videoAccessUnit([Data([0x65])]), pts90k: pts)
            }
        }
        // Let the prerolled frames drain, then sit silent for a hole well
        // beyond the depth.
        Thread.sleep(forTimeInterval: 0.8)
        Thread.sleep(forTimeInterval: 0.8)
        let before = queue.sync { recorder.releasedCount }
        XCTAssertGreaterThanOrEqual(before, 15, "prerolled frames must have drained during the hole")
        // Catch-up burst: the missed 24 frames arrive at once.
        queue.sync {
            for index in 21...44 {
                let pts = UInt64(index) * 3_000
                recorder.notePush(pts90k: pts)
                buffer.push(.videoAccessUnit([Data([0x65])]), pts90k: pts)
            }
        }
        let after = queue.sync { (recorder.releasedCount, buffer.bufferedCount, buffer.overflowFlushes) }
        XCTAssertGreaterThanOrEqual(after.0 - before, 20,
                                    "the overdue catch-up burst must drain on arrival, not after another depth")
        XCTAssertLessThanOrEqual(after.1, 4,
                                 "only not-yet-due frames may remain buffered (got \(after.1))")
        XCTAssertEqual(after.2, 0, "a sub-maxSpan hole must not hit the overflow flush")
        queue.sync {
            buffer.invalidate()
        }
    }
}
