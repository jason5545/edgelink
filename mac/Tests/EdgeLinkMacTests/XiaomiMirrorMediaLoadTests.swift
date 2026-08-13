import CoreMedia
import CoreVideo
import CryptoKit
import EdgeLinkKit
import Foundation
import Network
import VideoToolbox
import XCTest

// High-load media soak tests for the mirror media receivers. A scripted fake
// phone encodes real HEVC (VideoToolbox), muxes MPEG-TS, packetizes RTP/PT33,
// and pushes it through a MiplayKcpTransport exactly like the phone's encoder
// bridge. Two transports are soaked:
// - LAN: the full official RTSP route (phone dials the Mac listener, M1-M16,
//   ACTIVE_SETUP/PLAY, then KCP media to the Mac's MPT sink UDP port).
// - Relay: the cloudflare/TURN receiver (datagrams injected via
//   handleTurnMirrorMedia, as MacMirrorTurnSession does).
// Both assert the same thing: under sustained high-rate traffic the stall
// watchdogs must stay quiet — recovery must never fire on a healthy stream.
final class XiaomiMirrorMediaLoadTests: XCTestCase {
    private static var portBlockIndex: UInt16 = 0
    private var rtspPort: UInt16!
    private var sinkPort: UInt16!

    override func setUp() {
        super.setUp()
        Self.portBlockIndex += 1
        // Class-wide range 34_101...34_999 (parallel workers are separate
        // processes; ranges must not overlap the other harnesses').
        rtspPort = 34_101 + Self.portBlockIndex * 10
        sinkPort = rtspPort + 1
        // Keep the soak off the prod app's MPT sink port (UDP 15550) so the
        // suite passes while /Applications/EdgeLinkMac.app is running.
        XiaomiMirrorRTSPDiagnosticSource.officialMPTClientPortOverride = sinkPort
        continueAfterFailure = false
    }

    override func tearDown() {
        XiaomiMirrorRTSPDiagnosticSource.officialMPTClientPortOverride = nil
        UserDefaults.standard.removeObject(forKey: "xiaomiMirrorRTSPTransportMode")
        UserDefaults.standard.removeObject(forKey: "xiaomiMirrorRTSPProtocolProfile")
        super.tearDown()
    }

    // MARK: - LAN: official RTSP route with a KCP media flood

    func testLANMPTSinkStreamsHighRateWithoutRecovery() async throws {
        UserDefaults.standard.set("mpt", forKey: "xiaomiMirrorRTSPTransportMode")
        UserDefaults.standard.set("official", forKey: "xiaomiMirrorRTSPProtocolProfile")

        let source = XiaomiMirrorRTSPDiagnosticSource()
        let probe = MediaLoadProbe()
        source.onRecoveryRequired = { probe.noteRecovery($0) }
        source.onDecodedFrame = { _, _, _ in probe.noteDecodedFrame() }
        try source.start(port: rtspPort, advertisedHost: "127.0.0.1", lifetime: 300)
        defer { source.stop(reason: "test_teardown") }

        let phone = FakePhoneOfficialRTSPClient(host: "127.0.0.1", port: rtspPort)
        try phone.connect()
        try await waitFor("RTSP dialog reached PLAY", timeout: 10) { phone.playAcknowledged }

        let media = FakePhoneMPTMediaSource(
            width: 1200, height: 2608, averageBitRate: 40_000_000,
            loss: 0.02, duplicate: 0.2, retransmitsLost: true
        )
        media.sinkPort = sinkPort
        media.onDatagram = { [weak media] datagram in
            media?.sendUDP(datagram)
        }
        phone.onIDRRequest = { [weak media] in media?.forceNextKeyframe() }
        media.start()
        defer { media.stop() }

        // Soak well past the 6s no-packet and 10s initial-sync watchdog
        // thresholds so any load-induced stall has time to fire.
        try await Task.sleep(nanoseconds: 12_000_000_000)

        XCTAssertTrue(probe.recoveryEvents.isEmpty,
                      "LAN high-rate stream must not trigger recovery: \(probe.recoveryEvents)")
        XCTAssertGreaterThan(probe.decodedFrames, 60,
                             "decoder must keep up under load (got \(probe.decodedFrames) frames)")
        XCTAssertLessThan(probe.secondsSinceLastDecodedFrame, 2.0,
                          "decoded frames must still flow at the end of the soak")
        XCTAssertGreaterThan(media.datagramsSent, 500,
                             "the soak must actually push high traffic (sent \(media.datagramsSent))")
        XCTAssertGreaterThan(media.acksReceived, 0, "the sink must ACK the media stream")
    }

    // MARK: - Relay: cloudflare/TURN receiver with the same flood

    func testCloudflareReceiverStreamsHighRateWithoutRecovery() async throws {
        let source = XiaomiMirrorRTSPDiagnosticSource()
        let probe = MediaLoadProbe()
        source.onRecoveryRequired = { probe.noteRecovery($0) }
        source.onDecodedFrame = { _, _, _ in probe.noteDecodedFrame() }
        let sessionId = UUID().uuidString
        source.startCloudflareMirrorRTPReceiver(sessionId: sessionId, lifetime: 300, reason: "test")
        defer { source.stop(reason: "test_teardown") }

        let media = FakePhoneMPTMediaSource(
            width: 1200, height: 2608, averageBitRate: 40_000_000,
            loss: 0.02, duplicate: 0.3, retransmitsLost: true
        )
        media.onDatagram = { datagram in
            source.handleTurnMirrorMedia(datagram, sessionId: sessionId)
        }
        // ACKs from the receiver ride the outbound dc path; feed them back to
        // the fake phone's KCP like the phone-side bridge would.
        source.onCloudflareMirrorOutboundDatagramBatch = { [weak media] packets, _ in
            media?.receiveACKs(packets)
        }
        media.start()
        defer { media.stop() }

        try await Task.sleep(nanoseconds: 12_000_000_000)

        XCTAssertTrue(probe.recoveryEvents.isEmpty,
                      "relay high-rate stream must not trigger recovery: \(probe.recoveryEvents)")
        XCTAssertGreaterThan(probe.decodedFrames, 60,
                             "decoder must keep up under load (got \(probe.decodedFrames) frames)")
        XCTAssertLessThan(probe.secondsSinceLastDecodedFrame, 2.0,
                          "decoded frames must still flow at the end of the soak")
        XCTAssertGreaterThan(media.datagramsSent, 500,
                             "the soak must actually push high traffic (sent \(media.datagramsSent))")
    }

    // MARK: - LAN: ingestion stall reproduction (gap distribution)

    // Same 40Mbps flood as the recovery soak, but measured for stall-burst
    // cycles instead of watchdog events: the production symptom is a ~1s pause
    // every ~2 minutes with no loss/recovery. KCP ACKs are emitted inside the
    // Mac receiver's receiveDatagram on the receiver queue, so ACK gaps on the
    // fake phone directly measure Mac ingestion pipeline stalls.
    func testLANMPTSinkStreamsWithoutIngestionStalls() async throws {
        UserDefaults.standard.set("mpt", forKey: "xiaomiMirrorRTSPTransportMode")
        UserDefaults.standard.set("official", forKey: "xiaomiMirrorRTSPProtocolProfile")

        let source = XiaomiMirrorRTSPDiagnosticSource()
        let probe = MediaLoadProbe()
        source.onRecoveryRequired = { probe.noteRecovery($0) }
        source.onDecodedFrame = { _, _, _ in probe.noteDecodedFrame() }
        try source.start(port: rtspPort, advertisedHost: "127.0.0.1", lifetime: 300)
        defer { source.stop(reason: "test_teardown") }

        let phone = FakePhoneOfficialRTSPClient(host: "127.0.0.1", port: rtspPort)
        try phone.connect()
        try await waitFor("RTSP dialog reached PLAY", timeout: 10) { phone.playAcknowledged }

        let media = FakePhoneMPTMediaSource(
            width: 960, height: 2080, averageBitRate: 20_000_000,
            loss: 0.02, duplicate: 0.2, retransmitsLost: true
        )
        media.sinkPort = sinkPort
        media.onDatagram = { [weak media] datagram in
            media?.sendUDP(datagram)
        }
        phone.onIDRRequest = { [weak media] in media?.forceNextKeyframe() }
        media.start()
        defer { media.stop() }

        try await Task.sleep(nanoseconds: 30_000_000_000)

        DiagnosticsLog.info(
            "loadtest.lan_gap_stats decoded=\(probe.decodedFrames) " +
                "maxDecodeGapMs=\(String(format: "%.0f", probe.maxDecodeGapMilliseconds)) " +
                "decodeGaps200=\(probe.decodeGapsOver200ms) decodeGaps500=\(probe.decodeGapsOver500ms) " +
                "decodeGaps1000=\(probe.decodeGapsOver1000ms) " +
                "maxAckGapMs=\(String(format: "%.0f", media.maxAckGapMilliseconds)) " +
                "ackGaps200=\(media.ackGapsOver200ms) ackGaps500=\(media.ackGapsOver500ms) " +
                "datagrams=\(media.datagramsSent) acks=\(media.acksReceived) retransmits=\(media.retransmitsSent)"
        )

        XCTAssertTrue(probe.recoveryEvents.isEmpty,
                      "LAN stream must not trigger recovery: \(probe.recoveryEvents)")
        XCTAssertGreaterThan(probe.decodedFrames, 150,
                             "decoder must keep up under load (got \(probe.decodedFrames) frames)")
        // KCP HoL-blocking stalls are absorbed by the PTS-paced jitter
        // buffer in the MPT sink decode path (2026-08-11 fix): holes up to
        // the buffer depth no longer starve decode, and longer holes shrink
        // by the same amount, so decode gaps stay well under 500ms. The
        // hard bar sits at 1s — the original production symptom (~1s
        // pauses): under 4 parallel test workers a one-off sub-second
        // decode lag (observed 643-762ms with clean ACK gaps) is scheduler
        // contention on the decode queue, not a transport stall.
        XCTAssertEqual(media.ackGapsOver500ms, 0,
                       "receiver queue must not stall >500ms (maxAckGapMs=\(media.maxAckGapMilliseconds))")
        XCTAssertEqual(probe.decodeGapsOver1000ms, 0,
                       "decode must not stall >1s (maxDecodeGapMs=\(probe.maxDecodeGapMilliseconds), decodeGaps500=\(probe.decodeGapsOver500ms))")
    }

    // MARK: - LAN: fast phone PTS clock (jitter buffer skew regulation)

    // The real phone's PTS clock runs ~1.75% faster than Mac wall time
    // (measured 2026-08-11, session 02892A1C: ~91580 ticks/s). A fixed
    // PTS→wall anchor lets the buffered span grow to the 3×depth overflow
    // cap (~1.5s glass-to-glass) with a continuous overflow-flush storm; the
    // span-based early release must keep the stream healthy instead. The
    // latency bound itself is asserted in XiaomiMirrorJitterBufferTests.
    func testLANMPTSinkToleratesFastPhonePTSClock() async throws {
        UserDefaults.standard.set("mpt", forKey: "xiaomiMirrorRTSPTransportMode")
        UserDefaults.standard.set("official", forKey: "xiaomiMirrorRTSPProtocolProfile")

        let source = XiaomiMirrorRTSPDiagnosticSource()
        let probe = MediaLoadProbe()
        source.onRecoveryRequired = { probe.noteRecovery($0) }
        source.onDecodedFrame = { _, _, _ in probe.noteDecodedFrame() }
        try source.start(port: rtspPort, advertisedHost: "127.0.0.1", lifetime: 300)
        defer { source.stop(reason: "test_teardown") }

        let phone = FakePhoneOfficialRTSPClient(host: "127.0.0.1", port: rtspPort)
        try phone.connect()
        defer { phone.stop() }
        try await waitFor("RTSP dialog reached PLAY", timeout: 10) { phone.playAcknowledged }

        let media = FakePhoneMPTMediaSource(
            width: 960, height: 2080, averageBitRate: 20_000_000,
            loss: 0.02, duplicate: 0.2, retransmitsLost: true,
            ptsClockFactor: 1.0175
        )
        media.sinkPort = sinkPort
        media.onDatagram = { [weak media] datagram in
            media?.sendUDP(datagram)
        }
        phone.onIDRRequest = { [weak media] in media?.forceNextKeyframe() }
        media.start()
        defer { media.stop() }

        try await Task.sleep(nanoseconds: 25_000_000_000)

        XCTAssertTrue(probe.recoveryEvents.isEmpty,
                      "fast phone PTS clock must not trigger recovery: \(probe.recoveryEvents)")
        XCTAssertGreaterThan(probe.decodedFrames, 150,
                             "decoder must keep up under skew (got \(probe.decodedFrames) frames)")
        XCTAssertLessThan(probe.secondsSinceLastDecodedFrame, 2.0,
                          "decoded frames must still flow at the end of the soak")
        // Same 1s hard bar as the ingestion-stall soak (parallel-worker
        // scheduler contention can lag decode sub-second once per soak).
        XCTAssertEqual(probe.decodeGapsOver1000ms, 0,
                       "decode must not stall >1s under skew (maxDecodeGapMs=\(probe.maxDecodeGapMilliseconds), decodeGaps500=\(probe.decodeGapsOver500ms))")
        XCTAssertEqual(media.ackGapsOver500ms, 0,
                       "receiver queue must not stall >500ms under skew (maxAckGapMs=\(media.maxAckGapMilliseconds))")
    }

    // MARK: - LAN: static screen (zero packets) is not a transport death

    // Static phone content: the official encoder emits nothing at all — no
    // video, no audio, zero KCP pushes — which trips the 6s no-packets
    // watchdog. While the RTSP control dialog keeps answering keepalives the
    // source is idle, not dead: hold the last frame, never recover. Once the
    // control plane stops answering too, recovery must fire again.
    func testLANMPTSinkStaticScreenSilenceDoesNotRecover() async throws {
        UserDefaults.standard.set("mpt", forKey: "xiaomiMirrorRTSPTransportMode")
        UserDefaults.standard.set("official", forKey: "xiaomiMirrorRTSPProtocolProfile")

        let source = XiaomiMirrorRTSPDiagnosticSource()
        let probe = MediaLoadProbe()
        source.onRecoveryRequired = { probe.noteRecovery($0) }
        source.onDecodedFrame = { _, _, _ in probe.noteDecodedFrame() }
        try source.start(port: rtspPort, advertisedHost: "127.0.0.1", lifetime: 300)
        defer { source.stop(reason: "test_teardown") }

        let phone = FakePhoneOfficialRTSPClient(host: "127.0.0.1", port: rtspPort)
        try phone.connect()
        defer { phone.stop() }
        try await waitFor("RTSP dialog reached PLAY", timeout: 10) { phone.playAcknowledged }

        // Stream briefly so the session reaches steady state, then go
        // completely silent like a static phone screen.
        let media = FakePhoneMPTMediaSource(
            width: 640, height: 360, averageBitRate: 8_000_000
        )
        media.sinkPort = sinkPort
        media.onDatagram = { [weak media] datagram in
            media?.sendUDP(datagram)
        }
        phone.onIDRRequest = { [weak media] in media?.forceNextKeyframe() }
        media.start()
        try await Task.sleep(nanoseconds: 4_000_000_000)
        media.stop()
        XCTAssertGreaterThan(probe.decodedFrames, 10,
                             "the warm-up phase must decode frames (got \(probe.decodedFrames))")

        // 30s of total media silence = 5× the no-packets threshold, with the
        // RTSP keepalive dialog alive throughout.
        try await Task.sleep(nanoseconds: 30_000_000_000)

        XCTAssertTrue(probe.recoveryEvents.isEmpty,
                      "static-screen silence with a healthy control plane must not recover: \(probe.recoveryEvents)")
        XCTAssertGreaterThan(phone.getParameterRequestsAnswered, 0,
                             "the control plane must have exercised keepalives during the silence")

        // Negative control: the control plane goes dead too (keepalives no
        // longer answered) — now the same silence must recover.
        phone.respondsToGetParameter = false
        try await waitFor("recovery after control plane death", timeout: 40) {
            !probe.recoveryEvents.isEmpty
        }
    }

    private func waitFor(
        _ description: String,
        timeout: TimeInterval,
        condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("timeout waiting for: \(description)")
    }
}

// Assertion surface shared by both soaks; all state is lock-guarded because
// the media callbacks arrive on the receiver's serial queues.
private final class MediaLoadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var recoveryEvents: [XiaomiMirrorRTSPRecoveryEvent] = []
    private(set) var decodedFrames: UInt64 = 0
    private var lastDecodedFrameUptime: UInt64 = 0
    private(set) var maxDecodeGapMilliseconds: Double = 0
    private(set) var decodeGapsOver200ms = 0
    private(set) var decodeGapsOver500ms = 0
    private(set) var decodeGapsOver1000ms = 0

    var secondsSinceLastDecodedFrame: Double {
        lock.lock()
        defer { lock.unlock() }
        guard lastDecodedFrameUptime > 0 else { return .infinity }
        return Double(DispatchTime.now().uptimeNanoseconds - lastDecodedFrameUptime) / 1_000_000_000
    }

    func noteRecovery(_ event: XiaomiMirrorRTSPRecoveryEvent) {
        lock.lock()
        recoveryEvents.append(event)
        lock.unlock()
    }

    func noteDecodedFrame() {
        lock.lock()
        decodedFrames += 1
        let now = DispatchTime.now().uptimeNanoseconds
        if lastDecodedFrameUptime > 0 {
            let gapMs = Double(now - lastDecodedFrameUptime) / 1_000_000
            maxDecodeGapMilliseconds = max(maxDecodeGapMilliseconds, gapMs)
            if gapMs > 200 { decodeGapsOver200ms += 1 }
            if gapMs > 500 { decodeGapsOver500ms += 1 }
            if gapMs > 1000 { decodeGapsOver1000ms += 1 }
        }
        lastDecodedFrameUptime = now
        lock.unlock()
    }
}

// MARK: - Fake phone media source (HEVC encode → TS → RTP → KCP)

// Encodes noisy frames with VideoToolbox (worst-case bitrate), muxes them
// into the same RTP/PT33/MP2T/HEVC interleaved KCP stream the real phone
// emits, and paces pushes at 30fps.
private final class FakePhoneMPTMediaSource: @unchecked Sendable {
    var onDatagram: ((Data) -> Void)?

    private(set) var datagramsSent: UInt64 = 0
    private(set) var acksReceived: UInt64 = 0
    // ACK inter-arrival gaps measured on the fake phone. KCP ACKs are emitted
    // synchronously inside the Mac receiver's receiveDatagram on the receiver
    // queue, so a >200ms ACK gap means the Mac's ingestion pipeline stalled.
    private(set) var maxAckGapMilliseconds: Double = 0
    private(set) var ackGapsOver200ms = 0
    private(set) var ackGapsOver500ms = 0
    private var lastAckUptimeNanoseconds: UInt64 = 0

    private func noteAckArrival() {
        let now = DispatchTime.now().uptimeNanoseconds
        if lastAckUptimeNanoseconds > 0 {
            let gapMs = Double(now - lastAckUptimeNanoseconds) / 1_000_000
            maxAckGapMilliseconds = max(maxAckGapMilliseconds, gapMs)
            if gapMs > 200 { ackGapsOver200ms += 1 }
            if gapMs > 500 { ackGapsOver500ms += 1 }
        }
        lastAckUptimeNanoseconds = now
    }

    private let queue = DispatchQueue(label: "FakePhoneMPTMediaSource")
    private let kcp = MiplayKcpTransport(
        sinkMode: false,
        conversationID: 0x1234,
        sessionDescription: "fakephone-media"
    )
    private let width: Int
    private let height: Int
    private let frameRate: Int
    private let averageBitRate: Int
    // Network impairment on the media leg (models WiFi/dc behavior): each
    // datagram is dropped with `loss` probability and sent twice with
    // `duplicate` probability. When `retransmitsLost` is set the fake acts
    // like the real phone's KCP: segments not covered by an ACK una are
    // resent after a retransmit timeout.
    private let loss: Double
    private let duplicate: Double
    private let retransmitsLost: Bool
    // Sender PTS clock skew (1.0 = perfect). The real phone's PTS clock was
    // measured ~1.75% fast vs Mac wall time (2026-08-11); the sink jitter
    // buffer must regulate the resulting span growth instead of letting
    // latency climb to the overflow cap.
    private let ptsClockFactor: Double
    // Per-segment ARQ state, mirroring the official phone KCP sender
    // (micontinuity_sdk MTP_NET_ConnectionKcpStackCreate: ikcp wnd 1024,
    // nodelay=1, interval 10-20ms, fastresend=2-3, nocwnd=1, min RTO 30ms):
    // each skipped ACK increments the segment's fastack count and 2 strikes
    // resend immediately; otherwise the segment is resent once its RTO
    // elapses, with backoff on repeated timeouts.
    private struct UnackedSegment {
        let datagram: Data
        var sentAtUptimeNanoseconds: UInt64
        var resendAtUptimeNanoseconds: UInt64
        var fastack: Int
        var rtoNanoseconds: UInt64
    }
    private var unacked: [UInt32: UnackedSegment] = [:]
    private var pendingSend: [Data] = []
    private var retransmitTimer: DispatchSourceTimer?
    private static let baseRTONanoseconds: UInt64 = 40_000_000
    private static let maxRTONanoseconds: UInt64 = 500_000_000
    private static let fastResendLimit = 2
    private static let updateIntervalMilliseconds = 20
    // ikcp_flush resends at most once per segment per update cycle; the cap
    // additionally keeps a loss burst from turning into a retransmit flood
    // (2% loss at ~1.4k seg/s creates <1 new hole per 20ms tick).
    private static let maxResendPerUpdate = 64
    // KCP-style send window: new segments leave only while unacked fits the
    // window, so retransmits get priority and the backlog stays bounded
    // (without it, unacked grows to ~10k under loss and the retransmit
    // cycle dilates past the hole-heal deadline).
    private static let sendWindowSegments = 1_024

    init(
        width: Int = 640,
        height: Int = 360,
        frameRate: Int = 30,
        averageBitRate: Int = 15_000_000,
        loss: Double = 0,
        duplicate: Double = 0,
        retransmitsLost: Bool = false,
        ptsClockFactor: Double = 1.0
    ) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.averageBitRate = averageBitRate
        self.loss = loss
        self.duplicate = duplicate
        self.retransmitsLost = retransmitsLost
        self.ptsClockFactor = ptsClockFactor
    }
    private var encoder: FakePhoneHEVCEncoder?
    private var udpSocketFD: Int32 = -1
    private var udpReadSource: DispatchSourceRead?
    private var rtpSequence: UInt16 = 0
    private let ssrc: UInt32 = 0xdeadbeef
    private let muxer = FakePhoneTSMuxer()
    private var forceKeyframe = false

    func start() {
        queue.async {
            self.kcp.onSendDatagram = { [weak self] packet in
                guard let self else { return }
                if self.retransmitsLost {
                    if self.unacked.count >= Self.sendWindowSegments {
                        self.pendingSend.append(packet)
                        return
                    }
                    if let segment = MiplayKcpSegment(data: packet) {
                        let now = DispatchTime.now().uptimeNanoseconds
                        self.unacked[segment.sn] = UnackedSegment(
                            datagram: packet,
                            sentAtUptimeNanoseconds: now,
                            resendAtUptimeNanoseconds: now + Self.baseRTONanoseconds,
                            fastack: 0,
                            rtoNanoseconds: Self.baseRTONanoseconds
                        )
                    }
                }
                self.emitDatagram(packet)
            }
            if self.retransmitsLost {
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(
                    deadline: .now() + .milliseconds(Self.updateIntervalMilliseconds),
                    repeating: .milliseconds(Self.updateIntervalMilliseconds)
                )
                timer.setEventHandler { [weak self] in
                    self?.retransmitTimedOutSegments()
                }
                self.retransmitTimer = timer
                timer.resume()
            }
            self.openUDPSocket()
            let encoder = FakePhoneHEVCEncoder(width: self.width, height: self.height, frameRate: self.frameRate, averageBitRate: self.averageBitRate, ptsClockFactor: self.ptsClockFactor)
            encoder.onAccessUnit = { [weak self] nalUnits, pts90k in
                self?.queue.async {
                    self?.sendAccessUnit(nalUnits, pts90k: pts90k)
                }
            }
            encoder.start()
            self.encoder = encoder
        }
    }

    func stop() {
        queue.sync {
            retransmitTimer?.cancel()
            retransmitTimer = nil
            unacked.removeAll()
            pendingSend.removeAll()
            encoder?.stop()
            encoder = nil
            udpReadSource?.cancel()
            udpReadSource = nil
            if udpSocketFD >= 0 {
                Darwin.close(udpSocketFD)
                udpSocketFD = -1
            }
        }
    }

    private func emitDatagram(_ packet: Data) {
        if loss > 0, Double.random(in: 0..<1) < loss {
            return
        }
        datagramsSent += 1
        onDatagram?(packet)
        if duplicate > 0, Double.random(in: 0..<1) < duplicate {
            datagramsSent += 1
            onDatagram?(packet)
        }
    }

    // ikcp-style fast retransmit bookkeeping: an ACK for sn removes it from
    // the window, and every still-unacked segment it skips (sequence-wise
    // older) gains a fastack strike. Resends are emitted only by the update
    // tick (like ikcp_flush), never inline here — an inline resend-per-ACK
    // floods loopback under sustained loss, the Mac's socket buffer
    // overflows, and the resulting real loss death-spirals (observed
    // 2026-08-11: 3.1M retransmits in 30s melted the soak).
    private func noteAcknowledgedSegment(sn: UInt32) {
        unacked.removeValue(forKey: sn)
        for (candidateSN, var entry) in unacked
        where Int32(bitPattern: candidateSN &- sn) < 0 {
            entry.fastack += 1
            unacked[candidateSN] = entry
        }
    }

    private func retransmitTimedOutSegments() {
        let now = DispatchTime.now().uptimeNanoseconds
        let due = unacked
            .filter { $0.value.fastack >= Self.fastResendLimit || now >= $0.value.resendAtUptimeNanoseconds }
            .sorted { Int32(bitPattern: $0.key &- $1.key) < 0 }
            .prefix(Self.maxResendPerUpdate)
        for (sn, _) in due {
            guard var entry = unacked[sn] else { continue }
            if entry.fastack >= Self.fastResendLimit, now < entry.resendAtUptimeNanoseconds {
                // Fast retransmit: no RTO backoff (ikcp fastresend path).
                entry.fastack = 0
                entry.resendAtUptimeNanoseconds = now + entry.rtoNanoseconds
            } else {
                // RTO path: back off on repeated timeouts (ikcp nodelay
                // mode grows the RTO per xmit).
                entry.rtoNanoseconds = min(entry.rtoNanoseconds * 2, Self.maxRTONanoseconds)
                entry.fastack = 0
                entry.resendAtUptimeNanoseconds = now + entry.rtoNanoseconds
            }
            entry.sentAtUptimeNanoseconds = now
            unacked[sn] = entry
            retransmitsSent += 1
            emitDatagram(entry.datagram)
        }
        if retransmitsSent > 0, !due.isEmpty, retransmitsSent % 2000 < due.count || retransmitsSent == due.count {
            DiagnosticsLog.info(
                "fakephone.media.retransmit total=\(retransmitsSent) unacked=\(unacked.count) pending=\(pendingSend.count) latestUna=\(kcp.latestRemoteUNA.map(String.init) ?? "none")"
            )
        }
    }

    private func processACKDatagram(_ data: Data) {
        var offset = 0
        while offset + MiplayKcpTransport.headerLength <= data.count,
              let segment = MiplayKcpSegment(data: data, offset: offset) {
            if segment.command == MiplayKcpTransport.commandACK {
                noteAcknowledgedSegment(sn: segment.sn)
            }
            offset += MiplayKcpTransport.headerLength + Int(segment.length)
        }
    }

    private(set) var retransmitsSent = 0

    private func pruneAcknowledgedSegments() {
        guard let una = kcp.latestRemoteUNA else { return }
        unacked = unacked.filter { sn, _ in
            Int32(bitPattern: sn &- una) >= 0
        }
        while !pendingSend.isEmpty, unacked.count < Self.sendWindowSegments {
            let packet = pendingSend.removeFirst()
            if let segment = MiplayKcpSegment(data: packet) {
                let now = DispatchTime.now().uptimeNanoseconds
                unacked[segment.sn] = UnackedSegment(
                    datagram: packet,
                    sentAtUptimeNanoseconds: now,
                    resendAtUptimeNanoseconds: now + Self.baseRTONanoseconds,
                    fastack: 0,
                    rtoNanoseconds: Self.baseRTONanoseconds
                )
            }
            emitDatagram(packet)
        }
    }

    func forceNextKeyframe() {
        queue.async {
            self.forceKeyframe = true
            self.encoder?.forceNextKeyframe()
        }
    }

    func receiveACKs(_ packets: [Data]) {
        queue.async {
            for packet in packets {
                self.noteAckArrival()
                if self.retransmitsLost {
                    self.processACKDatagram(packet)
                }
                self.kcp.receiveDatagram(packet)
            }
            self.acksReceived = self.kcp.acksReceived
            self.pruneAcknowledgedSegments()
        }
    }

    func sendUDP(_ datagram: Data) {
        queue.async {
            self.sendUDPOnQueue(datagram)
        }
    }

    // MARK: UDP socket (LAN path: datagrams to the Mac's MPT sink port)

    // The Mac sink's UDP port (prod: 15550; these tests override it to stay
    // clear of a running prod app).
    var sinkPort: UInt16 = 15_550

    private func openUDPSocket() {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        _ = Darwin.fcntl(fd, F_SETFL, Darwin.fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        udpSocketFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.drainUDPAcks()
        }
        udpReadSource = source
        source.resume()
    }

    private func drainUDPAcks() {
        guard udpSocketFD >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.recv(udpSocketFD, &buffer, buffer.count, 0)
            guard count > 0 else { break }
            let packet = Data(buffer.prefix(count))
            noteAckArrival()
            if retransmitsLost {
                processACKDatagram(packet)
            }
            kcp.receiveDatagram(packet)
        }
        acksReceived = kcp.acksReceived
        pruneAcknowledgedSegments()
    }

    private func sendUDPOnQueue(_ datagram: Data) {
        guard udpSocketFD >= 0 else { return }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = sinkPort.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        datagram.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    _ = Darwin.sendto(
                        udpSocketFD, base, datagram.count, 0,
                        sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size)
                    )
                }
            }
        }
    }

    // MARK: AU → TS → RTP → interleaved → KCP

    private func sendAccessUnit(_ nalUnits: [Data], pts90k: UInt64) {
        let tsPackets = muxer.muxAccessUnit(nalUnits, pts90k: pts90k)
        var offset = 0
        while offset < tsPackets.count {
            let end = min(offset + 7, tsPackets.count)
            var payload = Data()
            for index in offset..<end {
                payload.append(tsPackets[index])
            }
            let marker = end == tsPackets.count
            let rtp = Self.encodeRTP(
                marker: marker,
                sequence: rtpSequence,
                timestamp: UInt32(truncatingIfNeeded: pts90k),
                ssrc: ssrc,
                payload: payload
            )
            rtpSequence &+= 1
            let interleaved = Self.encodeInterleavedFrame(channel: 0, payload: rtp)
            kcp.sendPush(payload: interleaved, rtpSequence: rtpSequence)
            offset = end
        }
    }

    private static func encodeRTP(
        marker: Bool,
        sequence: UInt16,
        timestamp: UInt32,
        ssrc: UInt32,
        payload: Data
    ) -> Data {
        var packet = Data(capacity: 12 + payload.count)
        packet.append(0x80)
        packet.append((marker ? 0x80 : 0) | 33)
        packet.append(UInt8(sequence >> 8))
        packet.append(UInt8(sequence & 0xff))
        packet.append(UInt8(timestamp >> 24))
        packet.append(UInt8((timestamp >> 16) & 0xff))
        packet.append(UInt8((timestamp >> 8) & 0xff))
        packet.append(UInt8(timestamp & 0xff))
        packet.append(UInt8(ssrc >> 24))
        packet.append(UInt8((ssrc >> 16) & 0xff))
        packet.append(UInt8((ssrc >> 8) & 0xff))
        packet.append(UInt8(ssrc & 0xff))
        packet.append(payload)
        return packet
    }

    private static func encodeInterleavedFrame(channel: UInt8, payload: Data) -> Data {
        var frame = Data(capacity: 4 + payload.count)
        frame.append(0x24)
        frame.append(channel)
        frame.append(UInt8(payload.count >> 8))
        frame.append(UInt8(payload.count & 0xff))
        frame.append(payload)
        return frame
    }
}

// MARK: - HEVC encoder (VideoToolbox, noise frames for worst-case bitrate)

private final class FakePhoneHEVCEncoder: @unchecked Sendable {
    var onAccessUnit: (([Data], UInt64) -> Void)?

    private let width: Int
    private let height: Int
    private let frameRate: Int
    private let averageBitRate: Int
    private let ptsClockFactor: Double
    private let queue = DispatchQueue(label: "FakePhoneHEVCEncoder")
    private var session: VTCompressionSession?
    private var frameIndex: Int64 = 0
    private var frameTimer: DispatchSourceTimer?
    private var forceKeyframe = false
    private var parameterSets: [Data] = []
    private var framesSubmitted = 0

    init(width: Int, height: Int, frameRate: Int, averageBitRate: Int = 15_000_000, ptsClockFactor: Double = 1.0) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.averageBitRate = averageBitRate
        self.ptsClockFactor = ptsClockFactor
    }

    func start() {
        queue.async {
            self.createSession()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(
                deadline: .now(),
                repeating: .milliseconds(1000 / self.frameRate)
            )
            timer.setEventHandler { [weak self] in
                self?.encodeNextFrame()
            }
            self.frameTimer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.sync {
            frameTimer?.cancel()
            frameTimer = nil
            if let session {
                VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
                VTCompressionSessionInvalidate(session)
            }
            session = nil
        }
    }

    func forceNextKeyframe() {
        queue.async { self.forceKeyframe = true }
    }

    private func createSession() {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: nil,
            imageBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ] as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: { refcon, _, status, _, sampleBuffer in
                guard let refcon, status == noErr, let sampleBuffer else { return }
                let encoder = Unmanaged<FakePhoneHEVCEncoder>.fromOpaque(refcon).takeUnretainedValue()
                encoder.handleEncoded(sampleBuffer)
            },
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )
        guard status == noErr, let session else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_HEVC_Main_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                             value: NSNumber(value: frameRate))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                             value: NSNumber(value: frameRate))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: NSNumber(value: averageBitRate))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering,
                             value: kCFBooleanFalse)
        VTCompressionSessionPrepareToEncodeFrames(session)
        self.session = session
    }

    private func encodeNextFrame() {
        guard let session else { return }
        framesSubmitted += 1
        if framesSubmitted <= 3 || framesSubmitted % 30 == 0 {
            DiagnosticsLog.info("fakephone.media.encode_submit count=\(framesSubmitted)")
        }
        var pixelBuffer: CVPixelBuffer?
        let attributes = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_32BGRA, attributes, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer else { return }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            for row in 0..<height {
                arc4random_buf(base.advanced(by: row * bytesPerRow), width * 4)
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        let ticksPerFrame: Int64 = 90_000 / Int64(frameRate)
        let pts = CMTime(value: Int64(Double(frameIndex * ticksPerFrame) * ptsClockFactor), timescale: 90_000)
        frameIndex += 1
        var properties: [String: Any]? = nil
        if forceKeyframe {
            forceKeyframe = false
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true]
        }
        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: properties as CFDictionary?,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
    }

    private func handleEncoded(_ sampleBuffer: CMSampleBuffer) {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let length = CMBlockBufferGetDataLength(dataBuffer)
        var sampleData = Data(count: length)
        sampleData.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: length, destination: base)
        }
        if let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) {
            parameterSets = Self.hevcParameterSets(from: formatDescription)
        }
        let isSync = Self.isSyncSample(sampleBuffer)
        let pts90k = UInt64(max(0, CMSampleBufferGetPresentationTimeStamp(sampleBuffer).value))
        var nalUnits: [Data] = []
        if isSync {
            nalUnits.append(contentsOf: parameterSets)
        }
        var offset = 0
        let bytes = [UInt8](sampleData)
        while offset + 4 <= bytes.count {
            let nalLength = (Int(bytes[offset]) << 24) | (Int(bytes[offset + 1]) << 16)
                | (Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])
            offset += 4
            guard nalLength > 0, offset + nalLength <= bytes.count else { break }
            nalUnits.append(Data(bytes[offset..<(offset + nalLength)]))
            offset += nalLength
        }
        guard !nalUnits.isEmpty else { return }
        accessUnitsProduced += 1
        if accessUnitsProduced <= 3 || accessUnitsProduced % 30 == 0 {
            DiagnosticsLog.info(
                "fakephone.media.au count=\(accessUnitsProduced) nals=\(nalUnits.count) " +
                    "bytes=\(nalUnits.reduce(0) { $0 + $1.count }) pts90k=\(pts90k)"
            )
        }
        onAccessUnit?(nalUnits, pts90k)
    }

    private var accessUnitsProduced = 0

    private static func isSyncSample(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false),
              CFArrayGetCount(attachments) > 0 else { return true }
        let attachment = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary.self)
        guard let value = CFDictionaryGetValue(
            attachment,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()
        ) else { return true }
        return !CFBooleanGetValue(unsafeBitCast(value, to: CFBoolean.self))
    }

    private static func hevcParameterSets(from formatDescription: CMFormatDescription) -> [Data] {
        var sets: [Data] = []
        var count = 0
        guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            formatDescription, parameterSetIndex: 0,
            parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil
        ) == noErr else { return sets }
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                formatDescription, parameterSetIndex: index,
                parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
            ) == noErr, let pointer, size > 0 else { continue }
            sets.append(Data(bytes: pointer, count: size))
        }
        return sets
    }
}

// MARK: - MPEG-TS muxer (PAT/PMT/PES, video PID 0x1011, streamType 0x24)

private final class FakePhoneTSMuxer {
    private var continuityCounters: [UInt16: UInt8] = [:]
    private var packetsSinceTables = Int.max

    func muxAccessUnit(_ nalUnits: [Data], pts90k: UInt64) -> [Data] {
        var pesPayload = Data()
        for nalUnit in nalUnits {
            pesPayload.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
            pesPayload.append(nalUnit)
        }
        var pes = Data([0x00, 0x00, 0x01, 0xE0])
        pes.append(contentsOf: [0x00, 0x00]) // unbounded length
        pes.append(contentsOf: [0x80, 0x80, 0x05])
        Self.encodePTS(pts90k, into: &pes)
        pes.append(pesPayload)

        var packets: [Data] = []
        if packetsSinceTables >= 20 {
            packetsSinceTables = 0
            packets.append(makeTSPacket(pid: 0x0000, payloadUnitStart: true, payload: Self.patSection()))
            packets.append(makeTSPacket(pid: 0x0100, payloadUnitStart: true, payload: Self.pmtSection()))
        }
        var offset = 0
        var first = true
        while offset < pes.count {
            let chunk = min(184, pes.count - offset)
            packets.append(makeTSPacket(
                pid: 0x1011,
                payloadUnitStart: first,
                payload: pes.subdata(in: offset..<(offset + chunk))
            ))
            first = false
            offset += chunk
        }
        packetsSinceTables += packets.count
        return packets
    }

    private func makeTSPacket(pid: UInt16, payloadUnitStart: Bool, payload: Data) -> Data {
        var body = payload
        if payloadUnitStart, pid != 0x1011 {
            body = Data([0x00]) + payload // section pointer field
        }
        var packet = Data()
        packet.append(0x47)
        packet.append((payloadUnitStart ? 0x40 : 0x00) | UInt8((pid >> 8) & 0x1f))
        packet.append(UInt8(pid & 0xff))
        let cc = continuityCounters[pid] ?? 0
        continuityCounters[pid] = (cc + 1) & 0x0f
        if body.count < 184 {
            let adaptationLength = 184 - body.count - 1
            packet.append(0x30 | cc)
            packet.append(UInt8(adaptationLength))
            if adaptationLength > 0 {
                // First adaptation byte is the flags byte; keep it zero (any
                // set bit reads as discontinuity/PCR/etc. on the parse side)
                // and stuff only the remaining bytes.
                packet.append(0x00)
                if adaptationLength > 1 {
                    packet.append(contentsOf: repeatElement(0xFF, count: adaptationLength - 1))
                }
            }
        } else {
            packet.append(0x10 | cc)
        }
        packet.append(body)
        return packet
    }

    private static func patSection() -> Data {
        var section = Data([0x00, 0xB0, 0x0D])
        section.append(contentsOf: [0x00, 0x01]) // transport stream id
        section.append(contentsOf: [0xC1, 0x00, 0x00]) // version 0, section 0, last 0
        section.append(contentsOf: [0x00, 0x01]) // program 1
        section.append(contentsOf: [0xE0 | UInt8(0x0100 >> 8), UInt8(0x0100 & 0xff)])
        section.append(contentsOf: Self.mpegCRC(section))
        return section
    }

    private static func pmtSection() -> Data {
        var section = Data([0x02, 0xB0, 0x12])
        section.append(contentsOf: [0x00, 0x01]) // program number
        section.append(contentsOf: [0xC1, 0x00, 0x00])
        section.append(contentsOf: [0xE0 | UInt8(0x1011 >> 8), UInt8(0x1011 & 0xff)]) // PCR pid
        section.append(contentsOf: [0xF0, 0x00]) // program info length
        section.append(0x24) // HEVC stream type
        section.append(contentsOf: [0xE0 | UInt8(0x1011 >> 8), UInt8(0x1011 & 0xff)])
        section.append(contentsOf: [0xF0, 0x00]) // ES info length
        section.append(contentsOf: Self.mpegCRC(section))
        return section
    }

    private static func mpegCRC(_ data: Data) -> [UInt8] {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 {
                crc = (crc & 0x8000_0000) != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1
            }
        }
        return [UInt8(crc >> 24), UInt8((crc >> 16) & 0xff), UInt8((crc >> 8) & 0xff), UInt8(crc & 0xff)]
    }

    private static func encodePTS(_ pts: UInt64, into data: inout Data) {
        data.append(0x21 | UInt8((pts >> 29) & 0x0e))
        data.append(UInt8((pts >> 22) & 0xff))
        data.append(UInt8(((pts >> 14) & 0xfe) | 0x01))
        data.append(UInt8((pts >> 7) & 0xff))
        data.append(UInt8(((pts << 1) & 0xfe) | 0x01))
    }
}

// MARK: - Fake phone official-route RTSP client

// Minimal official-profile WFD dialog: answer the Mac's OPTIONS challenge,
// send our own OPTIONS + GET_PARAMETER + SET_PARAMETER (M4), answer the
// Mac's ACTIVE_SETUP with a server_port and Session, ack ACTIVE_PLAY. After
// that the KCP media flood can start.
private final class FakePhoneOfficialRTSPClient: @unchecked Sendable {
    var onIDRRequest: (() -> Void)?
    private(set) var playAcknowledged = false
    // Static-screen test hooks: count sink-initiated GET_PARAMETER keepalives
    // and allow muting the replies to simulate a dead control plane.
    private(set) var getParameterRequestsAnswered = 0
    var respondsToGetParameter = true

    private let host: String
    private let port: UInt16
    private let queue = DispatchQueue(label: "FakePhoneOfficialRTSPClient")
    private var connection: NWConnection?
    private var buffer = Data()
    private var cseq = 0
    private var sessionHeader: String?

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    func connect() throws {
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        self.connection = connection
        connection.start(queue: queue)
        receive()
        queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.sendOptions()
        }
    }

    func stop() {
        connection?.cancel()
        connection = nil
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65_535) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.drain()
            }
            if error == nil, !isComplete {
                self.receive()
            }
        }
    }

    private func drain() {
        while let headerEnd = buffer.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) {
            let headerData = buffer.subdata(in: 0..<headerEnd.lowerBound)
            guard let headerText = String(data: headerData, encoding: .utf8) else {
                buffer.removeAll()
                return
            }
            var lines = headerText.components(separatedBy: "\r\n")
            let firstLine = lines.first ?? ""
            lines.removeFirst()
            var headers: [String: String] = [:]
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                    line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let contentLength = headers["content-length"].flatMap(Int.init) ?? 0
            let messageEnd = headerEnd.upperBound + contentLength
            guard buffer.count >= messageEnd else { return }
            let body = buffer.subdata(in: headerEnd.upperBound..<messageEnd)
            buffer.removeSubrange(0..<messageEnd)
            handle(firstLine: firstLine, headers: headers, body: body)
        }
    }

    private func handle(firstLine: String, headers: [String: String], body: Data) {
        if firstLine.hasPrefix("RTSP/") {
            // Response to one of our requests.
            if let pending = pendingMethod {
                pendingMethod = nil
                switch pending {
                case "OPTIONS":
                    sendGetParameter()
                case "GET_PARAMETER":
                    sendSetParameter()
                case "SET_PARAMETER":
                    break // Mac drives ACTIVE_SETUP next.
                default:
                    break
                }
            }
            return
        }
        let method = firstLine.split(separator: " ").first.map(String.init) ?? ""
        let cseq = headers["cseq"] ?? "0"
        switch method {
        case "OPTIONS":
            let authMsg = headers["authmsg"] ?? ""
            let ack = Self.authMsgAck(for: authMsg)
            var response = "RTSP/1.0 200 OK\r\nCSeq: \(cseq)\r\n"
            response += "Public: org.wfa.wfd1.0, GET_PARAMETER, SET_PARAMETER\r\n"
            response += "authKeyType: 2\r\nauthAlgorithmVal: 4\r\nauthMsgAck:\(ack)\r\n\r\n"
            sendRaw(response)
        case "SETUP":
            sessionHeader = "87654321"
            var response = "RTSP/1.0 200 OK\r\nCSeq: \(cseq)\r\nSession: 87654321\r\n"
            response += "Transport: RTP/AVP/MPT;unicast;server_port=16666\r\n\r\n"
            sendRaw(response)
        case "PLAY":
            playAcknowledged = true
            sendRaw("RTSP/1.0 200 OK\r\nCSeq: \(cseq)\r\nSession: 87654321\r\n\r\n")
        case "SET_PARAMETER":
            let bodyText = String(data: body, encoding: .utf8) ?? ""
            if bodyText.contains("wfd_idr_request") {
                onIDRRequest?()
            }
            sendRaw("RTSP/1.0 200 OK\r\nCSeq: \(cseq)\r\nContent-Length: 0\r\n\r\n")
        case "GET_PARAMETER":
            guard respondsToGetParameter else { return }
            getParameterRequestsAnswered += 1
            sendRaw("RTSP/1.0 200 OK\r\nCSeq: \(cseq)\r\nContent-Length: 0\r\n\r\n")
        default:
            sendRaw("RTSP/1.0 200 OK\r\nCSeq: \(cseq)\r\nContent-Length: 0\r\n\r\n")
        }
    }

    private var pendingMethod: String?

    private func sendOptions() {
        pendingMethod = "OPTIONS"
        cseq += 1
        let authMsg = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        sendRaw(
            "OPTIONS rtsp://\(host):\(port)/wfd1.0 RTSP/1.0\r\nCSeq: \(cseq)\r\n" +
            "Require: org.wfa.wfd1.0\r\nauthMsg:\(authMsg)\r\n\r\n"
        )
    }

    private func sendGetParameter() {
        pendingMethod = "GET_PARAMETER"
        cseq += 1
        sendRaw(
            "GET_PARAMETER rtsp://\(host):\(port)/wfd1.0 RTSP/1.0\r\nCSeq: \(cseq)\r\n" +
            "Content-Type: text/parameters\r\nContent-Length: 19\r\n\r\nwfd_video_formats\r\n"
        )
    }

    private func sendSetParameter() {
        pendingMethod = "SET_PARAMETER"
        cseq += 1
        let body = "wfd_presentation_URL: rtsp://\(host):\(port)/wfd1.0 none\r\n" +
            "wfd_client_rtp_ports: RTP/AVP/MPT;unicast 16666 0 mode=play\r\n"
        sendRaw(
            "SET_PARAMETER rtsp://\(host):\(port)/wfd1.0 RTSP/1.0\r\nCSeq: \(cseq)\r\n" +
            "Content-Type: text/parameters\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        )
    }

    private func sendRaw(_ text: String) {
        connection?.send(content: Data(text.utf8), completion: .idempotent)
    }

    private static func authMsgAck(for authMsg: String) -> String {
        let key = SymmetricKey(data: Data("EdgeLinkMirrorK!".utf8))
        let code = HMAC<SHA256>.authenticationCode(for: Data(authMsg.utf8), using: key)
        return code.map { String(format: "%02x", $0) }.joined()
    }
}
