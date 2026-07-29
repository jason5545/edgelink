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

    var sendFrame: ((Data) -> Void)?
    var autoUnlockOnReady = false
    var touchIdPreauthorized = false
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
        sessionID = UInt64.random(in: 1...UInt64.max)
        state = .queryingStatus
        var action = TrustStatusAction()
        action.authFeatures = [DuoScreenTrustFeature.unlockDevice]
        action.eventMode = DuoScreenTrustEventMode.authSettingFirst
        send(.statusAction(action))
        DiagnosticsLog.info("trust.mac.status_action_sent")
    }

    func stop() {
        state = .idle
        statusEvent = nil
        awaitingAuthEvent = false
        awaitingBindEvent = false
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
        if event.code == DuoScreenTrustCode.disabledBySetting {
            state = .ready(locked: true)
            DiagnosticsLog.info(
                "trust.mac.status_setting_only assumed_ready enabled=\(event.auth?.enableStatus ?? -99) " +
                    "bind=\(event.auth?.bindStatus ?? -99) localRisk=\(event.auth?.localRisk ?? -99) remoteRisk=\(event.auth?.remoteRisk ?? -99)"
            )
            if autoUnlockOnReady {
                autoUnlockOnReady = false
                Task { await self.requestUnlock() }
            }
            return
        }
        guard event.code == DuoScreenTrustCode.success else {
            return
        }
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
            state = .ready(locked: isRemoteLocked)
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
