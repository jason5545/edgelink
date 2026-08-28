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

    // MARK: - ff07 (live 2026-08-27: firmware moved the format-bearing kind
    // from 0x03 to 0x07 with the same fixed header: ff 07 | 00 00 00 0e |
    // 02 10 | 48000 | 310 | 16 | 1240. Live 2026-08-28: it also carries a
    // session-ID field before the PCM — u32 length incl. itself (36) at
    // offset 32, then a 32-char ASCII id — so PCM starts at 68, not 32.)

    private let liveSessionID = "be35dae855452c2ddbc5fb9264fd7325"

    private func makeFF07Packet(pcm: Data, sampleRate: UInt32 = 48_000, withSessionID: Bool = true) -> Data {
        var packet = Data([0xFF, 0x07, 0x00, 0x00, 0x00, 0x0E])
        packet.append(contentsOf: [0x02, 0x10]) // packedFormat: 2ch / 16-bit
        packet.append(contentsOf: [
            UInt8((sampleRate >> 24) & 0xFF), UInt8((sampleRate >> 16) & 0xFF),
            UInt8((sampleRate >> 8) & 0xFF), UInt8(sampleRate & 0xFF)
        ])
        let frames = UInt32(pcm.count / 4)
        packet.append(contentsOf: [
            UInt8((frames >> 24) & 0xFF), UInt8((frames >> 16) & 0xFF),
            UInt8((frames >> 8) & 0xFF), UInt8(frames & 0xFF)
        ])
        packet.append(contentsOf: [0x00, 0x00, 0x00, 0x10]) // bits = 16
        packet.append(contentsOf: [
            UInt8((pcm.count >> 24) & 0xFF), UInt8((pcm.count >> 16) & 0xFF),
            UInt8((pcm.count >> 8) & 0xFF), UInt8(pcm.count & 0xFF)
        ])
        packet.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // reserved
        packet.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // private PTS
        if withSessionID {
            appendSessionIDField(to: &packet)
        }
        packet.append(pcm)
        return packet
    }

    // u32 length including its own 4 bytes + ASCII id, exactly as captured.
    private func appendSessionIDField(to packet: inout Data) {
        let idBytes = Data(liveSessionID.utf8)
        let fieldLength = UInt32(4 + idBytes.count)
        packet.append(contentsOf: [
            UInt8((fieldLength >> 24) & 0xFF), UInt8((fieldLength >> 16) & 0xFF),
            UInt8((fieldLength >> 8) & 0xFF), UInt8(fieldLength & 0xFF)
        ])
        packet.append(idBytes)
    }

    // MARK: - ff06 (live 2026-08-28: the 8/27 firmware sends the audio data
    // itself as kind 0x06 — ff07 is only the per-session format record.
    // Layout: ff 06 | u32 16 | u32 declaredBytes | u32 0 | u32 privatePTS
    // (microseconds) | session-ID field | PCM. Every one of the 3241
    // captured records: declared=1240, idField=36, total 1294 bytes.)

    private func makeFF06Packet(pcm: Data, privatePTS: UInt32 = 255_385) -> Data {
        var packet = Data([0xFF, 0x06, 0x00, 0x00, 0x00, 0x10])
        packet.append(contentsOf: [
            UInt8((pcm.count >> 24) & 0xFF), UInt8((pcm.count >> 16) & 0xFF),
            UInt8((pcm.count >> 8) & 0xFF), UInt8(pcm.count & 0xFF)
        ])
        packet.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // reserved
        packet.append(contentsOf: [
            UInt8((privatePTS >> 24) & 0xFF), UInt8((privatePTS >> 16) & 0xFF),
            UInt8((privatePTS >> 8) & 0xFF), UInt8(privatePTS & 0xFF)
        ])
        appendSessionIDField(to: &packet)
        packet.append(pcm)
        return packet
    }

    func testFF07ParseExtractsFormatAndPayload() {
        let player = XiaomiMirrorMPTPrivateAudioPlayer(sessionID: UUID())
        let pcm = quietPCM()
        let parsed = player.parsePrivatePayload(makeFF07Packet(pcm: pcm))
        XCTAssertNotNil(parsed, "ff07 must parse — live 2026-08-27 stream went dark here")
        XCTAssertEqual(parsed?.kind, "ff07")
        XCTAssertEqual(parsed?.format.sampleRate, 48_000)
        XCTAssertEqual(parsed?.format.channels, 2)
        XCTAssertEqual(parsed?.format.bitsPerSample, 16)
        XCTAssertEqual(parsed?.pcmPayload, pcm, "session-ID field must not leak into the PCM (live 2026-08-28)")
        XCTAssertEqual(parsed?.declaredFrames, 310)
    }

    func testFF07WithoutSessionIDFieldKeeps32ByteHeader() {
        let player = XiaomiMirrorMPTPrivateAudioPlayer(sessionID: UUID())
        let pcm = quietPCM()
        let parsed = player.parsePrivatePayload(makeFF07Packet(pcm: pcm, withSessionID: false))
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.pcmPayload, pcm)
    }

    func testFF07QuietPCMPassesSafetyGate() {
        let player = XiaomiMirrorMPTPrivateAudioPlayer(sessionID: UUID())
        let parsed = player.parsePrivatePayload(makeFF07Packet(pcm: quietPCM()))!
        let stats = player.pcmS16LEStats(parsed.pcmPayload)
        XCTAssertTrue(player.isPrivateAudioPayloadSafe(parsed, stats: stats))
    }

    // MARK: - ff06 data records (live 2026-08-28 silent-audio incident:
    // every post-format audio record arrived as ff06 and the parser only
    // knew ff03/ff07/ff02, so parse failed 180950/180951 times and the
    // session played silence despite healthy PCM on the wire)

    func testFF06ParseExtractsPayloadFormatAndPTS() {
        let player = XiaomiMirrorMPTPrivateAudioPlayer(sessionID: UUID())
        let pcm = quietPCM()
        let parsed = player.parsePrivatePayload(makeFF06Packet(pcm: pcm))
        XCTAssertNotNil(parsed, "ff06 must parse — live 2026-08-28 stream was silent here")
        XCTAssertEqual(parsed?.kind, "ff06")
        XCTAssertEqual(parsed?.format.sampleRate, 48_000)
        XCTAssertEqual(parsed?.format.channels, 2)
        XCTAssertEqual(parsed?.format.bitsPerSample, 16)
        XCTAssertEqual(parsed?.pcmPayload, pcm)
        XCTAssertEqual(parsed?.declaredFrames, 310)
        XCTAssertEqual(parsed?.declaredPayloadBytes, pcm.count)
        XCTAssertEqual(parsed?.privatePTS90k, 255_385)
    }

    func testFF06RejectsTruncatedAndBadSessionIDLength() {
        let player = XiaomiMirrorMPTPrivateAudioPlayer(sessionID: UUID())
        XCTAssertNil(player.parsePrivatePayload(Data([0xFF, 0x06, 0x00, 0x00])))
        var badIDLength = makeFF06Packet(pcm: quietPCM())
        badIDLength[21] = 0xFF // session-ID field length 0xFF > 128 cap
        XCTAssertNil(player.parsePrivatePayload(badIDLength))
    }

    func testFF06QuietPCMPassesSafetyGate() {
        let player = XiaomiMirrorMPTPrivateAudioPlayer(sessionID: UUID())
        let parsed = player.parsePrivatePayload(makeFF06Packet(pcm: quietPCM()))!
        let stats = player.pcmS16LEStats(parsed.pcmPayload)
        XCTAssertTrue(player.isPrivateAudioPayloadSafe(parsed, stats: stats))
    }

    func testFF07FormatRecordThenFF06StreamAllParses() {
        // Exact live session shape: one ff07 format record, then a steady
        // ff06 stream. Before the fix every ff06 parse returned nil.
        let player = XiaomiMirrorMPTPrivateAudioPlayer(sessionID: UUID())
        let format = player.parsePrivatePayload(makeFF07Packet(pcm: quietPCM()))
        XCTAssertNotNil(format)
        for i in 0..<50 {
            let pcm = quietPCM()
            let parsed = player.parsePrivatePayload(
                makeFF06Packet(pcm: pcm, privatePTS: 255_385 + UInt32(i) * 6_458)
            )
            XCTAssertNotNil(parsed, "ff06 record \(i) must parse")
            XCTAssertEqual(parsed?.pcmPayload, pcm)
            let stats = player.pcmS16LEStats(parsed!.pcmPayload)
            XCTAssertTrue(player.isPrivateAudioPayloadSafe(parsed!, stats: stats))
        }
    }
}
