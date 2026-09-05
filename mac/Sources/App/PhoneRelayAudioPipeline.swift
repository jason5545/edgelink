import AVFoundation
import EdgeLinkKit
import Foundation

// Phone-call relay audio: DOWNLINK only (phone → Mac speaker). The Mac mic
// uplink is owned by the mirror-call relay session's
// LyraMirrorCallAudioSource, which speaks the phone sink's only dialect
// (ff02-framed LPCM 8k, AESPART CBC with the event-23 ECDH key) on both
// media routes (LAN-direct RTSP listener; cloud-relay envelopes). The 48kHz
// AAC/PT33 plaintext uplink that used to live here was never audible — the
// phone's MirrorCallService sink refuses to run without the ECDH key (jadx:
// "startAudioSink, mKey is null") — and was removed 2026-09-05.
final class PhoneRelayAudioController {
    enum State: String {
        case idle
        case downlinkOnly
        case degraded
    }

    let downlinkPlayer = PhoneRelayDownlinkPlayer()

    var echoCancellationEnabled = true

    private let queue = DispatchQueue(label: "EdgeLink.PhoneRelayAudioController")
    private var sharedEngine: AVAudioEngine?
    private var downlinkActive = false
    private(set) var state = State.idle

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
}
