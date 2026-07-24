import AVFoundation
import EdgeLinkKit
import Foundation

final class PhoneRelayAudioController {
    enum State: String {
        case idle
        case downlinkOnly
        case active
        case degraded
    }

    let downlinkPlayer = PhoneRelayDownlinkPlayer()

    var echoCancellationEnabled = true

    private let queue = DispatchQueue(label: "EdgeLink.PhoneRelayAudioController")
    private var sharedEngine: AVAudioEngine?
    private var uplinkEngine: AVAudioEngine?
    private var uplinkConverter: AVAudioConverter?
    private var uplinkConverterInputFormat: AVAudioFormat?
    private var aacEncoder: PhoneRelayAACEncoder?
    private var tsMuxer: PhoneRelayTSMuxer?
    private var rtpPacketizer: PhoneRelayRTPPacketizer?
    private var uplinkPacketHandler: ((Data) -> Void)?
    private var uplinkFlushTimer: DispatchSourceTimer?
    private var uplinkMuted = false
    private var pcmFramesCaptured: UInt64 = 0
    private var uplinkPacketsEmitted = 0
    private var downlinkActive = false
    private(set) var state = State.idle

    var isUplinkActive: Bool {
        uplinkPacketHandler != nil
    }

    func startDownlink() {
        queue.async {
            guard self.state == .idle else {
                return
            }
            if self.echoCancellationEnabled {
                guard let engine = self.startSharedEngine() else {
                    self.state = .degraded
                    return
                }
                self.downlinkPlayer.attachToSharedEngine(engine)
            }
            self.downlinkActive = true
            self.state = .downlinkOnly
            DiagnosticsLog.info(
                "phonerelay.mac.audio_downlink_start aec=\(self.echoCancellationEnabled)"
            )
        }
    }

    func stopDownlink(reason: String) {
        queue.async {
            self.stopUplinkOnQueue(reason: "downlink_stop_\(reason)")
            self.downlinkPlayer.detachSharedEngine()
            self.downlinkPlayer.stop(reason: reason)
            self.stopSharedEngine(reason: reason)
            if self.state != .idle {
                DiagnosticsLog.info("phonerelay.mac.audio_downlink_stop reason=\(reason)")
            }
            self.downlinkActive = false
            self.state = .idle
        }
    }

    func startUplink(packetHandler: @escaping (Data) -> Void) {
        queue.async {
            guard !self.isUplinkActive else {
                return
            }
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                self.startUplinkOnQueue(packetHandler: packetHandler, reason: "authorized")
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                    guard let self else {
                        return
                    }
                    DiagnosticsLog.info("phonerelay.mac.audio_uplink_permission granted=\(granted)")
                    self.queue.async {
                        guard granted, !self.isUplinkActive, self.state != .idle else {
                            return
                        }
                        self.startUplinkOnQueue(packetHandler: packetHandler, reason: "permission_granted")
                    }
                }
                DiagnosticsLog.info("phonerelay.mac.audio_uplink_permission_pending")
            case .denied, .restricted:
                DiagnosticsLog.warn("phonerelay.mac.audio_uplink_permission_denied")
                self.state = .degraded
            @unknown default:
                DiagnosticsLog.warn("phonerelay.mac.audio_uplink_permission_unknown")
                self.state = .degraded
            }
        }
    }

    func stopUplink(reason: String) {
        queue.async {
            self.stopUplinkOnQueue(reason: reason)
        }
    }

    func setUplinkMuted(_ muted: Bool) {
        queue.async {
            if self.uplinkMuted != muted {
                self.uplinkMuted = muted
                DiagnosticsLog.info("phonerelay.mac.audio_uplink_muted muted=\(muted)")
            }
        }
    }

    private func startUplinkOnQueue(packetHandler: @escaping (Data) -> Void, reason: String) {
        guard let encoder = PhoneRelayAACEncoder() else {
            DiagnosticsLog.warn("phonerelay.mac.audio_uplink_encoder_unavailable reason=\(reason)")
            state = .degraded
            return
        }
        let engine: AVAudioEngine
        if echoCancellationEnabled {
            guard let shared = sharedEngine ?? startSharedEngine() else {
                state = .degraded
                return
            }
            engine = shared
        } else {
            let uplinkEngine = AVAudioEngine()
            self.uplinkEngine = uplinkEngine
            engine = uplinkEngine
        }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0,
              let monoFormat = Self.uplinkPCMFormat,
              let converter = AVAudioConverter(from: inputFormat, to: monoFormat) else {
            DiagnosticsLog.warn(
                "phonerelay.mac.audio_uplink_format_unavailable " +
                    "inputRate=\(inputFormat.sampleRate) inputChannels=\(inputFormat.channelCount)"
            )
            state = .degraded
            return
        }

        aacEncoder = encoder
        tsMuxer = PhoneRelayTSMuxer()
        rtpPacketizer = PhoneRelayRTPPacketizer()
        uplinkConverter = converter
        uplinkConverterInputFormat = inputFormat
        uplinkPacketHandler = packetHandler
        pcmFramesCaptured = 0
        uplinkPacketsEmitted = 0

        inputNode.installTap(onBus: 0, bufferSize: Self.uplinkFramesPerBuffer, format: inputFormat) { [weak self] buffer, _ in
            guard let self else {
                return
            }
            self.queue.async {
                self.handleUplinkBuffer(buffer)
            }
        }

        do {
            if !engine.isRunning {
                try engine.start()
            }
            startUplinkFlushTimer()
            state = .active
            DiagnosticsLog.info(
                "phonerelay.mac.audio_uplink_start reason=\(reason) aec=\(echoCancellationEnabled) " +
                    "inputRate=\(inputFormat.sampleRate) inputChannels=\(inputFormat.channelCount) " +
                    "muted=\(uplinkMuted)"
            )
        } catch {
            inputNode.removeTap(onBus: 0)
            uplinkPacketHandler = nil
            DiagnosticsLog.error("phonerelay.mac.audio_uplink_start_failed", error)
            state = .degraded
        }
    }

    private func handleUplinkBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let handler = uplinkPacketHandler,
              let converter = uplinkConverter,
              let monoFormat = Self.uplinkPCMFormat,
              let muxer = tsMuxer,
              let packetizer = rtpPacketizer,
              let encoder = aacEncoder else {
            return
        }
        guard var pcm = Self.convertToMonoPCM(buffer, converter: converter, outputFormat: monoFormat),
              !pcm.isEmpty else {
            return
        }
        pcmFramesCaptured += UInt64(buffer.frameLength)
        if uplinkMuted {
            pcm.replaceSubrange(pcm.startIndex..<pcm.endIndex, with: repeatElement(0, count: pcm.count))
        }
        let accessUnits = encoder.encode(pcm)
        guard !accessUnits.isEmpty else {
            return
        }
        var rtpPackets: [Data] = []
        let firstOrdinal = encoder.accessUnitsEncoded - UInt64(accessUnits.count)
        for (index, accessUnit) in accessUnits.enumerated() {
            let pts = (firstOrdinal + UInt64(index)) * UInt64(PhoneRelayAACEncoder.framesPerAccessUnit) * 90_000 / 48_000
            rtpPackets.append(contentsOf: packetizer.appendTSPackets(muxer.appendAACAccessUnit(accessUnit, pts: pts)))
        }
        for packet in rtpPackets {
            uplinkPacketsEmitted += 1
            handler(packet)
        }
        if uplinkPacketsEmitted > 0, uplinkPacketsEmitted % 250 < rtpPackets.count {
            DiagnosticsLog.info(
                "phonerelay.mac.audio_uplink_progress packets=\(uplinkPacketsEmitted) " +
                    "accessUnits=\(encoder.accessUnitsEncoded) pes=\(muxer.pesPacketsMuxed)"
            )
        }
    }

    private func startUplinkFlushTimer() {
        uplinkFlushTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(Self.uplinkFlushIntervalMilliseconds), repeating: .milliseconds(Self.uplinkFlushIntervalMilliseconds))
        timer.setEventHandler { [weak self] in
            guard let self,
                  let packet = self.rtpPacketizer?.flush(),
                  let handler = self.uplinkPacketHandler else {
                return
            }
            self.uplinkPacketsEmitted += 1
            handler(packet)
        }
        uplinkFlushTimer = timer
        timer.resume()
    }

    private func stopUplinkOnQueue(reason: String) {
        let wasActive = isUplinkActive
        uplinkFlushTimer?.cancel()
        uplinkFlushTimer = nil
        if let packet = rtpPacketizer?.flush(), let handler = uplinkPacketHandler {
            handler(packet)
        }
        if let engine = uplinkEngine ?? sharedEngine {
            engine.inputNode.removeTap(onBus: 0)
        }
        if let uplinkEngine {
            uplinkEngine.stop()
            self.uplinkEngine = nil
        }
        uplinkConverter = nil
        uplinkConverterInputFormat = nil
        aacEncoder = nil
        tsMuxer = nil
        rtpPacketizer = nil
        uplinkPacketHandler = nil
        if wasActive {
            DiagnosticsLog.info(
                "phonerelay.mac.audio_uplink_stop reason=\(reason) packets=\(uplinkPacketsEmitted)"
            )
            if state == .active {
                state = downlinkActive ? .downlinkOnly : .idle
            }
        }
    }

    private func startSharedEngine() -> AVAudioEngine? {
        if let sharedEngine {
            return sharedEngine
        }
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        do {
            try inputNode.setVoiceProcessingEnabled(true)
            if #available(macOS 14.0, *) {
                inputNode.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                        enableAdvancedDucking: true,
                        duckingLevel: .min
                    )
            }
        } catch {
            DiagnosticsLog.error("phonerelay.mac.audio_voice_processing_failed", error)
            return nil
        }
        sharedEngine = engine
        DiagnosticsLog.info("phonerelay.mac.audio_shared_engine_created voiceProcessing=true")
        return engine
    }

    private func stopSharedEngine(reason: String) {
        guard let sharedEngine else {
            return
        }
        sharedEngine.stop()
        self.sharedEngine = nil
        DiagnosticsLog.info("phonerelay.mac.audio_shared_engine_stopped reason=\(reason)")
    }

    private static func convertToMonoPCM(
        _ buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        outputFormat: AVAudioFormat
    ) -> Data? {
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let frameCapacity = max(1, AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCapacity) else {
            return nil
        }
        var didProvideInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            didProvideInput = true
            outStatus.pointee = .haveData
            return buffer
        }
        if let conversionError {
            DiagnosticsLog.warn("phonerelay.mac.audio_uplink_convert_failed error=\(conversionError)")
            return nil
        }
        guard status != .error,
              outputBuffer.frameLength > 0,
              let channelData = outputBuffer.int16ChannelData else {
            return nil
        }
        let byteCount = Int(outputBuffer.frameLength) * Int(outputFormat.channelCount) * MemoryLayout<Int16>.size
        return Data(bytes: channelData[0], count: byteCount)
    }

    private static var uplinkPCMFormat: AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        )
    }

    private static let uplinkFramesPerBuffer: AVAudioFrameCount = 960
    private static let uplinkFlushIntervalMilliseconds = 40
}
