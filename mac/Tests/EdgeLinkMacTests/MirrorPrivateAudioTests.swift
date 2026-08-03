import Foundation
import XCTest

// Covers the mirror private-audio (0x83 stream) parsing and the garbage
// filter. The 2026-08-03 incident: loud podcast PCM (full-scale, ~100%
// nonzero) was dropped as "suspicious" even after the ff02 stream had
// self-primed, causing audible crackling — the filter must only guard the
// unprimed phase.
final class MirrorPrivateAudioTests: XCTestCase {
    private func makeFF02Packet(pcm: Data, declaredBytes: UInt32? = nil) -> Data {
        var packet = Data([0xFF, 0x02, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00])
        let declared = declaredBytes ?? UInt32(pcm.count)
        packet.append(contentsOf: [
            UInt8((declared >> 24) & 0xFF), UInt8((declared >> 16) & 0xFF),
            UInt8((declared >> 8) & 0xFF), UInt8(declared & 0xFF),
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00
        ])
        packet.append(pcm)
        return packet
    }

    private func loudPCM(frames: Int = 310) -> Data {
        var pcm = Data()
        for i in 0..<(frames * 2) {
            let sample = Int16(bitPattern: UInt16((i * 7919) % 65_000))
            var clamped = max(-32_700, min(32_700, Int(sample)))
            if abs(clamped) < 28_000 { clamped = clamped < 0 ? -31_000 : 31_000 }
            pcm.append(contentsOf: [
                UInt8(UInt16(bitPattern: Int16(clamped)) & 0xFF),
                UInt8((UInt16(bitPattern: Int16(clamped)) >> 8) & 0xFF)
            ])
        }
        return pcm
    }

    private func quietPCM(frames: Int = 310) -> Data {
        var pcm = Data()
        for i in 0..<(frames * 2) {
            let sample = Int16(sin(Double(i) * 0.1) * 300)
            pcm.append(contentsOf: [
                UInt8(UInt16(bitPattern: sample) & 0xFF),
                UInt8((UInt16(bitPattern: sample) >> 8) & 0xFF)
            ])
        }
        return pcm
    }

    func testFF02ParseExtractsFormatAndPayload() {
        let player = XiaomiMirrorMPTPrivateAudioPlayer(sessionID: UUID())
        let pcm = quietPCM()
        let parsed = player.parsePrivatePayload(makeFF02Packet(pcm: pcm))
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.kind, "ff02")
        XCTAssertEqual(parsed?.format.sampleRate, 48_000)
        XCTAssertEqual(parsed?.format.channels, 2)
        XCTAssertEqual(parsed?.format.bitsPerSample, 16)
        XCTAssertEqual(parsed?.pcmPayload.count, pcm.count)
        XCTAssertEqual(parsed?.declaredFrames, 310)
    }

    func testParseRejectsShortAndBadMagic() {
        let player = XiaomiMirrorMPTPrivateAudioPlayer(sessionID: UUID())
        XCTAssertNil(player.parsePrivatePayload(Data([0xFF, 0x02, 0x00])))
        XCTAssertNil(player.parsePrivatePayload(Data(repeating: 0x00, count: 64)))
    }

    func testLoudPCMRejectedBeforePriming() {
        let player = XiaomiMirrorMPTPrivateAudioPlayer(sessionID: UUID())
        let parsed = player.parsePrivatePayload(makeFF02Packet(pcm: loudPCM()))!
        let stats = player.pcmS16LEStats(parsed.pcmPayload)
        XCTAssertGreaterThanOrEqual(stats.maxAbs, 30_000)
        XCTAssertFalse(
            player.isPrivateAudioPayloadSafe(parsed, stats: stats),
            "unproven full-scale stream must stay filtered during priming"
        )
    }

    func testLoudPCMAcceptedAfterFF02Priming() {
        let player = XiaomiMirrorMPTPrivateAudioPlayer(sessionID: UUID())
        player.privateAudioFormatPrimed = true
        let parsed = player.parsePrivatePayload(makeFF02Packet(pcm: loudPCM()))!
        let stats = player.pcmS16LEStats(parsed.pcmPayload)
        XCTAssertTrue(
            player.isPrivateAudioPayloadSafe(parsed, stats: stats),
            "post-prime ff02 loud podcast PCM is content, not garbage (2026-08-03 crackle incident)"
        )
    }

    func testQuietPCMAcceptedRegardlessOfPriming() {
        let player = XiaomiMirrorMPTPrivateAudioPlayer(sessionID: UUID())
        let parsed = player.parsePrivatePayload(makeFF02Packet(pcm: quietPCM()))!
        let stats = player.pcmS16LEStats(parsed.pcmPayload)
        XCTAssertTrue(player.isPrivateAudioPayloadSafe(parsed, stats: stats, allowUnprimedFF02: true))
    }

    func testRejectsNonMultipleOfFrameSize() {
        let player = XiaomiMirrorMPTPrivateAudioPlayer(sessionID: UUID())
        player.privateAudioFormatPrimed = true
        var pcm = quietPCM()
        pcm.append(0x00)
        let parsed = player.parsePrivatePayload(makeFF02Packet(pcm: pcm))!
        let stats = player.pcmS16LEStats(parsed.pcmPayload)
        XCTAssertFalse(player.isPrivateAudioPayloadSafe(parsed, stats: stats))
    }

    func testFF02SelfPrimeSequencePlaysAfterStreak() {
        let player = XiaomiMirrorMPTPrivateAudioPlayer(sessionID: UUID())
        let pcm = quietPCM()
        let packet = makeFF02Packet(pcm: pcm)
        // Before the streak completes nothing schedules; after, payload must
        // be accepted by the safety gate (scheduling itself needs audio HW,
        // so only the gate is asserted here).
        for _ in 0..<3 {
            let parsed = player.parsePrivatePayload(packet)!
            let stats = player.pcmS16LEStats(parsed.pcmPayload)
            _ = player.isPrivateAudioPayloadSafe(parsed, stats: stats, allowUnprimedFF02: true)
        }
        let parsed = player.parsePrivatePayload(packet)!
        let stats = player.pcmS16LEStats(parsed.pcmPayload)
        XCTAssertTrue(player.isPrivateAudioPayloadSafe(parsed, stats: stats, allowUnprimedFF02: true))
    }
}
