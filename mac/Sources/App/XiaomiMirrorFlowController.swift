import EdgeLinkKit
import Foundation

enum XiaomiMirrorMask: Equatable {
    case loading
    case locked
    case unlocking
    case connectFailed
    case permission
    case risk
    case bind
    case binding
}

// Official PC-client mirror flow, extracted for end-to-end testing.
//
// The official client treats the cast channel, the mirror session, and the
// lock state as independent concerns: it sends OPEN_MIRROR_SCREEN as soon as
// the channel is up (even while the phone is locked) and lets duo.screen
// status events drive the lock mask on top. An active screen session is what
// keeps the channel alive, so the unlock auth and its event ride the same
// connection.
@MainActor
final class XiaomiMirrorFlowController {
    enum Stage: Equatable {
        case idle
        case connecting
        case unlocking
        case opening
        case streaming
        case failed
    }

    private(set) var stage: Stage = .idle {
        didSet { emit() }
    }
    private(set) var mask: XiaomiMirrorMask? {
        didSet { emit() }
    }

    let trustManager: MacTrustManager

    var sessionProvider: () -> LyraCastTrustSession? = { nil }
    var sessionFactory: (_ reason: String) -> Void = { _ in }
    var biometricEvaluate: () async throws -> Void = {}
    var openMirrorScreen: (_ session: LyraCastTrustSession) -> Void = { _ in }
    var stopMirrorMedia: () -> Void = {}
    var activateUI: () -> Void = {}
    var hasRemoteVideo: () -> Bool = { false }
    var onChanged: ((_ stage: Stage, _ mask: XiaomiMirrorMask?) -> Void)?
    var onTrustState: ((MacTrustManager.State) -> Void)?
    var log: (String) -> Void = { _ in }

    private var flowGeneration: UInt64 = 0

    init(trustManager: MacTrustManager) {
        self.trustManager = trustManager
        trustManager.onStateChanged = { [weak self] state in
            Task { @MainActor in
                self?.handleTrustState(state)
            }
        }
        trustManager.onUnlockSucceeded = { [weak self] in
            self?.log("xiaomi.mac.trust_unlock_succeeded")
        }
    }

    private func emit() {
        onChanged?(stage, mask)
    }

    // User opened the mirror window.
    func start() {
        flowGeneration &+= 1
        openSent = false
        if stage != .unlocking {
            stage = .connecting
            mask = .loading
        }
        if let existing = sessionProvider(), !existing.isChannelReady {
            // The phone released the cast channel; re-dial just the cast logi
            // conn on the same phys conn, keeping the adopted mitrustservice
            // conn (and any in-flight auth on it) alive.
            existing.redialCastChannel()
        } else if sessionProvider() == nil {
            sessionFactory("mirror_flow")
        }
        if sessionProvider()?.isChannelReady == true {
            openMirrorScreenNow()
            return
        }
        let generation = flowGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline {
                if self.sessionProvider()?.isChannelReady == true { break }
                if self.sessionProvider() == nil {
                    self.sessionFactory("mirror_flow_rebuild")
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            guard generation == self.flowGeneration,
                  self.stage == .connecting || self.stage == .unlocking else {
                return
            }
            if self.sessionProvider()?.isChannelReady == true {
                self.openMirrorScreenNow()
            } else {
                self.stage = .failed
                self.mask = .connectFailed
                self.log("xiaomi.mac.mirror_flow_channel_timeout generation=\(generation)")
            }
        }
    }

    // Session's cast channel (re)negotiated while a flow is waiting.
    func notifyChannelReady() {
        switch stage {
        case .connecting, .unlocking, .failed:
            openMirrorScreenNow()
        default:
            break
        }
    }

    // First decoded video frame arrived.
    func notifyVideoFrame() {
        if stage == .opening || stage == .unlocking {
            stage = .streaming
        }
        if case .ready(let locked) = trustManager.state, locked {
            mask = .locked
        } else if mask == .connectFailed {
            mask = nil
        } else if mask == .loading, case .ready = trustManager.state {
            mask = nil
        }
    }

    // Lock-mask button (解除鎖定): always Touch ID → duo.screen authAction.
    // Status polls are unreliable on this device (it reports both
    // disabledBySetting and success/unlocked while actually locked), so the
    // button never early-returns on a polled "unlocked" state — the 562 on an
    // already-unlocked phone is harmless (instant success).
    func unlockRequested() {
        stage = .unlocking
        mask = .unlocking
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.biometricEvaluate()
            } catch {
                self.log("trust.mac.local_auth_rejected error=\(error.localizedDescription)")
                await MainActor.run {
                    if self.stage == .unlocking {
                        self.stage = .opening
                        self.mask = .locked
                    }
                }
                return
            }
            await MainActor.run {
                self.activateUI()
                self.trustManager.touchIdPreauthorized = true
                if self.sessionProvider()?.isChannelReady == true,
                   case .ready = self.trustManager.state {
                    Task { await self.trustManager.requestUnlock() }
                } else {
                    self.trustManager.autoUnlockOnReady = true
                    if let session = self.sessionProvider() {
                        session.redialCastChannel()
                    } else {
                        self.start()
                    }
                }
            }
        }
    }

    // Connect-failed mask button (重試): the phone tears down its RTSP server
    // ~80s after OPEN, so retry means re-sending OPEN, not just re-dialing
    // RTSP.
    func retryRequested() {
        stopMirrorMedia()
        openSent = false
        if sessionProvider()?.isChannelReady == true {
            openMirrorScreenNow()
        } else {
            start()
        }
    }

    // Bind mask button (開始配對): the phone reported notBound, so kick the
    // official duo.screen bind flow — the phone shows its own verification UI
    // and drives the 595/546 TDIF rebind on the mitrust channel. A successful
    // bind event lands in .ready and the flow auto-resumes (open / unlock).
    func bindRequested() {
        guard trustManager.state == .needsBind else { return }
        trustManager.requestBind()
    }

    // Mirror stopped (window closed / peer stop / disconnect).
    func stop() {
        flowGeneration &+= 1
        openSent = false
        stage = .idle
        mask = nil
    }

    // Channel is up: send OPEN_MIRROR_SCREEN (like the official client does,
    // regardless of lock state) and kick the WFD client; the duo.screen
    // status query runs in parallel and drives the mask. OPEN is sent at
    // most once per flow — a duplicate makes the phone tear down its RTSP
    // server mid-stream (official never re-sends it either).
    private var openSent = false

    private func openMirrorScreenNow() {
        guard !openSent,
              let session = sessionProvider(), session.isChannelReady,
              stage != .opening, stage != .streaming else { return }
        openSent = true
        stage = .opening
        openMirrorScreen(session)
        trustManager.start()
        let generation = flowGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard let self,
                  generation == self.flowGeneration,
                  self.stage == .opening,
                  !self.hasRemoteVideo(),
                  self.mask == .loading || self.mask == nil else {
                return
            }
            self.stage = .failed
            self.mask = .connectFailed
            self.log("xiaomi.mac.mirror_open_timeout generation=\(generation)")
        }
    }

    private func handleTrustState(_ state: MacTrustManager.State) {
        onTrustState?(state)
        guard stage != .idle else { return }
        switch state {
        case .queryingStatus:
            if stage != .unlocking, mask != .locked {
                mask = .loading
            }
        case .authenticating:
            stage = .unlocking
            mask = .unlocking
        case .ready(let locked):
            if locked {
                if stage != .unlocking {
                    mask = .locked
                }
            } else {
                // A placeholder "unlocked" (disabledBySetting / enable=0) must
                // not clear the lock mask on this device — only a confirmed
                // authEvent, a status event with real keyguard info (enable=1),
                // or the Android app's own KeyguardManager report may.
                // Placeholders never reach this branch as unlocked:
                // MacTrustManager retries them instead.
                if mask == .locked, !trustManager.unlockConfirmed,
                   !trustManager.keyguardInfoConfirmed, !trustManager.isExternallyUnlocked {
                    break
                }
                if hasRemoteVideo() {
                    stage = .streaming
                    mask = nil
                } else if stage != .opening {
                    mask = .loading
                    openMirrorScreenNow()
                } else {
                    // Bind just succeeded mid-open: drop the bind/binding mask
                    // and wait for the video that's already on its way.
                    mask = .loading
                }
            }
        case .needsBind:
            mask = .bind
        case .binding:
            mask = .binding
        case .riskBlocked:
            mask = .risk
        case .failed:
            stage = .failed
            mask = .connectFailed
        default:
            break
        }
    }
}
