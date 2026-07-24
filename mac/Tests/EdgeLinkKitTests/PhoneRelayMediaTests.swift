import XCTest
@testable import EdgeLinkKit

final class PhoneRelayMediaTests: XCTestCase {
    func testCRC32MPEGKnownVector() {
        let data = Data("123456789".utf8)
        XCTAssertEqual(PhoneRelayTS.crc32MPEG(data), 0x0376_e6e7)
    }

    func testADTSHeaderEncodesFrameLengthAndConfig() {
        let config = PhoneRelayADTSConfig(sampleRate: 48_000, channels: 1)
        let header = Array(config.header(payloadLength: 100))
        XCTAssertEqual(header.count, 7)
        XCTAssertEqual(header[0], 0xff)
        XCTAssertEqual(header[1], 0xf1)
        let samplingIndex = (header[2] >> 2) & 0x0f
        XCTAssertEqual(samplingIndex, 3)
        let channelConfig = ((header[2] & 0x01) << 2) | (header[3] >> 6)
        XCTAssertEqual(channelConfig, 1)
        let frameLength = (Int(header[3] & 0x03) << 11) | (Int(header[4]) << 3) | (Int(header[5]) >> 5)
        XCTAssertEqual(frameLength, 107)
    }

    func testMuxerEmitsProgramHeadersAndWellFormedPES() {
        let muxer = PhoneRelayTSMuxer()
        let accessUnit = Data(repeating: 0xab, count: 100)
        let packets = muxer.appendAACAccessUnit(accessUnit, pts: 0)
        XCTAssertGreaterThanOrEqual(packets.count, 3)
        for packet in packets {
            XCTAssertEqual(packet.count, PhoneRelayTS.packetSize)
            XCTAssertEqual(packet.first, PhoneRelayTS.syncByte)
        }
        XCTAssertEqual(tsPID(packets[0]), 0)
        XCTAssertEqual(tsPID(packets[1]), PhoneRelayTS.pmtPID)
        XCTAssertEqual(tsPID(packets[2]), PhoneRelayTS.audioPID)

        let pat = packets[0]
        let patSection = Data(pat[5..<(5 + 16)])
        XCTAssertEqual(PhoneRelayTS.crc32MPEG(patSection), 0)
        let pmt = packets[1]
        let pmtSection = Data(pmt[5..<(5 + 21)])
        XCTAssertEqual(PhoneRelayTS.crc32MPEG(pmtSection), 0)

        let firstAudio = packets[2]
        XCTAssertEqual(firstAudio[1] & 0x40, 0x40)
        XCTAssertEqual(firstAudio[3] & 0x30, 0x30)
        let adaptationLength = Int(firstAudio[4])
        let payloadStart = 5 + adaptationLength
        XCTAssertEqual(Array(firstAudio[payloadStart..<(payloadStart + 4)]), [0x00, 0x00, 0x01, 0xc0])

        for index in 1..<5 {
            _ = muxer.appendAACAccessUnit(accessUnit, pts: UInt64(index * 1_920))
        }
        let sixth = muxer.appendAACAccessUnit(accessUnit, pts: 5 * 1_920)
        XCTAssertEqual(tsPID(sixth[0]), 0)
        XCTAssertEqual(tsPID(sixth[1]), PhoneRelayTS.pmtPID)
        XCTAssertEqual(muxer.pesPacketsMuxed, 6)
    }

    func testMuxerContinuityCountersIncrementPerPID() {
        let muxer = PhoneRelayTSMuxer()
        let accessUnit = Data(repeating: 0x11, count: 400)
        var previousAudioCC: UInt8?
        var previousPATCC: UInt8?
        for frame in 0..<10 {
            let packets = muxer.appendAACAccessUnit(accessUnit, pts: UInt64(frame * 1_920))
            for packet in packets where tsPID(packet) == PhoneRelayTS.audioPID {
                let cc = packet[3] & 0x0f
                if let previousAudioCC {
                    XCTAssertEqual(cc, (previousAudioCC &+ 1) & 0x0f, "frame \(frame)")
                }
                previousAudioCC = cc
            }
            for packet in packets where tsPID(packet) == 0 {
                let cc = packet[3] & 0x0f
                if let previousPATCC {
                    XCTAssertEqual(cc, (previousPATCC &+ 1) & 0x0f)
                }
                previousPATCC = cc
            }
        }
    }

    func testPacketizerGroupsAndFlushes() {
        let packetizer = PhoneRelayRTPPacketizer(ssrc: 0x0102_0304, timestamp: 1_000)
        let tsPacket = Data(repeating: 0x47, count: PhoneRelayTS.packetSize)
        let emitted = packetizer.appendTSPackets(Array(repeating: tsPacket, count: 6))
        XCTAssertEqual(emitted.count, 1)
        XCTAssertEqual(emitted[0].count, 12 + 5 * PhoneRelayTS.packetSize)
        XCTAssertEqual(emitted[0][0], 0x80)
        XCTAssertEqual(emitted[0][1], 0x80 | PhoneRelayTS.rtpPayloadType)
        XCTAssertEqual(UInt16(emitted[0][2]) << 8 | UInt16(emitted[0][3]), 0)
        XCTAssertEqual(be32(emitted[0], 4), 1_000)
        XCTAssertEqual(be32(emitted[0], 8), 0x0102_0304)
        XCTAssertEqual(packetizer.bufferedTSPacketCount, 1)

        let flushed = packetizer.flush()
        XCTAssertNotNil(flushed)
        XCTAssertEqual(flushed?.count, 12 + PhoneRelayTS.packetSize)
        XCTAssertEqual(UInt16(flushed![2]) << 8 | UInt16(flushed![3]), 1)
        XCTAssertEqual(be32(flushed!, 4), 1_000 + 1_800)
        XCTAssertNil(packetizer.flush())
    }

    func testMuxerDemuxerRoundTrip() {
        let muxer = PhoneRelayTSMuxer()
        var demuxer = PhoneRelayTSDemuxer()
        let accessUnit = Data((0..<250).map { UInt8($0 % 251) })
        var tsStream = Data()
        for frame in 0..<7 {
            for packet in muxer.appendAACAccessUnit(accessUnit, pts: UInt64(frame * 1_920)) {
                tsStream.append(packet)
            }
        }
        let payload = demuxer.extractAudioPayload(fromTSPayload: tsStream)
        let expectedFrame = PhoneRelayADTSConfig().header(payloadLength: accessUnit.count) + accessUnit
        XCTAssertEqual(payload.count, expectedFrame.count * 7)
        for frame in 0..<7 {
            let start = payload.index(payload.startIndex, offsetBy: expectedFrame.count * frame)
            let slice = payload[start..<payload.index(start, offsetBy: expectedFrame.count)]
            XCTAssertEqual(Data(slice), expectedFrame, "frame \(frame)")
        }
        XCTAssertEqual(demuxer.pesPacketCount, 7)
    }

    func testRTPPayloadOffsetParsesBasicHeader() {
        var packet = Data([0x80, 0xa1, 0x00, 0x01, 0x00, 0x00, 0x10, 0x00, 0xde, 0xad, 0xbe, 0xef])
        packet.append(Data(repeating: 0x47, count: 188))
        XCTAssertEqual(PhoneRelayTSDemuxer.rtpPayloadOffset(in: packet), 12)
        XCTAssertNil(PhoneRelayTSDemuxer.rtpPayloadOffset(in: Data([0x00, 0x01, 0x02])))
    }

    func testAACEncoderProducesAccessUnits() throws {
        let encoder = try XCTUnwrap(PhoneRelayAACEncoder())
        var pcm = Data()
        let frames = PhoneRelayAACEncoder.framesPerAccessUnit * 4
        pcm.reserveCapacity(frames * 2)
        for index in 0..<frames {
            let phase = Double(index % 48) / 48.0 * 2 * .pi
            let sample = Int16(sin(phase) * 8_000)
            pcm.append(UInt8(bitPattern: Int8(truncatingIfNeeded: sample & 0xff)))
            pcm.append(UInt8(bitPattern: Int8(truncatingIfNeeded: sample >> 8)))
        }
        let accessUnits = encoder.encode(pcm)
        XCTAssertGreaterThanOrEqual(accessUnits.count, 3)
        for accessUnit in accessUnits {
            XCTAssertFalse(accessUnit.isEmpty)
            XCTAssertLessThan(accessUnit.count, PhoneRelayAACEncoder.framesPerAccessUnit)
        }
    }

    func testEncoderMuxerDemuxerChainYieldsParseableADTS() throws {
        let encoder = try XCTUnwrap(PhoneRelayAACEncoder())
        let muxer = PhoneRelayTSMuxer()
        var demuxer = PhoneRelayTSDemuxer()
        var tsStream = Data()
        let silentPCM = Data(count: PhoneRelayAACEncoder.framesPerAccessUnit * 2 * 8)
        for accessUnit in encoder.encode(silentPCM) {
            let pts = (encoder.accessUnitsEncoded - 1) * UInt64(PhoneRelayAACEncoder.framesPerAccessUnit) * 90_000 / 48_000
            for packet in muxer.appendAACAccessUnit(accessUnit, pts: pts) {
                tsStream.append(packet)
            }
        }
        let payload = demuxer.extractAudioPayload(fromTSPayload: tsStream)
        XCTAssertFalse(payload.isEmpty)
        var offset = payload.startIndex
        var frames = 0
        while offset < payload.endIndex {
            guard payload[offset] == 0xff,
                  payload.index(after: offset) < payload.endIndex,
                  (payload[payload.index(after: offset)] & 0xf0) == 0xf0 else {
                XCTFail("missing ADTS sync at offset \(offset)")
                return
            }
            let b3 = payload[payload.index(offset, offsetBy: 3)]
            let b4 = payload[payload.index(offset, offsetBy: 4)]
            let b5 = payload[payload.index(offset, offsetBy: 5)]
            let frameLength = (Int(b3 & 0x03) << 11) | (Int(b4) << 3) | (Int(b5) >> 5)
            XCTAssertGreaterThanOrEqual(frameLength, 7)
            offset = payload.index(offset, offsetBy: frameLength)
            frames += 1
        }
        XCTAssertEqual(offset, payload.endIndex)
        XCTAssertGreaterThanOrEqual(frames, 1)
    }

    private func tsPID(_ packet: Data) -> UInt16 {
        (UInt16(packet[1] & 0x1f) << 8) | UInt16(packet[2])
    }

    private func be32(_ data: Data, _ offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 24) | (UInt32(data[offset + 1]) << 16) |
            (UInt32(data[offset + 2]) << 8) | UInt32(data[offset + 3])
    }
}
