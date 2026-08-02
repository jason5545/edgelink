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

    var sendFrame: ((Data) -> Void)?
    var autoUnlockOnReady = false
    var touchIdPreauthorized = false
    // Truthful keyguard state from the EdgeLink Android app (KeyguardManager
    // via phone.lockState push), freshness-gated by the caller. Used when
    // duo.screen polls only yield placeholders — they lie on om1.
    var externalLockState: (() -> Bool?)?
    var isExternallyUnlocked: Bool { externalLockState?() == false }
    var onAuthActionSent: (() -> Void)?
    var onAuthEventHandled: (() -> Void)?
    var onUnlockSucceeded: (() -> Void)?
    var onStateChanged: ((State) -> Void)?

    private var sessionID: UInt64 = 0
    private var awaitingAuthEvent = false
    private var awaitingBindEvent = false
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

    func start() {
        // The session's duoScreenStatusEnabled path and the mirror flow both
        // start us on channel-ready — the official client sends exactly one
        // status query, so collapse back-to-back starts into one.
        guard state != .queryingStatus else { return }
        sessionID = UInt64.random(in: 1...UInt64.max)
        statusQueryEpoch &+= 1
        statusRetryCount = 0
        keyguardInfoConfirmed = false
        state = .queryingStatus
        sendStatusQuery()
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

    func stop() {
        state = .idle
        statusEvent = nil
        awaitingAuthEvent = false
        awaitingBindEvent = false
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
        if let auth = statusEvent?.auth, auth.remoteRisk > DuoScreenTrustRisk.none.rawValue {
            state = .riskBlocked(DuoScreenTrustRisk(rawValue: auth.remoteRisk) ?? .none)
            DiagnosticsLog.warn("trust.mac.unlock_blocked remoteRisk=\(auth.remoteRisk)")
            return
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
            DiagnosticsLog.info("trust.mac.verify_event code=\(event.code)")
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
            guard state == .queryingStatus else { return }
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
                // Fall back to the phone's own KeyguardManager report when we
                // have one (duo.screen polls lie on om1); otherwise stay
                // conservative (locked unless a confirmed unlock) so the
                // unlock entry stays reachable.
                let fallbackLocked = externalLockState?() ?? !unlockConfirmed
                DiagnosticsLog.info(
                    "trust.mac.status_query_fallback locked=\(fallbackLocked) source=\(self.externalLockState?() != nil ? "phone_lock_push" : "conservative")"
                )
                state = .ready(locked: fallbackLocked)
                if autoUnlockOnReady {
                    autoUnlockOnReady = false
                    Task { await self.requestUnlock() }
                }
            }
            return
        }
        statusRetryCount = 0
        keyguardInfoConfirmed = true
        guard let auth = event.auth else {
            state = .failed("手機不支援跨裝置解鎖")
            return
        }
        if auth.remoteRisk != DuoScreenTrustRisk.none.rawValue {
            state = .riskBlocked(DuoScreenTrustRisk(rawValue: auth.remoteRisk) ?? .none)
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
        default:
            state = .failed("解鎖失敗 (\(event.code))")
            DiagnosticsLog.warn("trust.mac.unlock_failed code=\(event.code)")
        }
    }

    private func send(_ msg: DuoScreenTrustMessage) {
        let trust = DuoScreenTrust(sessionID: sessionID, msg: msg)
        let frame = DuoScreenProtocolV1.encodeFrame(type: DuoScreenProtocolV1.typeTrust, payload: DuoScreenTrustProto.encode(trust))
        sendFrame?(frame)
    }
}
