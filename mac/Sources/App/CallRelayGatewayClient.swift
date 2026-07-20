import EdgeLinkKit
import AVFoundation
import Foundation

struct CallRelayGatewayPlaybackStats: Equatable {
    let rtpPackets: Int
    let tsBytes: Int
    let pcmBytes: Int
    let totalPCMBytes: Int
    let pesPacketCount: Int
    let samples: Int
    let nonzeroSamples: Int
    let maxAbs: Int
    let averageAbs: Int
    let fingerprint: String
    let prefix: String

    var hasValidStream: Bool {
        totalPCMBytes >= 16_000 && nonzeroSamples > 0 && maxAbs >= 256
    }

    var diagnosticSummary: String {
        "rtpPackets=\(rtpPackets) tsBytes=\(tsBytes) pcmBytes=\(pcmBytes) pcmTotal=\(totalPCMBytes) " +
            "pes=\(pesPacketCount) samples=\(samples) nonzero=\(nonzeroSamples) " +
            "maxAbs=\(maxAbs) avgAbs=\(averageAbs) fp=\(fingerprint)"
    }
}

final class CallRelayCloudflareBridge: @unchecked Sendable {
    var onPlaybackStats: ((CallRelayGatewayPlaybackStats) -> Void)?

    private let queue = DispatchQueue(label: "EdgeLink.CallRelayCloudflareBridge")
    private let player = CallRelayMPEGTSPlayer()
    private var activeSessionId: String?
    private var receivedPackets = 0

    func start(sessionId: String) {
        queue.async {
            if self.activeSessionId != sessionId {
                self.player.stop(reason: "replace_session")
                self.receivedPackets = 0
            }
            self.activeSessionId = sessionId
            DiagnosticsLog.info("callrelay.mac.cloudflare_start sessionId=\(sessionId)")
        }
    }

    func handle(_ body: PhoneRelayMediaBody) {
        queue.async {
            guard body.direction == "android_to_mac",
                  body.kind == "rtp",
                  body.sessionId == self.activeSessionId,
                  let dataBase64 = body.dataBase64,
                  let packet = Data(base64Encoded: dataBase64) else {
                return
            }
            self.receivedPackets += 1
            if self.receivedPackets == 1 || self.receivedPackets % 100 == 0 {
                DiagnosticsLog.info(
                    "callrelay.mac.cloudflare_rtp_in sessionId=\(body.sessionId) " +
                        "count=\(self.receivedPackets) bytes=\(packet.count)"
                )
            }
            if let stats = self.player.writeRTPPacket(packet) {
                self.onPlaybackStats?(stats)
            }
        }
    }

    func stop(reason: String) {
        queue.async {
            if let sessionId = self.activeSessionId {
                DiagnosticsLog.info(
                    "callrelay.mac.cloudflare_stop sessionId=\(sessionId) reason=\(reason) " +
                        "packets=\(self.receivedPackets)"
                )
            }
            self.activeSessionId = nil
            self.receivedPackets = 0
            self.player.stop(reason: reason)
        }
    }
}

private final class CallRelayMPEGTSPlayer {
    private var audioEngine: AVAudioEngine?
    private var audioPlayer: AVAudioPlayerNode?
    private var rtpPackets = 0
    private var tsBytes = 0
    private var pcmBytes = 0
    private var pesPacketCount = 0
    private var validStreamReported = false
    private var pcmCaptureHandle: FileHandle?
    private var pcmCaptureBytes = 0
    private let pcmCapturePath = "/private/tmp/edgelink-downlink.pcm"
    private let pcmCaptureLimitBytes = 8 * 1024 * 1024

    private var pcmCaptureEnabled: Bool {
        UserDefaults.standard.object(forKey: "phoneRelayDownlinkPCMCaptureEnabled") as? Bool ?? false
    }

    func writeRTPPacket(_ packet: Data) -> CallRelayGatewayPlaybackStats? {
        guard let payload = rtpPayload(in: packet),
              payload.first == 0x47 else {
            return nil
        }
        rtpPackets += 1
        tsBytes += payload.count
        let pcmPayload = extractPhoneRelayPCM(fromMPEGTS: payload)
        guard !pcmPayload.isEmpty else {
            return nil
        }
        writePCMCapture(pcmPayload)
        if audioEngine?.isRunning != true {
            start()
        }
        guard playPCM(pcmPayload) else {
            return nil
        }
        let previousPCMTotal = pcmBytes
        pcmBytes += pcmPayload.count
        let sampleStats = pcmS16LEStats(pcmPayload)
        let stats = CallRelayGatewayPlaybackStats(
            rtpPackets: rtpPackets,
            tsBytes: tsBytes,
            pcmBytes: pcmPayload.count,
            totalPCMBytes: pcmBytes,
            pesPacketCount: pesPacketCount,
            samples: sampleStats.samples,
            nonzeroSamples: sampleStats.nonzeroSamples,
            maxAbs: sampleStats.maxAbs,
            averageAbs: sampleStats.averageAbs,
            fingerprint: DiagnosticsLog.fingerprint(pcmPayload),
            prefix: hexPrefix(pcmPayload)
        )
        let isFirstValidStream = stats.hasValidStream && !validStreamReported
        if isFirstValidStream {
            validStreamReported = true
            DiagnosticsLog.info("callrelay.mac.cloudflare_pcm_valid \(stats.diagnosticSummary)")
        }
        let shouldLogStats = previousPCMTotal == 0 ||
            pcmBytes % 64_000 < pcmPayload.count ||
            isFirstValidStream
        if shouldLogStats {
            DiagnosticsLog.info(
                "callrelay.mac.cloudflare_pcm_playback_write \(stats.diagnosticSummary) prefix=\(stats.prefix)"
            )
        }
        return stats
    }

    func stop(reason: String) {
        if audioEngine != nil || audioPlayer != nil {
            DiagnosticsLog.info(
                "callrelay.mac.cloudflare_player_stop reason=\(reason) " +
                    "rtpPackets=\(rtpPackets) tsBytes=\(tsBytes) pcmBytes=\(pcmBytes)"
            )
        }
        audioPlayer?.stop()
        audioEngine?.stop()
        audioEngine = nil
        audioPlayer = nil
        rtpPackets = 0
        tsBytes = 0
        pcmBytes = 0
        pesPacketCount = 0
        validStreamReported = false
        stopPCMCapture()
    }

    private func writePCMCapture(_ payload: Data) {
        guard pcmCaptureEnabled, pcmCaptureBytes < pcmCaptureLimitBytes else {
            return
        }
        if pcmCaptureHandle == nil {
            FileManager.default.createFile(atPath: pcmCapturePath, contents: nil)
            pcmCaptureHandle = FileHandle(forWritingAtPath: pcmCapturePath)
            pcmCaptureBytes = 0
        }
        guard let handle = pcmCaptureHandle else {
            return
        }
        let remaining = pcmCaptureLimitBytes - pcmCaptureBytes
        let chunk = payload.count > remaining ? payload.prefix(remaining) : payload
        do {
            try handle.write(contentsOf: chunk)
            pcmCaptureBytes += chunk.count
        } catch {
            stopPCMCapture()
        }
    }

    private func stopPCMCapture() {
        if pcmCaptureHandle != nil {
            DiagnosticsLog.info(
                "callrelay.mac.downlink_pcm_capture_stop path=\(pcmCapturePath) bytes=\(pcmCaptureBytes)"
            )
        }
        try? pcmCaptureHandle?.close()
        pcmCaptureHandle = nil
        pcmCaptureBytes = 0
    }

    private func start() {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        guard let format = Self.pcmFormat else {
            DiagnosticsLog.warn("callrelay.mac.cloudflare_player_unavailable pcm_format")
            return
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        do {
            try engine.start()
            player.volume = 1
            player.play()
            audioEngine = engine
            audioPlayer = player
            DiagnosticsLog.info(
                "callrelay.mac.cloudflare_player_start engine=AVAudioEngine " +
                    "format=s16le sampleRate=8000 channels=1 outputRate=\(engine.outputNode.outputFormat(forBus: 0).sampleRate)"
            )
        } catch {
            DiagnosticsLog.error("callrelay.mac.cloudflare_player_start_failed", error)
        }
    }

    private func playPCM(_ data: Data) -> Bool {
        guard let player = audioPlayer,
              let format = Self.pcmFormat else {
            return false
        }
        let frameCount = data.count / MemoryLayout<Int16>.size
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(frameCount)
              ),
              let channel = buffer.int16ChannelData?[0] else {
            return false
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return
            }
            memcpy(channel, baseAddress, frameCount * MemoryLayout<Int16>.size)
        }
        player.scheduleBuffer(buffer)
        return true
    }

    private func extractPhoneRelayPCM(fromMPEGTS payload: Data) -> Data {
        let bytes = Array(payload)
        var output = Data()
        var offset = 0
        while offset + Self.mpegTSPacketSize <= bytes.count {
            guard bytes[offset] == 0x47 else {
                offset += 1
                continue
            }
            let packetStart = offset
            let packetEnd = offset + Self.mpegTSPacketSize
            let payloadUnitStart = (bytes[packetStart + 1] & 0x40) != 0
            let pid = (UInt16(bytes[packetStart + 1] & 0x1f) << 8) | UInt16(bytes[packetStart + 2])
            let adaptationFieldControl = (bytes[packetStart + 3] >> 4) & 0x03
            var payloadStart = packetStart + 4

            if adaptationFieldControl == 2 || adaptationFieldControl == 3 {
                guard payloadStart < packetEnd else {
                    offset = packetEnd
                    continue
                }
                payloadStart += 1 + Int(bytes[payloadStart])
            }
            guard (adaptationFieldControl == 1 || adaptationFieldControl == 3),
                  pid == Self.phoneRelayAudioTSPID,
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
                let pcmStart = payloadStart + 9 + headerLength
                if pcmStart < packetEnd {
                    output.append(contentsOf: bytes[pcmStart..<packetEnd])
                    pesPacketCount += 1
                }
            } else {
                output.append(contentsOf: bytes[payloadStart..<packetEnd])
            }
            offset = packetEnd
        }
        return output
    }

    private func pcmS16LEStats(_ data: Data) -> (samples: Int, nonzeroSamples: Int, maxAbs: Int, averageAbs: Int) {
        let bytes = Array(data)
        var sampleCount = 0
        var nonzeroSamples = 0
        var maxAbs = 0
        var absTotal = 0
        var index = 0
        while index + 1 < bytes.count {
            let raw = UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
            let sample = Int(Int16(bitPattern: raw))
            let magnitude = abs(sample)
            sampleCount += 1
            if sample != 0 {
                nonzeroSamples += 1
            }
            maxAbs = max(maxAbs, magnitude)
            absTotal += magnitude
            index += 2
        }
        return (
            samples: sampleCount,
            nonzeroSamples: nonzeroSamples,
            maxAbs: maxAbs,
            averageAbs: sampleCount > 0 ? absTotal / sampleCount : 0
        )
    }

    private func hexPrefix(_ data: Data, count: Int = 16) -> String {
        data.prefix(count).map { String(format: "%02x", $0) }.joined()
    }

    private func rtpPayload(in packet: Data) -> Data? {
        guard packet.count >= 12 else {
            return nil
        }
        let bytes = [UInt8](packet.prefix(min(packet.count, 20)))
        guard bytes[0] >> 6 == 2 else {
            return nil
        }
        let hasExtension = (bytes[0] & 0x10) != 0
        let csrcCount = Int(bytes[0] & 0x0F)
        var offset = 12 + csrcCount * 4
        guard packet.count >= offset else {
            return nil
        }
        if hasExtension {
            guard packet.count >= offset + 4 else {
                return nil
            }
            let lengthOffset = packet.index(packet.startIndex, offsetBy: offset + 2)
            let length = (UInt16(packet[lengthOffset]) << 8) | UInt16(packet[packet.index(after: lengthOffset)])
            offset += 4 + Int(length) * 4
            guard packet.count >= offset else {
                return nil
            }
        }
        return Data(packet.dropFirst(offset))
    }

    private static var pcmFormat: AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 8_000,
            channels: 1,
            interleaved: false
        )
    }

    private static let mpegTSPacketSize = 188
    private static let phoneRelayAudioTSPID: UInt16 = 0x1100
}
