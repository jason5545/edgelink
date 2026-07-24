import AVFoundation
import EdgeLinkKit
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

final class PhoneRelayDownlinkPlayer {
    private let stateLock = NSLock()
    private var standaloneEngine: AVAudioEngine?
    private var sharedEngine: AVAudioEngine?
    private var audioPlayer: AVAudioPlayerNode?
    private var playerEngine: AVAudioEngine?
    private var stoppedPlayer: AVAudioPlayerNode?
    private var demuxer = PhoneRelayTSDemuxer()
    private var rtpPackets = 0
    private var tsBytes = 0
    private var pcmBytes = 0
    private var validStreamReported = false
    private var pcmCaptureHandle: FileHandle?
    private var pcmCaptureBytes = 0
    private let pcmCapturePath = "/private/tmp/edgelink-downlink.pcm"
    private let pcmCaptureLimitBytes = 8 * 1024 * 1024

    private var pcmCaptureEnabled: Bool {
        UserDefaults.standard.object(forKey: "phoneRelayDownlinkPCMCaptureEnabled") as? Bool ?? false
    }

    func attachToSharedEngine(_ engine: AVAudioEngine) {
        stateLock.lock()
        defer { stateLock.unlock() }
        if sharedEngine === engine, audioPlayer != nil {
            return
        }
        stopPlayerNodeLocked()
        sharedEngine = engine
        DiagnosticsLog.info("callrelay.mac.downlink_player_shared_engine")
    }

    func detachSharedEngine() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard sharedEngine != nil else {
            return
        }
        stopPlayerNodeLocked()
        sharedEngine = nil
        DiagnosticsLog.info("callrelay.mac.downlink_player_standalone_engine")
    }

    func writeRTPPacket(_ packet: Data) -> CallRelayGatewayPlaybackStats? {
        guard let payloadOffset = PhoneRelayTSDemuxer.rtpPayloadOffset(in: packet),
              payloadOffset < packet.count else {
            return nil
        }
        let payload = Data(packet.dropFirst(payloadOffset))
        guard payload.first == PhoneRelayTS.syncByte else {
            return nil
        }
        rtpPackets += 1
        tsBytes += payload.count
        let pcmPayload = demuxer.extractAudioPayload(fromTSPayload: payload)
        guard !pcmPayload.isEmpty else {
            return nil
        }
        writePCMCapture(pcmPayload)
        stateLock.lock()
        if audioPlayer == nil {
            startLocked()
        }
        let played = playPCM(pcmPayload)
        stateLock.unlock()
        guard played else {
            return nil
        }
        let previousPCMTotal = pcmBytes
        pcmBytes += pcmPayload.count
        let sampleStats = PhoneRelayPCMStats.s16le(pcmPayload)
        let stats = CallRelayGatewayPlaybackStats(
            rtpPackets: rtpPackets,
            tsBytes: tsBytes,
            pcmBytes: pcmPayload.count,
            totalPCMBytes: pcmBytes,
            pesPacketCount: demuxer.pesPacketCount,
            samples: sampleStats.samples,
            nonzeroSamples: sampleStats.nonzero,
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
        stateLock.lock()
        if standaloneEngine != nil || sharedEngine != nil || audioPlayer != nil {
            DiagnosticsLog.info(
                "callrelay.mac.cloudflare_player_stop reason=\(reason) " +
                    "rtpPackets=\(rtpPackets) tsBytes=\(tsBytes) pcmBytes=\(pcmBytes)"
            )
        }
        stopPlayerNodeLocked()
        try? standaloneEngine?.stop()
        standaloneEngine = nil
        demuxer = PhoneRelayTSDemuxer()
        rtpPackets = 0
        tsBytes = 0
        pcmBytes = 0
        validStreamReported = false
        stateLock.unlock()
        stopPCMCapture()
    }

    private func stopPlayerNodeLocked() {
        guard let player = audioPlayer else {
            return
        }
        player.stop()
        // Never call engine.detach here: the shared engine can be stopped
        // concurrently on PhoneRelayAudioController's queue, which tears
        // down the render graph and makes detachNode: throw an uncatchable
        // NSException. Keep the stopped node attached (cached for reuse if
        // the same engine survives) and let engine dealloc clean it up.
        stoppedPlayer = player
        audioPlayer = nil
        playerEngine = nil
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

    private func startLocked() {
        guard let format = Self.pcmFormat else {
            DiagnosticsLog.warn("callrelay.mac.cloudflare_player_unavailable pcm_format")
            return
        }
        if let sharedEngine {
            let player: AVAudioPlayerNode
            if let cached = stoppedPlayer, cached.engine === sharedEngine {
                player = cached
                stoppedPlayer = nil
            } else {
                player = AVAudioPlayerNode()
                sharedEngine.attach(player)
                sharedEngine.connect(player, to: sharedEngine.mainMixerNode, format: format)
            }
            if !sharedEngine.isRunning {
                do {
                    try sharedEngine.start()
                } catch {
                    DiagnosticsLog.error("callrelay.mac.cloudflare_player_start_failed", error)
                    return
                }
            }
            player.volume = 1
            player.play()
            audioPlayer = player
            playerEngine = sharedEngine
            DiagnosticsLog.info(
                "callrelay.mac.cloudflare_player_start engine=shared " +
                    "format=s16le sampleRate=8000 channels=1 outputRate=\(sharedEngine.outputNode.outputFormat(forBus: 0).sampleRate)"
            )
            return
        }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        do {
            try engine.start()
            player.volume = 1
            player.play()
            standaloneEngine = engine
            audioPlayer = player
            playerEngine = engine
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

    private func hexPrefix(_ data: Data, count: Int = 16) -> String {
        data.prefix(count).map { String(format: "%02x", $0) }.joined()
    }

    private static var pcmFormat: AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 8_000,
            channels: 1,
            interleaved: false
        )
    }
}
