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
    // Drops the current session synchronously (wedged-dial recovery): the
    // next beginStart then builds a fresh session — fresh phys handshake,
    // and on the relay path a fresh mesh flow index.
    var sessionInvalidator: () -> Void = {}
    var biometricEvaluate: () async throws -> Void = {}
    var openMirrorScreen: (_ session: LyraCastTrustSession) -> Void = { _ in }
    var stopMirrorMedia: () -> Void = {}
    var activateUI: () -> Void = {}
    var hasRemoteVideo: () -> Bool = { false }
    // Any parsed mirror media (video OR audio) has arrived. The official
    // encoder emits zero video frames on a static phone screen while audio
    // keeps flowing, so "media present, no video" is a HEALTHY mirror, not
    // a failed OPEN.
    var hasRemoteMedia: () -> Bool = { false }
    var onChanged: ((_ stage: Stage, _ mask: XiaomiMirrorMask?) -> Void)?
    var onTrustState: ((MacTrustManager.State) -> Void)?
    var log: (String) -> Void = { _ in }

    private var flowGeneration: UInt64 = 0

    // After a user stop (CLOSE_SCREEN) the phone unwinds its mirror
    // lifecycle asynchronously; a re-OPEN that lands mid-teardown gets the
    // channel killed (live 2026-08-03: logi disconnect 52011 right after
    // OPEN) and starts a kill/re-open storm. start() waits out this settle
    // window after stop() before re-OPENing.
    var userStopSettle: TimeInterval = 1.5
    private var lastStopAt: Date = .distantPast

    // Storm guard: a channel release that arrives right after our OPEN is a
    // reaction to the OPEN (phone mid-teardown or trust re-check), so an
    // immediate redial + re-OPEN just re-triggers it. Rapid releases get a
    // linear backoff, and past the budget the flow gives up to the
    // retryable connect-failed mask instead of looping 正在連接 forever.
    var channelReleaseBackoff: TimeInterval = 1
    var channelReleaseMaxRapidRetries = 3
    private static let channelReleaseRapidWindow: TimeInterval = 20
    private var rapidChannelReleases = 0
    private var lastChannelReleaseAt: Date = .distantPast

    // Relay-path OPEN hardening (live 2026-08-08): the phone creates its
    // channel object asynchronously after confirm (observed binder stall of
    // 761ms), and its native stack DROPS channel data that arrives before
    // creation ("ChannelNotCreatedYet"). The OPEN_MIRROR_SCREEN sent right
    // on channel-ready was lost that way — no open, no WFD source, and the
    // phone bridge looped on ECONNREFUSED :7236 forever. Mitigations: a
    // short grace delay before the first OPEN on relay, and a single
    // guarded resend when the open timeout expires with zero video.
    var relayOpenGrace: TimeInterval = 0.6
    var openTimeout: TimeInterval = 20
    private var openResendAttempted = false

    // Fresh-dial stall (live 2026-08-11): a dial that lands in phone-side
    // transport churn (screen-off keepalive suppression tearing the
    // relay-fed phys conns, relay reconnect) wedges — the phone answers the
    // phys sync but the logi-layer exchange never advances. The channel wait
    // then failed straight to 連接失敗 and only a manual 重試 (fresh
    // session, fresh flow index) recovered. Retry automatically before
    // surfacing the failure.
    var channelReadyTimeout: TimeInterval = 15
    var channelTimeoutMaxAutoRetries = 1
    private var channelTimeoutRetries = 0

    // Stale re-lock (live 2026-08-13 07:45): the user ran the Touch ID
    // unlock BEFORE the mirror was streaming; the phone unlocked, then its
    // screen timeout re-armed the keyguard in the unlock→streaming gap, so
    // the mirror opened onto a locked status resolution and parked on the
    // lock mask ("Touch ID 過了但畫面還是鎖的"). When the lock reporter
    // confirmed that unlock took effect and the locked resolution arrives
    // within staleRelockGrace of it, treat the lock as a stale re-lock and
    // re-run the unlock auth (one extra Touch ID prompt) instead of
    // parking. Each unlock_success buys at most one automatic re-auth, so
    // a phone that keeps timing out cannot loop prompts.
    var staleRelockGrace: TimeInterval = 60
    private var staleRelockRetriedAfter: Date?

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
        channelTimeoutRetries = 0
        if stage != .unlocking {
            stage = .connecting
            mask = .loading
        }
        let settleRemaining = userStopSettle - Date().timeIntervalSince(lastStopAt)
        if settleRemaining > 0 {
            let generation = flowGeneration
            log("xiaomi.mac.mirror_flow_start_settle settleMs=\(Int(settleRemaining * 1000)) generation=\(generation)")
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(settleRemaining * 1_000_000_000))
                guard let self, generation == self.flowGeneration else { return }
                self.beginStart()
            }
            return
        }
        beginStart()
    }

    private func beginStart() {
        if let existing = sessionProvider(), !existing.isChannelReady,
           existing.channelWasEstablishedBefore
        {
            // The phone released the cast channel; re-dial just the cast logi
            // conn on the same phys conn, keeping the adopted mitrustservice
            // conn (and any in-flight auth on it) alive. A fresh mid-dial
            // session (never established) is left alone — redialing it
            // aborts the in-flight negotiation.
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
            let deadline = Date().addingTimeInterval(self.channelReadyTimeout)
            while Date() < deadline {
                // A stopped/superseded flow must not keep rebuilding
                // sessions in the background (post-reboot recovery, test
                // teardown, or a user stop would leak ghost sessions that
                // steal the phone's negotiation from the next flow).
                if generation != self.flowGeneration { return }
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
            } else if self.channelTimeoutRetries < self.channelTimeoutMaxAutoRetries {
                self.channelTimeoutRetries += 1
                self.log(
                    "xiaomi.mac.mirror_flow_channel_retry attempt=\(self.channelTimeoutRetries) " +
                        "generation=\(generation)"
                )
                self.sessionInvalidator()
                self.beginStart()
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
        case .opening where !openSent:
            // A pending OPEN resend was waiting on the channel.
            openMirrorScreenNow()
        default:
            break
        }
    }

    // Phone released the cast channel mid-stream (reboot / sdk release):
    // the mirror is dead regardless of what the video watchdog thinks, so
    // restart the whole flow — redial the channel, then re-OPEN the mirror
    // screen once notifyChannelReady fires. Rapid-fire releases (the phone
    // killing the channel in reaction to each re-OPEN) back off linearly
    // and eventually give up to the retryable connect-failed mask.
    func notifyChannelReleased() {
        switch stage {
        case .opening, .streaming, .unlocking:
            // .unlocking included: the 562/mitrust ceremony rides the cast
            // channel, so losing it mid-auth must rebuild the channel too —
            // the phone re-drives the pending ceremony on the rebuilt one
            // (the trust manager keeps the auth wait alive across the
            // rebuild; live 2026-08-13 relay flap).
            stopMirrorMedia()
            openSent = false
            let now = Date()
            if now.timeIntervalSince(lastChannelReleaseAt) < Self.channelReleaseRapidWindow {
                rapidChannelReleases += 1
            } else {
                rapidChannelReleases = 1
            }
            lastChannelReleaseAt = now
            guard rapidChannelReleases <= channelReleaseMaxRapidRetries else {
                stage = .failed
                mask = .connectFailed
                log("xiaomi.mac.mirror_flow_release_storm releases=\(rapidChannelReleases)")
                return
            }
            mask = .loading
            let backoff = channelReleaseBackoff * TimeInterval(rapidChannelReleases - 1)
            guard backoff > 0 else {
                start()
                return
            }
            let generation = flowGeneration
            log("xiaomi.mac.mirror_flow_release_backoff releases=\(rapidChannelReleases) backoffMs=\(Int(backoff * 1000))")
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                guard let self, generation == self.flowGeneration else { return }
                self.start()
            }
        default:
            break
        }
    }

    // First decoded video frame arrived.
    func notifyVideoFrame() {
        if stage == .opening || stage == .unlocking {
            stage = .streaming
        }
        if stage == .streaming {
            rapidChannelReleases = 0
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
    // RTSP. The reopen is forced: stale media from the pre-retry session can
    // leave stage == .streaming, but the phone's server is gone (teardown on
    // risk refusal / OPEN expiry), so the pipeline must be re-OPENed anyway.
    func retryRequested() {
        stopMirrorMedia()
        openSent = false
        if sessionProvider()?.isChannelReady == true {
            openMirrorScreenNow(force: true)
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
        openResendAttempted = false
        lastStopAt = Date()
        rapidChannelReleases = 0
        stage = .idle
        mask = nil
    }

    // Channel is up: send OPEN_MIRROR_SCREEN (like the official client does,
    // regardless of lock state) and kick the WFD client; the duo.screen
    // status query runs in parallel and drives the mask. OPEN is sent at
    // most once per flow — a duplicate makes the phone tear down its RTSP
    // server mid-stream (official never re-sends it either).
    private var openSent = false

    private func openMirrorScreenNow(force: Bool = false) {
        guard !openSent,
              let session = sessionProvider(), session.isChannelReady,
              force || stage != .streaming else { return }
        if stage != .opening {
            stage = .opening
            // Re-opening from a failed state must re-arm the open timeout,
            // which only fires under the loading/no mask.
            if mask == .connectFailed {
                mask = .loading
            }
            trustManager.start()
        }
        openSent = true
        let generation = flowGeneration
        if session.isRelayRouted && relayOpenGrace > 0 {
            // Relay path: hold the OPEN briefly so the phone finishes
            // creating its channel object first — data sent before that is
            // dropped by the native stack (ChannelNotCreatedYet, live
            // 2026-08-08: the whole session deadlocked on it).
            openSent = false
            Task { @MainActor [weak self] in
                let grace = self?.relayOpenGrace ?? 0
                try? await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000))
                guard let self, generation == self.flowGeneration,
                      self.stage == .opening, !self.openSent else { return }
                self.openSent = true
                self.openMirrorScreen(session)
                self.armOpenTimeout(generation: generation)
            }
        } else {
            openMirrorScreen(session)
            armOpenTimeout(generation: generation)
        }
    }

    // While the open is in flight and the trust status query is still
    // unanswered, watch for the first media: a flowing stream proves the
    // OPEN was processed, so the trust state can resolve early from the
    // phone's KeyguardManager report instead of holding the loading mask
    // for the full nudge budget (live 2026-08-08: ~16s of 正在連線 over
    // playing video).
    private func armMediaFlowWatch(generation: UInt64) {
        Task { @MainActor [weak self] in
            while let self,
                  generation == self.flowGeneration,
                  self.stage == .opening,
                  self.trustManager.state == .queryingStatus {
                if self.hasRemoteMedia(),
                   self.trustManager.resolveStatusEarlyForFlowingMedia() {
                    return
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
    }

    private func armOpenTimeout(generation: UInt64) {
        let timeout = openTimeout
        armMediaFlowWatch(generation: generation)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard let self,
                  generation == self.flowGeneration,
                  self.stage == .opening,
                  !self.hasRemoteVideo(),
                  self.mask == .loading || self.mask == nil else {
                return
            }
            if self.hasRemoteMedia() {
                // Media is flowing but the phone screen is static, so the
                // encoder emits no video (audio-only stream). OPEN was
                // clearly processed — resending it would tear down the
                // phone's RTSP server and failing would kill a healthy
                // session (live 2026-08-08: that resend started a rebuild
                // cascade that bricked the whole relay path). Treat the
                // mirror as established and wait for the first video frame.
                self.log("xiaomi.mac.mirror_open_media_only generation=\(generation)")
                self.stage = .streaming
                if case .ready(let locked) = self.trustManager.state {
                    self.mask = locked ? .locked : nil
                }
                return
            }
            if !self.openResendAttempted {
                // Zero video this long after OPEN means the OPEN almost
                // certainly never reached the phone's message handler (a
                // processed OPEN starts the WFD source and media within a
                // couple of seconds). A duplicate OPEN is only dangerous
                // mid-stream, so resending here is safe — and it is the
                // only way to recover the dropped-datagram case.
                self.openResendAttempted = true
                self.openSent = false
                self.log("xiaomi.mac.mirror_open_resend generation=\(generation)")
                if let session = self.sessionProvider(), session.isChannelReady {
                    self.openMirrorScreen(session)
                    self.openSent = true
                    self.armOpenTimeout(generation: generation)
                } else if self.sessionProvider() == nil {
                    self.sessionFactory("mirror_open_resend")
                }
                // Channel dead: notifyChannelReady re-opens once redialed.
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
                if stage == .unlocking, !trustManager.awaitingAuthEvent {
                    // The auth attempt ended without an unlock (phone-side
                    // cancel, retry request, or the auth-event timeout):
                    // return to the lock mask so 解除鎖定 can be retried
                    // instead of sitting on 解鎖中 forever (live 2026-08-11).
                    stage = .opening
                    mask = .locked
                } else if stage == .connecting || stage == .opening {
                    // Mirror start landing on locked: if a reporter-
                    // confirmed unlock_success is still inside the grace
                    // window this is a stale re-lock (screen timeout
                    // re-armed the keyguard before the mirror opened) —
                    // re-run the unlock auth instead of parking.
                    if let unlockedAt = trustManager.lastUnlockSuccessAt,
                       Date().timeIntervalSince(unlockedAt) < staleRelockGrace,
                       let externalUnlockAt = trustManager.lastExternalUnlockAt,
                       externalUnlockAt >= unlockedAt,
                       staleRelockRetriedAfter != unlockedAt,
                       // State events arrive via a Task hop: by the time
                       // this runs the manager may already be mid-requery
                       // (a fresh start() put it back in .queryingStatus).
                       // Acting on the stale queued event would fire Touch
                       // ID off a superseded state — and unlockRequested's
                       // fallback path would redial the healthy channel,
                       // killing the in-flight query (E2E 2026-08-13).
                       case .ready(locked: true) = trustManager.state {
                        staleRelockRetriedAfter = unlockedAt
                        log(
                            "xiaomi.mac.mirror_stale_relock_reauth ageMs=\(Int(Date().timeIntervalSince(unlockedAt) * 1000))"
                        )
                        unlockRequested()
                        break
                    }
                    mask = .locked
                } else if stage != .unlocking {
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
                if mask == .risk {
                    // Risk cleared on the phone (password verified): the
                    // phone tore down its RTSP server when quick-auth was
                    // refused, so the mirror pipeline must be reopened, not
                    // just awaited.
                    mask = .loading
                    retryRequested()
                    break
                }
                if hasRemoteVideo() || hasRemoteMedia() {
                    // Media (video, or audio on a static screen) proves the
                    // OPEN was processed: the mirror is established.
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
