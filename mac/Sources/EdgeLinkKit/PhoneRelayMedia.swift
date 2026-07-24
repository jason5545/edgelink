import AVFoundation
import Foundation

public enum PhoneRelayTS {
    public static let packetSize = 188
    public static let syncByte: UInt8 = 0x47
    public static let audioPID: UInt16 = 0x1100
    public static let pmtPID: UInt16 = 0x1000
    public static let rtpPayloadType: UInt8 = 33
    public static let rtpClockRate = 90_000
    public static let packetsPerRTPPacket = 5
    public static let programHeaderIntervalPES = 5
    public static let timestampBase: UInt64 = 126_000
    public static let uplinkSSRC: UInt32 = 0xed9e_1101

    static func crc32MPEG(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc = (crc << 8) ^ crcTable[Int(((crc >> 24) ^ UInt32(byte)) & 0xff)]
        }
        return crc
    }

    private static let crcTable: [UInt32] = (0...255).map { index in
        var value = UInt32(index) << 24
        for _ in 0..<8 {
            value = (value & 0x8000_0000) != 0 ? (value << 1) ^ 0x04c1_1db7 : value << 1
        }
        return value
    }
}

public struct PhoneRelayADTSConfig: Sendable {
    public let profile: UInt8
    public let samplingFrequencyIndex: UInt8
    public let channelConfiguration: UInt8

    public init(sampleRate: Int = 48_000, channels: Int = 1) {
        profile = 1
        switch sampleRate {
        case 96_000: samplingFrequencyIndex = 0
        case 88_200: samplingFrequencyIndex = 1
        case 64_000: samplingFrequencyIndex = 2
        case 48_000: samplingFrequencyIndex = 3
        case 44_100: samplingFrequencyIndex = 4
        case 32_000: samplingFrequencyIndex = 5
        case 24_000: samplingFrequencyIndex = 6
        case 16_000: samplingFrequencyIndex = 8
        default: samplingFrequencyIndex = 3
        }
        channelConfiguration = UInt8(max(1, min(channels, 7)))
    }

    public func header(payloadLength: Int) -> Data {
        let frameLength = payloadLength + 7
        return Data([
            0xff,
            0xf1,
            (profile << 6) | (samplingFrequencyIndex << 2) | (channelConfiguration >> 2),
            ((channelConfiguration & 0x03) << 6) | UInt8((frameLength >> 11) & 0x03),
            UInt8((frameLength >> 3) & 0xff),
            UInt8((frameLength & 0x07) << 5) | 0x1f,
            0xfc
        ])
    }
}

public final class PhoneRelayTSMuxer {
    public var programHeaderIntervalPES = PhoneRelayTS.programHeaderIntervalPES
    public var timestampBase = PhoneRelayTS.timestampBase
    public private(set) var pesPacketsMuxed = 0
    public private(set) var tsPacketsEmitted = 0

    private let adts: PhoneRelayADTSConfig
    private var pesIndex = 0
    private var audioContinuity: UInt8 = 0
    private var patContinuity: UInt8 = 0
    private var pmtContinuity: UInt8 = 0

    public init(adts: PhoneRelayADTSConfig = PhoneRelayADTSConfig()) {
        self.adts = adts
    }

    public func appendAACAccessUnit(_ accessUnit: Data, pts: UInt64) -> [Data] {
        var packets: [Data] = []
        let timestamp = (pts + timestampBase) & 0x1_ffff_ffff
        if pesIndex % programHeaderIntervalPES == 0 {
            packets.append(patPacket())
            packets.append(pmtPacket())
        }
        var framed = adts.header(payloadLength: accessUnit.count)
        framed.append(accessUnit)
        packets.append(contentsOf: pesPackets(payload: framed, pts: timestamp))
        pesIndex += 1
        pesPacketsMuxed += 1
        tsPacketsEmitted += packets.count
        return packets
    }

    private func patPacket() -> Data {
        var section = Data([0x00, 0xb0, 0x0d, 0x00, 0x01, 0xc1, 0x00, 0x00, 0x00, 0x01])
        section.append(0xe0 | UInt8((PhoneRelayTS.pmtPID >> 8) & 0x1f))
        section.append(UInt8(PhoneRelayTS.pmtPID & 0xff))
        appendUInt32BE(PhoneRelayTS.crc32MPEG(section), to: &section)
        return psiPacket(pid: 0, continuity: &patContinuity, section: section)
    }

    private func pmtPacket() -> Data {
        var section = Data([0x02, 0xb0, 0x12, 0x00, 0x01, 0xc1, 0x00, 0x00])
        section.append(0xe0 | UInt8((PhoneRelayTS.audioPID >> 8) & 0x1f))
        section.append(UInt8(PhoneRelayTS.audioPID & 0xff))
        section.append(contentsOf: [0xf0, 0x00])
        section.append(0x0f)
        section.append(0xe0 | UInt8((PhoneRelayTS.audioPID >> 8) & 0x1f))
        section.append(UInt8(PhoneRelayTS.audioPID & 0xff))
        section.append(contentsOf: [0xf0, 0x00])
        appendUInt32BE(PhoneRelayTS.crc32MPEG(section), to: &section)
        return psiPacket(pid: PhoneRelayTS.pmtPID, continuity: &pmtContinuity, section: section)
    }

    private func psiPacket(pid: UInt16, continuity: inout UInt8, section: Data) -> Data {
        var packet = Data([PhoneRelayTS.syncByte, 0x40 | UInt8((pid >> 8) & 0x1f), UInt8(pid & 0xff)])
        packet.append(0x10 | (continuity & 0x0f))
        continuity &+= 1
        packet.append(0x00)
        packet.append(section)
        packet.append(contentsOf: repeatElement(0xff, count: PhoneRelayTS.packetSize - packet.count))
        return packet
    }

    private func pesPackets(payload: Data, pts: UInt64) -> [Data] {
        var pes = Data([0x00, 0x00, 0x01, 0xc0])
        let pesLength = payload.count + 8
        appendUInt16BE(pesLength > 0xffff ? 0 : UInt16(pesLength), to: &pes)
        pes.append(contentsOf: [0x80, 0x80, 0x05])
        pes.append(contentsOf: Self.encodePTS(pts))
        pes.append(payload)

        var packets: [Data] = []
        var offset = 0
        var isFirst = true
        while offset < pes.count {
            let remaining = pes.count - offset
            var packet = Data(capacity: PhoneRelayTS.packetSize)
            packet.append(PhoneRelayTS.syncByte)
            let pusi: UInt8 = isFirst ? 0x40 : 0x00
            packet.append(pusi | UInt8((PhoneRelayTS.audioPID >> 8) & 0x1f))
            packet.append(UInt8(PhoneRelayTS.audioPID & 0xff))
            if isFirst {
                packet.append(0x30 | (audioContinuity & 0x0f))
                audioContinuity &+= 1
                let payloadCapacity = PhoneRelayTS.packetSize - 4 - 8
                let chunk = min(remaining, payloadCapacity)
                let adaptationLength = PhoneRelayTS.packetSize - 4 - 1 - chunk
                packet.append(UInt8(adaptationLength))
                packet.append(0x10)
                Self.appendPCR(to: &packet, base: pts)
                if adaptationLength > 7 {
                    packet.append(contentsOf: repeatElement(0xff, count: adaptationLength - 7))
                }
                packet.append(pes[offset..<(offset + chunk)])
                offset += chunk
            } else if remaining <= PhoneRelayTS.packetSize - 4 {
                if remaining == PhoneRelayTS.packetSize - 4 {
                    packet.append(0x10 | (audioContinuity & 0x0f))
                } else {
                    packet.append(0x30 | (audioContinuity & 0x0f))
                    let adaptationLength = PhoneRelayTS.packetSize - 4 - 1 - remaining
                    packet.append(UInt8(adaptationLength))
                    if adaptationLength > 0 {
                        packet.append(0x00)
                        if adaptationLength > 1 {
                            packet.append(contentsOf: repeatElement(0xff, count: adaptationLength - 1))
                        }
                    }
                }
                audioContinuity &+= 1
                packet.append(pes[offset..<pes.count])
                offset = pes.count
            } else {
                packet.append(0x10 | (audioContinuity & 0x0f))
                audioContinuity &+= 1
                packet.append(pes[offset..<(offset + PhoneRelayTS.packetSize - 4)])
                offset += PhoneRelayTS.packetSize - 4
            }
            packets.append(packet)
            isFirst = false
        }
        return packets
    }

    static func encodePTS(_ value: UInt64) -> [UInt8] {
        let pts = value & 0x1_ffff_ffff
        return [
            0x20 | UInt8(((pts >> 30) & 0x07) << 1) | 0x01,
            UInt8((pts >> 22) & 0xff),
            UInt8(((pts >> 15) & 0x7f) << 1) | 0x01,
            UInt8((pts >> 7) & 0xff),
            UInt8((pts & 0x7f) << 1) | 0x01
        ]
    }

    static func appendPCR(to packet: inout Data, base: UInt64) {
        let pcrBase = base & 0x1_ffff_ffff
        packet.append(UInt8((pcrBase >> 25) & 0xff))
        packet.append(UInt8((pcrBase >> 17) & 0xff))
        packet.append(UInt8((pcrBase >> 9) & 0xff))
        packet.append(UInt8((pcrBase >> 1) & 0xff))
        packet.append(UInt8(((pcrBase & 1) << 7) | 0x7e))
        packet.append(0x00)
    }
}

public final class PhoneRelayRTPPacketizer {
    public let ssrc: UInt32
    public var packetsPerRTPPacket = PhoneRelayTS.packetsPerRTPPacket
    public private(set) var packetsSent = 0
    public private(set) var bufferedTSPacketCount = 0

    private var buffer: [Data] = []
    private var sequenceNumber: UInt16 = 0
    private var timestamp: UInt32

    public init(ssrc: UInt32 = PhoneRelayTS.uplinkSSRC, timestamp: UInt32 = .random(in: 0..<UInt32.max)) {
        self.ssrc = ssrc
        self.timestamp = timestamp
    }

    public func appendTSPackets(_ packets: [Data]) -> [Data] {
        buffer.append(contentsOf: packets)
        bufferedTSPacketCount = buffer.count
        var output: [Data] = []
        while buffer.count >= packetsPerRTPPacket {
            output.append(makeRTPPacket(Array(buffer.prefix(packetsPerRTPPacket))))
            buffer.removeFirst(packetsPerRTPPacket)
        }
        bufferedTSPacketCount = buffer.count
        return output
    }

    public func flush() -> Data? {
        guard !buffer.isEmpty else {
            return nil
        }
        let packet = makeRTPPacket(buffer)
        buffer.removeAll(keepingCapacity: true)
        bufferedTSPacketCount = 0
        return packet
    }

    private func makeRTPPacket(_ tsPackets: [Data]) -> Data {
        var packet = Data(capacity: 12 + tsPackets.count * PhoneRelayTS.packetSize)
        packet.append(0x80)
        packet.append(0x80 | PhoneRelayTS.rtpPayloadType)
        appendUInt16BE(sequenceNumber, to: &packet)
        appendUInt32BE(timestamp, to: &packet)
        appendUInt32BE(ssrc, to: &packet)
        for tsPacket in tsPackets {
            packet.append(tsPacket)
        }
        sequenceNumber &+= 1
        timestamp &+= 1_800
        packetsSent += 1
        return packet
    }
}

public struct PhoneRelayTSDemuxer {
    public private(set) var pesPacketCount = 0

    public init() {}

    public static func rtpPayloadOffset(in packet: Data) -> Int? {
        let bytes = Array(packet.prefix(16))
        guard bytes.count >= 12, bytes[0] >> 6 == 2, bytes[1] < 192 else {
            return nil
        }
        let csrcCount = Int(bytes[0] & 0x0f)
        var offset = 12 + (csrcCount * 4)
        guard packet.count >= offset else {
            return nil
        }
        if (bytes[0] & 0x10) != 0 {
            guard packet.count >= offset + 4 else {
                return nil
            }
            let extensionHeader = Array(packet.dropFirst(offset).prefix(4))
            let extensionWordCount = (Int(extensionHeader[2]) << 8) | Int(extensionHeader[3])
            offset += 4 + (extensionWordCount * 4)
            guard packet.count >= offset else {
                return nil
            }
        }
        return offset
    }

    public mutating func extractAudioPayload(fromTSPayload payload: Data, pid: UInt16 = PhoneRelayTS.audioPID) -> Data {
        let bytes = Array(payload)
        var output = Data()
        var offset = 0
        while offset + PhoneRelayTS.packetSize <= bytes.count {
            guard bytes[offset] == PhoneRelayTS.syncByte else {
                offset += 1
                continue
            }
            let packetStart = offset
            let packetEnd = offset + PhoneRelayTS.packetSize
            let payloadUnitStart = (bytes[packetStart + 1] & 0x40) != 0
            let packetPID = (UInt16(bytes[packetStart + 1] & 0x1f) << 8) | UInt16(bytes[packetStart + 2])
            let adaptationFieldControl = (bytes[packetStart + 3] >> 4) & 0x03
            var payloadStart = packetStart + 4

            if adaptationFieldControl == 2 || adaptationFieldControl == 3 {
                guard payloadStart < packetEnd else {
                    offset = packetEnd
                    continue
                }
                payloadStart += 1 + Int(bytes[payloadStart])
            }
            guard adaptationFieldControl == 1 || adaptationFieldControl == 3,
                  packetPID == pid,
                  payloadStart < packetEnd else {
                offset = packetEnd
                continue
            }

            if payloadUnitStart,
               payloadStart + 9 <= packetEnd,
               bytes[payloadStart] == 0x00,
               bytes[payloadStart + 1] == 0x00,
               bytes[payloadStart + 2] == 0x01 {
                let headerLength = Int(bytes[payloadStart + 8])
                let payloadOffset = payloadStart + 9 + headerLength
                if payloadOffset < packetEnd {
                    output.append(contentsOf: bytes[payloadOffset..<packetEnd])
                    pesPacketCount += 1
                }
            } else {
                output.append(contentsOf: bytes[payloadStart..<packetEnd])
            }
            offset = packetEnd
        }
        return output
    }
}

public final class PhoneRelayAACEncoder {
    public static let framesPerAccessUnit = 1_024
    public private(set) var accessUnitsEncoded: UInt64 = 0

    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private var pendingPCM = Data()

    public init?(sampleRate: Double = 48_000, bitRate: Int = 64_000) {
        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ), let outputFormat = AVAudioFormat(settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitRate
        ]), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            return nil
        }
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.converter = converter
    }

    public func encode(_ pcm: Data) -> [Data] {
        pendingPCM.append(pcm)
        let bytesPerAccessUnit = Self.framesPerAccessUnit * MemoryLayout<Int16>.size
        var accessUnits: [Data] = []
        while pendingPCM.count >= bytesPerAccessUnit {
            let chunk = Data(pendingPCM.prefix(bytesPerAccessUnit))
            pendingPCM.removeFirst(bytesPerAccessUnit)
            if let accessUnit = convert(chunk) {
                accessUnits.append(accessUnit)
                accessUnitsEncoded += 1
            }
        }
        return accessUnits
    }

    private func convert(_ pcm: Data) -> Data? {
        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: AVAudioFrameCount(Self.framesPerAccessUnit)
        ), let channel = inputBuffer.int16ChannelData?[0] else {
            return nil
        }
        inputBuffer.frameLength = AVAudioFrameCount(Self.framesPerAccessUnit)
        pcm.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return
            }
            memcpy(channel, baseAddress, pcm.count)
        }
        let outputBuffer = AVAudioCompressedBuffer(
            format: outputFormat,
            packetCapacity: 1,
            maximumPacketSize: Self.framesPerAccessUnit
        )
        var didProvideInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            didProvideInput = true
            outStatus.pointee = .haveData
            return inputBuffer
        }
        guard status != AVAudioConverterOutputStatus.error,
              conversionError == nil,
              outputBuffer.packetCount > 0,
              outputBuffer.byteLength > 0 else {
            return nil
        }
        return Data(bytes: outputBuffer.data, count: Int(outputBuffer.byteLength))
    }
}

public enum PhoneRelayPCMStats {
    public static func s16le(_ data: Data) -> (samples: Int, nonzero: Int, maxAbs: Int, averageAbs: Int) {
        var sampleCount = 0
        var nonzero = 0
        var maxAbs = 0
        var absoluteTotal: Int64 = 0
        data.withUnsafeBytes { rawBuffer in
            let samples = rawBuffer.bindMemory(to: Int16.self)
            sampleCount = samples.count
            for sample in samples {
                let absolute = abs(Int(sample))
                if absolute > 0 {
                    nonzero += 1
                }
                maxAbs = max(maxAbs, absolute)
                absoluteTotal += Int64(absolute)
            }
        }
        let averageAbs = sampleCount > 0 ? Int(absoluteTotal / Int64(sampleCount)) : 0
        return (sampleCount, nonzero, maxAbs, averageAbs)
    }
}

private func appendUInt16BE(_ value: UInt16, to data: inout Data) {
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8(value & 0xff))
}

private func appendUInt32BE(_ value: UInt32, to data: inout Data) {
    data.append(UInt8((value >> 24) & 0xff))
    data.append(UInt8((value >> 16) & 0xff))
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8(value & 0xff))
}
