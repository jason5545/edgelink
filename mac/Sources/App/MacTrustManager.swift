import EdgeLinkKit
import Foundation

final class MacTrustManager: ObservableObject {
    enum State: Equatable {
        case idle
        case queryingStatus
        case needsBind
        case binding
        case ready(locked: Bool)
        case authenticating
        case riskBlocked(DuoScreenTrustRisk)
        case failed(String)
    }

    @Published private(set) var state: State = .idle {
        didSet { onStateChanged?(state) }
    }
    @Published private(set) var statusEvent: TrustStatusEvent?
    // Set only by a successful duo.screen authEvent (562/563). Status polls
    // on this device are unreliable (the phone answers disabledBySetting and
    // then a success event with remoteKeyguardStatus=valid while still
    // locked, after its shared-auth query times out), so the lock mask may
    // only be cleared by this confirmed signal.
    private(set) var unlockConfirmed = false
    // Set when a status event arrives that actually carries keyguard
    // information (success + authEnableStatus=enabled). The official client
    // gets these reliably; our earlier authSettingFirst query made the phone
    // answer with enable=0 placeholders that default keyguard to valid (the
    // "unlocked" lie), so placeholders must not be trusted.
    private(set) var keyguardInfoConfirmed = false

    // Official LiveScreenTrustManager retries the auth-status query
    // (retryQueryAuthStatusCount) when the phone returns placeholder
    // answers. Same here: re-query while the phone's own getSupportStatus is
    // still resolving, then fall back to the conservative locked state.
    var statusRetryDelay: TimeInterval = 1.0
    var maxStatusRetries = 5
    private var statusRetryCount = 0
    private var statusQueryEpoch: UInt64 = 0
    // The placeholder retry loop only runs once the phone answers; a query
    // dropped without any reply (phone-side mitrustservice not connected
    // yet — live 2026-08-08 relay session: status_action_sent, then silence
    // for minutes) would leave the flow in queryingStatus forever and the
    // mirror window stuck on 正在連線 while video already plays. Re-send
    // unanswered queries a few times before giving up to the fallback.
    var statusNudgeDelay: TimeInterval = 4.0
    var maxStatusNudges = 3
    private var statusNudgeCount = 0

    var sendFrame: ((Data) -> Void)?
    var autoUnlockOnReady = false
    // Set by a phone-initiated pair request: the next truthful notBound
    // status immediately kicks the official bind flow (the phone shows its
    // own verification UI) instead of just surfacing the bind mask.
    var autoBindOnNeedsBind = false
    var touchIdPreauthorized = false
    // Truthful keyguard state from the EdgeLink Android app (KeyguardManager
    // via phone.lockState push), freshness-gated by the caller. Used when
    // duo.screen polls only yield placeholders — they lie on om1.
    // "locked" reports are conservative and always honored; an "unlocked"
    // report only vouches while fresh — a lock transition since the report
    // (screen off → stop → quick restart) must not let the flow stream the
    // lock screen without an unlock.
    var externalLockState: (() -> (locked: Bool, at: Date)?)?
    // Android pushes on screen broadcasts and a 15s always-on heartbeat, so
    // a fresh report is ~15s old; tolerate a couple of missed beats (doze)
    // before treating "unlocked" as stale. Fast lock transitions ride the
    // SCREEN_OFF broadcast push (~0.3s), so this window does not let a
    // just-locked phone pass as unlocked.
    var externalUnlockedFreshness: TimeInterval = 45
    var isExternallyUnlocked: Bool { externalLockState?()?.locked == false }

    // The external report if it may be acted on: locked reports pass at any
    // age (the caller's own outer gate still applies), unlocked reports only
    // within externalUnlockedFreshness.
    private func usableExternalLockState() -> Bool? {
        guard let report = externalLockState?() else { return nil }
        guard report.locked || Date().timeIntervalSince(report.at) < externalUnlockedFreshness else {
            return nil
        }
        return report.locked
    }
    var onAuthActionSent: (() -> Void)?
    var onAuthEventHandled: (() -> Void)?
    var onUnlockSucceeded: (() -> Void)?
    var onStateChanged: ((State) -> Void)?

    private var sessionID: UInt64 = 0
    private var awaitingAuthEvent = false
    private var awaitingBindEvent = false
    private var awaitingVerifyEvent = false
    private let biometric: BiometricAuthManager

    init(biometric: BiometricAuthManager = .shared) {
        self.biometric = biometric
    }

    var isBound: Bool {
        guard let auth = statusEvent?.auth else { return false }
        return auth.bindStatus == DuoScreenTrustBindStatus.bound.rawValue
    }

    var isRemoteLocked: Bool {
        guard let event = statusEvent else { return true }
        return event.remoteKeyguardStatus != DuoScreenKeyguardStatus.valid
    }

    // The phone reports its own risk in localRisk (its perspective);
    // remoteRisk is the risk of the Mac side and stays 0 on the wire
    // (live 2026-08-03: phone sendMsg localRisk=3, remoteRisk=0 while the
    // TA demanded risk auth). The official client's "remote risk" handling
    // reads the phone's localRisk.
    static func phoneRisk(_ auth: TrustAuthStatus) -> DuoScreenTrustRisk {
        let raw = auth.localRisk != 0 ? auth.localRisk : auth.remoteRisk
        return DuoScreenTrustRisk(rawValue: raw) ?? .none
    }

    func start() {
        // The session's duoScreenStatusEnabled path and the mirror flow both
        // start us on channel-ready — the official client sends exactly one
        // status query, so collapse back-to-back starts into one.
        guard state != .queryingStatus else { return }
        sessionID = UInt64.random(in: 1...UInt64.max)
        statusQueryEpoch &+= 1
        statusRetryCount = 0
        statusNudgeCount = 0
        keyguardInfoConfirmed = false
        // A new flow must re-verify: a 562 unlock confirmed in a previous
        // flow says nothing about the phone's current keyguard (the user may
        // have re-locked while the mirror was stopped).
        unlockConfirmed = false
        state = .queryingStatus
        sendStatusQuery()
        scheduleStatusQueryNudge()
    }

    private func sendStatusQuery() {
        // Official wire format (live capture 2026-07-31, phone-side logcat):
        // TrustStatusActionMessage{authFeatures=[1], eventMode=0,
        // authMethods=[4, 5]}. Do NOT set eventMode=authSettingFirst — with
        // it the phone answers disabledBySetting plus enable=0 placeholders.
        var action = TrustStatusAction()
        action.authFeatures = [DuoScreenTrustFeature.unlockDevice]
        action.authMethods = [UInt32(DuoScreenTrustAuthMethod.password), UInt32(DuoScreenTrustAuthMethod.fingerprint)]
        send(.statusAction(action))
        DiagnosticsLog.info("trust.mac.status_action_sent")
    }

    private func scheduleStatusQueryNudge() {
        let epoch = statusQueryEpoch
        let delay = statusNudgeDelay
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self,
                  self.statusQueryEpoch == epoch,
                  self.state == .queryingStatus,
                  self.statusEvent == nil else { return }
            guard self.statusNudgeCount < self.maxStatusNudges else {
                // Every query went unanswered (phone-side mitrustservice not
                // attached yet on the relay path, live 2026-08-08). Staying
                // in queryingStatus keeps the loading mask forever while
                // video already plays — fall back exactly like the exhausted
                // placeholder retries do.
                self.enterStatusFallback(reason: "nudge_exhausted")
                return
            }
            self.statusNudgeCount += 1
            DiagnosticsLog.info("trust.mac.status_query_nudge count=\(self.statusNudgeCount)")
            self.sendStatusQuery()
            self.scheduleStatusQueryNudge()
        }
    }

    // Gave up on duo.screen status: fall back to the phone's own
    // KeyguardManager report when we have a usable one (duo.screen polls lie
    // on om1); otherwise stay conservative (locked unless a confirmed
    // unlock) so the unlock entry stays reachable.
    private func enterStatusFallback(reason: String) {
        let externalFallback = usableExternalLockState()
        let fallbackLocked = externalFallback ?? !unlockConfirmed
        DiagnosticsLog.info(
            "trust.mac.status_query_fallback locked=\(fallbackLocked) source=\(externalFallback != nil ? "phone_lock_push" : "conservative") reason=\(reason)"
        )
        state = .ready(locked: fallbackLocked)
        if autoUnlockOnReady {
            autoUnlockOnReady = false
            Task { await self.requestUnlock() }
        }
    }

    // Media is already flowing while the status query is still unanswered
    // (relay path: mitrustservice attaches late and drops every query). The
    // mirror clearly opened, so resolve from the phone's own KeyguardManager
    // report now instead of holding the loading mask for the whole nudge
    // budget (live 2026-08-08: video played behind 正在連線 for ~16s).
    // Returns true when the state was resolved. Without a usable external
    // report nothing changes — the nudge loop keeps its fallback timing.
    @discardableResult
    func resolveStatusEarlyForFlowingMedia() -> Bool {
        guard state == .queryingStatus,
              usableExternalLockState() != nil else { return false }
        enterStatusFallback(reason: "media_flowing")
        return true
    }

    func stop() {
        state = .idle
        statusEvent = nil
        awaitingAuthEvent = false
        awaitingBindEvent = false
        awaitingVerifyEvent = false
        unlockConfirmed = false
        keyguardInfoConfirmed = false
        statusQueryEpoch &+= 1
        statusRetryCount = 0
    }

    func requestBind() {
        guard state == .needsBind else { return }
        state = .binding
        awaitingBindEvent = true
        var action = TrustBindAction()
        action.feature = DuoScreenTrustFeature.unlockDevice
        action.unlockUi = true
        action.reason = 0
        send(.bindAction(action))
        DiagnosticsLog.info("trust.mac.bind_action_sent")
    }

    func requestUnlock() async {
        guard case .ready = state else { return }
        if let auth = statusEvent?.auth {
            let risk = Self.phoneRisk(auth)
            if risk != .none {
                enterRiskBlocked(risk)
                DiagnosticsLog.warn("trust.mac.unlock_blocked risk=\(risk.rawValue)")
                return
            }
        }
        state = .authenticating
        if touchIdPreauthorized {
            touchIdPreauthorized = false
        } else {
            do {
                try await biometric.evaluate(reason: "解鎖手機鎖定螢幕")
            } catch {
                state = .ready(locked: true)
                DiagnosticsLog.info("trust.mac.local_auth_rejected error=\(error.localizedDescription)")
                return
            }
        }
        awaitingAuthEvent = true
        var action = TrustAuthAction()
        action.feature = DuoScreenTrustFeature.unlockDevice
        action.method = DuoScreenTrustAuthMethod.fingerprint
        action.unlockUi = true
        action.notCheckSetting = true
        send(.authAction(action))
        DiagnosticsLog.info("trust.mac.auth_action_sent")
        onAuthActionSent?()
    }

    func handleFrame(_ frame: Data) {
        guard let (type, payload) = try? DuoScreenProtocolV1.decodeFrame(frame),
              type == DuoScreenProtocolV1.typeTrust,
              let trust = try? DuoScreenTrustProto.decode(payload) else {
            return
        }
        if trust.sessionID != 0 {
            sessionID = trust.sessionID
        }
        guard let msg = trust.msg else { return }
        switch msg {
        case .statusEvent(let event):
            handleStatusEvent(event)
        case .bindEvent(let event):
            handleBindEvent(event)
        case .authEvent(let event):
            handleAuthEvent(event)
        case .verifyEvent(let event):
            handleVerifyEvent(event)
        case .passwordEvent(let event):
            DiagnosticsLog.info("trust.mac.password_event code=\(event.code)")
        case .misc(let misc):
            DiagnosticsLog.info("trust.mac.misc type=\(misc.type)")
        default:
            break
        }
    }

    private func handleStatusEvent(_ event: TrustStatusEvent) {
        statusEvent = event
        // Only success + authEnableStatus=enabled carries real keyguard
        // info. disabledBySetting and success+enable=unset are placeholders
        // while the phone's own getSupportStatus is still resolving (on
        // timeout it returns defaults — keyguard=valid while locked, the
        // 2026-08-02 live "unlocked" lie). Official retries the query
        // instead of acting on placeholders; do the same, then fall back to
        // the conservative locked state so the unlock entry stays reachable.
        let carriesKeyguardInfo = event.code == DuoScreenTrustCode.success
            && event.auth?.enableStatus == DuoScreenTrustEnableStatus.enabled.rawValue
        guard carriesKeyguardInfo else {
            DiagnosticsLog.info(
                "trust.mac.status_no_info code=\(event.code) enable=\(event.auth?.enableStatus ?? -99)"
            )
            // Placeholders lie about keyguard, but their auth payload still
            // comes from the phone's real getSupportStatus TA query — a
            // notBound bindStatus or a nonzero risk inside a placeholder is
            // trustworthy (myron only ever reports these inside enable=0
            // placeholders, live 2026-08-03).
            if let auth = event.auth {
                if let bind = DuoScreenTrustBindStatus(rawValue: auth.bindStatus), bind != .bound {
                    state = .needsBind
                    DiagnosticsLog.info("trust.mac.status_placeholder_needs_bind bind=\(auth.bindStatus)")
                    if autoBindOnNeedsBind {
                        autoBindOnNeedsBind = false
                        requestBind()
                    }
                    return
                }
                let risk = Self.phoneRisk(auth)
                if risk != .none {
                    enterRiskBlocked(risk)
                    return
                }
            }
            guard state == .queryingStatus else { return }
            if let externalLocked = usableExternalLockState() {
                DiagnosticsLog.info("trust.mac.status_external_shortcut locked=\(externalLocked)")
                state = .ready(locked: externalLocked)
                if autoUnlockOnReady {
                    autoUnlockOnReady = false
                    Task { await self.requestUnlock() }
                }
                return
            }
            if let report = externalLockState?(), !report.locked {
                DiagnosticsLog.info(
                    "trust.mac.status_external_stale ageMs=\(Int(Date().timeIntervalSince(report.at) * 1000))"
                )
            }
            if statusRetryCount < maxStatusRetries {
                statusRetryCount += 1
                let epoch = statusQueryEpoch
                let delay = statusRetryDelay
                DiagnosticsLog.info("trust.mac.status_query_retry count=\(statusRetryCount)")
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    guard let self,
                          self.statusQueryEpoch == epoch,
                          self.state == .queryingStatus else { return }
                    self.sendStatusQuery()
                }
            } else {
                // Placeholders exhausted the official-style retry budget.
                enterStatusFallback(reason: "placeholder_retries_exhausted")
            }
            return
        }
        statusRetryCount = 0
        keyguardInfoConfirmed = true
        guard let auth = event.auth else {
            state = .failed("手機不支援跨裝置解鎖")
            return
        }
        let phoneRisk = Self.phoneRisk(auth)
        if phoneRisk != .none {
            enterRiskBlocked(phoneRisk)
            return
        }
        switch DuoScreenTrustBindStatus(rawValue: auth.bindStatus) {
        case .bound:
            if isRemoteLocked {
                unlockConfirmed = false
            }
            state = .ready(locked: isRemoteLocked)
            if autoUnlockOnReady {
                autoUnlockOnReady = false
                // A 562 on an already-unlocked phone is an instant success,
                // so auto-unlock fires on any truthful ready, locked or not.
                Task { await self.requestUnlock() }
            }
        case .notBound, .keyError, .passwordChanged, .certExpired, .none:
            state = .needsBind
            if autoBindOnNeedsBind {
                autoBindOnNeedsBind = false
                requestBind()
            }
        }
        DiagnosticsLog.info("trust.mac.status_event bind=\(auth.bindStatus) enable=\(auth.enableStatus) remoteLocked=\(self.isRemoteLocked)")
    }

    private func handleBindEvent(_ event: TrustBindEvent) {
        guard awaitingBindEvent else { return }
        awaitingBindEvent = false
        switch event.code {
        case DuoScreenTrustCode.success:
            state = .ready(locked: isRemoteLocked)
            DiagnosticsLog.info("trust.mac.bind_success")
        case DuoScreenTrustCode.userCancel, DuoScreenTrustCode.timeoutCancel:
            state = .needsBind
            DiagnosticsLog.info("trust.mac.bind_cancelled code=\(event.code)")
        default:
            state = .failed("綁定失敗 (\(event.code))")
            DiagnosticsLog.warn("trust.mac.bind_failed code=\(event.code)")
        }
    }

    private func handleAuthEvent(_ event: TrustAuthEvent) {
        guard awaitingAuthEvent, event.feature == DuoScreenTrustFeature.unlockDevice else { return }
        awaitingAuthEvent = false
        defer { onAuthEventHandled?() }
        switch event.code {
        case DuoScreenTrustCode.success:
            unlockConfirmed = true
            state = .ready(locked: false)
            DiagnosticsLog.info("trust.mac.unlock_success")
            onUnlockSucceeded?()
        case DuoScreenTrustCode.userCancel, DuoScreenTrustCode.timeoutCancel:
            state = .ready(locked: true)
            DiagnosticsLog.info("trust.mac.unlock_cancelled code=\(event.code)")
        case DuoScreenTrustCode.retryWithFingerprint:
            state = .ready(locked: true)
            DiagnosticsLog.info("trust.mac.unlock_retry_requested")
        case DuoScreenTrustCode.riskAuthRequired:
            // The phone's quick-auth TA demands one on-phone password
            // verification (matches localRisk=deviceReboot in the shared
            // auth status). Surface the risk mask and kick the official
            // verify flow — the phone shows its own password UI, no rebind
            // needed. No quick-auth retry afterwards: the verify UI unlocks
            // the phone itself, so the flow resumes streaming directly.
            enterRiskBlocked(.deviceReboot)
            DiagnosticsLog.info("trust.mac.unlock_risk_auth_required code=\(event.code)")
        default:
            state = .failed("解鎖失敗 (\(event.code))")
            DiagnosticsLog.warn("trust.mac.unlock_failed code=\(event.code)")
        }
    }

    // Official risk handling (LiveScreenTrustManager "handle remote risk" →
    // "trust service veriry"): on a risk report the Mac sends a
    // verifyAction and the PHONE shows its own lock-screen password UI
    // (.remoteservice.locksettings.LockScreenUIActivity). Entering the
    // password re-provisions the per-boot TA auth token — no rebind needed.
    private func enterRiskBlocked(_ risk: DuoScreenTrustRisk) {
        state = .riskBlocked(risk)
        guard !awaitingVerifyEvent else { return }
        awaitingVerifyEvent = true
        var action = TrustVerifyAction()
        action.feature = DuoScreenTrustFeature.unlockDevice
        action.unlockUi = true
        action.risk = risk.rawValue
        action.notCheckSetting = true
        send(.verifyAction(action))
        DiagnosticsLog.info("trust.mac.verify_action_sent risk=\(risk.rawValue)")
    }

    private func handleVerifyEvent(_ event: TrustVerifyEvent) {
        guard awaitingVerifyEvent, event.feature == DuoScreenTrustFeature.unlockDevice else { return }
        awaitingVerifyEvent = false
        switch event.code {
        case DuoScreenTrustCode.success:
            DiagnosticsLog.info("trust.mac.verify_success")
            // The phone's verify UI (LockScreenUIActivity) unlocks the phone
            // as the password passes — the user lands on the home screen.
            // Official resumes streaming from here; a quick-auth retry would
            // be a redundant second unlock ceremony.
            unlockConfirmed = true
            state = .ready(locked: false)
        case DuoScreenTrustCode.userCancel, DuoScreenTrustCode.timeoutCancel:
            DiagnosticsLog.info("trust.mac.verify_cancelled code=\(event.code)")
        default:
            DiagnosticsLog.warn("trust.mac.verify_failed code=\(event.code)")
        }
    }

    // The EdgeLink Android app's KeyguardManager push is truthful. While
    // risk-blocked (post-reboot TA verify), a phone-side unlock — the verify
    // UI's password, or a plain manual unlock — resolves the flow with no
    // further Mac-side auth; the verifyEvent may never arrive if the phone
    // tore the channel down on unlock.
    func notifyExternalLockState(locked: Bool) {
        guard !locked, case .riskBlocked = state else { return }
        awaitingVerifyEvent = false
        unlockConfirmed = true
        state = .ready(locked: false)
        DiagnosticsLog.info("trust.mac.risk_resolved_phone_unlocked")
    }

    private func send(_ msg: DuoScreenTrustMessage) {
        let trust = DuoScreenTrust(sessionID: sessionID, msg: msg)
        let frame = DuoScreenProtocolV1.encodeFrame(type: DuoScreenProtocolV1.typeTrust, payload: DuoScreenTrustProto.encode(trust))
        sendFrame?(frame)
    }
}
