import AppKit
import Combine
import CryptoKit
import EdgeLinkKit
import Foundation

@MainActor
final class EdgeLinkRuntime: ObservableObject {
    private static let secureKeepaliveIntervalNanoseconds: UInt64 = 5_000_000_000
    private static let securePongTimeoutSeconds: TimeInterval = 15
    private static let xiaomiMirrorKeyboardCommand = "xiaomi.mirror.keyboard"
    private static let xiaomiMirrorKeyboardReadyCommand = "xiaomi.mirror.keyboardReady"
    private static let xiaomiMirrorKeyboardReleaseCommand = "xiaomi.mirror.keyboardRelease"
    private static let xiaomiMirrorPointerCommand = "xiaomi.mirror.pointer"
    private static let xiaomiMirrorGlobalCommand = "xiaomi.mirror.global"
    private static let xiaomiMirrorKeyboardReadyRetryInterval: TimeInterval = 1.5
    private static let androidMetaAltLeft = 0x10
    private static let androidMetaAltRight = 0x20
    private static let androidMetaShiftLeft = 0x40
    private static let androidMetaShiftRight = 0x80
    private static let androidMetaCtrlLeft = 0x2_000
    private static let androidMetaCtrlRight = 0x4_000
    private static let androidMetaWinLeft = 0x2_0000
    private static let androidMetaWinRight = 0x4_0000
    private static var allowXiaomiScreenPrimaryRoute: Bool {
        UserDefaults.standard.object(forKey: xiaomiScreenPrimaryRouteDefaultsKey) as? Bool ?? true
    }

    @Published private(set) var localDeviceId = "Registering..."
    @Published private(set) var peerName = "No paired Android"
    @Published private(set) var peerDeviceId = ""
    @Published private(set) var connectionStatus = "Starting"
    @Published private(set) var isConnected = false
    @Published private(set) var canDisconnect = false
    @Published private(set) var pairingSAS = ""
    @Published private(set) var pairingPeerName = ""
    @Published private(set) var pairingStatus = ""
    @Published private(set) var isPairing = false
    @Published private(set) var canAcceptPairing = false
    @Published private(set) var macNotificationSyncEnabled: Bool
    @Published private(set) var verificationCodeSystemBridgeEnabled: Bool
    @Published private(set) var verificationCodeAutoCopyEnabled: Bool
    @Published private(set) var latestVerificationCode: VerificationCodeCandidate?
    @Published private(set) var smsMessages: [SmsMessageBody] = []
    @Published private(set) var smsSendStatus = ""
    @Published private(set) var phoneCallStatus = ""
    @Published private(set) var incomingPhoneCallLabel = ""
    @Published private(set) var lastDialedPhoneNumber: String
    @Published private(set) var isPhoneCallActive = false
    @Published private(set) var phoneRelayEchoCancellationEnabled: Bool
    @Published private(set) var latestMiLinkStatus: MiLinkStatusBody?
    @Published private(set) var latestMiLinkFrame: MiLinkFrameBody?
    @Published private(set) var xiaomiMiLinkCommandStatus = ""
    @Published private(set) var xiaomiHyperConnectAvailable = XiaomiHyperConnectBridge.isInstalled
    @Published private(set) var xiaomiMiShareDiscoveryStatus = String(localized: "小米快傳 discovery：準備中")
    @Published private(set) var xiaomiMiSharePublishedDeviceId = ""
    @Published private(set) var xiaomiMiShareDiscoveredPeers: [XiaomiMiShareDiscoveredPeer] = []
    @Published private(set) var isPhoneScreenSessionActive = false
    @Published private(set) var isPhoneScreenViewerVisible = false
    @Published private(set) var hasViewedPhoneScreen = false

    private let identityStore = KeychainIdentityStore()
    private let pairingStore: ApplicationSupportPairingStore?
    private let registrar: WorkerDeviceRegistrar
    private let relayTransport: RelayTransport
    private let pairingTransport: PairingTransport
    private let lanTransport = LANTransport()
    private let clipboardSync = ClipboardSync()
    private let notificationPresenter = MacNotificationPresenter()
    private let incomingCallPresenter = MacIncomingCallPresenter()
    private let verificationCodeBridge = MacVerificationCodeBridge()
    private let macNotificationSource = MacNotificationDatabaseSource()
    private let screenSession = MacScreenSession()
    private let turnCredentialClient: TurnCredentialClient
    private let presenceClient: PresenceClient
    private let phoneRelayAudioController = PhoneRelayAudioController()
    private let callRelayCloudflareBridge: CallRelayCloudflareBridge
    private let phoneRelaySession = MacPhoneRelaySession()
    private let phoneRelayProbe = MiLinkPhoneRelayProbe()
    private let xiaomiMirrorRTSPDiagnosticSource = XiaomiMirrorRTSPDiagnosticSource()
    private let xiaomiMiShareDiscovery = XiaomiMiShareDiscovery()
    private var lyraFileSendSession: LyraFileSendSession?
    private let encoder = JSONEncoder()
    private var currentSession: SecureSessionHost?
    private var localIdentity: LocalIdentity?
    private var pairingTask: Task<Void, Never>?
    private var pendingPairing: MacPendingPairing?
    private var task: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private var currentPeer: PinnedPeer?
    private var currentConnectionGeneration: UUID?
    private var currentChannel: ByteChannel?
    private var currentChannelGeneration: UUID?
    private var currentChannelTransport: String?
    private var lanSessionListener: LANSessionListener?
    private var lanSessionTask: Task<Void, Never>?
    private var hostSessionDidConnect = false
    private var lastSecurePongAt = Date.distantPast
    private var pendingAwakeNotification = false
    private var resumeConnectionAfterWake = false
    private var systemSleepWakeCancellables = Set<AnyCancellable>()
    private var pendingSmsSends: [String: SmsSendBody] = [:]
    private var pendingPhoneActions: [String: PhoneActionBody] = [:]
    private var activePhoneRelaySessionId: String?
    private var phoneRelaySourceSequence = 0
    private var phoneRelaySourceSendFailed = false
    private var phoneCallStatuses: [String: PhoneCallStatusBody] = [:]
    private var androidMicRelayArmed = false
    private var phoneRelayProbeRunning = false
    private var phoneRelaySessionRunning = false
    private var phoneRelayUplinkActive = false
    private var phoneRelayDebugTask: Task<Void, Never>?
    private var phoneRelayDebugSessionID: UUID?
    private var phoneRelayDebugDialRequestID: String?
    private var phoneRelayDebugDialError: String?
    private var phoneRelayDebugLastStats: MiLinkPhoneRelayPCMStats?
    private var phoneRelayDebugValidStats: MiLinkPhoneRelayPCMStats?
    private var phoneRelayDebugLastGatewayStats: CallRelayGatewayPlaybackStats?
    private var phoneRelayDebugValidGatewayStats: CallRelayGatewayPlaybackStats?
    private var latestTurnCredential: TurnCredentialSnapshot?
    private var turnCredentialTask: Task<TurnCredentialSnapshot?, Never>?
    private var pendingXiaomiScreenFallback: PendingXiaomiScreenFallback?
    private var pendingXiaomiScreenFallbackTask: Task<Void, Never>?
    private var deferredViewPhoneScreenTask: Task<Void, Never>?
    private var xiaomiScreenRecoveryTask: Task<Void, Never>?
    private var xiaomiScreenRecoveryAttempt = 0
    private var xiaomiScreenLastSessionRebuildAt = Date.distantPast
    private var xiaomiScreenLastSessionRebuildSourceSessionID: UUID?
    private var xiaomiScreenLastSessionRebuildRequestID: String?
    private var xiaomiScreenLastSourceRecoveryAt = Date.distantPast
    private var xiaomiScreenLastSourceRecoverySessionID: UUID?
    private var xiaomiScreenLastSourceRecoveryRequestID: String?
    private var xiaomiScreenLastSourceRecoveryDecodedFrames: UInt64?
    private var xiaomiScreenUserStopped = false
    private var activeXiaomiMirrorCloudflareSessionId: String?
    private var xiaomiMirrorCloudflareDatagramsSent: UInt64 = 0
    private var didAutoBindXiaomiDistAudio = false
    private var didAutoQueryXiaomiMirrorDevices = false
    private var didPrepareXiaomiMirrorKeyboard = false
    private var xiaomiMirrorKeyboardReadyLastAttemptAt = Date.distantPast

    private struct PendingXiaomiScreenFallback {
        let requestId: String
        let command: String
        let route: String
        let startedAt: Date
        let timeoutMs: Int
        let officialDiscoveryRequired: Bool
        let phoneDevices: Int
        let hyperConnectInstalled: Bool
        var fallbackStarted: Bool

        var elapsedMs: Int {
            Int(Date().timeIntervalSince(startedAt) * 1_000)
        }
    }

    init(
        workerBaseURL: URL = EdgeLinkConfig.workerBaseURL,
        relayURL: URL = EdgeLinkConfig.relayURL,
        pairingWebSocketURL: URL = EdgeLinkConfig.pairingWebSocketURL
    ) {
        macNotificationSyncEnabled = UserDefaults.standard.object(forKey: Self.macNotificationSyncDefaultsKey) as? Bool ?? true
        verificationCodeSystemBridgeEnabled = UserDefaults.standard.object(forKey: Self.verificationCodeSystemBridgeDefaultsKey) as? Bool ?? true
        verificationCodeAutoCopyEnabled = UserDefaults.standard.object(forKey: Self.verificationCodeAutoCopyDefaultsKey) as? Bool ?? true
        phoneRelayEchoCancellationEnabled = UserDefaults.standard.object(forKey: Self.phoneRelayEchoCancellationDefaultsKey) as? Bool ?? true
        lastDialedPhoneNumber = UserDefaults.standard.string(forKey: Self.lastDialedPhoneNumberDefaultsKey) ?? ""
        pairingStore = try? ApplicationSupportPairingStore()
        registrar = WorkerDeviceRegistrar(baseURL: workerBaseURL)
        relayTransport = RelayTransport(endpoint: relayURL)
        pairingTransport = PairingTransport(baseURL: workerBaseURL, webSocketURL: pairingWebSocketURL)
        turnCredentialClient = TurnCredentialClient(baseURL: workerBaseURL)
        presenceClient = PresenceClient(baseURL: workerBaseURL)
        callRelayCloudflareBridge = CallRelayCloudflareBridge(downlinkPlayer: phoneRelayAudioController.downlinkPlayer)
        phoneRelayAudioController.echoCancellationEnabled = phoneRelayEchoCancellationEnabled
        notificationPresenter.onCopyVerificationCode = { [weak self] code in
            Task { @MainActor in
                self?.copyVerificationCode(code, reason: "notification_action")
            }
        }
        incomingCallPresenter.onAnswerPhoneCall = { [weak self] callId in
            Task { @MainActor in
                self?.handleIncomingCallUIAnswer(callId: callId)
            }
        }
        incomingCallPresenter.onHangUpPhoneCall = { [weak self] callId in
            Task { @MainActor in
                self?.handleIncomingCallUIHangUp(callId: callId)
            }
        }
        screenSession.onWindowVisibilityChanged = { [weak self] visible in
            Task { @MainActor in
                self?.isPhoneScreenViewerVisible = visible
            }
        }
        screenSession.onSessionActivityChanged = { [weak self] active in
            Task { @MainActor in
                self?.isPhoneScreenSessionActive = active
            }
        }
        screenSession.onXiaomiMirrorKey = { [weak self] event, isDown in
            self?.sendXiaomiMirrorKeyboardEvent(event, isDown: isDown) ?? false
        }
        screenSession.onXiaomiMirrorPointer = { [weak self] body in
            self?.sendXiaomiMirrorPointer(body) ?? false
        }
        screenSession.onXiaomiMirrorGlobal = { [weak self] action in
            self?.sendXiaomiMirrorGlobal(action) ?? false
        }
        xiaomiMirrorRTSPDiagnosticSource.onDecodedFrame = { [weak self, screenSession] pixelBuffer, width, height in
            Task { @MainActor in
                self?.xiaomiScreenRecoveryAttempt = 0
                self?.xiaomiScreenLastSourceRecoveryDecodedFrames = nil
                screenSession.renderXiaomiMirrorFrame(pixelBuffer, width: width, height: height)
                self?.prepareXiaomiMirrorKeyboardIfNeeded(source: "decoded_frame")
            }
        }
        xiaomiMirrorRTSPDiagnosticSource.onRecoveryRequired = { [weak self] event in
            Task { @MainActor in
                self?.handleXiaomiMirrorRTSPRecoveryRequired(event)
            }
        }
        xiaomiMirrorRTSPDiagnosticSource.onPeerStop = { [weak self] reason, sessionID, generation in
            Task { @MainActor in
                self?.handleXiaomiMirrorPeerStop(
                    reason: reason,
                    sessionID: sessionID,
                    generation: generation
                )
            }
        }
        xiaomiMirrorRTSPDiagnosticSource.onCloudflareMirrorOutboundDatagram = { [weak self] packet, sessionId in
            Task { @MainActor in
                self?.sendXiaomiMirrorCloudflareDatagram(packet, sessionId: sessionId)
            }
        }
        phoneRelayProbe.onSinkPCMStats = { [weak self] stats in
            Task { @MainActor in
                self?.handlePhoneRelayPCMStats(stats)
            }
        }
        phoneRelaySession.onDownlinkRTPPacket = { [weak self] packet in
            guard let self else {
                return
            }
            if let stats = self.phoneRelayAudioController.downlinkPlayer.writeRTPPacket(packet) {
                Task { @MainActor in
                    self.handleCallRelayGatewayPlaybackStats(stats)
                }
            }
        }
        phoneRelaySession.onUplinkDestination = { [weak self] _, _ in
            Task { @MainActor in
                self?.startPhoneRelayUplink(reason: "lan_destination")
            }
        }
        phoneRelaySession.onTeardown = { [weak self] reason in
            Task { @MainActor in
                self?.stopPhoneRelayUplink(reason: "lan_\(reason)")
            }
        }
        xiaomiMiShareDiscovery.onSnapshotChanged = { [weak self] snapshot in
            Task { @MainActor in
                self?.handleXiaomiMiShareDiscoverySnapshot(snapshot)
            }
        }
        callRelayCloudflareBridge.onPlaybackStats = { [weak self] stats in
            Task { @MainActor in
                self?.handleCallRelayGatewayPlaybackStats(stats)
            }
        }
        EdgeLinkURLRouter.shared.setHandler { [weak self] url in
            Task { @MainActor in
                self?.handleExternalURL(url)
            }
        }
        observeSystemSleepWake()
        verificationCodeBridge.warmObservers()
        lanTransport.startReachabilityProbe()
        task = Task { await run() }
        startXiaomiMirrorRTSPDiagnosticSourceOnLaunchIfNeeded()
    }

    deinit {
        task?.cancel()
        pairingTask?.cancel()
        connectionTask?.cancel()
        phoneRelayDebugTask?.cancel()
        turnCredentialTask?.cancel()
        pendingXiaomiScreenFallbackTask?.cancel()
        xiaomiScreenRecoveryTask?.cancel()
        currentChannel?.close()
        lanTransport.stopReachabilityProbe()
        phoneRelayProbe.stop()
        xiaomiMirrorRTSPDiagnosticSource.stop(reason: "runtime_deinit")
        xiaomiMiShareDiscovery.stop()
        callRelayCloudflareBridge.stop(reason: "runtime_deinit")
        screenSession.closeWindow(sendRemoteStop: false)
    }

    func startPairing() {
        guard let identity = localIdentity else {
            DiagnosticsLog.warn("pair.mac.start requested before identity ready")
            pairingStatus = "Registering"
            return
        }
        DiagnosticsLog.info("pair.mac.start requested hostId=\(identity.deviceId)")
        pairingTask?.cancel()
        pairingTask = Task { await runPairing(identity: identity) }
    }

    func acceptPairing() {
        guard let pendingPairing else {
            DiagnosticsLog.warn("pair.mac.accept ignored no_pending_pairing")
            return
        }
        DiagnosticsLog.info("pair.mac.accept click hostId=\(pendingPairing.hostId) clientId=\(pendingPairing.clientId)")
        canAcceptPairing = false
        pairingStatus = "Waiting for Android"
        Task {
            do {
                try await pairingTransport.confirm(pendingPairing.confirmRequest())
                DiagnosticsLog.info("pair.mac.confirm sent hostId=\(pendingPairing.hostId) clientId=\(pendingPairing.clientId)")
            } catch {
                DiagnosticsLog.error("pair.mac.confirm failed hostId=\(pendingPairing.hostId) clientId=\(pendingPairing.clientId)", error)
                await MainActor.run {
                    self.pairingStatus = "Pairing failed"
                    self.isPairing = false
                }
            }
        }
    }

    func setMacNotificationSyncEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.macNotificationSyncDefaultsKey)
        macNotificationSyncEnabled = enabled
        DiagnosticsLog.info("notification.mac.sync_enabled enabled=\(enabled)")
        if enabled {
            Task { await macNotificationSource.resetBaseline() }
        }
    }

    func setVerificationCodeSystemBridgeEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.verificationCodeSystemBridgeDefaultsKey)
        verificationCodeSystemBridgeEnabled = enabled
        DiagnosticsLog.info("verification.mac.system_bridge_enabled enabled=\(enabled)")
        if enabled {
            verificationCodeBridge.warmObservers()
        }
    }

    func setPhoneRelayEchoCancellationEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.phoneRelayEchoCancellationDefaultsKey)
        phoneRelayEchoCancellationEnabled = enabled
        phoneRelayAudioController.echoCancellationEnabled = enabled
        DiagnosticsLog.info("phonerelay.mac.echo_cancellation_enabled enabled=\(enabled)")
    }

    func setVerificationCodeAutoCopyEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.verificationCodeAutoCopyDefaultsKey)
        verificationCodeAutoCopyEnabled = enabled
        DiagnosticsLog.info("verification.mac.auto_copy_enabled enabled=\(enabled)")
    }

    func copyLatestVerificationCode() {
        guard let latestVerificationCode else {
            return
        }
        copyVerificationCode(latestVerificationCode.code, reason: "menu")
    }

    func viewPhoneScreen() {
        viewPhoneScreen(allowRouteDeferral: true)
    }

    private func viewPhoneScreen(allowRouteDeferral: Bool) {
        guard isConnected else {
            DiagnosticsLog.warn("screen.mac.start_ignored not_connected")
            return
        }
        let preferredScreenRoute = latestMiLinkStatus?.preferredRoutes?["screen"]
        let xiaomiScreenRoute = Self.xiaomiScreenRouteCandidate(
            from: latestMiLinkStatus,
            preferredRoute: preferredScreenRoute
        )
        if xiaomiScreenRoute?.hasPrefix("xiaomi.") != true,
           !screenSession.isUsingXiaomiMirrorRoute,
           allowRouteDeferral,
           latestMiLinkStatus == nil,
           !isPhoneScreenSessionActive {
            scheduleDeferredViewPhoneScreen()
            return
        }
        deferredViewPhoneScreenTask?.cancel()
        deferredViewPhoneScreenTask = nil
        if xiaomiScreenRoute?.hasPrefix("xiaomi.") == true || screenSession.isUsingXiaomiMirrorRoute {
            guard Self.allowXiaomiScreenPrimaryRoute else {
                screenSession.setXiaomiMirrorRouteActive(false)
                xiaomiMiLinkCommandStatus = String(localized: "小米鏡像已停用")
                DiagnosticsLog.warn(
                    "xiaomi.mac.screen_no_fallback route=\(xiaomiScreenRoute ?? "unknown") " +
                        "preferredRoute=\(preferredScreenRoute ?? "unknown") " +
                        "reason=disabled_by_user_default " +
                        "officialDiscoveryRequired=\(latestMiLinkStatus?.officialDiscoveryRequired ?? false) " +
                        "phoneDevices=\(latestMiLinkStatus?.phoneRemoteDeviceCount ?? 0) " +
                        "hyperConnectInstalled=\(xiaomiHyperConnectAvailable) " +
                        "xiaomiMirrorDeviceIdSource=hyperconnect_cache"
                )
                return
            }
            if let pending = pendingXiaomiScreenFallback {
                screenSession.setXiaomiMirrorRouteActive(true)
                xiaomiMiLinkCommandStatus = String(localized: "小米鏡像啟動中")
                DiagnosticsLog.info(
                    "xiaomi.mac.screen_start_gate reason=pending requestId=\(pending.requestId) " +
                        "route=\(pending.route) elapsedMs=\(pending.elapsedMs)"
                )
                return
            }
            if xiaomiScreenRecoveryTask != nil {
                screenSession.setXiaomiMirrorRouteActive(true)
                xiaomiMiLinkCommandStatus = String(localized: "小米鏡像恢復中")
                DiagnosticsLog.info(
                    "xiaomi.mac.screen_start_gate reason=recovering " +
                        "attempt=\(xiaomiScreenRecoveryAttempt)"
                )
                return
            }
            if isPhoneScreenSessionActive {
                if screenSession.isUsingXiaomiMirrorRoute {
                    screenSession.setXiaomiMirrorRouteActive(true)
                    screenSession.showActiveWindow()
                    isPhoneScreenViewerVisible = true
                    hasViewedPhoneScreen = true
                    xiaomiScreenUserStopped = false
                    DiagnosticsLog.info(
                        "xiaomi.mac.screen_start_gate reason=active_show_existing " +
                            "route=\(xiaomiScreenRoute ?? "xiaomi.mirror.active")"
                    )
                    return
                }
                DiagnosticsLog.warn(
                    "xiaomi.mac.screen_webrtc_session_replaced route=\(xiaomiScreenRoute ?? "xiaomi.mirror.active") " +
                        "reason=xiaomi_route_no_webrtc_fallback"
                )
                screenSession.hideWindowAndStop(sendRemoteStop: isConnected)
                isPhoneScreenSessionActive = false
                isPhoneScreenViewerVisible = false
            }
            screenSession.setXiaomiMirrorRouteActive(true)
            screenSession.showConnectingWindow()
            let command = "xiaomi.mirror.startMainDisplay"
            let timeoutMs = 12_000
            let peerHost = Self.xiaomiMirrorAdvertisedHost()
            let peerPort = Self.xiaomiMirrorRTSPDiagnosticPort
            if xiaomiMirrorRTSPDiagnosticSource.hasActiveSession() {
                stopXiaomiMirrorRTSPDiagnosticSource(reason: "screen_route_recall")
                DiagnosticsLog.info("xiaomi.mac.screen_recall_previous_session_stopped")
            }
            let cloudflareMirrorSessionId = startNewXiaomiMirrorCloudflareSessionIfEnabled(reason: "manual_start")
            xiaomiScreenUserStopped = false
            resetXiaomiScreenRecoveryState(reason: "manual_start")
            didPrepareXiaomiMirrorKeyboard = false
            xiaomiMirrorKeyboardReadyLastAttemptAt = .distantPast
            startXiaomiMirrorRTSPDiagnosticSourceIfNeeded(peerHost: peerHost, reason: "screen_route")
            DiagnosticsLog.info(
                "xiaomi.mac.screen_route_selected command=\(command) route=\(xiaomiScreenRoute ?? "xiaomi.mirror.active") " +
                    "preferredRoute=\(preferredScreenRoute ?? "unknown") " +
                    "officialDiscoveryRequired=\(latestMiLinkStatus?.officialDiscoveryRequired ?? false) " +
                    "phoneDevices=\(latestMiLinkStatus?.phoneRemoteDeviceCount ?? 0) " +
                    "hyperConnectInstalled=\(xiaomiHyperConnectAvailable) gatedByOfficialApp=false " +
                    "peerHost=\(peerHost ?? "default") peerPort=\(peerPort) fakeRemote=true " +
                    "xiaomiMirrorDeviceId=none timeoutMs=\(timeoutMs) " +
                    "mediaTransport=\(cloudflareMirrorSessionId == nil ? "direct" : "cloudflare") " +
                    "cloudSessionId=\(cloudflareMirrorSessionId ?? "none")"
            )
            var args: [String: String] = [:]
            if let peerHost {
                args["peerHost"] = peerHost
            }
            args["peerPort"] = String(peerPort)
            args["forceFakeRemote"] = "true"
            addXiaomiMirrorLANProbeArgs(to: &args, peerHost: peerHost)
            addXiaomiMirrorCloudflareArgs(to: &args, sessionId: cloudflareMirrorSessionId)
            let requestId = sendMiLinkCommand(
                command: command,
                args: args
            )
            if let requestId {
                if let cloudflareMirrorSessionId {
                    xiaomiMirrorRTSPDiagnosticSource.startCloudflareMirrorRTPReceiver(
                        sessionId: cloudflareMirrorSessionId,
                        lifetime: Self.xiaomiMirrorRTSPDiagnosticLifetimeSeconds,
                        reason: "screen_route_start"
                    )
                }
                armPendingXiaomiScreenCommand(
                    requestId: requestId,
                    command: command,
                    route: xiaomiScreenRoute ?? "xiaomi.mirror.active",
                    timeoutMs: timeoutMs
                )
                prepareXiaomiMirrorKeyboardIfNeeded(source: "screen_route_start")
                return
            }
            screenSession.setXiaomiMirrorRouteActive(false)
            activeXiaomiMirrorCloudflareSessionId = nil
            xiaomiMirrorRTSPDiagnosticSource.stopCloudflareMirrorRTPReceiver(reason: "screen_command_failed")
            DiagnosticsLog.warn("xiaomi.mac.screen_command_failed_before_send route=\(xiaomiScreenRoute ?? "xiaomi.mirror.active")")
            xiaomiMiLinkCommandStatus = String(localized: "小米鏡像指令未送出")
            return
        }
        screenSession.setXiaomiMirrorRouteActive(false)
        startEdgeLinkPhoneScreen(reason: "generic")
    }

    private func scheduleDeferredViewPhoneScreen() {
        guard deferredViewPhoneScreenTask == nil else {
            return
        }
        xiaomiMiLinkCommandStatus = String(localized: "等待小米鏡像路由…")
        screenSession.showConnectingWindow()
        DiagnosticsLog.info("xiaomi.mac.screen_route_deferred reason=awaiting_milink_status")
        deferredViewPhoneScreenTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await MainActor.run {
                guard let self else {
                    return
                }
                self.deferredViewPhoneScreenTask = nil
                DiagnosticsLog.info(
                    "xiaomi.mac.screen_route_deferred_timeout hasStatus=\(self.latestMiLinkStatus != nil)"
                )
                self.viewPhoneScreen(allowRouteDeferral: false)
            }
        }
    }

    private func armPendingXiaomiScreenCommand(
        requestId: String,
        command: String,
        route: String,
        timeoutMs: Int
    ) {
        pendingXiaomiScreenFallback = PendingXiaomiScreenFallback(
            requestId: requestId,
            command: command,
            route: route,
            startedAt: Date(),
            timeoutMs: timeoutMs,
            officialDiscoveryRequired: latestMiLinkStatus?.officialDiscoveryRequired ?? false,
            phoneDevices: latestMiLinkStatus?.phoneRemoteDeviceCount ?? 0,
            hyperConnectInstalled: xiaomiHyperConnectAvailable,
            fallbackStarted: false
        )
        pendingXiaomiScreenFallbackTask?.cancel()
        pendingXiaomiScreenFallbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
            await MainActor.run {
                guard let self,
                      let pending = self.pendingXiaomiScreenFallback,
                      pending.requestId == requestId,
                      !pending.fallbackStarted else {
                    return
                }
                self.pendingXiaomiScreenFallbackTask = nil
                self.pendingXiaomiScreenFallback = nil
                self.xiaomiMiLinkCommandStatus = String(localized: "小米鏡像未回應")
                DiagnosticsLog.warn(
                    "xiaomi.mac.screen_no_fallback requestId=\(requestId) command=\(pending.command) " +
                        "route=\(pending.route) reason=timeout timeoutMs=\(pending.timeoutMs) " +
                        "elapsedMs=\(pending.elapsedMs) officialDiscoveryRequired=\(pending.officialDiscoveryRequired) " +
                        "phoneDevices=\(pending.phoneDevices) hyperConnectInstalled=\(pending.hyperConnectInstalled)"
                )
            }
        }
    }

    private func startEdgeLinkPhoneScreen(reason: String) {
        let preferredScreenRoute = latestMiLinkStatus?.preferredRoutes?["screen"]
        if Self.xiaomiScreenRouteCandidate(
            from: latestMiLinkStatus,
            preferredRoute: preferredScreenRoute
        )?.hasPrefix("xiaomi.") == true || screenSession.isUsingXiaomiMirrorRoute {
            screenSession.setXiaomiMirrorRouteActive(true)
            xiaomiMiLinkCommandStatus = String(localized: "小米鏡像路由中")
            DiagnosticsLog.warn(
                "screen.mac.webrtc_start_blocked reason=xiaomi_route_no_webrtc_fallback " +
                    "requestedReason=\(reason) preferredRoute=\(preferredScreenRoute ?? "unknown")"
            )
            return
        }
        screenSession.setXiaomiMirrorRouteActive(false)
        Task { [weak self] in
            guard let self else {
                return
            }
            _ = await self.ensureTurnCredentials(reason: "screen_start_\(reason)")
            if self.isPhoneScreenSessionActive {
                self.screenSession.showActiveWindow()
                self.isPhoneScreenViewerVisible = true
                self.hasViewedPhoneScreen = true
                DiagnosticsLog.info("screen.mac.show_existing reason=\(reason)")
                return
            }
            self.screenSession.openAndStart()
            self.isPhoneScreenSessionActive = true
            self.isPhoneScreenViewerVisible = true
            self.hasViewedPhoneScreen = true
            DiagnosticsLog.info("screen.mac.started reason=\(reason)")
        }
    }

    func showPhoneScreen() {
        guard isPhoneScreenSessionActive else {
            viewPhoneScreen()
            return
        }
        screenSession.showActiveWindow()
        isPhoneScreenViewerVisible = true
    }

    func stopPhoneScreen() {
        stopXiaomiScreenRouteForUser(reason: "user_stop")
        screenSession.hideWindowAndStop(sendRemoteStop: isConnected)
        isPhoneScreenSessionActive = false
        isPhoneScreenViewerVisible = false
    }

    func disconnect() {
        DiagnosticsLog.info("relay.mac.disconnect_requested")
        currentConnectionGeneration = nil
        canDisconnect = false
        connectionTask?.cancel()
        connectionTask = nil
        lanSessionTask?.cancel()
        lanSessionTask = nil
        turnCredentialTask?.cancel()
        turnCredentialTask = nil
        latestTurnCredential = nil
        pendingXiaomiScreenFallbackTask?.cancel()
        pendingXiaomiScreenFallbackTask = nil
        pendingXiaomiScreenFallback = nil
        xiaomiScreenRecoveryTask?.cancel()
        xiaomiScreenRecoveryTask = nil
        xiaomiScreenRecoveryAttempt = 0
        resetXiaomiScreenRecoveryState(reason: "disconnect")
        xiaomiScreenUserStopped = false
        activeXiaomiMirrorCloudflareSessionId = nil
        releaseXiaomiMirrorKeyboard(reason: "disconnect")
        stopXiaomiMirrorRTSPDiagnosticSource(reason: "disconnect")
        didAutoBindXiaomiDistAudio = false
        didAutoQueryXiaomiMirrorDevices = false

        let shouldSendRemoteStop = isConnected
        screenSession.hideWindowAndStop(sendRemoteStop: shouldSendRemoteStop)
        currentChannel?.close()
        currentChannel = nil
        currentChannelGeneration = nil
        currentChannelTransport = nil
        currentSession = nil
        screenSession.clearSender()
        screenSession.setIceServerConfigs([])
        screenSession.setMicrophoneRelayEnabled(false)
        stopPhoneRelayProbe(reason: "disconnect")
        callRelayCloudflareBridge.stop(reason: "disconnect")
        activePhoneRelaySessionId = nil
        incomingCallPresenter.endAll(reason: .failed)
        phoneCallStatuses.removeAll()
        incomingPhoneCallLabel = ""
        androidMicRelayArmed = false
        isPhoneCallActive = false
        isConnected = false
        isPhoneScreenSessionActive = false
        isPhoneScreenViewerVisible = false
        connectionStatus = peerDeviceId.isEmpty ? "No paired Android" : "Disconnected"
    }

    func reconnect() {
        guard let identity = localIdentity else {
            DiagnosticsLog.warn("relay.mac.reconnect_requested before_identity_ready")
            connectionStatus = "Registering"
            task?.cancel()
            task = Task { await run() }
            return
        }
        let storedPeer: PinnedPeer?
        do {
            storedPeer = try loadPreferredPeer()
        } catch {
            DiagnosticsLog.error("relay.mac.reconnect_peer_load_failed", error)
            storedPeer = nil
        }
        guard let peer = currentPeer ?? storedPeer else {
            DiagnosticsLog.warn("relay.mac.reconnect_requested no_paired_peer")
            isConnected = false
            canDisconnect = false
            connectionStatus = "No paired Android"
            return
        }

        DiagnosticsLog.info("relay.mac.reconnect_requested hostId=\(identity.deviceId) clientId=\(peer.deviceId)")
        peerName = peer.name
        peerDeviceId = DeviceID.display(peer.deviceId)
        startConnection(identity: identity, peer: peer, reason: "manual")
    }

    func quit() {
        DiagnosticsLog.info("runtime.mac.quit_requested")
        disconnect()
        NSApplication.shared.terminate(nil)
    }

    func sendSms(to rawRecipient: String, text rawText: String) {
        let recipient = rawRecipient.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !recipient.isEmpty, !text.isEmpty else {
            smsSendStatus = String(localized: "請填收件人與訊息")
            return
        }
        guard let session = currentSession, isConnected else {
            smsSendStatus = String(localized: "SMS 目前不可用")
            DiagnosticsLog.warn("sms.mac.send_ignored not_connected")
            return
        }

        let requestId = UUID().uuidString
        let body = SmsSendBody(requestId: requestId, to: recipient, text: text)
        pendingSmsSends[requestId] = body
        smsSendStatus = String(localized: "正在送出 SMS")

        Task {
            do {
                let data = try encoder.encode(Envelope(t: EnvelopeType.smsSend, b: body))
                try await session.sendPlaintext(data)
                DiagnosticsLog.info("sms.mac.send_requested requestId=\(requestId) toFp=\(Self.fingerprint(recipient))")
            } catch {
                await MainActor.run {
                    self.pendingSmsSends.removeValue(forKey: requestId)
                    self.smsSendStatus = String(localized: "SMS 送出失敗")
                }
                DiagnosticsLog.error("sms.mac.send_request_failed requestId=\(requestId)", error)
            }
        }
    }

    @discardableResult
    func dialPhone(number rawNumber: String) -> String? {
        let number = rawNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !number.isEmpty else {
            phoneCallStatus = String(localized: "請填電話號碼")
            return nil
        }
        rememberDialedPhoneNumber(number)
        return sendPhoneAction(action: "dial", number: number)
    }

    @discardableResult
    func redialLastPhoneNumber() -> String? {
        dialPhone(number: lastDialedPhoneNumber)
    }

    @discardableResult
    func answerPhoneCall() -> String? {
        sendPhoneAction(action: "answer")
    }

    @discardableResult
    func hangUpPhoneCall() -> String? {
        sendPhoneAction(action: "hangup")
    }

    @discardableResult
    func sendPhoneDTMF(sequence rawSequence: String) -> String? {
        guard isPhoneCallActive else {
            phoneCallStatus = String(localized: "通話中才能送按鍵")
            return nil
        }
        guard let sequence = Self.sanitizeDTMFSequence(rawSequence) else {
            phoneCallStatus = String(localized: "請輸入客服按鍵")
            return nil
        }
        return sendPhoneAction(action: "dtmf", number: sequence)
    }

    func sendFilesWithXiaomiHyperConnect() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.title = String(localized: "小米快傳")
        panel.prompt = String(localized: "傳送")
        guard panel.runModal() == .OK else {
            return
        }

        guard let endpoint = xiaomiMiShareDiscovery.currentPhoneMeshEndpoint(),
              let deviceIdHex = xiaomiMiShareDiscovery.localDeviceIdHex
        else {
            xiaomiMiLinkCommandStatus = String(localized: "看不到手機，請確認手機已開啟小米快傳")
            DiagnosticsLog.warn("xiaomi.mishare.send_no_phone_endpoint")
            if XiaomiHyperConnectBridge.isInstalled {
                do {
                    try XiaomiHyperConnectBridge.openTransfer(fileURLs: panel.urls)
                    xiaomiMiLinkCommandStatus = String(localized: "已交給小米快傳")
                } catch {
                    xiaomiMiLinkCommandStatus = String(localized: "小米快傳開啟失敗")
                }
            }
            return
        }

        let files = LyraFileSendSession.makeFiles(from: panel.urls)
        let session = LyraFileSendSession(
            host: endpoint.host,
            port: endpoint.port,
            deviceIdHex: deviceIdHex,
            displayName: xiaomiMiShareDiscovery.localDisplayName,
            files: files
        )
        session.onStatus = { [weak self] status in
            DispatchQueue.main.async {
                self?.xiaomiMiLinkCommandStatus = String(localized: "小米快傳：\(status)")
            }
        }
        lyraFileSendSession = session
        session.start()
        xiaomiMiLinkCommandStatus = String(localized: "小米快傳：連接手機…")
        DiagnosticsLog.info(
            "xiaomi.mishare.send_started to=\(endpoint.host):\(endpoint.port) files=\(files.count)"
        )
    }

    @discardableResult
    func openPhoneMiShare() -> String? {
        sendMiLinkCommand(command: "xiaomi.mishare.openSettings")
    }

    @discardableResult
    func probePhoneMiShareDiscovery(timeoutMs: Int = 5_000) -> String? {
        sendMiLinkCommand(
            command: "xiaomi.mishare.discover",
            args: ["timeoutMs": String(timeoutMs)]
        )
    }

    @discardableResult
    func probePhoneMiShareNsdDiscovery(timeoutMs: Int = 5_000) -> String? {
        sendMiLinkCommand(
            command: "xiaomi.mishare.nsdDiscover",
            args: ["timeoutMs": String(timeoutMs)]
        )
    }

    @discardableResult
    func probePhoneMiConnectNetworking(args: [String: String] = [:]) -> String? {
        sendMiLinkCommand(
            command: "xiaomi.mi_connect.networkingProbe",
            args: args
        )
    }

    @discardableResult
    func registerPhoneMiConnectLyraService(args: [String: String] = [:]) -> String? {
        sendMiLinkCommand(
            command: "xiaomi.mi_connect.registerLyraService",
            args: args
        )
    }

    func restartXiaomiMiShareDiscovery() {
        guard let localIdentity else {
            xiaomiMiShareDiscoveryStatus = String(localized: "小米快傳 discovery：identity 尚未就緒")
            DiagnosticsLog.warn("xiaomi.mishare.discovery_restart_ignored identity_missing")
            return
        }
        startXiaomiMiShareDiscovery(identity: localIdentity, reason: "manual_restart")
    }

    private func startXiaomiMiShareDiscovery(identity: LocalIdentity, reason: String) {
        let displayName = Host.current().localizedName ?? "EdgeLink Mac"
        xiaomiMiShareDiscovery.start(identitySeed: identity.deviceId, displayName: displayName)
        DiagnosticsLog.info(
            "xiaomi.mishare.discovery_started reason=\(reason) localDeviceId=\(identity.deviceId) displayName=\(displayName)"
        )
    }

    private func handleXiaomiMiShareDiscoverySnapshot(_ snapshot: XiaomiMiShareDiscoverySnapshot) {
        xiaomiMiShareDiscoveredPeers = snapshot.peers
        xiaomiMiSharePublishedDeviceId = snapshot.publishedDeviceIdHex ?? ""

        let publishText: String
        if snapshot.isPublishing, let deviceId = snapshot.publishedDeviceIdHex {
            publishText = String(localized: "Mac 已廣播 \(deviceId)")
        } else if snapshot.isBrowsing {
            publishText = String(localized: "Mac 廣播準備中")
        } else {
            publishText = String(localized: "Mac 尚未開始")
        }

        let peerText: String
        if snapshot.peers.isEmpty {
            peerText = String(localized: "未看到手機")
        } else {
            let names = snapshot.peers.prefix(2).map(\.displayLabel).joined(separator: "、")
            let suffix = snapshot.peers.count > 2 ? String(localized: " 等 \(snapshot.peers.count) 台") : ""
            peerText = String(localized: "看到 \(names)\(suffix)")
        }

        if let error = snapshot.lastError {
            xiaomiMiShareDiscoveryStatus = String(localized: "小米快傳 discovery：\(publishText)，\(peerText)；\(error)")
        } else {
            xiaomiMiShareDiscoveryStatus = String(localized: "小米快傳 discovery：\(publishText)，\(peerText)")
        }
    }

    func runPhoneRelayDebugCall(
        number rawNumber: String = "800",
        timeoutSeconds rawTimeout: TimeInterval = 30,
        minimumHoldSeconds rawMinimumHold: TimeInterval = 0
    ) {
        let number = rawNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.phoneRelayDebugDefaultNumber
            : rawNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let timeoutSeconds = min(max(rawTimeout, 1), Self.phoneRelayDebugMaxTimeoutSeconds)
        let minimumHoldSeconds = min(max(rawMinimumHold, 0), timeoutSeconds)
        phoneRelayDebugTask?.cancel()
        phoneRelayDebugTask = Task { [weak self] in
            await self?.runPhoneRelayDebugCallTask(
                number: number,
                timeoutSeconds: timeoutSeconds,
                minimumHoldSeconds: minimumHoldSeconds
            )
        }
    }

    private func runPhoneRelayDebugCallTask(
        number: String,
        timeoutSeconds: TimeInterval,
        minimumHoldSeconds: TimeInterval
    ) async {
        guard isConnected else {
            DiagnosticsLog.warn("phonerelay.mac.debug_call_ignored numberFp=\(Self.fingerprint(number)) not_connected")
            phoneRelayDebugTask = nil
            return
        }

        let sessionID = phoneRelayProbe.resetSinkPCMValidation(reason: "debug_call_start")
        phoneRelayDebugSessionID = sessionID
        phoneRelayDebugDialRequestID = nil
        phoneRelayDebugDialError = nil
        phoneRelayDebugLastStats = nil
        phoneRelayDebugValidStats = nil
        phoneRelayDebugLastGatewayStats = nil
        phoneRelayDebugValidGatewayStats = nil
        DiagnosticsLog.info(
            "phonerelay.mac.debug_call_start session=\(sessionID.uuidString) " +
                "numberFp=\(Self.fingerprint(number)) timeoutMs=\(Int(timeoutSeconds * 1000)) " +
                "minimumHoldMs=\(Int(minimumHoldSeconds * 1000))"
        )

        guard let dialRequestID = dialPhone(number: number) else {
            DiagnosticsLog.warn("phonerelay.mac.debug_call_dial_not_sent session=\(sessionID.uuidString)")
            phoneRelayDebugTask = nil
            return
        }
        phoneRelayDebugDialRequestID = dialRequestID

        let startedAt = Date()
        let deadline = startedAt.addingTimeInterval(timeoutSeconds)
        while !Task.isCancelled && Date() < deadline {
            if let dialError = phoneRelayDebugDialError {
                DiagnosticsLog.warn(
                    "phonerelay.mac.debug_call_dial_failed session=\(sessionID.uuidString) " +
                        "requestId=\(dialRequestID) error=\(dialError)"
                )
                phoneRelayDebugTask = nil
                return
            }
            let heldLongEnough = Date().timeIntervalSince(startedAt) >= minimumHoldSeconds
            if let gatewayStats = phoneRelayDebugValidGatewayStats,
               gatewayStats.hasValidStream,
               heldLongEnough {
                DiagnosticsLog.info("phonerelay.mac.debug_call_valid_gateway_stream \(gatewayStats.diagnosticSummary)")
                hangUpPhoneCall()
                phoneRelayDebugTask = nil
                return
            }
            if let stats = phoneRelayDebugValidStats,
               stats.sessionID == sessionID,
               stats.hasValidStream,
               heldLongEnough {
                DiagnosticsLog.info("phonerelay.mac.debug_call_valid_stream \(stats.diagnosticSummary)")
                hangUpPhoneCall()
                phoneRelayDebugTask = nil
                return
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        if Task.isCancelled {
            DiagnosticsLog.info("phonerelay.mac.debug_call_cancelled session=\(sessionID.uuidString)")
        } else {
            let lastStats = phoneRelayDebugLastStats?.diagnosticSummary ?? "none"
            let lastGatewayStats = phoneRelayDebugLastGatewayStats?.diagnosticSummary ?? "none"
            DiagnosticsLog.warn(
                "phonerelay.mac.debug_call_timeout session=\(sessionID.uuidString) " +
                    "timeoutMs=\(Int(timeoutSeconds * 1000)) lastStats=\(lastStats) " +
                    "lastGatewayStats=\(lastGatewayStats)"
            )
            hangUpPhoneCall()
        }
        phoneRelayDebugTask = nil
    }

    private func handlePhoneRelayPCMStats(_ stats: MiLinkPhoneRelayPCMStats) {
        guard stats.sessionID == phoneRelayDebugSessionID else {
            return
        }
        phoneRelayDebugLastStats = stats
        if stats.hasValidStream {
            phoneRelayDebugValidStats = stats
        }
    }

    private func handleCallRelayGatewayPlaybackStats(_ stats: CallRelayGatewayPlaybackStats) {
        guard phoneRelayDebugSessionID != nil else {
            return
        }
        phoneRelayDebugLastGatewayStats = stats
        if stats.hasValidStream {
            phoneRelayDebugValidGatewayStats = stats
        }
    }

    private func handleExternalURL(_ url: URL) {
        guard url.scheme?.lowercased() == "edgelink" else {
            DiagnosticsLog.warn("runtime.mac.url_ignored scheme=\(url.scheme ?? "none")")
            return
        }
        let command = Self.externalURLCommand(url)
        switch command {
        case "debug-phone-relay", "phone-relay-debug":
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let queryItems = components?.queryItems ?? []
            let number = queryItems.first { $0.name == "number" }?.value ?? Self.phoneRelayDebugDefaultNumber
            let timeout = queryItems.first { $0.name == "timeout" || $0.name == "timeoutSeconds" }?.value
                .flatMap(TimeInterval.init) ?? Self.phoneRelayDebugMaxTimeoutSeconds
            let minimumHold = queryItems.first { $0.name == "hold" || $0.name == "holdSeconds" }?.value
                .flatMap(TimeInterval.init) ?? 0
            DiagnosticsLog.info(
                "runtime.mac.url_debug_phone_relay numberFp=\(Self.fingerprint(number)) " +
                    "timeoutMs=\(Int(min(max(timeout, 1), Self.phoneRelayDebugMaxTimeoutSeconds) * 1000)) " +
                    "minimumHoldMs=\(Int(min(max(minimumHold, 0), timeout) * 1000))"
            )
            runPhoneRelayDebugCall(
                number: number,
                timeoutSeconds: timeout,
                minimumHoldSeconds: minimumHold
            )
        case "view-phone-screen", "phone-screen", "screen":
            DiagnosticsLog.info("runtime.mac.url_view_phone_screen")
            viewPhoneScreen()
        case "xiaomi-mirror-rtsp", "xiaomi-mirror-rtsp-listener", "mirror-rtsp":
            let args = Self.externalURLQueryArgs(url)
            let requestedPeerHost = args["peerHost"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let peerHost = requestedPeerHost?.isEmpty == false ? requestedPeerHost : Self.xiaomiMirrorAdvertisedHost()
            DiagnosticsLog.info(
                "runtime.mac.url_xiaomi_mirror_rtsp_listener peerHost=\(peerHost ?? "none") args=\(args)"
            )
            startXiaomiMirrorRTSPDiagnosticSourceIfNeeded(peerHost: peerHost, reason: "url")
        case "xiaomi-mirror-rtsp-client", "mirror-rtsp-client":
            let args = Self.externalURLQueryArgs(url)
            guard let host = args["host"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !host.isEmpty,
                  let rawPort = args["port"],
                  let port = UInt16(rawPort) else {
                DiagnosticsLog.warn("runtime.mac.url_xiaomi_mirror_rtsp_client_invalid args=\(args)")
                return
            }
            DiagnosticsLog.info(
                "runtime.mac.url_xiaomi_mirror_rtsp_client host=\(host) port=\(port) args=\(args)"
            )
            connectXiaomiMirrorRTSPDiagnosticSource(host: host, port: port, reason: "url")
        case "xiaomi-mishare", "mishare":
            DiagnosticsLog.info("runtime.mac.url_xiaomi_mishare")
            openPhoneMiShare()
        case "xiaomi-mishare-discover", "mishare-discover":
            DiagnosticsLog.info("runtime.mac.url_xiaomi_mishare_discover")
            probePhoneMiShareDiscovery()
        case "xiaomi-mishare-nsd-discover", "mishare-nsd-discover":
            DiagnosticsLog.info("runtime.mac.url_xiaomi_mishare_nsd_discover")
            probePhoneMiShareNsdDiscovery()
        case "xiaomi-networking-probe", "mi-connect-networking-probe", "miconnect-networking-probe":
            let args = Self.externalURLQueryArgs(url)
            DiagnosticsLog.info("runtime.mac.url_xiaomi_networking_probe args=\(args)")
            probePhoneMiConnectNetworking(args: args)
        case "xiaomi-networking-register", "mi-connect-networking-register", "miconnect-networking-register":
            let args = Self.externalURLQueryArgs(url)
            DiagnosticsLog.info("runtime.mac.url_xiaomi_networking_register args=\(args)")
            registerPhoneMiConnectLyraService(args: args)
        default:
            DiagnosticsLog.warn("runtime.mac.url_ignored command=\(command)")
        }
    }

    private static func externalURLCommand(_ url: URL) -> String {
        if let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines),
           !host.isEmpty {
            return host.lowercased()
        }
        return url.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
    }

    private static func externalURLQueryArgs(_ url: URL) -> [String: String] {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        var args: [String: String] = [:]
        for item in items {
            guard let value = item.value else {
                continue
            }
            args[item.name] = value
        }
        return args
    }

    private func rememberDialedPhoneNumber(_ number: String) {
        guard lastDialedPhoneNumber != number else {
            return
        }
        lastDialedPhoneNumber = number
        UserDefaults.standard.set(number, forKey: Self.lastDialedPhoneNumberDefaultsKey)
    }

    private func ensurePhoneRelayProbeEnabled(reason: String) {
        guard !phoneRelayProbeRunning else {
            return
        }
        DiagnosticsLog.info("phonerelay.mac.probe_auto_start reason=\(reason)")
        startPhoneRelayProbe()
    }

    private func startPhoneRelayProbe() {
        do {
            let peerHost = UserDefaults.standard.string(forKey: Self.phoneRelayProbePeerHostDefaultsKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let peerPort = Self.phoneRelayProbePeerPort()
            try phoneRelayProbe.start(
                port: Self.phoneRelayProbePort,
                peerHost: peerHost?.isEmpty == false ? peerHost : nil,
                peerPort: peerPort
            )
            phoneRelayProbeRunning = true
            let peerDescription: String
            if let peerHost, !peerHost.isEmpty {
                peerDescription = "\(peerHost):\(peerPort)"
            } else {
                peerDescription = "none"
            }
            DiagnosticsLog.info(
                "phonerelay.mac.probe_auto_started port=\(Self.phoneRelayProbePort) " +
                    "peer=\(peerDescription)"
            )
        } catch {
            phoneRelayProbeRunning = false
            DiagnosticsLog.error("phonerelay.mac.probe_start_failed port=\(Self.phoneRelayProbePort)", error)
        }
    }

    private func stopPhoneRelayProbe(reason: String) {
        guard phoneRelayProbeRunning else {
            return
        }
        phoneRelayProbeRunning = false
        phoneRelayProbe.stop()
        DiagnosticsLog.info("phonerelay.mac.probe_auto_stopped reason=\(reason)")
    }

    private func startXiaomiMirrorRTSPDiagnosticSourceIfNeeded(peerHost: String?, reason: String) {
        guard Self.xiaomiMirrorRTSPDiagnosticEnabled() else {
            DiagnosticsLog.info(
                "xiaomi.mirror.rtsp.listener_start_skipped reason=\(reason) disabled=true " +
                    "defaultsKey=\(Self.xiaomiMirrorRTSPDiagnosticEnabledDefaultsKey)"
            )
            return
        }
        guard !phoneRelayProbeRunning else {
            DiagnosticsLog.warn(
                "xiaomi.mirror.rtsp.listener_start_skipped reason=\(reason) phoneRelayProbeRunning=true " +
                    "port=\(Self.xiaomiMirrorRTSPDiagnosticPort)"
            )
            return
        }
        do {
            try xiaomiMirrorRTSPDiagnosticSource.start(
                port: Self.xiaomiMirrorRTSPDiagnosticPort,
                advertisedHost: peerHost,
                lifetime: Self.xiaomiMirrorRTSPDiagnosticLifetimeSeconds
            )
            DiagnosticsLog.info(
                "xiaomi.mirror.rtsp.listener_auto_started reason=\(reason) " +
                    "port=\(Self.xiaomiMirrorRTSPDiagnosticPort) advertisedHost=\(peerHost ?? "none")"
            )
        } catch {
            DiagnosticsLog.error(
                "xiaomi.mirror.rtsp.listener_start_failed reason=\(reason) port=\(Self.xiaomiMirrorRTSPDiagnosticPort)",
                error
            )
        }
    }

    private func stopXiaomiMirrorRTSPDiagnosticSource(reason: String) {
        didPrepareXiaomiMirrorKeyboard = false
        xiaomiMirrorKeyboardReadyLastAttemptAt = .distantPast
        xiaomiMirrorRTSPDiagnosticSource.stop(reason: reason)
    }

    private func connectXiaomiMirrorRTSPDiagnosticSource(host: String, port: UInt16, reason: String) {
        guard Self.xiaomiMirrorRTSPDiagnosticEnabled() else {
            DiagnosticsLog.info(
                "xiaomi.mirror.rtsp.active_client_start_skipped reason=\(reason) disabled=true " +
                    "defaultsKey=\(Self.xiaomiMirrorRTSPDiagnosticEnabledDefaultsKey)"
            )
            return
        }
        do {
            try xiaomiMirrorRTSPDiagnosticSource.connect(
                host: host,
                port: port,
                advertisedHost: Self.xiaomiMirrorAdvertisedHost(),
                lifetime: Self.xiaomiMirrorRTSPDiagnosticLifetimeSeconds
            )
            DiagnosticsLog.info(
                "xiaomi.mirror.rtsp.active_client_auto_started reason=\(reason) " +
                    "host=\(host) port=\(port)"
            )
        } catch {
            DiagnosticsLog.error(
                "xiaomi.mirror.rtsp.active_client_start_failed reason=\(reason) host=\(host) port=\(port)",
                error
            )
        }
    }

    private func startNewXiaomiMirrorCloudflareSessionIfEnabled(reason: String) -> String? {
        guard Self.xiaomiMirrorCloudflareMediaEnabled() else {
            activeXiaomiMirrorCloudflareSessionId = nil
            xiaomiMirrorRTSPDiagnosticSource.stopCloudflareMirrorRTPReceiver(reason: "\(reason)_disabled")
            return nil
        }
        let sessionId = UUID().uuidString
        activeXiaomiMirrorCloudflareSessionId = sessionId
        DiagnosticsLog.info(
            "xiaomi.mirror.cloudflare.session_created reason=\(reason) sessionId=\(sessionId)"
        )
        return sessionId
    }

    private func addXiaomiMirrorCloudflareArgs(to args: inout [String: String], sessionId: String?) {
        guard let sessionId else {
            return
        }
        args["mediaTransport"] = "cloudflare"
        args["mirrorSessionId"] = sessionId
        args["rtpEnvelope"] = EnvelopeType.miLinkMirrorMedia
    }

    private func addXiaomiMirrorLANProbeArgs(to args: inout [String: String], peerHost: String?) {
        guard Self.xiaomiMirrorRTSPDiagnosticEnabled(),
              peerHost?.isEmpty == false,
              lanTransport.isReachabilityProbeReady,
              xiaomiMirrorRTSPDiagnosticSource.isListenerReady() else {
            return
        }
        args["lanProbePort"] = String(LANTransport.reachabilityProbePort)
    }

    private func xiaomiMirrorCloudflareSessionIdForRecovery(rebuildSession: Bool, reason: String) -> String? {
        guard Self.xiaomiMirrorCloudflareMediaEnabled() else {
            activeXiaomiMirrorCloudflareSessionId = nil
            return nil
        }
        if rebuildSession || activeXiaomiMirrorCloudflareSessionId == nil {
            return startNewXiaomiMirrorCloudflareSessionIfEnabled(reason: reason)
        }
        return activeXiaomiMirrorCloudflareSessionId
    }

    private func handleXiaomiMirrorRTSPRecoveryRequired(_ event: XiaomiMirrorRTSPRecoveryEvent) {
        guard !xiaomiScreenUserStopped else {
            DiagnosticsLog.info(
                "xiaomi.mac.screen_recovery_suppressed reason=user_stopped " +
                    "rtspSession=\(event.sessionID.uuidString) trigger=\(event.trigger) stallReason=\(event.reason)"
            )
            return
        }
        guard isConnected else {
            DiagnosticsLog.warn(
                "xiaomi.mac.screen_recovery_skipped reason=not_connected " +
                    "rtspSession=\(event.sessionID.uuidString) trigger=\(event.trigger)"
            )
            return
        }
        if let pending = pendingXiaomiScreenFallback {
            DiagnosticsLog.info(
                "xiaomi.mac.screen_recovery_suppressed reason=already_pending phase=event " +
                    "rtspSession=\(event.sessionID.uuidString) pendingRequestId=\(pending.requestId) " +
                    "pendingElapsedMs=\(pending.elapsedMs)"
            )
            return
        }
        guard xiaomiScreenRecoveryTask == nil else {
            DiagnosticsLog.info(
                "xiaomi.mac.screen_recovery_suppressed reason=already_recovering phase=event " +
                    "rtspSession=\(event.sessionID.uuidString) attempt=\(xiaomiScreenRecoveryAttempt)"
            )
            return
        }
        if shouldSuppressXiaomiScreenRecoveryForCooldown(event: event, phase: "event") {
            return
        }
        if Self.isXiaomiScreenFrameStall(event.reason),
           !Self.shouldEscalateXiaomiScreenFrameStallToSessionRebuild(event),
           shouldSuppressXiaomiScreenSourceRecoveryForCooldown(event: event, phase: "event_before_attempt") {
            return
        }
        let attempt = xiaomiScreenRecoveryAttempt + 1
        xiaomiScreenRecoveryAttempt = attempt
        let recoveryWillRebuildSession = Self.shouldRebuildXiaomiScreenSession(event: event, attempt: attempt)
        if recoveryWillRebuildSession || !isPhoneScreenSessionActive {
            xiaomiMiLinkCommandStatus = String(localized: "小米鏡像恢復中")
        }
        if attempt > Self.xiaomiScreenRecoveryHighAttemptWarningThreshold {
            DiagnosticsLog.warn(
                "xiaomi.mac.screen_recovery_continuing rtspSession=\(event.sessionID.uuidString) " +
                    "trigger=\(event.trigger) reason=\(event.reason) attempt=\(attempt) " +
                    "lastMediaSeconds=\(Self.formatSeconds(event.elapsedMediaSeconds)) " +
                    "lastFrameSeconds=\(Self.formatOptionalSeconds(event.elapsedFrameSeconds)) " +
                    "pushReceived=\(event.pushReceived) inboundRTP=\(event.inboundRTP) decodedFrames=\(event.decodedFrames)"
            )
        }
        DiagnosticsLog.warn(
            "xiaomi.mac.screen_recovery_requested rtspSession=\(event.sessionID.uuidString) " +
                "trigger=\(event.trigger) reason=\(event.reason) attempt=\(attempt) " +
                "sourceEndpoint=\(event.host ?? "none"):\(event.port.map(String.init) ?? "none") " +
                "lastMediaSeconds=\(Self.formatSeconds(event.elapsedMediaSeconds)) " +
                "lastFrameSeconds=\(Self.formatOptionalSeconds(event.elapsedFrameSeconds)) " +
                "datagrams=\(event.datagramsReceived) pushReceived=\(event.pushReceived) " +
                "inboundRTP=\(event.inboundRTP) decodedFrames=\(event.decodedFrames)"
        )
        xiaomiScreenRecoveryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.xiaomiScreenRecoveryDelayNanoseconds)
            await MainActor.run {
                guard let self else {
                    return
                }
                self.xiaomiScreenRecoveryTask = nil
                self.startXiaomiMirrorRecoveryCommand(event: event, attempt: attempt)
            }
        }
    }

    private func startXiaomiMirrorRecoveryCommand(event: XiaomiMirrorRTSPRecoveryEvent, attempt: Int) {
        guard !xiaomiScreenUserStopped else {
            DiagnosticsLog.info(
                "xiaomi.mac.screen_recovery_suppressed reason=user_stopped_after_delay " +
                    "rtspSession=\(event.sessionID.uuidString) attempt=\(attempt) stallReason=\(event.reason)"
            )
            return
        }
        if let pending = pendingXiaomiScreenFallback {
            DiagnosticsLog.info(
                "xiaomi.mac.screen_recovery_suppressed reason=already_pending phase=after_delay " +
                    "rtspSession=\(event.sessionID.uuidString) pendingRequestId=\(pending.requestId) " +
                    "pendingElapsedMs=\(pending.elapsedMs)"
            )
            return
        }
        if shouldSuppressXiaomiScreenRecoveryForCooldown(event: event, phase: "after_delay") {
            return
        }
        let preferredScreenRoute = latestMiLinkStatus?.preferredRoutes?["screen"]
        guard let xiaomiScreenRoute = Self.xiaomiScreenRouteCandidate(
            from: latestMiLinkStatus,
            preferredRoute: preferredScreenRoute
        ), xiaomiScreenRoute.hasPrefix("xiaomi.") else {
            DiagnosticsLog.warn(
                "xiaomi.mac.screen_recovery_skipped reason=xiaomi_route_missing " +
                    "rtspSession=\(event.sessionID.uuidString) preferredRoute=\(preferredScreenRoute ?? "unknown")"
            )
            return
        }
        guard Self.allowXiaomiScreenPrimaryRoute else {
            xiaomiMiLinkCommandStatus = String(localized: "小米鏡像已停用")
            DiagnosticsLog.warn(
                "xiaomi.mac.screen_recovery_skipped reason=disabled_by_user_default " +
                    "rtspSession=\(event.sessionID.uuidString) route=\(xiaomiScreenRoute)"
            )
            return
        }

        let peerHost = Self.xiaomiMirrorAdvertisedHost()
        let peerPort = Self.xiaomiMirrorRTSPDiagnosticPort
        let shouldRebuildSession = Self.shouldRebuildXiaomiScreenSession(event: event, attempt: attempt)
        let cloudflareMirrorSessionId = xiaomiMirrorCloudflareSessionIdForRecovery(
            rebuildSession: shouldRebuildSession,
            reason: shouldRebuildSession ? "session_rebuild" : "source_recovery"
        )
        if shouldRebuildSession {
            let command = "xiaomi.mirror.startMainDisplay"
            let timeoutMs = Self.xiaomiScreenSessionRebuildTimeoutMs
            stopXiaomiMirrorRTSPDiagnosticSource(reason: "screen_recovery_session_rebuild")
            startXiaomiMirrorRTSPDiagnosticSourceIfNeeded(peerHost: peerHost, reason: "screen_recovery_session_rebuild")
            var args: [String: String] = [
                "peerPort": String(peerPort),
                "forceFakeRemote": "true",
                "recovery": "true",
                "sessionRecovery": "true",
                "recoveryAttempt": String(attempt),
                "recoveryReason": event.reason
            ]
            if let peerHost {
                args["peerHost"] = peerHost
            }
            addXiaomiMirrorLANProbeArgs(to: &args, peerHost: peerHost)
            addXiaomiMirrorCloudflareArgs(to: &args, sessionId: cloudflareMirrorSessionId)
            DiagnosticsLog.warn(
                "xiaomi.mac.screen_recovery_command_start command=\(command) route=\(xiaomiScreenRoute) " +
                    "attempt=\(attempt) trigger=\(event.trigger) reason=\(event.reason) " +
                    "peerHost=\(peerHost ?? "default") peerPort=\(peerPort) fakeRemote=true " +
                    "action=session_rebuild timeoutMs=\(timeoutMs) " +
                    "mediaTransport=\(cloudflareMirrorSessionId == nil ? "direct" : "cloudflare") " +
                    "cloudSessionId=\(cloudflareMirrorSessionId ?? "none")"
            )
            guard let requestId = sendMiLinkCommand(command: command, args: args) else {
                xiaomiMiLinkCommandStatus = String(localized: "小米鏡像重建指令未送出")
                DiagnosticsLog.warn(
                    "xiaomi.mac.screen_recovery_command_failed_before_send route=\(xiaomiScreenRoute) " +
                        "attempt=\(attempt) reason=\(event.reason) action=session_rebuild"
                )
                return
            }
            markXiaomiScreenSessionRebuildStarted(
                requestId: requestId,
                sourceSessionID: event.sessionID,
                reason: event.reason
            )
            if let cloudflareMirrorSessionId {
                xiaomiMirrorRTSPDiagnosticSource.startCloudflareMirrorRTPReceiver(
                    sessionId: cloudflareMirrorSessionId,
                    lifetime: Self.xiaomiMirrorRTSPDiagnosticLifetimeSeconds,
                    reason: "screen_recovery_session_rebuild"
                )
            }
            armPendingXiaomiScreenCommand(
                requestId: requestId,
                command: command,
                route: xiaomiScreenRoute,
                timeoutMs: timeoutMs
            )
            xiaomiMiLinkCommandStatus = String(localized: "小米鏡像重建連線中")
            DiagnosticsLog.info(
                "xiaomi.mac.screen_recovery_command_sent requestId=\(requestId) " +
                    "command=\(command) attempt=\(attempt) action=session_rebuild"
            )
            return
        }
        if shouldSuppressXiaomiScreenSourceRecoveryForCooldown(event: event, phase: "after_rebuild_decision") {
            return
        }

        let command = "xiaomi.mirror.requestSourceRecovery"
        var args: [String: String] = [
            "peerPort": String(peerPort),
            "forceFakeRemote": "true",
            "recovery": "true",
            "sourceRecoveryOnly": "true",
            "recoveryAttempt": String(attempt),
            "recoveryReason": event.reason
        ]
        if let peerHost {
            args["peerHost"] = peerHost
        }
        addXiaomiMirrorLANProbeArgs(to: &args, peerHost: peerHost)
        addXiaomiMirrorCloudflareArgs(to: &args, sessionId: cloudflareMirrorSessionId)
        DiagnosticsLog.warn(
            "xiaomi.mac.screen_recovery_command_start command=\(command) route=\(xiaomiScreenRoute) " +
                "attempt=\(attempt) trigger=\(event.trigger) reason=\(event.reason) " +
                "peerHost=\(peerHost ?? "default") peerPort=\(peerPort) fakeRemote=true " +
                "action=source_only_keep_rtsp " +
                "mediaTransport=\(cloudflareMirrorSessionId == nil ? "direct" : "cloudflare") " +
                "cloudSessionId=\(cloudflareMirrorSessionId ?? "none")"
        )
        guard let requestId = sendMiLinkCommand(command: command, args: args) else {
            xiaomiMiLinkCommandStatus = String(localized: "小米鏡像恢復指令未送出")
            DiagnosticsLog.warn(
                "xiaomi.mac.screen_recovery_command_failed_before_send route=\(xiaomiScreenRoute) " +
                    "attempt=\(attempt) reason=\(event.reason)"
            )
            return
        }
        markXiaomiScreenSourceRecoveryStarted(
            requestId: requestId,
            sourceSessionID: event.sessionID,
            reason: event.reason,
            decodedFrames: event.decodedFrames
        )
        if !isPhoneScreenSessionActive {
            xiaomiMiLinkCommandStatus = String(localized: "小米鏡像要求來源刷新")
        }
        DiagnosticsLog.info(
            "xiaomi.mac.screen_recovery_command_sent requestId=\(requestId) " +
                "command=\(command) attempt=\(attempt) action=source_only_keep_rtsp"
        )
    }

    private func handleXiaomiMirrorPeerStop(reason: String, sessionID: UUID, generation: UInt64) {
        guard xiaomiMirrorRTSPDiagnosticSource.shouldHonorPeerStop(generation: generation) else {
            DiagnosticsLog.info(
                "xiaomi.mac.screen_peer_stop_ignored session=\(sessionID.uuidString) reason=\(reason) " +
                    "generation=\(generation) cause=stale_or_replaced_session"
            )
            return
        }
        stopXiaomiScreenRouteForUser(reason: reason)
        screenSession.hideWindowAndStop(sendRemoteStop: false)
        isPhoneScreenSessionActive = false
        isPhoneScreenViewerVisible = false
        DiagnosticsLog.info(
            "xiaomi.mac.screen_peer_stop session=\(sessionID.uuidString) reason=\(reason) recoverySuppressed=true"
        )
    }

    private func stopXiaomiScreenRouteForUser(reason: String) {
        xiaomiScreenUserStopped = true
        releaseXiaomiMirrorKeyboard(reason: reason)
        pendingXiaomiScreenFallbackTask?.cancel()
        pendingXiaomiScreenFallbackTask = nil
        pendingXiaomiScreenFallback = nil
        xiaomiScreenRecoveryTask?.cancel()
        xiaomiScreenRecoveryTask = nil
        xiaomiScreenRecoveryAttempt = 0
        resetXiaomiScreenRecoveryState(reason: reason)
        activeXiaomiMirrorCloudflareSessionId = nil
        stopXiaomiMirrorRTSPDiagnosticSource(reason: reason)
        DiagnosticsLog.info(
            "xiaomi.mac.screen_stop_cleanup reason=\(reason) recoverySuppressed=true"
        )
    }

    private func shouldSuppressXiaomiScreenRecoveryForCooldown(
        event: XiaomiMirrorRTSPRecoveryEvent,
        phase: String
    ) -> Bool {
        let now = Date()
        let elapsed = now.timeIntervalSince(xiaomiScreenLastSessionRebuildAt)
        guard elapsed >= 0,
              elapsed < Self.xiaomiScreenSessionRebuildCooldownSeconds else {
            return false
        }
        let remainingMs = Int((Self.xiaomiScreenSessionRebuildCooldownSeconds - elapsed) * 1_000)
        let reason = xiaomiScreenLastSessionRebuildSourceSessionID == event.sessionID ? "stale_session" : "cooldown"
        DiagnosticsLog.info(
            "xiaomi.mac.screen_recovery_suppressed reason=\(reason) phase=\(phase) " +
                "rtspSession=\(event.sessionID.uuidString) " +
                "lastRebuildSession=\(xiaomiScreenLastSessionRebuildSourceSessionID?.uuidString ?? "none") " +
                "lastRebuildRequestId=\(xiaomiScreenLastSessionRebuildRequestID ?? "none") " +
                "trigger=\(event.trigger) stallReason=\(event.reason) " +
                "cooldownRemainingMs=\(max(0, remainingMs))"
        )
        return true
    }

    private func markXiaomiScreenSessionRebuildStarted(
        requestId: String,
        sourceSessionID: UUID,
        reason: String
    ) {
        xiaomiScreenLastSessionRebuildAt = Date()
        xiaomiScreenLastSessionRebuildSourceSessionID = sourceSessionID
        xiaomiScreenLastSessionRebuildRequestID = requestId
        DiagnosticsLog.info(
            "xiaomi.mac.screen_recovery_rebuild_cooldown_started requestId=\(requestId) " +
                "sourceSession=\(sourceSessionID.uuidString) reason=\(reason) " +
                "cooldownMs=\(Int(Self.xiaomiScreenSessionRebuildCooldownSeconds * 1_000))"
        )
    }

    private func resetXiaomiScreenRecoveryState(reason: String) {
        xiaomiScreenLastSessionRebuildAt = .distantPast
        xiaomiScreenLastSessionRebuildSourceSessionID = nil
        xiaomiScreenLastSessionRebuildRequestID = nil
        xiaomiScreenLastSourceRecoveryAt = .distantPast
        xiaomiScreenLastSourceRecoverySessionID = nil
        xiaomiScreenLastSourceRecoveryRequestID = nil
        xiaomiScreenLastSourceRecoveryDecodedFrames = nil
        DiagnosticsLog.info("xiaomi.mac.screen_recovery_state_reset reason=\(reason)")
    }

    private static func xiaomiScreenSourceRecoveryCooldown(forDecodedFrames decodedFrames: UInt64?) -> TimeInterval {
        guard let decodedFrames, decodedFrames >= xiaomiScreenStartupDecodedFrameThreshold else {
            return xiaomiScreenSourceRecoveryStartupCooldownSeconds
        }
        return xiaomiScreenSourceRecoveryCooldownSeconds
    }

    private func shouldSuppressXiaomiScreenSourceRecoveryForCooldown(
        event: XiaomiMirrorRTSPRecoveryEvent,
        phase: String
    ) -> Bool {
        if Self.isXiaomiScreenFrameStall(event.reason),
           xiaomiScreenLastSourceRecoverySessionID == event.sessionID,
           let lastDecodedFrames = xiaomiScreenLastSourceRecoveryDecodedFrames,
           event.decodedFrames < lastDecodedFrames {
            xiaomiScreenLastSourceRecoveryDecodedFrames = nil
            DiagnosticsLog.info(
                "xiaomi.mac.screen_recovery_source_counter_reset phase=\(phase) " +
                    "rtspSession=\(event.sessionID.uuidString) " +
                    "lastSourceRequestId=\(xiaomiScreenLastSourceRecoveryRequestID ?? "none") " +
                    "trigger=\(event.trigger) stallReason=\(event.reason) " +
                    "decodedFrames=\(event.decodedFrames) lastSourceDecodedFrames=\(lastDecodedFrames)"
            )
        } else if Self.isXiaomiScreenFrameStall(event.reason),
                  xiaomiScreenLastSourceRecoverySessionID == event.sessionID,
                  let lastDecodedFrames = xiaomiScreenLastSourceRecoveryDecodedFrames,
                  event.decodedFrames == lastDecodedFrames {
            DiagnosticsLog.info(
                "xiaomi.mac.screen_recovery_suppressed reason=source_recovery_no_decode_progress " +
                    "phase=\(phase) rtspSession=\(event.sessionID.uuidString) " +
                    "lastSourceRequestId=\(xiaomiScreenLastSourceRecoveryRequestID ?? "none") " +
                    "trigger=\(event.trigger) stallReason=\(event.reason) " +
                    "decodedFrames=\(event.decodedFrames) lastSourceDecodedFrames=\(lastDecodedFrames)"
            )
            return true
        }
        let now = Date()
        let cooldownSeconds = Self.xiaomiScreenSourceRecoveryCooldown(forDecodedFrames: event.decodedFrames)
        let elapsed = now.timeIntervalSince(xiaomiScreenLastSourceRecoveryAt)
        guard elapsed >= 0,
              elapsed < cooldownSeconds else {
            return false
        }
        let remainingMs = Int((cooldownSeconds - elapsed) * 1_000)
        let reason = xiaomiScreenLastSourceRecoverySessionID == event.sessionID ? "source_cooldown_same_session" : "source_cooldown"
        DiagnosticsLog.info(
            "xiaomi.mac.screen_recovery_suppressed reason=\(reason) phase=\(phase) " +
                "rtspSession=\(event.sessionID.uuidString) " +
                "lastSourceSession=\(xiaomiScreenLastSourceRecoverySessionID?.uuidString ?? "none") " +
                "lastSourceRequestId=\(xiaomiScreenLastSourceRecoveryRequestID ?? "none") " +
                "trigger=\(event.trigger) stallReason=\(event.reason) " +
                "cooldownRemainingMs=\(max(0, remainingMs))"
        )
        return true
    }

    private func markXiaomiScreenSourceRecoveryStarted(
        requestId: String,
        sourceSessionID: UUID,
        reason: String,
        decodedFrames: UInt64
    ) {
        xiaomiScreenLastSourceRecoveryAt = Date()
        xiaomiScreenLastSourceRecoverySessionID = sourceSessionID
        xiaomiScreenLastSourceRecoveryRequestID = requestId
        xiaomiScreenLastSourceRecoveryDecodedFrames = decodedFrames
        DiagnosticsLog.info(
            "xiaomi.mac.screen_recovery_source_cooldown_started requestId=\(requestId) " +
                "sourceSession=\(sourceSessionID.uuidString) reason=\(reason) " +
                "decodedFrames=\(decodedFrames) " +
                "cooldownMs=\(Int(Self.xiaomiScreenSourceRecoveryCooldown(forDecodedFrames: decodedFrames) * 1_000))"
        )
    }

    private static func shouldRebuildXiaomiScreenSession(
        event: XiaomiMirrorRTSPRecoveryEvent,
        attempt: Int
    ) -> Bool {
        if event.reason == "rtsp_keepalive_missed" {
            return true
        }
        if event.reason == "no_packets_beyond_6s" {
            let mediaGate = event.decodedFrames < Self.xiaomiScreenStartupDecodedFrameThreshold
                ? Self.xiaomiScreenSessionRebuildStartupNoPacketSeconds
                : Self.xiaomiScreenSessionRebuildAfterNoPacketSeconds
            return attempt > xiaomiScreenSourceRecoveryMaxAttempts &&
                event.elapsedMediaSeconds >= mediaGate
        }
        if Self.isXiaomiScreenFrameStall(event.reason) {
            return shouldEscalateXiaomiScreenFrameStallToSessionRebuild(event)
        }
        if attempt > xiaomiScreenSourceRecoveryMaxAttempts {
            return true
        }
        if let elapsedFrameSeconds = event.elapsedFrameSeconds,
           elapsedFrameSeconds >= xiaomiScreenSessionRebuildAfterNoFrameSeconds {
            return true
        }
        return false
    }

    private static func isXiaomiScreenFrameStall(_ reason: String) -> Bool {
        reason == "decoded_frame_stalled_beyond_threshold" ||
            reason.hasPrefix("decoded_frame_stalled")
    }

    private static func shouldEscalateXiaomiScreenFrameStallToSessionRebuild(
        _ event: XiaomiMirrorRTSPRecoveryEvent
    ) -> Bool {
        guard let elapsedFrameSeconds = event.elapsedFrameSeconds else {
            return false
        }
        return elapsedFrameSeconds >= xiaomiScreenSessionRebuildAfterNoFrameSeconds
    }

    private func startXiaomiMirrorRTSPDiagnosticSourceOnLaunchIfNeeded() {
        guard Self.allowXiaomiScreenPrimaryRoute else {
            return
        }
        startXiaomiMirrorRTSPDiagnosticSourceIfNeeded(
            peerHost: Self.xiaomiMirrorAdvertisedHost(),
            reason: "runtime_launch"
        )
    }

    private func freshTurnCredential() -> TurnCredentialSnapshot? {
        guard let latestTurnCredential, latestTurnCredential.isFresh() else {
            return nil
        }
        screenSession.setIceServerConfigs(latestTurnCredential.iceServers)
        return latestTurnCredential
    }

    @discardableResult
    private func ensureTurnCredentials(reason: String) async -> TurnCredentialSnapshot? {
        if let credential = freshTurnCredential() {
            DiagnosticsLog.info("turn.mac.credentials_reuse reason=\(reason) \(credential.diagnosticSummary)")
            return credential
        }
        guard let identity = localIdentity else {
            DiagnosticsLog.warn("turn.mac.credentials_ignored reason=\(reason) no_identity")
            return nil
        }
        let connectionGeneration = currentConnectionGeneration
        let hostId = identity.deviceId

        if let turnCredentialTask {
            DiagnosticsLog.info("turn.mac.credentials_join_inflight reason=\(reason) hostId=\(hostId)")
            let credential = await turnCredentialTask.value
            if let credential, currentConnectionGeneration == connectionGeneration {
                latestTurnCredential = credential
                screenSession.setIceServerConfigs(credential.iceServers)
            }
            return credential
        }

        DiagnosticsLog.info("turn.mac.credentials_fetch_start reason=\(reason) hostId=\(hostId)")
        let client = turnCredentialClient
        let task = Task { () -> TurnCredentialSnapshot? in
            do {
                return try await client.fetch(hostId: hostId, identity: identity)
            } catch {
                DiagnosticsLog.error("turn.mac.credentials_fetch_failed reason=\(reason) hostId=\(hostId)", error)
                return nil
            }
        }
        turnCredentialTask = task
        let credential = await task.value
        turnCredentialTask = nil

        guard currentConnectionGeneration == connectionGeneration else {
            DiagnosticsLog.warn("turn.mac.credentials_discarded_stale reason=\(reason) hostId=\(hostId)")
            return nil
        }
        guard let credential else {
            screenSession.setIceServerConfigs([])
            return nil
        }
        latestTurnCredential = credential
        screenSession.setIceServerConfigs(credential.iceServers)
        DiagnosticsLog.info("turn.mac.credentials_ready reason=\(reason) hostId=\(hostId) \(credential.diagnosticSummary)")
        return credential
    }

    @discardableResult
    private func sendMiLinkCommand(
        command: String,
        args: [String: String] = [:],
        updatesStatus: Bool = true
    ) -> String? {
        guard let session = currentSession, isConnected else {
            if updatesStatus {
                xiaomiMiLinkCommandStatus = String(localized: "小米服務目前未連線")
            }
            DiagnosticsLog.warn("xiaomi.mac.command_ignored command=\(command) not_connected")
            return nil
        }

        let requestId = UUID().uuidString
        let body = MiLinkCommandBody(
            requestId: requestId,
            command: command,
            args: args,
            ts: Int64(Date().timeIntervalSince1970)
        )
        if updatesStatus {
            xiaomiMiLinkCommandStatus = String(localized: "小米服務執行中")
        }
        Task { @MainActor [weak self] in
            await self?.sendMiLinkCommandBody(body, session: session)
        }
        return requestId
    }

    @discardableResult
    private func sendXiaomiMirrorKeyboardEvent(_ event: NSEvent, isDown: Bool) -> Bool {
        prepareXiaomiMirrorKeyboardIfNeeded(source: "key_event")
        guard let androidKeyCode = Self.androidKeyCode(forMacKeyCode: event.keyCode, characters: event.charactersIgnoringModifiers) else {
            DiagnosticsLog.warn(
                "xiaomi.mac.keyboard_ignored reason=unmapped macKeyCode=\(event.keyCode) down=\(isDown)"
            )
            return false
        }
        let args = Self.xiaomiMirrorKeyboardArgs(
            androidKeyCode: androidKeyCode,
            event: event,
            isDown: isDown
        )
        _ = sendMiLinkCommand(
            command: Self.xiaomiMirrorKeyboardCommand,
            args: args,
            updatesStatus: false
        )
        DiagnosticsLog.info(
            "xiaomi.mac.keyboard_sent macKeyCode=\(event.keyCode) androidKeyCode=\(androidKeyCode) " +
                "down=\(isDown) modifiers=\(args["modifiers"] ?? "-")"
        )
        return true
    }

    @discardableResult
    private func sendXiaomiMirrorPointer(_ body: CtrlPointerBody) -> Bool {
        let meta = screenSession.screenMeta
        var args = [
            "action": body.action,
            "x": "\(body.x)",
            "y": "\(body.y)",
            "screenWidth": "\(meta?.w ?? 0)",
            "screenHeight": "\(meta?.h ?? 0)"
        ]
        if let wheelDy = body.wheelDy {
            args["wheelDy"] = "\(wheelDy)"
        }
        let requestId = sendMiLinkCommand(
            command: Self.xiaomiMirrorPointerCommand,
            args: args,
            updatesStatus: false
        )
        if let requestId {
            DiagnosticsLog.info(
                "xiaomi.mac.pointer_sent requestId=\(requestId) action=\(body.action) " +
                    "x=\(body.x) y=\(body.y) wheelDy=\(body.wheelDy ?? 0) " +
                    "screen=\(meta?.w ?? 0)x\(meta?.h ?? 0)"
            )
            return true
        }
        DiagnosticsLog.warn(
            "xiaomi.mac.pointer_ignored action=\(body.action) x=\(body.x) y=\(body.y) not_sent"
        )
        return false
    }

    @discardableResult
    private func sendXiaomiMirrorGlobal(_ action: String) -> Bool {
        let requestId = sendMiLinkCommand(
            command: Self.xiaomiMirrorGlobalCommand,
            args: ["action": action],
            updatesStatus: false
        )
        if let requestId {
            DiagnosticsLog.info(
                "xiaomi.mac.global_sent requestId=\(requestId) action=\(action)"
            )
            return true
        }
        DiagnosticsLog.warn("xiaomi.mac.global_ignored action=\(action) not_sent")
        return false
    }

    private func prepareXiaomiMirrorKeyboardIfNeeded(source: String) {
        guard !didPrepareXiaomiMirrorKeyboard else {
            return
        }
        let now = Date()
        guard now.timeIntervalSince(xiaomiMirrorKeyboardReadyLastAttemptAt) >= Self.xiaomiMirrorKeyboardReadyRetryInterval else {
            return
        }
        xiaomiMirrorKeyboardReadyLastAttemptAt = now
        guard isConnected else {
            DiagnosticsLog.warn("xiaomi.mac.keyboard_ready_ignored source=\(source) not_connected")
            return
        }
        let requestId = sendMiLinkCommand(
            command: Self.xiaomiMirrorKeyboardReadyCommand,
            args: [
                "source": source,
                "prepareOnly": "true"
            ],
            updatesStatus: false
        )
        if let requestId {
            DiagnosticsLog.info("xiaomi.mac.keyboard_ready_sent source=\(source) requestId=\(requestId)")
        }
    }

    private func releaseXiaomiMirrorKeyboard(reason: String) {
        didPrepareXiaomiMirrorKeyboard = false
        xiaomiMirrorKeyboardReadyLastAttemptAt = .distantPast
        guard isConnected else {
            DiagnosticsLog.warn("xiaomi.mac.keyboard_release_ignored reason=\(reason) not_connected")
            return
        }
        let requestId = sendMiLinkCommand(
            command: Self.xiaomiMirrorKeyboardReleaseCommand,
            args: ["source": reason],
            updatesStatus: false
        )
        if let requestId {
            DiagnosticsLog.info("xiaomi.mac.keyboard_release_sent reason=\(reason) requestId=\(requestId)")
        }
    }

    private static func xiaomiMirrorKeyboardArgs(
        androidKeyCode: Int,
        event: NSEvent,
        isDown: Bool
    ) -> [String: String] {
        var args = [
            "keyCode": "\(androidKeyCode)",
            "down": isDown ? "true" : "false",
            "modifiers": "\(androidMetaState(from: event.modifierFlags, macKeyCode: event.keyCode, isDown: isDown))",
            "macKeyCode": "\(event.keyCode)"
        ]
        if let characters = event.charactersIgnoringModifiers, !characters.isEmpty {
            args["characters"] = String(characters.prefix(8))
        }
        return args
    }

    private static func androidMetaState(
        from flags: NSEvent.ModifierFlags,
        macKeyCode: UInt16,
        isDown: Bool
    ) -> Int {
        let normalized = flags.intersection(.deviceIndependentFlagsMask)
        var meta = 0
        if normalized.contains(.shift) {
            meta |= androidMetaShiftLeft
        }
        if normalized.contains(.option) {
            meta |= androidMetaAltLeft
        }
        if normalized.contains(.control) {
            meta |= androidMetaCtrlLeft
        }
        if normalized.contains(.command) {
            meta |= androidMetaWinLeft
        }

        switch macKeyCode {
        case 60:
            meta = (meta & ~androidMetaShiftLeft) | (isDown ? androidMetaShiftRight : 0)
        case 61:
            meta = (meta & ~androidMetaAltLeft) | (isDown ? androidMetaAltRight : 0)
        case 62:
            meta = (meta & ~androidMetaCtrlLeft) | (isDown ? androidMetaCtrlRight : 0)
        case 54:
            meta = (meta & ~androidMetaWinLeft) | (isDown ? androidMetaWinRight : 0)
        default:
            break
        }
        return meta
    }

    private static func androidKeyCode(forMacKeyCode keyCode: UInt16, characters: String?) -> Int? {
        switch keyCode {
        case 0: return 29
        case 1: return 47
        case 2: return 32
        case 3: return 34
        case 4: return 36
        case 5: return 35
        case 6: return 54
        case 7: return 52
        case 8: return 31
        case 9: return 50
        case 11: return 30
        case 12: return 45
        case 13: return 51
        case 14: return 33
        case 15: return 46
        case 16: return 53
        case 17: return 48
        case 18: return 8
        case 19: return 9
        case 20: return 10
        case 21: return 11
        case 22: return 13
        case 23: return 12
        case 24: return 70
        case 25: return 16
        case 26: return 14
        case 27: return 69
        case 28: return 15
        case 29: return 7
        case 30: return 72
        case 31: return 43
        case 32: return 49
        case 33: return 71
        case 34: return 37
        case 35: return 44
        case 36, 76: return 66
        case 37: return 40
        case 38: return 38
        case 39: return 75
        case 40: return 39
        case 41: return 74
        case 42: return 73
        case 43: return 55
        case 44: return 76
        case 45: return 42
        case 46: return 41
        case 47: return 56
        case 48: return 61
        case 49: return 62
        case 50: return 68
        case 51: return 67
        case 53: return 111
        case 54: return 118
        case 55: return 117
        case 56: return 59
        case 57: return 115
        case 58: return 57
        case 59: return 113
        case 60: return 60
        case 61: return 58
        case 62: return 114
        case 96: return 135
        case 97: return 136
        case 98: return 137
        case 99: return 133
        case 100: return 138
        case 101: return 139
        case 103: return 141
        case 109: return 140
        case 111: return 142
        case 114: return 124
        case 115: return 122
        case 116: return 92
        case 117: return 112
        case 118: return 134
        case 119: return 123
        case 120: return 132
        case 121: return 93
        case 122: return 131
        case 123: return 21
        case 124: return 22
        case 125: return 20
        case 126: return 19
        default:
            return androidKeyCode(forCharacter: characters)
        }
    }

    private static func androidKeyCode(forCharacter characters: String?) -> Int? {
        guard let normalized = characters?.lowercased(), normalized.unicodeScalars.count == 1,
              let scalar = normalized.unicodeScalars.first else {
            return nil
        }
        let value = scalar.value
        if value >= 97 && value <= 122 {
            return Int(value - 97) + 29
        }
        if value >= 49 && value <= 57 {
            return Int(value - 49) + 8
        }
        if value == 48 {
            return 7
        }
        switch scalar {
        case " ": return 62
        case "\t": return 61
        case "\r", "\n": return 66
        case "\u{7F}": return 67
        case "`": return 68
        case "-": return 69
        case "=": return 70
        case "[": return 71
        case "]": return 72
        case "\\": return 73
        case ";": return 74
        case "'": return 75
        case "/": return 76
        case ",": return 55
        case ".": return 56
        default:
            return nil
        }
    }

    private func sendMiLinkCommandBody(_ body: MiLinkCommandBody, session: SecureSessionHost) async {
        do {
            let data = try encoder.encode(Envelope(t: EnvelopeType.miLinkCommand, b: body))
            try await session.sendPlaintext(data)
            DiagnosticsLog.info(
                "xiaomi.mac.command_sent requestId=\(body.requestId) command=\(body.command) args=\(body.args)"
            )
        } catch {
            if pendingXiaomiScreenFallback?.requestId == body.requestId {
                pendingXiaomiScreenFallback = nil
                pendingXiaomiScreenFallbackTask?.cancel()
                pendingXiaomiScreenFallbackTask = nil
                DiagnosticsLog.warn(
                    "xiaomi.mac.screen_no_fallback requestId=\(body.requestId) " +
                        "command=\(body.command) reason=send_failed"
                )
            }
            if !Self.isXiaomiMirrorKeyboardCommand(body.command) {
                xiaomiMiLinkCommandStatus = String(localized: "小米服務送出失敗")
            }
            DiagnosticsLog.error("xiaomi.mac.command_send_failed requestId=\(body.requestId) command=\(body.command)", error)
        }
    }

    @discardableResult
    private func sendPhoneAction(action: String, number: String? = nil) -> String? {
        guard let session = currentSession, isConnected else {
            phoneCallStatus = String(localized: "電話目前不可用")
            DiagnosticsLog.warn("phone.mac.action_ignored action=\(action) not_connected")
            return nil
        }

        let requestId = UUID().uuidString
        phoneCallStatus = Self.localizedPhoneActionInProgress(action)
        if action == "dial" || action == "answer" {
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                let endpoint = await self.preparePhoneRelayEndpoint(action: action)
                let body = PhoneActionBody(
                    requestId: requestId,
                    action: action,
                    number: number,
                    relayHost: endpoint.host,
                    relayPort: endpoint.port,
                    relaySessionId: endpoint.sessionId,
                    relayControlPort: endpoint.controlPort,
                    lanHost: endpoint.lanHost,
                    lanPort: endpoint.lanPort,
                    lanProbePort: endpoint.lanProbePort
                )
                self.pendingPhoneActions[requestId] = body
                await self.sendPhoneActionBody(body, session: session)
            }
            return requestId
        }

        let body = PhoneActionBody(
            requestId: requestId,
            action: action,
            number: number,
            relayHost: nil,
            relayPort: nil
        )
        pendingPhoneActions[requestId] = body
        if action == "hangup" {
            stopPhoneCallRelayAudio(reason: "phone_action_hangup")
        }

        Task { @MainActor [weak self] in
            await self?.sendPhoneActionBody(body, session: session)
        }
        return requestId
    }

    private func preparePhoneRelayEndpoint(action: String) async -> PhoneRelayEndpoint {
        let sessionId = UUID().uuidString
        activePhoneRelaySessionId = sessionId
        phoneRelaySourceSequence = 0
        phoneRelaySourceSendFailed = false
        callRelayCloudflareBridge.start(sessionId: sessionId)
        phoneRelayAudioController.echoCancellationEnabled = phoneRelayEchoCancellationEnabled
        phoneRelayAudioController.startDownlink()
        startPhoneRelaySession(reason: "phone_action_\(action)")
        let lanCandidateReady = await waitForPhoneRelayLANCandidateReady()
        let lanHost = lanCandidateReady
            ? Self.phoneRelayAdvertisedHost()
            : nil
        DiagnosticsLog.info(
            "phone.mac.relay_endpoint action=\(action) mode=secure_channel " +
                "phoneLocal=127.0.0.1:\(Self.phoneRelayProbePort) sessionId=\(sessionId) " +
                "lanCandidate=\(lanHost ?? "none"):\(Self.phoneRelayProbePort) " +
                "lanProbePort=\(lanHost == nil ? 0 : Int(LANTransport.reachabilityProbePort)) " +
                "aec=\(phoneRelayEchoCancellationEnabled)"
        )
        return PhoneRelayEndpoint(
            host: "127.0.0.1",
            port: Int(Self.phoneRelayProbePort),
            sessionId: sessionId,
            lanHost: lanHost,
            lanPort: lanHost == nil ? nil : Int(Self.phoneRelayProbePort),
            lanProbePort: lanHost == nil ? nil : Int(LANTransport.reachabilityProbePort)
        )
    }

    private func startPhoneRelaySession(reason: String) {
        guard !phoneRelaySessionRunning else {
            return
        }
        guard !phoneRelayProbeRunning else {
            DiagnosticsLog.warn(
                "phonerelay.mac.session_start_skipped reason=\(reason) probe_running=true port=\(Self.phoneRelayProbePort)"
            )
            return
        }
        do {
            try phoneRelaySession.start(port: Self.phoneRelayProbePort)
            phoneRelaySessionRunning = true
            DiagnosticsLog.info("phonerelay.mac.session_started reason=\(reason) port=\(Self.phoneRelayProbePort)")
        } catch {
            phoneRelaySessionRunning = false
            DiagnosticsLog.error("phonerelay.mac.session_start_failed reason=\(reason)", error)
        }
    }

    private func stopPhoneRelaySession(reason: String) {
        guard phoneRelaySessionRunning else {
            return
        }
        phoneRelaySessionRunning = false
        phoneRelaySession.stop(reason: reason)
        DiagnosticsLog.info("phonerelay.mac.session_stopped reason=\(reason)")
    }

    private func startPhoneRelayUplink(reason: String) {
        guard !phoneRelayUplinkActive else {
            return
        }
        guard activePhoneRelaySessionId != nil else {
            DiagnosticsLog.info("phonerelay.mac.uplink_start_skipped reason=\(reason) no_active_session")
            return
        }
        phoneRelayUplinkActive = true
        phoneRelayAudioController.echoCancellationEnabled = phoneRelayEchoCancellationEnabled
        phoneRelayAudioController.startUplink { [weak self] packet in
            Task { @MainActor in
                self?.routePhoneRelayUplinkPacket(packet)
            }
        }
        phoneRelaySession.setUplinkActive(true)
        DiagnosticsLog.info(
            "phonerelay.mac.uplink_start reason=\(reason) aec=\(phoneRelayEchoCancellationEnabled)"
        )
    }

    private func stopPhoneRelayUplink(reason: String) {
        guard phoneRelayUplinkActive else {
            return
        }
        phoneRelayUplinkActive = false
        phoneRelayAudioController.stopUplink(reason: reason)
        phoneRelaySession.setUplinkActive(false)
        DiagnosticsLog.info("phonerelay.mac.uplink_stop reason=\(reason)")
    }

    private func routePhoneRelayUplinkPacket(_ packet: Data) {
        if phoneRelaySessionRunning, phoneRelaySession.hasUplinkDestination {
            phoneRelaySession.sendUplinkRTP(packet)
            return
        }
        Task {
            await sendPhoneRelaySourcePacket(packet)
        }
    }

    private func waitForPhoneRelayLANCandidateReady() async -> Bool {
        for attempt in 0...12 {
            let listenerReady = phoneRelaySessionRunning
                ? phoneRelaySession.isTCPListenerReady()
                : (phoneRelayProbeRunning && phoneRelayProbe.isTCPListenerReady())
            if listenerReady, lanTransport.isReachabilityProbeReady {
                return true
            }
            guard attempt < 12, !Task.isCancelled else {
                return false
            }
            do {
                try await Task.sleep(nanoseconds: 25_000_000)
            } catch {
                return false
            }
        }
        return false
    }

    private func sendPhoneActionBody(_ body: PhoneActionBody, session: SecureSessionHost) async {
        do {
            let data = try encoder.encode(Envelope(t: EnvelopeType.phoneAction, b: body))
            try await session.sendPlaintext(data)
            DiagnosticsLog.info(
                "phone.mac.action_requested requestId=\(body.requestId) action=\(body.action) " +
                    "numberFp=\(body.number.map(Self.fingerprint) ?? "none") " +
                    "relay=\(body.relayHost ?? "none"):\(body.relayPort.map(String.init) ?? "none")"
            )
        } catch {
            pendingPhoneActions.removeValue(forKey: body.requestId)
            if body.action == "dial" || body.action == "answer" {
                stopPhoneCallRelayAudio(reason: "phone_action_send_failed_\(body.action)")
            }
            phoneCallStatus = Self.localizedPhoneActionFailed(body.action)
            DiagnosticsLog.error("phone.mac.action_request_failed requestId=\(body.requestId) action=\(body.action)", error)
        }
    }

    private func handlePhoneRelayStartRequest(_ request: PhoneRelayStartRequestBody) {
        guard let session = currentSession, isConnected else {
            DiagnosticsLog.warn("phone.mac.relay_start_ignored requestId=\(request.requestId) reason=\(request.reason) not_connected")
            return
        }

        phoneCallStatus = String(localized: "手機通話接到 Mac 中")
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            let endpoint = await self.preparePhoneRelayEndpoint(action: "phone_relay_start")
            let success = endpoint.host != nil
            let body = PhoneRelayEndpointBody(
                requestId: request.requestId,
                relayHost: endpoint.host,
                relayPort: endpoint.port,
                relaySessionId: endpoint.sessionId,
                relayControlPort: endpoint.controlPort,
                lanHost: endpoint.lanHost,
                lanPort: endpoint.lanPort,
                lanProbePort: endpoint.lanProbePort,
                success: success,
                error: success ? nil : "relay_endpoint_unavailable",
                ts: Int64(Date().timeIntervalSince1970)
            )
            if success {
                self.isPhoneCallActive = true
                self.phoneCallStatus = String(localized: "手機通話已接到 Mac")
            } else {
                self.stopPhoneCallRelayAudio(reason: "phone_relay_endpoint_unavailable")
                self.phoneCallStatus = String(localized: "接手機通話失敗")
            }
            await self.sendPhoneRelayEndpoint(body, session: session)
        }
    }

    private func sendPhoneRelayEndpoint(_ body: PhoneRelayEndpointBody, session: SecureSessionHost) async {
        do {
            let data = try encoder.encode(Envelope(t: EnvelopeType.phoneRelayEndpoint, b: body))
            try await session.sendPlaintext(data)
            DiagnosticsLog.info(
                "phone.mac.relay_endpoint_sent requestId=\(body.requestId) success=\(body.success) " +
                    "relay=\(body.relayHost ?? "none"):\(body.relayPort.map(String.init) ?? "none") " +
                    "sessionId=\(body.relaySessionId ?? "none") " +
                    "lan=\(body.lanHost ?? "none"):\(body.lanPort.map(String.init) ?? "none") " +
                    "lanProbePort=\(body.lanProbePort.map(String.init) ?? "none")"
            )
        } catch {
            stopPhoneCallRelayAudio(reason: "phone_relay_endpoint_send_failed")
            isPhoneCallActive = false
            phoneCallStatus = String(localized: "接手機通話失敗")
            DiagnosticsLog.error("phone.mac.relay_endpoint_send_failed requestId=\(body.requestId)", error)
        }
    }

    private func handlePhoneRelayMedia(_ body: PhoneRelayMediaBody) {
        guard body.sessionId == activePhoneRelaySessionId else {
            DiagnosticsLog.info(
                "callrelay.mac.cloudflare_media_ignored sessionId=\(body.sessionId) " +
                    "active=\(activePhoneRelaySessionId ?? "none") kind=\(body.kind)"
            )
            return
        }

        if body.kind == "rtp" {
            callRelayCloudflareBridge.handle(body)
            return
        }
        guard body.kind == "status", let event = body.event else {
            return
        }
        DiagnosticsLog.info("callrelay.mac.cloudflare_status sessionId=\(body.sessionId) event=\(event)")
        switch event {
        case "source_start":
            startPhoneRelayUplink(reason: "cloudflare_source_start")
        case "source_stop", "bridge_failed", "bridge_stopped":
            stopPhoneRelayUplink(reason: "cloudflare_\(event)")
            phoneRelayProbe.stopExternalSourceRTP(reason: "cloudflare_\(event)")
        default:
            break
        }
    }

    private func sendPhoneRelaySourcePacket(_ packet: Data) async {
        guard !phoneRelaySourceSendFailed,
              let session = currentSession,
              let sessionId = activePhoneRelaySessionId else {
            return
        }
        phoneRelaySourceSequence += 1
        let sequence = phoneRelaySourceSequence
        let body = PhoneRelayMediaBody(
            sessionId: sessionId,
            direction: "mac_to_android",
            kind: "rtp",
            dataBase64: packet.base64EncodedString(),
            bytes: packet.count,
            sequence: sequence,
            ts: Int64(Date().timeIntervalSince1970 * 1_000)
        )
        do {
            let data = try encoder.encode(Envelope(t: EnvelopeType.phoneRelayMedia, b: body))
            try await session.sendPlaintext(data)
            if sequence == 1 || sequence % 100 == 0 {
                DiagnosticsLog.info(
                    "callrelay.mac.cloudflare_rtp_out sessionId=\(sessionId) " +
                        "count=\(sequence) bytes=\(packet.count)"
                )
            }
        } catch {
            guard activePhoneRelaySessionId == sessionId, !phoneRelaySourceSendFailed else {
                return
            }
            phoneRelaySourceSendFailed = true
            DiagnosticsLog.error(
                "callrelay.mac.cloudflare_rtp_send_failed sessionId=\(sessionId) " +
                    "count=\(sequence)",
                error
            )
            phoneRelayProbe.stopExternalSourceRTP(reason: "cloudflare_send_failed")
        }
    }

    private func run() async {
        do {
            connectionStatus = "Registering"
            let identity = try await loadOrRegisterIdentity()
            localIdentity = identity
            localDeviceId = DeviceID.display(identity.deviceId)
            DiagnosticsLog.info("runtime.mac.identity deviceId=\(identity.deviceId) pkfp=\(DiagnosticsLog.fingerprint(identity.publicKey))")
            startXiaomiMiShareDiscovery(identity: identity, reason: "identity_ready")

            guard let peer = try loadPreferredPeer() else {
                DiagnosticsLog.info("runtime.mac.no_paired_peer")
                connectionStatus = "No paired Android"
                canDisconnect = false
                return
            }

            DiagnosticsLog.info("runtime.mac.loaded_peer clientId=\(peer.deviceId) pkfp=\(DiagnosticsLog.fingerprint(peer.publicKey))")
            peerName = peer.name
            peerDeviceId = DeviceID.display(peer.deviceId)
            currentPeer = peer
            startConnection(identity: identity, peer: peer, reason: "startup")
        } catch {
            DiagnosticsLog.error("runtime.mac.setup_failed", error)
            isConnected = false
            canDisconnect = false
            connectionStatus = "Setup failed"
        }
    }

    private func loadPreferredPeer() throws -> PinnedPeer? {
        let peers = try pairingStore?.loadPeers() ?? []
        let peer = peers.max { lhs, rhs in
            lhs.pairedAt < rhs.pairedAt
        }
        if peers.count > 1, let peer {
            DiagnosticsLog.info("runtime.mac.preferred_peer clientId=\(peer.deviceId) peerCount=\(peers.count)")
        }
        return peer
    }

    private func runPairing(identity: LocalIdentity) async {
        do {
            guard let pairingStore else {
                throw LocalStoreError.missingApplicationSupportDirectory
            }

            isPairing = true
            canAcceptPairing = false
            pairingSAS = ""
            pairingPeerName = ""
            pairingStatus = "Opening pairing"
            DiagnosticsLog.info("pair.mac.open hostId=\(identity.deviceId) hostPkFp=\(DiagnosticsLog.fingerprint(identity.publicKey))")

            try await pairingTransport.start(identity: identity)
            DiagnosticsLog.info("pair.mac.start_ok hostId=\(identity.deviceId)")
            let channel = try await pairingTransport.connect(hostId: identity.deviceId)
            DiagnosticsLog.info("pair.mac.ws_connected hostId=\(identity.deviceId)")
            defer { channel.close() }

            let hostNonce = HandshakeSession.randomNonce()
            let commitment = Pairing.commitment(hostPublicKey: identity.publicKey, hostNonce: hostNonce)
            DiagnosticsLog.info("pair.mac.commitment_ready hostId=\(identity.deviceId) commitFp=\(DiagnosticsLog.fingerprint(commitment))")
            var pairedPeer: PinnedPeer?

            pairingLoop: while let text = try await channel.receive() {
                let type = try PairingWire.type(text)
                DiagnosticsLog.info("pair.mac.message type=\(type) hostId=\(identity.deviceId)")
                switch type {
                case PairingType.ready:
                    try await channel.send(PairingWire.encodeCommit(commitment))
                    DiagnosticsLog.info("pair.mac.commit_sent hostId=\(identity.deviceId)")
                case PairingType.revealClient:
                    let reveal = try PairingWire.decodeRevealClient(text)
                    guard
                        let clientPublicKey = Data(base64Encoded: reveal.clientPk),
                        let clientNonce = Data(base64Encoded: reveal.nonceC)
                    else {
                        throw PairingRuntimeError.invalidPeerMessage
                    }
                    DiagnosticsLog.info("pair.mac.reveal_client clientId=\(reveal.clientId) clientPkFp=\(DiagnosticsLog.fingerprint(clientPublicKey))")

                    let sas = Pairing.sas(
                        hostPublicKey: identity.publicKey,
                        clientPublicKey: clientPublicKey,
                        hostNonce: hostNonce,
                        clientNonce: clientNonce
                    )
                    DiagnosticsLog.info("pair.mac.sas hostId=\(identity.deviceId) clientId=\(reveal.clientId) sas=\(sas.display)")
                    let pending = MacPendingPairing(
                        hostId: identity.deviceId,
                        clientId: reveal.clientId,
                        hostPkBase64: identity.publicKey.base64EncodedString(),
                        clientPkBase64: reveal.clientPk,
                        hostName: identity.name,
                        clientName: reveal.name,
                        clientPublicKey: clientPublicKey
                    )
                    pendingPairing = pending
                    pairingSAS = sas.display
                    pairingPeerName = reveal.name
                    pairingStatus = "Compare code"
                    canAcceptPairing = true
                    try await channel.send(PairingWire.encodeRevealHost(identity: identity, nonce: hostNonce))
                    DiagnosticsLog.info("pair.mac.reveal_host_sent hostId=\(identity.deviceId) clientId=\(reveal.clientId)")
                case PairingType.complete:
                    let complete = try PairingWire.decodeComplete(text)
                    DiagnosticsLog.info("pair.mac.complete_received hostId=\(complete.hostId) clientId=\(complete.clientId)")
                    if let pending = pendingPairing, complete.hostId == pending.hostId, complete.clientId == pending.clientId {
                        let peer = PinnedPeer(
                            deviceId: pending.clientId,
                            name: pending.clientName,
                            publicKey: pending.clientPublicKey,
                            pairedAt: Date()
                        )
                        pairedPeer = peer
                        try pairingStore.savePeer(peer)
                        DiagnosticsLog.info("pair.mac.peer_saved clientId=\(peer.deviceId) pkfp=\(DiagnosticsLog.fingerprint(peer.publicKey))")
                        break pairingLoop
                    } else {
                        DiagnosticsLog.warn("pair.mac.complete_mismatch expected=\(pendingPairing?.hostId ?? "nil")/\(pendingPairing?.clientId ?? "nil") got=\(complete.hostId)/\(complete.clientId)")
                    }
                default:
                    continue
                }
            }

            guard let peer = pairedPeer else {
                DiagnosticsLog.warn("pair.mac.no_paired_peer_after_loop hostId=\(identity.deviceId)")
                return
            }
            pendingPairing = nil
            peerName = peer.name
            peerDeviceId = DeviceID.display(peer.deviceId)
            pairingSAS = ""
            pairingPeerName = ""
            pairingStatus = "Paired"
            isPairing = false
            canAcceptPairing = false
            DiagnosticsLog.info("pair.mac.done hostId=\(identity.deviceId) clientId=\(peer.deviceId)")
            startConnection(identity: identity, peer: peer, reason: "pairing")
        } catch {
            DiagnosticsLog.error("pair.mac.failed hostId=\(identity.deviceId)", error)
            pairingStatus = "Pairing failed"
            isPairing = false
            canAcceptPairing = false
        }
    }

    private func loadOrRegisterIdentity() async throws -> LocalIdentity {
        if let identity = try identityStore.loadIdentity() {
            DiagnosticsLog.info("runtime.mac.identity_loaded deviceId=\(identity.deviceId)")
            return identity
        }

        let name = Host.current().localizedName ?? "Jason's Mac"
        let signingKey = Curve25519.Signing.PrivateKey()
        let deviceId = try await registrar.register(
            pubkey: signingKey.publicKey.rawRepresentation,
            name: name,
            platform: "macos"
        )
        DiagnosticsLog.info("runtime.mac.identity_registered deviceId=\(deviceId) name=\(name) pkfp=\(DiagnosticsLog.fingerprint(signingKey.publicKey.rawRepresentation))")
        let identity = LocalIdentity(deviceId: deviceId, name: name, signingKey: signingKey)
        try identityStore.saveIdentity(identity)
        return identity
    }

    private func startConnection(identity: LocalIdentity, peer: PinnedPeer, reason: String) {
        let connectionGeneration = UUID()
        currentPeer = peer
        currentConnectionGeneration = connectionGeneration
        canDisconnect = true

        startLANSessionListenerIfNeeded(identity: identity)
        lanSessionTask?.cancel()
        lanSessionTask = nil

        connectionTask?.cancel()
        currentChannel?.close()
        currentChannel = nil
        currentChannelGeneration = nil
        currentChannelTransport = nil
        currentSession = nil
        screenSession.clearSender()
        stopPhoneRelayProbe(reason: "start_connection")
        androidMicRelayArmed = false
        isPhoneCallActive = false
        if reason == "manual" {
            connectionStatus = "Reconnecting"
        }

        connectionTask = Task { [weak self] in
            guard let self else {
                return
            }
            await self.connectLoop(
                identity: identity,
                peer: peer,
                connectionGeneration: connectionGeneration
            )
        }
    }

    private func connectLoop(identity: LocalIdentity, peer: PinnedPeer, connectionGeneration: UUID) async {
        var retryDelay: UInt64 = 1_000_000_000

        while !Task.isCancelled && currentConnectionGeneration == connectionGeneration {
            var channel: ByteChannel?
            let channelGeneration = UUID()

            do {
                defer {
                    channel?.close()
                    if currentChannelGeneration == channelGeneration {
                        currentChannel = nil
                        currentChannelGeneration = nil
                        currentChannelTransport = nil
                    }
                }

                DiagnosticsLog.info("relay.mac.connect_start hostId=\(identity.deviceId) clientId=\(peer.deviceId)")
                hostSessionDidConnect = false
                if currentChannelGeneration == nil {
                    isConnected = false
                    canDisconnect = true
                    connectionStatus = "Connecting relay"
                }
                let connectedChannel = try await relayTransport.connect(hostId: identity.deviceId, identity: identity)
                guard currentConnectionGeneration == connectionGeneration else {
                    connectedChannel.close()
                    return
                }
                channel = connectedChannel
                try await runHostSession(
                    channel: connectedChannel,
                    identity: identity,
                    peer: peer,
                    connectionGeneration: connectionGeneration,
                    channelGeneration: channelGeneration,
                    transport: "relay"
                )
            } catch {
                if Task.isCancelled || currentConnectionGeneration != connectionGeneration {
                    DiagnosticsLog.info("relay.mac.connect_cancelled hostId=\(identity.deviceId) clientId=\(peer.deviceId)")
                    return
                }
                DiagnosticsLog.error("relay.mac.disconnected hostId=\(identity.deviceId) clientId=\(peer.deviceId)", error)
                if currentChannelGeneration == nil {
                    isConnected = false
                    currentSession = nil
                    screenSession.clearSender()
                    screenSession.handleTransportInterrupted()
                    stopPhoneCallRelayAudio(reason: "transport_interrupted")
                    androidMicRelayArmed = false
                    isPhoneCallActive = false
                    connectionStatus = "Disconnected"
                }
                if hostSessionDidConnect {
                    retryDelay = 1_000_000_000
                }
                try? await Task.sleep(nanoseconds: retryDelay)
                retryDelay = min(retryDelay * 2, 30_000_000_000)
            }
        }
    }

    private func runHostSession(
        channel: ByteChannel,
        identity: LocalIdentity,
        peer: PinnedPeer,
        connectionGeneration: UUID,
        channelGeneration: UUID,
        transport: String
    ) async throws {
        if currentChannelGeneration == nil {
            currentChannel = channel
            currentChannelGeneration = channelGeneration
            currentChannelTransport = transport
        }

        let callRelayCloudflareBridge = callRelayCloudflareBridge
        let xiaomiMirrorRTSPDiagnosticSource = xiaomiMirrorRTSPDiagnosticSource
                let dispatcher = CommandDispatcher(
                    clipboardSync: clipboardSync,
                    notificationPresenter: notificationPresenter,
                    screenSession: screenSession,
                    onStatusPong: { [weak self] in
                        Task { @MainActor in
                            self?.recordSecurePong(generation: channelGeneration)
                        }
                    },
                    onSmsMessage: { [weak self] message in
                        Task { @MainActor in
                            self?.handleSmsMessage(message)
                        }
                    },
                    onSmsSendResult: { [weak self] result in
                        Task { @MainActor in
                            self?.handleSmsSendResult(result)
                        }
                    },
                    onPhoneActionResult: { [weak self] result in
                        Task { @MainActor in
                            self?.handlePhoneActionResult(result)
                        }
                    },
                    onPhoneRelayStartRequest: { [weak self] request in
                        Task { @MainActor in
                            self?.handlePhoneRelayStartRequest(request)
                        }
                    },
                    onPhoneRelayMedia: { [weak self] media in
                        guard let self else {
                            return
                        }
                        if media.kind == "rtp" {
                            callRelayCloudflareBridge.handle(media)
                            return
                        }
                        Task { @MainActor in
                            self.handlePhoneRelayMedia(media)
                        }
                    },
                    onPhoneCallStatus: { [weak self] status in
                        Task { @MainActor in
                            self?.handlePhoneCallStatus(status)
                        }
                    },
                    onAndroidMicStatus: { [weak self] status in
                        Task { @MainActor in
                            self?.handleAndroidMicStatus(status)
                        }
                    },
                    onMiLinkStatus: { [weak self] status in
                        Task { @MainActor in
                            self?.handleMiLinkStatus(status)
                        }
                    },
                    onMiLinkFrame: { [weak self] frame in
                        Task { @MainActor in
                            self?.handleMiLinkFrame(frame)
                        }
                    },
                    onMiLinkMirrorMedia: { [weak self] media in
                        guard let self else {
                            return
                        }
                        if media.kind == "rtp" || media.kind == "rtp_batch" {
                            xiaomiMirrorRTSPDiagnosticSource.handleCloudflareMirrorMedia(media)
                            return
                        }
                        Task { @MainActor in
                            self.handleMiLinkMirrorMedia(media)
                        }
                    },
                    onMiLinkCommandResult: { [weak self] result in
                        Task { @MainActor in
                            self?.handleMiLinkCommandResult(result)
                        }
                    }
                )
                let session = SecureSessionHost(
                    channel: channel,
                    identity: identity,
                    peer: peer,
                    dispatcher: dispatcher
                )

                if currentChannelGeneration == channelGeneration {
                    connectionStatus = "Handshaking"
                }
                try await session.connect()
                guard currentConnectionGeneration == connectionGeneration else {
                    channel.close()
                    return
                }
                if currentChannelGeneration != channelGeneration {
                    if currentChannelGeneration == nil || transport == "lan" {
                        if currentChannelGeneration != nil {
                            DiagnosticsLog.info("\(transport).mac.preempt_active_session hostId=\(identity.deviceId) clientId=\(peer.deviceId) replacedTransport=\(currentChannelTransport ?? "unknown")")
                            currentChannel?.close()
                        }
                        currentChannel = channel
                        currentChannelGeneration = channelGeneration
                        currentChannelTransport = transport
                    } else {
                        DiagnosticsLog.info("relay.mac.redundant_session_closed hostId=\(identity.deviceId) clientId=\(peer.deviceId) activeTransport=\(currentChannelTransport ?? "unknown")")
                        channel.close()
                        throw SecureKeepaliveError.redundantSession
                    }
                }
                DiagnosticsLog.info("\(transport).mac.handshake_ok hostId=\(identity.deviceId) clientId=\(peer.deviceId)")
                currentSession = session
                lastSecurePongAt = Date()
                Task { [weak self] in
                    _ = await self?.ensureTurnCredentials(reason: "relay_connected")
                }
                screenSession.setSender { data in
                    Task {
                        do {
                            try await session.sendPlaintext(data)
                        } catch {
                            DiagnosticsLog.error("screen.mac.send_failed", error)
                        }
                    }
                }
                isConnected = true
                connectionStatus = "Connected"
                hostSessionDidConnect = true
                resumeXiaomiMirrorAfterReconnectIfNeeded()
                reportPresence(.awake, reason: "connected")
                if pendingAwakeNotification {
                    pendingAwakeNotification = false
                    if let data = try? encoder.encode(Envelope(t: EnvelopeType.macAwake, b: EmptyBody())) {
                        DiagnosticsLog.info("runtime.mac.awake_notify hostId=\(identity.deviceId) clientId=\(peer.deviceId)")
                        try? await session.sendPlaintext(data)
                    }
                }

                let clipboardTask = Task { await clipboardLoop(session: session) }
                let notificationTask = Task { await macNotificationLoop(identity: identity, session: session) }
                defer {
                    clipboardTask.cancel()
                    notificationTask.cancel()
                    if currentSession === session {
                        currentSession = nil
                        screenSession.clearSender()
                    }
                }
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        try await session.receiveLoop()
                    }
                    group.addTask { [weak self] in
                        guard let self else {
                            return
                        }
                        try await self.secureKeepaliveLoop(
                            session: session,
                            generation: channelGeneration,
                            hostId: identity.deviceId,
                            clientId: peer.deviceId
                        )
                    }
                    _ = try await group.next()
                    group.cancelAll()
                }
                throw SecureKeepaliveError.receiveLoopEnded
    }

    private func startLANSessionListenerIfNeeded(identity: LocalIdentity) {
        guard lanSessionListener == nil else {
            return
        }
        let listener = LANSessionListener { [weak self] channel in
            if let channel = channel as? LANTCPByteChannel {
                channel.start()
            }
            Task { @MainActor in
                self?.handleLANAcceptedChannel(channel)
            }
        }
        lanSessionListener = listener
        listener.start(serviceName: identity.name)
    }

    private func handleLANAcceptedChannel(_ channel: ByteChannel) {
        guard let identity = localIdentity,
              let peer = currentPeer,
              let generation = currentConnectionGeneration else {
            DiagnosticsLog.warn("lan.mac.session_rejected reason=no_pairing_context")
            channel.close()
            return
        }
        let channelGeneration = UUID()
        DiagnosticsLog.info("lan.mac.session_start hostId=\(identity.deviceId) clientId=\(peer.deviceId)")
        lanSessionTask?.cancel()
        lanSessionTask = Task { [weak self] in
            guard let self else {
                channel.close()
                return
            }
            defer {
                channel.close()
                Task { @MainActor in
                    if self.currentChannelGeneration == channelGeneration {
                        self.currentChannel = nil
                        self.currentChannelGeneration = nil
                        self.currentChannelTransport = nil
                    }
                }
            }
            do {
                try await self.runHostSession(
                    channel: channel,
                    identity: identity,
                    peer: peer,
                    connectionGeneration: generation,
                    channelGeneration: channelGeneration,
                    transport: "lan"
                )
            } catch {
                DiagnosticsLog.error("lan.mac.session_ended hostId=\(identity.deviceId) clientId=\(peer.deviceId)", error)
                if self.currentChannelGeneration == channelGeneration {
                    self.isConnected = false
                    self.connectionStatus = "Disconnected"
                }
            }
        }
    }

    private func recordSecurePong(generation: UUID) {
        guard currentChannelGeneration == generation else {
            return
        }
        lastSecurePongAt = Date()
        if isConnected {
            connectionStatus = "Connected"
        }
    }

    private func resumeXiaomiMirrorAfterReconnectIfNeeded() {
        guard isPhoneScreenSessionActive, !xiaomiScreenUserStopped else {
            return
        }
        DiagnosticsLog.info("xiaomi.mac.screen_resume_after_reconnect")
        xiaomiScreenRecoveryTask?.cancel()
        xiaomiScreenRecoveryTask = nil
        isPhoneScreenSessionActive = false
        isPhoneScreenViewerVisible = false
        viewPhoneScreen(allowRouteDeferral: false)
    }

    private func secureKeepaliveLoop(
        session: SecureSessionHost,
        generation: UUID,
        hostId: String,
        clientId: String
    ) async throws {
        while !Task.isCancelled {
            try await Task.sleep(nanoseconds: Self.secureKeepaliveIntervalNanoseconds)
            try Task.checkCancellation()

            guard currentChannelGeneration == generation, currentSession === session else {
                return
            }

            let now = Date()
            let pongAgeSeconds = now.timeIntervalSince(lastSecurePongAt)
            let inboundAgeSeconds = await session.inboundIdleDuration(at: now)
            let livenessAgeSeconds = min(pongAgeSeconds, inboundAgeSeconds)
            if livenessAgeSeconds >= Self.securePongTimeoutSeconds {
                DiagnosticsLog.warn(
                    "relay.mac.pong_timeout hostId=\(hostId) clientId=\(clientId) " +
                        "ageMs=\(Int(livenessAgeSeconds * 1000)) pongAgeMs=\(Int(pongAgeSeconds * 1000)) " +
                        "inboundAgeMs=\(Int(inboundAgeSeconds * 1000)) timeoutMs=\(Int(Self.securePongTimeoutSeconds * 1000))"
                )
                currentChannel?.close()
                throw SecureKeepaliveError.pongTimedOut
            }

            let data = try encoder.encode(Envelope(t: EnvelopeType.statusPing, b: EmptyBody()))
            try await session.sendPlaintext(data)
        }
    }

    private func observeSystemSleepWake() {
        let notificationCenter = NSWorkspace.shared.notificationCenter

        notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.handleSystemSleep()
                }
            }
            .store(in: &systemSleepWakeCancellables)

        notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.handleSystemWake()
                }
            }
            .store(in: &systemSleepWakeCancellables)
    }

    private func handleSystemSleep() async {
        DiagnosticsLog.info("runtime.mac.system_sleep")
        resumeConnectionAfterWake = currentConnectionGeneration != nil
        if let session = currentSession,
           let data = try? encoder.encode(Envelope(t: EnvelopeType.macSleep, b: EmptyBody())) {
            try? await session.sendPlaintext(data)
            pendingAwakeNotification = true
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if let identity = localIdentity {
            do {
                try await presenceClient.report(hostId: identity.deviceId, identity: identity, state: .sleeping)
                DiagnosticsLog.info("presence.mac.reported state=sleeping reason=system_sleep")
            } catch {
                DiagnosticsLog.warn("presence.mac.report_failed state=sleeping error=\(error.localizedDescription)")
            }
        }
        currentConnectionGeneration = nil
        connectionTask?.cancel()
        connectionTask = nil
        lanSessionTask?.cancel()
        lanSessionTask = nil
        currentChannel?.close()
        currentChannel = nil
        currentChannelGeneration = nil
        currentChannelTransport = nil
        currentSession = nil
        screenSession.clearSender()
        isConnected = false
        connectionStatus = "Sleeping"
    }

    private func handleSystemWake() {
        DiagnosticsLog.info("runtime.mac.system_wake")
        currentChannel?.close()
        guard resumeConnectionAfterWake else {
            return
        }
        resumeConnectionAfterWake = false
        reconnect()
    }

    private func reportPresence(_ state: MacPowerPresence, reason: String) {
        guard let identity = localIdentity else {
            return
        }
        Task {
            for attempt in 1...3 {
                do {
                    try await presenceClient.report(hostId: identity.deviceId, identity: identity, state: state)
                    DiagnosticsLog.info("presence.mac.reported state=\(state.rawValue) reason=\(reason)")
                    return
                } catch {
                    DiagnosticsLog.warn("presence.mac.report_failed state=\(state.rawValue) attempt=\(attempt) error=\(error.localizedDescription)")
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
        }
    }

    private func clipboardLoop(session: SecureSessionHost) async {
        while !Task.isCancelled && currentSession === session {
            if let snapshot = clipboardSync.pollLocalText() {
                let body = ClipboardSetBody(
                    text: snapshot.text,
                    ts: snapshot.timestampSeconds,
                    hash: snapshot.hash
                )
                if let data = try? encoder.encode(Envelope(t: EnvelopeType.clipboardSet, b: body)) {
                    try? await session.sendPlaintext(data)
                    DiagnosticsLog.info("clipboard.mac.sent hashFp=\(Self.fingerprint(snapshot.hash))")
                }
            }
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
    }

    private func sendScreenPlaintext(_ plaintext: Data) async {
        guard let session = currentSession else {
            DiagnosticsLog.warn("screen.mac.send_ignored no_current_session")
            return
        }
        do {
            try await session.sendPlaintext(plaintext)
        } catch {
            DiagnosticsLog.error("screen.mac.send_failed", error)
        }
    }

    private func macNotificationLoop(identity: LocalIdentity, session: SecureSessionHost) async {
        await macNotificationSource.resetBaseline()
        while !Task.isCancelled && currentSession === session {
            if macNotificationSyncEnabled {
                let bodies = await macNotificationSource.poll(sourceDeviceId: identity.deviceId)
                for body in bodies {
                    if let data = try? encoder.encode(Envelope(t: EnvelopeType.notificationPost, b: body)) {
                        do {
                            try await session.sendPlaintext(data)
                            DiagnosticsLog.info("notification.mac.db.sent id=\(body.id) app=\(body.app)")
                        } catch {
                            DiagnosticsLog.error("notification.mac.db.send_failed id=\(body.id)", error)
                        }
                    }
                }
            } else {
                await macNotificationSource.resetBaseline()
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private func handleSmsMessage(_ message: SmsMessageBody) {
        smsMessages.removeAll { existing in
            existing.id == message.id ||
                (existing.address == message.address &&
                    existing.text == message.text &&
                    existing.direction == message.direction &&
                    abs(existing.ts - message.ts) <= 300)
        }
        smsMessages.insert(message, at: 0)

        DiagnosticsLog.info("sms.mac.message_received id=\(message.id) addressFp=\(Self.fingerprint(message.address)) backfill=\(message.isBackfill)")
        if !message.isBackfill && message.direction == "inbound" {
            if let candidate = VerificationCodeExtractor.extract(
                from: message.text,
                sourceAddress: message.address,
                sourceMessageId: message.id,
                timestamp: message.ts
            ) {
                handleVerificationCode(candidate, message: message)
            } else {
                notificationPresenter.show(
                    NotificationPostBody(
                        id: message.id,
                        sourceDeviceId: message.sourceDeviceId,
                        sourcePlatform: message.sourcePlatform,
                        app: "SMS",
                        bundle: "sms",
                        title: message.address,
                        text: message.text,
                        ts: message.ts
                    )
                )
            }
        }
    }

    private func handleMiLinkStatus(_ status: MiLinkStatusBody) {
        latestMiLinkStatus = status
        autoWarmXiaomiServicesIfNeeded(status)
        if deferredViewPhoneScreenTask != nil {
            deferredViewPhoneScreenTask?.cancel()
            deferredViewPhoneScreenTask = nil
            DiagnosticsLog.info("xiaomi.mac.screen_route_deferred_resolved reason=milink_status")
            viewPhoneScreen(allowRouteDeferral: false)
        }
        DiagnosticsLog.info(
            "milink.mac.status available=\(status.available) route=\(status.route) " +
                "officialDiscoveryRequired=\(status.officialDiscoveryRequired) " +
                "root=\(status.rootProbeOk) attribution=\(status.attributionProbeOk) " +
                "messenger=\(status.messengerTransportOk) cast=\(status.castServiceOk) " +
                "services=\(status.services?.filter(\.available).count ?? 0)/\(status.services?.count ?? 0) " +
                "preferredRoutes=\(status.preferredRoutes ?? [:]) " +
                "phoneContinuity=\(status.phoneContinuityOk ?? false) " +
                "callRelay=\(status.phoneCallRelayServiceOk ?? false) " +
                "mediaRelayCallback=\(status.phoneMediaRelayCallbackOk ?? false) " +
                "phoneDevices=\(status.phoneRemoteDeviceCount ?? 0) " +
                "mediaRelayCandidates=\(status.phoneMediaRelayCandidateCount ?? 0)"
        )
    }

    private func handleMiLinkFrame(_ frame: MiLinkFrameBody) {
        latestMiLinkFrame = frame
        if frame.route == "xiaomi.mirror.cast" {
            do {
                guard let data = Data(base64Encoded: frame.dataBase64) else {
                    throw XiaomiMirrorCastFrameError.invalidBase64
                }
                let configuration = try XiaomiMirrorScreenConfiguration.decodeOfficialFrame(data)
                screenSession.handleXiaomiMirrorScreenConfiguration(configuration)
            } catch {
                DiagnosticsLog.error("milink.mac.xiaomi_cast_frame_decode_failed", error)
            }
        }
        DiagnosticsLog.info(
            "milink.mac.frame_received clientNo=\(frame.clientNo) seq=\(frame.sequence) " +
                "bytes=\(frame.bytes) hasNext=\(frame.hasNext) route=\(frame.route)"
        )
    }

    private func sendXiaomiMirrorCloudflareDatagram(_ packet: Data, sessionId: String) {
        guard let session = currentSession, isConnected else {
            return
        }
        xiaomiMirrorCloudflareDatagramsSent += 1
        let sentCount = xiaomiMirrorCloudflareDatagramsSent
        let body = MiLinkMirrorMediaBody(
            sessionId: sessionId,
            direction: "mac_to_android",
            kind: "rtp",
            dataBase64: packet.base64EncodedString(),
            bytes: packet.count,
            ts: Int64(Date().timeIntervalSince1970)
        )
        Task {
            do {
                let data = try encoder.encode(Envelope(t: EnvelopeType.miLinkMirrorMedia, b: body))
                try await session.sendPlaintext(data)
                if sentCount == 1 || sentCount % 500 == 0 {
                    DiagnosticsLog.info(
                        "xiaomi.mirror.cloudflare.datagram_out sessionId=\(sessionId) " +
                            "count=\(sentCount) bytes=\(packet.count)"
                    )
                }
            } catch {
                DiagnosticsLog.warn(
                    "xiaomi.mirror.cloudflare.datagram_send_failed sessionId=\(sessionId) count=\(sentCount)"
                )
            }
        }
    }

    private func handleMiLinkMirrorMedia(_ body: MiLinkMirrorMediaBody) {
        xiaomiMirrorRTSPDiagnosticSource.handleCloudflareMirrorMedia(body)
        guard body.kind == "status", let event = body.event else {
            return
        }
        DiagnosticsLog.info("xiaomi.mirror.cloudflare.status_ui sessionId=\(body.sessionId) event=\(event)")
        switch event {
        case "bridge_starting", "local_rtsp_connected":
            xiaomiMiLinkCommandStatus = String(localized: "小米鏡像連線中")
        case "bridge_ready":
            xiaomiMiLinkCommandStatus = String(localized: "小米鏡像串流準備中")
        case "source_start":
            xiaomiMiLinkCommandStatus = String(localized: "小米鏡像串流中")
        case "bridge_failed":
            xiaomiMiLinkCommandStatus = String(localized: "小米鏡像橋接失敗")
        case "bridge_stopped", "source_stop":
            if !xiaomiScreenUserStopped {
                xiaomiMiLinkCommandStatus = String(localized: "小米鏡像已停止")
            }
        default:
            break
        }
    }

    private enum XiaomiMirrorCastFrameError: Error {
        case invalidBase64
    }

    private func handleMiLinkCommandResult(_ result: MiLinkCommandResultBody) {
        let isMirrorPending = Self.isPendingMiMirrorCommandResult(result)
        let updatesCommandStatus = !Self.isXiaomiMirrorKeyboardCommand(result.command)
        if result.command == Self.xiaomiMirrorKeyboardReadyCommand {
            didPrepareXiaomiMirrorKeyboard = result.success
        }
        if updatesCommandStatus {
            if result.command == "xiaomi.mirror.requestSourceRecovery" {
                if !isPhoneScreenSessionActive {
                    xiaomiMiLinkCommandStatus = result.success ? String(localized: "小米鏡像來源已刷新") : String(localized: "小米鏡像來源刷新失敗")
                }
            } else if isMirrorPending {
                xiaomiMiLinkCommandStatus = String(localized: "小米鏡像啟動中")
            } else {
                xiaomiMiLinkCommandStatus = result.success ? String(localized: "小米服務已接手") : String(localized: "小米服務失敗：\(result.message)")
            }
        }
        let pending = pendingXiaomiScreenFallback
        let elapsedMs = pending?.requestId == result.requestId ? pending?.elapsedMs : nil
        DiagnosticsLog.info(
            "xiaomi.mac.command_result requestId=\(result.requestId) command=\(result.command) " +
                "success=\(result.success) route=\(result.route) " +
                "elapsedMs=\(elapsedMs.map(String.init) ?? "unknown") " +
                "message=\(result.message) data=\(Self.formatDiagnosticsData(result.data))"
        )

        guard let pending, pending.requestId == result.requestId else {
            if result.command == "xiaomi.mirror.startMainDisplay" {
                DiagnosticsLog.warn(
                    "xiaomi.mac.command_result_unmatched requestId=\(result.requestId) command=\(result.command) " +
                        "success=\(result.success) route=\(result.route) data=\(Self.formatDiagnosticsData(result.data))"
                )
                DiagnosticsLog.info(
                    "xiaomi.mac.screen_recovery_suppressed reason=late_result phase=command_result " +
                        "requestId=\(result.requestId) command=\(result.command) route=\(result.route)"
                )
            }
            return
        }

        if pending.fallbackStarted {
            pendingXiaomiScreenFallback = nil
            DiagnosticsLog.warn(
                "xiaomi.mac.command_result_late requestId=\(result.requestId) command=\(result.command) " +
                    "success=\(result.success) route=\(result.route) elapsedMs=\(pending.elapsedMs) " +
                    "message=\(result.message) data=\(Self.formatDiagnosticsData(result.data))"
            )
            return
        }

        pendingXiaomiScreenFallback = nil
        pendingXiaomiScreenFallbackTask?.cancel()
        pendingXiaomiScreenFallbackTask = nil

        if let cloudSessionId = Self.xiaomiMirrorCloudflareSessionId(from: result) {
            activeXiaomiMirrorCloudflareSessionId = cloudSessionId
            xiaomiMiLinkCommandStatus = String(localized: "小米鏡像連線中")
            xiaomiMirrorRTSPDiagnosticSource.startCloudflareMirrorRTPReceiver(
                sessionId: cloudSessionId,
                lifetime: Self.xiaomiMirrorRTSPDiagnosticLifetimeSeconds,
                reason: "xiaomi_command_result"
            )
            DiagnosticsLog.info(
                "xiaomi.mac.screen_pending_cloudflare requestId=\(result.requestId) command=\(pending.command) " +
                    "route=\(pending.route) elapsedMs=\(pending.elapsedMs) sessionId=\(cloudSessionId) " +
                    "data=\(Self.formatDiagnosticsData(result.data))"
            )
            if isMirrorPending {
                return
            }
        }

        if isMirrorPending, let sourceEndpoint = Self.xiaomiMirrorAndroidSourceEndpoint(from: result) {
            xiaomiMiLinkCommandStatus = String(localized: "小米鏡像連線中")
            DiagnosticsLog.info(
                "xiaomi.mac.screen_pending_active_client requestId=\(result.requestId) command=\(pending.command) " +
                    "route=\(pending.route) elapsedMs=\(pending.elapsedMs) " +
                    "source=\(sourceEndpoint.host):\(sourceEndpoint.port) data=\(Self.formatDiagnosticsData(result.data))"
            )
            connectXiaomiMirrorRTSPDiagnosticSource(
                host: sourceEndpoint.host,
                port: sourceEndpoint.port,
                reason: "xiaomi_pending_android_server"
            )
            return
        }

        if isMirrorPending {
            xiaomiMiLinkCommandStatus = String(localized: "小米鏡像未完成")
            DiagnosticsLog.warn(
                "xiaomi.mac.screen_no_fallback requestId=\(result.requestId) command=\(pending.command) " +
                    "route=\(pending.route) reason=pending elapsedMs=\(pending.elapsedMs) " +
                    "message=\(result.message) data=\(Self.formatDiagnosticsData(result.data))"
            )
            return
        }

        if result.success {
            hasViewedPhoneScreen = true
            DiagnosticsLog.info(
                "xiaomi.mac.screen_started requestId=\(result.requestId) route=\(result.route) " +
                    "elapsedMs=\(pending.elapsedMs) data=\(Self.formatDiagnosticsData(result.data))"
            )
        } else {
            xiaomiMiLinkCommandStatus = String(localized: "小米鏡像失敗")
            activeXiaomiMirrorCloudflareSessionId = nil
            xiaomiMirrorRTSPDiagnosticSource.stopCloudflareMirrorRTPReceiver(reason: "command_result_failed")
            DiagnosticsLog.warn(
                "xiaomi.mac.screen_no_fallback requestId=\(result.requestId) command=\(pending.command) " +
                    "route=\(pending.route) reason=result_failed elapsedMs=\(pending.elapsedMs) " +
                    "message=\(result.message) data=\(Self.formatDiagnosticsData(result.data))"
            )
        }
    }

    private static func isPendingMiMirrorCommandResult(_ result: MiLinkCommandResultBody) -> Bool {
        guard result.command == "xiaomi.mirror.startMainDisplay" else {
            return false
        }
        if result.route == "xiaomi.mirror.pending" {
            return true
        }
        guard result.route.hasPrefix("xiaomi.mirror"),
              result.data["fallback"] != "edgelink.screen" else {
            return false
        }
        return result.data["state"] == "pending" ||
            result.data["pending"] == "true" ||
            result.data["providerValue"] == "pending"
    }

    private static func isXiaomiMirrorKeyboardCommand(_ command: String) -> Bool {
        command == xiaomiMirrorKeyboardCommand || command == xiaomiMirrorKeyboardReadyCommand ||
            command == xiaomiMirrorKeyboardReleaseCommand
    }

    private static func xiaomiMirrorAndroidSourceEndpoint(
        from result: MiLinkCommandResultBody
    ) -> (host: String, port: UInt16)? {
        guard result.command == "xiaomi.mirror.startMainDisplay",
              result.route == "xiaomi.mirror.pending",
              result.data["sourceRole"] == "android_server",
              let rawHost = result.data["sourceListenHost"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawHost.isEmpty,
              rawHost != "0.0.0.0",
              let rawPort = result.data["sourceListenPort"],
              let portValue = UInt16(rawPort) else {
            return nil
        }
        return (rawHost, portValue)
    }

    private static func xiaomiMirrorCloudflareSessionId(from result: MiLinkCommandResultBody) -> String? {
        guard result.command == "xiaomi.mirror.startMainDisplay",
              result.data["mediaTransport"] == "cloudflare",
              result.data["sourceRole"] == "android_cloud_bridge" || result.data["cloudBridge"] == "true",
              let sessionId = result.data["mirrorSessionId"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionId.isEmpty else {
            return nil
        }
        return sessionId
    }

    private static func xiaomiScreenRouteCandidate(
        from status: MiLinkStatusBody?,
        preferredRoute: String?
    ) -> String? {
        if preferredRoute?.hasPrefix("xiaomi.") == true {
            return preferredRoute
        }
        return status?.services?.first { service in
            service.category == "screen" &&
                service.available &&
                service.route.hasPrefix("xiaomi.")
        }?.id
    }

    private func autoWarmXiaomiServicesIfNeeded(_ status: MiLinkStatusBody) {
        guard isConnected else {
            return
        }
        let prefersXiaomiMirror =
            Self.xiaomiScreenRouteCandidate(
                from: status,
                preferredRoute: status.preferredRoutes?["screen"]
            )?.hasPrefix("xiaomi.") == true ||
            status.preferredRoutes?["recentApps"]?.hasPrefix("xiaomi.") == true
        if !didAutoQueryXiaomiMirrorDevices, prefersXiaomiMirror {
            didAutoQueryXiaomiMirrorDevices = true
            sendMiLinkCommand(command: "xiaomi.mirror.queryRemoteDevices")
        }
        if !didAutoBindXiaomiDistAudio,
           status.preferredRoutes?["audio"] == "xiaomi.audiomonitor.DistAudioService" {
            didAutoBindXiaomiDistAudio = true
            sendMiLinkCommand(command: "xiaomi.distaudio.bind")
        }
    }

    private func handleVerificationCode(_ candidate: VerificationCodeCandidate, message: SmsMessageBody) {
        latestVerificationCode = candidate
        DiagnosticsLog.info(
            "verification.mac.detected id=\(candidate.id) codeFp=\(Self.fingerprint(candidate.code)) domain=\(candidate.domain ?? "none") addressFp=\(Self.fingerprint(message.address))"
        )

        if verificationCodeAutoCopyEnabled {
            copyVerificationCode(candidate.code, reason: "auto")
        }
        if verificationCodeSystemBridgeEnabled {
            verificationCodeBridge.deliver(candidate)
        }
        notificationPresenter.showVerificationCode(candidate, message: message)
    }

    private func copyVerificationCode(_ code: String, reason: String) {
        clipboardSync.setLocalTextWithoutPublishing(code)
        DiagnosticsLog.info("verification.mac.copied reason=\(reason) codeFp=\(Self.fingerprint(code))")
    }

    private func handleSmsSendResult(_ result: SmsSendResultBody) {
        let pending = pendingSmsSends.removeValue(forKey: result.requestId)
        if result.success {
            smsSendStatus = String(localized: "SMS 已送出佇列")
            if let pending {
                handleSmsMessage(
                    SmsMessageBody(
                        id: "sms:local:\(result.requestId)",
                        sourceDeviceId: localIdentity?.deviceId,
                        sourcePlatform: "macos",
                        address: result.to,
                        text: pending.text,
                        direction: "outbound",
                        isBackfill: false,
                        ts: result.ts
                    )
                )
            }
            DiagnosticsLog.info("sms.mac.send_result requestId=\(result.requestId) success=true toFp=\(Self.fingerprint(result.to))")
        } else {
            let smsErrorMessage = result.error ?? String(localized: "未知錯誤")
            smsSendStatus = String(localized: "SMS 失敗：\(smsErrorMessage)")
            DiagnosticsLog.warn("sms.mac.send_result requestId=\(result.requestId) success=false error=\(result.error ?? "unknown")")
        }
    }

    private func handlePhoneCallStatus(_ status: PhoneCallStatusBody) {
        if status.callId == "all" {
            incomingCallPresenter.endAll(reason: .remoteEnded)
            phoneCallStatuses.removeAll()
            incomingPhoneCallLabel = ""
            if isPhoneCallActive {
                stopPhoneCallRelayAudio(reason: "phone_call_status_all_ended")
            }
            isPhoneCallActive = false
            phoneCallStatus = String(localized: "通話已結束")
            DiagnosticsLog.info("phone.mac.call_status_all reason=\(status.reason) state=\(status.state)")
            return
        }

        let caller = Self.phoneCallCallerLabel(status)
        switch status.state {
        case "ringing":
            phoneCallStatuses[status.callId] = status
            incomingPhoneCallLabel = caller
            phoneCallStatus = String(localized: "手機來電：\(caller)")
            incomingCallPresenter.reportIncomingCall(status)
        case "active", "dialing", "connecting", "held":
            phoneCallStatuses[status.callId] = status
            if status.state == "active", !incomingCallPresenter.wasAnsweredByIncomingUI(callId: status.callId) {
                incomingCallPresenter.endCall(status, reason: .answeredElsewhere)
            }
            incomingPhoneCallLabel = ""
            isPhoneCallActive = true
            phoneCallStatus = Self.localizedPhoneCallStatus(status, caller: caller)
        case "disconnected", "disconnecting", "ended":
            phoneCallStatuses.removeValue(forKey: status.callId)
            incomingCallPresenter.endCall(status, reason: .remoteEnded)
            if incomingPhoneCallLabel == caller {
                incomingPhoneCallLabel = ""
            }
            if phoneCallStatuses.isEmpty {
                if isPhoneCallActive {
                    stopPhoneCallRelayAudio(reason: "phone_call_status_\(status.state)")
                }
                isPhoneCallActive = false
                phoneCallStatus = String(localized: "通話已結束")
            }
        default:
            phoneCallStatuses[status.callId] = status
        }
        DiagnosticsLog.info(
            "phone.mac.call_status callId=\(status.callId) state=\(status.state) " +
                "direction=\(status.direction ?? "unknown") canAnswer=\(status.canAnswer) reason=\(status.reason)"
        )
    }

    private func handleIncomingCallUIAnswer(callId: String) {
        incomingPhoneCallLabel = ""
        phoneCallStatus = String(localized: "接聽手機來電中")
        _ = answerPhoneCall()
        DiagnosticsLog.info("phone.mac.incoming_ui_answer callId=\(callId)")
    }

    private func handleIncomingCallUIHangUp(callId: String) {
        incomingPhoneCallLabel = ""
        phoneCallStatus = String(localized: "拒接手機來電中")
        _ = hangUpPhoneCall()
        DiagnosticsLog.info("phone.mac.incoming_ui_hangup callId=\(callId)")
    }

    private func handlePhoneActionResult(_ result: PhoneActionResultBody) {
        let pendingAction = pendingPhoneActions.removeValue(forKey: result.requestId)
        if result.requestId == phoneRelayDebugDialRequestID && !result.success {
            phoneRelayDebugDialError = result.error ?? "unknown"
        }
        if result.success {
            if result.action == "dial" || result.action == "answer" {
                isPhoneCallActive = true
            }
            if result.action == "hangup" {
                let isRemoteHangup = pendingAction == nil
                stopPhoneCallRelayAudio(reason: isRemoteHangup ? "remote_phone_hangup" : "phone_action_result_hangup")
                isPhoneCallActive = false
                phoneCallStatus = isRemoteHangup
                    ? String(localized: "通話已結束")
                    : Self.localizedPhoneActionSent(result.action)
                DiagnosticsLog.info(
                    "phone.mac.action_result requestId=\(result.requestId) action=\(result.action) " +
                        "success=true remoteHangup=\(isRemoteHangup)"
                )
                return
            }
            phoneCallStatus = Self.localizedPhoneActionSent(result.action)
            DiagnosticsLog.info("phone.mac.action_result requestId=\(result.requestId) action=\(result.action) success=true")
        } else {
            if result.action == "dial" || result.action == "answer" {
                stopPhoneCallRelayAudio(reason: "phone_action_failed_\(result.action)")
                isPhoneCallActive = false
            }
            let phoneActionError = result.error ?? String(localized: "未知錯誤")
            phoneCallStatus = Self.localizedPhoneActionFailureMessage(result.action, error: phoneActionError)
            DiagnosticsLog.warn(
                "phone.mac.action_result requestId=\(result.requestId) action=\(result.action) success=false error=\(result.error ?? "unknown")"
            )
        }
    }

    private func stopPhoneCallRelayAudio(reason: String) {
        stopPhoneRelayUplink(reason: reason)
        phoneRelayAudioController.stopDownlink(reason: reason)
        stopPhoneRelaySession(reason: reason)
        stopPhoneRelayProbe(reason: reason)
        phoneRelayProbe.stopExternalSourceRTP(reason: reason)
        callRelayCloudflareBridge.stop(reason: reason)
        activePhoneRelaySessionId = nil
        phoneRelaySourceSequence = 0
        phoneRelaySourceSendFailed = false
    }

    private func handleAndroidMicStatus(_ status: AndroidMicStatusBody) {
        let source = status.sourceName ?? status.source.map(String.init) ?? "unknown"
        if status.active {
            androidMicRelayArmed = true
            if phoneRelaySessionRunning {
                DiagnosticsLog.info(
                    "mic.mac.android_probe_skipped source=\(source) reason=phone_relay_session_running"
                )
            } else {
                ensurePhoneRelayProbeEnabled(reason: "android_mic_\(source)")
                phoneRelayProbe.armSourceRTP(reason: "android_mic_\(source)")
            }
            DiagnosticsLog.info(
                "mic.mac.android_active source=\(source) count=\(status.activeRecordingCount) " +
                    "session=\(status.sessionId.map(String.init) ?? "none") reason=\(status.reason)"
            )
        } else {
            if androidMicRelayArmed {
                stopPhoneRelayProbe(reason: "android_mic_inactive")
            }
            androidMicRelayArmed = false
            DiagnosticsLog.info("mic.mac.android_inactive reason=\(status.reason)")
        }
    }

    private static func localizedPhoneActionInProgress(_ action: String) -> String {
        switch action {
        case "dial":
            return String(localized: "撥號中")
        case "answer":
            return String(localized: "接聽中")
        case "hangup":
            return String(localized: "掛斷中")
        case "dtmf":
            return String(localized: "按鍵中")
        default:
            return String(localized: "電話操作中")
        }
    }

    private static func localizedPhoneActionFailed(_ action: String) -> String {
        switch action {
        case "dial":
            return String(localized: "撥號失敗")
        case "answer":
            return String(localized: "接聽失敗")
        case "hangup":
            return String(localized: "掛斷失敗")
        case "dtmf":
            return String(localized: "按鍵失敗")
        default:
            return String(localized: "電話操作失敗")
        }
    }

    private static func localizedPhoneActionSent(_ action: String) -> String {
        switch action {
        case "dial":
            return String(localized: "撥號已送出")
        case "answer":
            return String(localized: "接聽已送出")
        case "hangup":
            return String(localized: "掛斷已送出")
        case "dtmf":
            return String(localized: "按鍵已送出")
        default:
            return String(localized: "電話操作已送出")
        }
    }

    private static func localizedPhoneActionFailureMessage(_ action: String, error: String) -> String {
        switch action {
        case "dial":
            return String(localized: "撥號失敗：\(error)")
        case "answer":
            return String(localized: "接聽失敗：\(error)")
        case "hangup":
            return String(localized: "掛斷失敗：\(error)")
        case "dtmf":
            return String(localized: "按鍵失敗：\(error)")
        default:
            return String(localized: "電話操作失敗：\(error)")
        }
    }

    private static func phoneCallCallerLabel(_ status: PhoneCallStatusBody) -> String {
        if let displayName = status.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !displayName.isEmpty {
            return displayName
        }
        if let handle = status.handle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !handle.isEmpty {
            return handle
        }
        return String(localized: "未知號碼")
    }

    private static func localizedPhoneCallStatus(_ status: PhoneCallStatusBody, caller: String) -> String {
        switch status.state {
        case "dialing":
            return String(localized: "手機撥號中：\(caller)")
        case "connecting":
            return String(localized: "手機通話連線中：\(caller)")
        case "held":
            return String(localized: "手機通話保留中：\(caller)")
        case "active":
            return String(localized: "手機通話中：\(caller)")
        default:
            return String(localized: "手機通話：\(caller)")
        }
    }

    private static func sanitizeDTMFSequence(_ raw: String) -> String? {
        var normalized = ""
        for character in raw.trimmingCharacters(in: .whitespacesAndNewlines) {
            switch character {
            case "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "*", "#", ",":
                normalized.append(character)
            case "＊":
                normalized.append("*")
            case "＃":
                normalized.append("#")
            case "，", "p", "P":
                normalized.append(",")
            case " ", "\t", "\n", "\r", "-":
                continue
            default:
                return nil
            }
        }
        guard !normalized.isEmpty,
              normalized.count <= 32,
              normalized.contains(where: { $0.isNumber || $0 == "*" || $0 == "#" }),
              normalized.allSatisfy({ $0.isNumber || $0 == "*" || $0 == "#" || $0 == "," }) else {
            return nil
        }
        return normalized
    }

    private static func fingerprint(_ value: String) -> String {
        DiagnosticsLog.fingerprint(Data(value.utf8))
    }

    private static func formatDiagnosticsData(_ data: [String: String]) -> String {
        if data.isEmpty {
            return "{}"
        }
        return data
            .sorted { lhs, rhs in lhs.key < rhs.key }
            .map { key, value in "\(key)=\(value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " "))" }
            .joined(separator: "|")
    }

    private static func formatSeconds(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private static func formatOptionalSeconds(_ value: Double?) -> String {
        value.map { String(format: "%.2f", $0) } ?? "none"
    }

    private static let macNotificationSyncDefaultsKey = "macNotificationSyncEnabled"
    private static let verificationCodeSystemBridgeDefaultsKey = "verificationCodeSystemBridgeEnabled"
    private static let verificationCodeAutoCopyDefaultsKey = "verificationCodeAutoCopyEnabled"
    private static let lastDialedPhoneNumberDefaultsKey = "lastDialedPhoneNumber"
    private static let phoneRelayEchoCancellationDefaultsKey = "phoneRelayEchoCancellationEnabled"
    private static let phoneRelayProbePeerHostDefaultsKey = "phoneRelayProbePeerHost"
    private static let phoneRelayProbePeerPortDefaultsKey = "phoneRelayProbePeerPort"
    private static let phoneRelayProbePort: UInt16 = 7102
    private static let xiaomiScreenPrimaryRouteDefaultsKey = "xiaomiScreenPrimaryRouteEnabled"
    private static let xiaomiMirrorCloudflareMediaDefaultsKey = "xiaomiMirrorCloudflareMediaEnabled"
    private static let xiaomiMirrorRTSPDiagnosticEnabledDefaultsKey = "xiaomiMirrorRTSPDiagnosticEnabled"
    private static let xiaomiMirrorRTSPDiagnosticPort: UInt16 = 7102
    private static let xiaomiMirrorRTSPDiagnosticLifetimeSeconds: TimeInterval = 1800
    private static let xiaomiScreenRecoveryDelayNanoseconds: UInt64 = 150_000_000
    private static let xiaomiScreenRecoveryHighAttemptWarningThreshold = 3
    private static let xiaomiScreenSourceRecoveryMaxAttempts = 2
    private static let xiaomiScreenSessionRebuildAfterNoFrameSeconds: Double = 18
    private static let xiaomiScreenSessionRebuildAfterNoPacketSeconds: Double = 30
    private static let xiaomiScreenSessionRebuildStartupNoPacketSeconds: Double = 10
    private static let xiaomiScreenSourceRecoveryCooldownSeconds: TimeInterval = 10
    private static let xiaomiScreenSourceRecoveryStartupCooldownSeconds: TimeInterval = 3
    private static let xiaomiScreenStartupDecodedFrameThreshold: UInt64 = 300
    private static let xiaomiScreenSessionRebuildCooldownSeconds: TimeInterval = 45
    private static let xiaomiScreenSessionRebuildTimeoutMs = 12_000
    private static let phoneRelayDebugDefaultNumber = "800"
    private static let phoneRelayDebugMaxTimeoutSeconds: TimeInterval = 30

    private static func xiaomiMirrorRTSPDiagnosticEnabled() -> Bool {
        UserDefaults.standard.object(forKey: xiaomiMirrorRTSPDiagnosticEnabledDefaultsKey) as? Bool ?? true
    }

    private static func xiaomiMirrorCloudflareMediaEnabled() -> Bool {
        UserDefaults.standard.object(forKey: xiaomiMirrorCloudflareMediaDefaultsKey) as? Bool ?? true
    }

    private static func phoneRelayProbePeerPort() -> UInt16 {
        let value = UserDefaults.standard.integer(forKey: phoneRelayProbePeerPortDefaultsKey)
        guard value > 0, value <= Int(UInt16.max) else {
            return phoneRelayProbePort
        }
        return UInt16(value)
    }

    private static func phoneRelayAdvertisedHost() -> String? {
        if let override = UserDefaults.standard.string(forKey: "phoneRelayProbeSourceHost")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return override
        }
        return MiLinkPhoneRelayProbe.preferredLocalIPv4Address()
    }

    private static func xiaomiMirrorAdvertisedHost() -> String? {
        let current = MiLinkPhoneRelayProbe.preferredLocalIPv4Address()
        let override = UserDefaults.standard.string(forKey: "phoneRelayProbeSourceHost")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let current, !current.isEmpty {
            if let override, !override.isEmpty, override != current {
                DiagnosticsLog.info(
                    "xiaomi.mirror.rtsp.advertised_host_override_ignored " +
                        "override=\(override) current=\(current)"
                )
            }
            return current
        }
        return override?.isEmpty == false ? override : nil
    }
}

enum EdgeLinkConfig {
    static let workerBaseURL = URL(string: "https://edgelink-worker.black-hill-f944.workers.dev")!
    static let relayURL = URL(string: "wss://edgelink-worker.black-hill-f944.workers.dev/v1/connect")!
    static let pairingWebSocketURL = URL(string: "wss://edgelink-worker.black-hill-f944.workers.dev/v1/pair/ws")!
}

private struct PhoneRelayEndpoint {
    let host: String?
    let port: Int
    let sessionId: String?
    let controlPort: Int?
    let lanHost: String?
    let lanPort: Int?
    let lanProbePort: Int?

    init(
        host: String?,
        port: Int,
        sessionId: String? = nil,
        controlPort: Int? = nil,
        lanHost: String? = nil,
        lanPort: Int? = nil,
        lanProbePort: Int? = nil
    ) {
        self.host = host
        self.port = port
        self.sessionId = sessionId
        self.controlPort = controlPort
        self.lanHost = lanHost
        self.lanPort = lanPort
        self.lanProbePort = lanProbePort
    }
}

private struct MacPendingPairing {
    let hostId: String
    let clientId: String
    let hostPkBase64: String
    let clientPkBase64: String
    let hostName: String
    let clientName: String
    let clientPublicKey: Data

    func confirmRequest() -> PairConfirmRequest {
        PairConfirmRequest(
            role: "host",
            hostId: hostId,
            clientId: clientId,
            hostPk: hostPkBase64,
            clientPk: clientPkBase64,
            hostName: hostName,
            clientName: clientName
        )
    }
}

private enum PairingRuntimeError: Error {
    case invalidPeerMessage
}

private enum SecureKeepaliveError: Error {
    case receiveLoopEnded
    case pongTimedOut
    case redundantSession
}
