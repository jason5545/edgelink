import AppKit
import Combine
import CryptoKit
import EdgeLinkKit
import Foundation

@MainActor
final class EdgeLinkRuntime: ObservableObject {
    private static let secureKeepaliveIntervalNanoseconds: UInt64 = 5_000_000_000
    private static let securePongTimeoutSeconds: TimeInterval = 15
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
    @Published private(set) var latestMiLinkStatus: MiLinkStatusBody?
    @Published private(set) var latestMiLinkFrame: MiLinkFrameBody?
    @Published private(set) var xiaomiMiLinkCommandStatus = ""
    @Published private(set) var xiaomiHyperConnectAvailable = XiaomiHyperConnectBridge.isInstalled
    @Published private(set) var xiaomiMiShareDiscoveryStatus = "小米快傳 discovery：準備中"
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
    private let clipboardSync = ClipboardSync()
    private let notificationPresenter = MacNotificationPresenter()
    private let incomingCallPresenter = MacIncomingCallPresenter()
    private let verificationCodeBridge = MacVerificationCodeBridge()
    private let macNotificationSource = MacNotificationDatabaseSource()
    private let screenSession = MacScreenSession()
    private let turnCredentialClient: TurnCredentialClient
    private let callRelayGatewayClient: CallRelayGatewayClient
    private let phoneRelayProbe = MiLinkPhoneRelayProbe()
    private let xiaomiMirrorRTSPDiagnosticSource = XiaomiMirrorRTSPDiagnosticSource()
    private let xiaomiMiShareDiscovery = XiaomiMiShareDiscovery()
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
    private var lastSecurePongAt = Date.distantPast
    private var systemSleepWakeCancellables = Set<AnyCancellable>()
    private var pendingSmsSends: [String: SmsSendBody] = [:]
    private var pendingPhoneActions: [String: PhoneActionBody] = [:]
    private var phoneCallStatuses: [String: PhoneCallStatusBody] = [:]
    private var androidMicRelayArmed = false
    private var phoneRelayProbeRunning = false
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
    private var didAutoBindXiaomiDistAudio = false
    private var didAutoQueryXiaomiMirrorDevices = false

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
        lastDialedPhoneNumber = UserDefaults.standard.string(forKey: Self.lastDialedPhoneNumberDefaultsKey) ?? ""
        pairingStore = try? ApplicationSupportPairingStore()
        registrar = WorkerDeviceRegistrar(baseURL: workerBaseURL)
        relayTransport = RelayTransport(endpoint: relayURL)
        pairingTransport = PairingTransport(baseURL: workerBaseURL, webSocketURL: pairingWebSocketURL)
        turnCredentialClient = TurnCredentialClient(baseURL: workerBaseURL)
        callRelayGatewayClient = CallRelayGatewayClient(
            host: EdgeLinkConfig.callRelayGatewayHost,
            port: EdgeLinkConfig.callRelayGatewayControlPort
        )
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
        xiaomiMirrorRTSPDiagnosticSource.onDecodedFrame = { [weak self, screenSession] pixelBuffer, width, height in
            Task { @MainActor in
                self?.xiaomiScreenRecoveryAttempt = 0
                self?.xiaomiScreenLastSourceRecoveryDecodedFrames = nil
                screenSession.renderXiaomiMirrorFrame(pixelBuffer, width: width, height: height)
            }
        }
        xiaomiMirrorRTSPDiagnosticSource.onRecoveryRequired = { [weak self] event in
            Task { @MainActor in
                self?.handleXiaomiMirrorRTSPRecoveryRequired(event)
            }
        }
        xiaomiMirrorRTSPDiagnosticSource.onPeerStop = { [weak self] reason, sessionID in
            Task { @MainActor in
                self?.handleXiaomiMirrorPeerStop(reason: reason, sessionID: sessionID)
            }
        }
        phoneRelayProbe.onSinkPCMStats = { [weak self] stats in
            Task { @MainActor in
                self?.handlePhoneRelayPCMStats(stats)
            }
        }
        xiaomiMiShareDiscovery.onSnapshotChanged = { [weak self] snapshot in
            Task { @MainActor in
                self?.handleXiaomiMiShareDiscoverySnapshot(snapshot)
            }
        }
        callRelayGatewayClient.onSourceStart = { [weak self] reason in
            self?.phoneRelayProbe.startExternalSourceRTP(reason: "gateway_\(reason)") { [weak self] packet in
                self?.callRelayGatewayClient.sendSourceRTPPacket(packet)
            }
        }
        callRelayGatewayClient.onSourceStop = { [weak self] reason in
            self?.phoneRelayProbe.stopExternalSourceRTP(reason: "gateway_\(reason)")
        }
        callRelayGatewayClient.onPlaybackStats = { [weak self] stats in
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
        phoneRelayProbe.stop()
        xiaomiMirrorRTSPDiagnosticSource.stop(reason: "runtime_deinit")
        xiaomiMiShareDiscovery.stop()
        callRelayGatewayClient.close(reason: "runtime_deinit")
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
        guard isConnected else {
            DiagnosticsLog.warn("screen.mac.start_ignored not_connected")
            return
        }
        let preferredScreenRoute = latestMiLinkStatus?.preferredRoutes?["screen"]
        let xiaomiScreenRoute = Self.xiaomiScreenRouteCandidate(
            from: latestMiLinkStatus,
            preferredRoute: preferredScreenRoute
        )
        if xiaomiScreenRoute?.hasPrefix("xiaomi.") == true {
            guard Self.allowXiaomiScreenPrimaryRoute else {
                xiaomiMiLinkCommandStatus = "小米鏡像已停用"
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
                xiaomiMiLinkCommandStatus = "小米鏡像啟動中"
                DiagnosticsLog.info(
                    "xiaomi.mac.screen_start_gate reason=pending requestId=\(pending.requestId) " +
                        "route=\(pending.route) elapsedMs=\(pending.elapsedMs)"
                )
                return
            }
            if xiaomiScreenRecoveryTask != nil {
                xiaomiMiLinkCommandStatus = "小米鏡像恢復中"
                DiagnosticsLog.info(
                    "xiaomi.mac.screen_start_gate reason=recovering " +
                        "attempt=\(xiaomiScreenRecoveryAttempt)"
                )
                return
            }
            if isPhoneScreenSessionActive {
                screenSession.showActiveWindow()
                isPhoneScreenViewerVisible = true
                hasViewedPhoneScreen = true
                xiaomiScreenUserStopped = false
                DiagnosticsLog.info(
                    "xiaomi.mac.screen_start_gate reason=active_show_existing " +
                        "route=\(xiaomiScreenRoute ?? "unknown")"
                )
                return
            }
            let command = "xiaomi.mirror.startMainDisplay"
            let timeoutMs = 12_000
            let peerHost = Self.xiaomiMirrorAdvertisedHost()
            let peerPort = Self.xiaomiMirrorRTSPDiagnosticPort
            xiaomiScreenUserStopped = false
            resetXiaomiScreenRecoveryState(reason: "manual_start")
            startXiaomiMirrorRTSPDiagnosticSourceIfNeeded(peerHost: peerHost, reason: "screen_route")
            DiagnosticsLog.info(
                "xiaomi.mac.screen_route_selected command=\(command) route=\(xiaomiScreenRoute ?? "unknown") " +
                    "preferredRoute=\(preferredScreenRoute ?? "unknown") " +
                    "officialDiscoveryRequired=\(latestMiLinkStatus?.officialDiscoveryRequired ?? false) " +
                    "phoneDevices=\(latestMiLinkStatus?.phoneRemoteDeviceCount ?? 0) " +
                    "hyperConnectInstalled=\(xiaomiHyperConnectAvailable) gatedByOfficialApp=false " +
                    "peerHost=\(peerHost ?? "default") peerPort=\(peerPort) fakeRemote=true " +
                    "xiaomiMirrorDeviceId=none timeoutMs=\(timeoutMs)"
            )
            var args: [String: String] = [:]
            if let peerHost {
                args["peerHost"] = peerHost
            }
            args["peerPort"] = String(peerPort)
            args["forceFakeRemote"] = "true"
            let requestId = sendMiLinkCommand(
                command: command,
                args: args
            )
            if let requestId {
                armPendingXiaomiScreenCommand(
                    requestId: requestId,
                    command: command,
                    route: xiaomiScreenRoute ?? "unknown",
                    timeoutMs: timeoutMs
                )
                return
            }
            DiagnosticsLog.warn("xiaomi.mac.screen_command_failed_before_send route=\(xiaomiScreenRoute ?? "unknown")")
            xiaomiMiLinkCommandStatus = "小米鏡像指令未送出"
            return
        }
        startEdgeLinkPhoneScreen(reason: "generic")
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
                self.xiaomiMiLinkCommandStatus = "小米鏡像未回應"
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
        stopXiaomiMirrorRTSPDiagnosticSource(reason: "disconnect")
        didAutoBindXiaomiDistAudio = false
        didAutoQueryXiaomiMirrorDevices = false

        let shouldSendRemoteStop = isConnected
        screenSession.hideWindowAndStop(sendRemoteStop: shouldSendRemoteStop)
        currentChannel?.close()
        currentChannel = nil
        currentChannelGeneration = nil
        currentSession = nil
        screenSession.clearSender()
        screenSession.setIceServerConfigs([])
        screenSession.setMicrophoneRelayEnabled(false)
        stopPhoneRelayProbe(reason: "disconnect")
        callRelayGatewayClient.close(reason: "disconnect")
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
            smsSendStatus = "請填收件人與訊息"
            return
        }
        guard let session = currentSession, isConnected else {
            smsSendStatus = "SMS 目前不可用"
            DiagnosticsLog.warn("sms.mac.send_ignored not_connected")
            return
        }

        let requestId = UUID().uuidString
        let body = SmsSendBody(requestId: requestId, to: recipient, text: text)
        pendingSmsSends[requestId] = body
        smsSendStatus = "正在送出 SMS"

        Task {
            do {
                let data = try encoder.encode(Envelope(t: EnvelopeType.smsSend, b: body))
                try await session.sendPlaintext(data)
                DiagnosticsLog.info("sms.mac.send_requested requestId=\(requestId) toFp=\(Self.fingerprint(recipient))")
            } catch {
                await MainActor.run {
                    self.pendingSmsSends.removeValue(forKey: requestId)
                    self.smsSendStatus = "SMS 送出失敗"
                }
                DiagnosticsLog.error("sms.mac.send_request_failed requestId=\(requestId)", error)
            }
        }
    }

    @discardableResult
    func dialPhone(number rawNumber: String) -> String? {
        let number = rawNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !number.isEmpty else {
            phoneCallStatus = "請填電話號碼"
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
            phoneCallStatus = "通話中才能送按鍵"
            return nil
        }
        guard let sequence = Self.sanitizeDTMFSequence(rawSequence) else {
            phoneCallStatus = "請輸入客服按鍵"
            return nil
        }
        return sendPhoneAction(action: "dtmf", number: sequence)
    }

    func sendFilesWithXiaomiHyperConnect() {
        xiaomiHyperConnectAvailable = XiaomiHyperConnectBridge.isInstalled
        guard xiaomiHyperConnectAvailable else {
            xiaomiMiLinkCommandStatus = "小米互聯服務未安裝"
            DiagnosticsLog.warn("xiaomi.mac.transfer_ignored hyperconnect_missing")
            return
        }

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.title = "小米快傳"
        panel.prompt = "傳送"
        guard panel.runModal() == .OK else {
            return
        }

        do {
            try XiaomiHyperConnectBridge.openTransfer(fileURLs: panel.urls)
            xiaomiMiLinkCommandStatus = "已交給小米快傳"
            DiagnosticsLog.info("xiaomi.mac.transfer_opened files=\(panel.urls.count)")
        } catch {
            xiaomiMiLinkCommandStatus = "小米快傳開啟失敗"
            DiagnosticsLog.error("xiaomi.mac.transfer_failed", error)
        }
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
            xiaomiMiShareDiscoveryStatus = "小米快傳 discovery：identity 尚未就緒"
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
            publishText = "Mac 已廣播 \(deviceId)"
        } else if snapshot.isBrowsing {
            publishText = "Mac 廣播準備中"
        } else {
            publishText = "Mac 尚未開始"
        }

        let peerText: String
        if snapshot.peers.isEmpty {
            peerText = "未看到手機"
        } else {
            let names = snapshot.peers.prefix(2).map(\.displayLabel).joined(separator: "、")
            let suffix = snapshot.peers.count > 2 ? " 等 \(snapshot.peers.count) 台" : ""
            peerText = "看到 \(names)\(suffix)"
        }

        if let error = snapshot.lastError {
            xiaomiMiShareDiscoveryStatus = "小米快傳 discovery：\(publishText)，\(peerText)；\(error)"
        } else {
            xiaomiMiShareDiscoveryStatus = "小米快傳 discovery：\(publishText)，\(peerText)"
        }
    }

    func runPhoneRelayDebugCall(number rawNumber: String = "800", timeoutSeconds rawTimeout: TimeInterval = 30) {
        let number = rawNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.phoneRelayDebugDefaultNumber
            : rawNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let timeoutSeconds = min(max(rawTimeout, 1), Self.phoneRelayDebugMaxTimeoutSeconds)
        phoneRelayDebugTask?.cancel()
        phoneRelayDebugTask = Task { [weak self] in
            await self?.runPhoneRelayDebugCallTask(number: number, timeoutSeconds: timeoutSeconds)
        }
    }

    private func runPhoneRelayDebugCallTask(number: String, timeoutSeconds: TimeInterval) async {
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
                "numberFp=\(Self.fingerprint(number)) timeoutMs=\(Int(timeoutSeconds * 1000))"
        )

        guard let dialRequestID = dialPhone(number: number) else {
            DiagnosticsLog.warn("phonerelay.mac.debug_call_dial_not_sent session=\(sessionID.uuidString)")
            phoneRelayDebugTask = nil
            return
        }
        phoneRelayDebugDialRequestID = dialRequestID

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while !Task.isCancelled && Date() < deadline {
            if let dialError = phoneRelayDebugDialError {
                DiagnosticsLog.warn(
                    "phonerelay.mac.debug_call_dial_failed session=\(sessionID.uuidString) " +
                        "requestId=\(dialRequestID) error=\(dialError)"
                )
                phoneRelayDebugTask = nil
                return
            }
            if let gatewayStats = phoneRelayDebugValidGatewayStats,
               gatewayStats.hasValidStream {
                DiagnosticsLog.info("phonerelay.mac.debug_call_valid_gateway_stream \(gatewayStats.diagnosticSummary)")
                hangUpPhoneCall()
                phoneRelayDebugTask = nil
                return
            }
            if let stats = phoneRelayDebugValidStats,
               stats.sessionID == sessionID,
               stats.hasValidStream {
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
            DiagnosticsLog.info(
                "runtime.mac.url_debug_phone_relay numberFp=\(Self.fingerprint(number)) " +
                    "timeoutMs=\(Int(min(max(timeout, 1), Self.phoneRelayDebugMaxTimeoutSeconds) * 1000))"
            )
            runPhoneRelayDebugCall(number: number, timeoutSeconds: timeout)
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
            xiaomiMiLinkCommandStatus = "小米鏡像恢復中"
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
            xiaomiMiLinkCommandStatus = "小米鏡像已停用"
            DiagnosticsLog.warn(
                "xiaomi.mac.screen_recovery_skipped reason=disabled_by_user_default " +
                    "rtspSession=\(event.sessionID.uuidString) route=\(xiaomiScreenRoute)"
            )
            return
        }

        let peerHost = Self.xiaomiMirrorAdvertisedHost()
        let peerPort = Self.xiaomiMirrorRTSPDiagnosticPort
        let shouldRebuildSession = Self.shouldRebuildXiaomiScreenSession(event: event, attempt: attempt)
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
            DiagnosticsLog.warn(
                "xiaomi.mac.screen_recovery_command_start command=\(command) route=\(xiaomiScreenRoute) " +
                    "attempt=\(attempt) trigger=\(event.trigger) reason=\(event.reason) " +
                    "peerHost=\(peerHost ?? "default") peerPort=\(peerPort) fakeRemote=true " +
                    "action=session_rebuild timeoutMs=\(timeoutMs)"
            )
            guard let requestId = sendMiLinkCommand(command: command, args: args) else {
                xiaomiMiLinkCommandStatus = "小米鏡像重建指令未送出"
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
            armPendingXiaomiScreenCommand(
                requestId: requestId,
                command: command,
                route: xiaomiScreenRoute,
                timeoutMs: timeoutMs
            )
            xiaomiMiLinkCommandStatus = "小米鏡像重建連線中"
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
        DiagnosticsLog.warn(
            "xiaomi.mac.screen_recovery_command_start command=\(command) route=\(xiaomiScreenRoute) " +
                "attempt=\(attempt) trigger=\(event.trigger) reason=\(event.reason) " +
                "peerHost=\(peerHost ?? "default") peerPort=\(peerPort) fakeRemote=true " +
                "action=source_only_keep_rtsp"
        )
        guard let requestId = sendMiLinkCommand(command: command, args: args) else {
            xiaomiMiLinkCommandStatus = "小米鏡像恢復指令未送出"
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
            xiaomiMiLinkCommandStatus = "小米鏡像要求來源刷新"
        }
        DiagnosticsLog.info(
            "xiaomi.mac.screen_recovery_command_sent requestId=\(requestId) " +
                "command=\(command) attempt=\(attempt) action=source_only_keep_rtsp"
        )
    }

    private func handleXiaomiMirrorPeerStop(reason: String, sessionID: UUID) {
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
        pendingXiaomiScreenFallbackTask?.cancel()
        pendingXiaomiScreenFallbackTask = nil
        pendingXiaomiScreenFallback = nil
        xiaomiScreenRecoveryTask?.cancel()
        xiaomiScreenRecoveryTask = nil
        xiaomiScreenRecoveryAttempt = 0
        resetXiaomiScreenRecoveryState(reason: reason)
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
        let elapsed = now.timeIntervalSince(xiaomiScreenLastSourceRecoveryAt)
        guard elapsed >= 0,
              elapsed < Self.xiaomiScreenSourceRecoveryCooldownSeconds else {
            return false
        }
        let remainingMs = Int((Self.xiaomiScreenSourceRecoveryCooldownSeconds - elapsed) * 1_000)
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
                "cooldownMs=\(Int(Self.xiaomiScreenSourceRecoveryCooldownSeconds * 1_000))"
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
            return attempt > xiaomiScreenSourceRecoveryMaxAttempts &&
                event.elapsedMediaSeconds >= xiaomiScreenSessionRebuildAfterNoPacketSeconds
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
    private func sendMiLinkCommand(command: String, args: [String: String] = [:]) -> String? {
        guard let session = currentSession, isConnected else {
            xiaomiMiLinkCommandStatus = "小米服務目前未連線"
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
        xiaomiMiLinkCommandStatus = "小米服務執行中"
        Task { @MainActor [weak self] in
            await self?.sendMiLinkCommandBody(body, session: session)
        }
        return requestId
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
            xiaomiMiLinkCommandStatus = "小米服務送出失敗"
            DiagnosticsLog.error("xiaomi.mac.command_send_failed requestId=\(body.requestId) command=\(body.command)", error)
        }
    }

    @discardableResult
    private func sendPhoneAction(action: String, number: String? = nil) -> String? {
        guard let session = currentSession, isConnected else {
            phoneCallStatus = "電話目前不可用"
            DiagnosticsLog.warn("phone.mac.action_ignored action=\(action) not_connected")
            return nil
        }

        let requestId = UUID().uuidString
        phoneCallStatus = "\(Self.localizedPhoneAction(action))中"
        if action == "dial" || action == "answer" {
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                let credential = await self.ensureTurnCredentials(reason: "phone_action_\(action)")
                if credential != nil {
                    DiagnosticsLog.info("phone.mac.turn_credentials_ready action=\(action)")
                } else {
                    DiagnosticsLog.warn("phone.mac.turn_credentials_missing action=\(action)")
                }
                let endpoint = await self.preparePhoneRelayEndpoint(action: action)
                let body = PhoneActionBody(
                    requestId: requestId,
                    action: action,
                    number: number,
                    relayHost: endpoint.host,
                    relayPort: endpoint.port,
                    relaySessionId: endpoint.sessionId,
                    relayControlPort: endpoint.controlPort
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
            stopPhoneRelayProbe(reason: "phone_action_hangup")
            phoneRelayProbe.stopExternalSourceRTP(reason: "phone_action_hangup")
            callRelayGatewayClient.close(reason: "phone_action_hangup")
        }

        Task { @MainActor [weak self] in
            await self?.sendPhoneActionBody(body, session: session)
        }
        return requestId
    }

    private func preparePhoneRelayEndpoint(action: String) async -> PhoneRelayEndpoint {
        guard let identity = localIdentity else {
            return localPhoneRelayEndpoint(action: action, reason: "no_identity")
        }
        do {
            let gatewaySession = try await callRelayGatewayClient.startSession(identity: identity)
            DiagnosticsLog.info(
                "phone.mac.relay_endpoint action=\(action) mode=gateway " +
                    "host=\(gatewaySession.relayHost) port=\(gatewaySession.relayPort) " +
                    "sessionId=\(gatewaySession.sessionId)"
            )
            return PhoneRelayEndpoint(
                host: gatewaySession.relayHost,
                port: gatewaySession.relayPort,
                sessionId: gatewaySession.sessionId,
                controlPort: Int(EdgeLinkConfig.callRelayGatewayControlPort)
            )
        } catch {
            DiagnosticsLog.error("phone.mac.gateway_endpoint_failed action=\(action)", error)
            return localPhoneRelayEndpoint(action: action, reason: "gateway_failed")
        }
    }

    private func localPhoneRelayEndpoint(action: String, reason: String) -> PhoneRelayEndpoint {
        let relayHost = Self.phoneRelayAdvertisedHost()
        ensurePhoneRelayProbeEnabled(reason: "phone_action_\(action)_\(reason)")
        phoneRelayProbe.armSourceRTP(reason: "phone_action_\(action)_\(reason)")
        DiagnosticsLog.info(
            "phone.mac.relay_endpoint action=\(action) mode=lan_fallback " +
                "host=\(relayHost ?? "none") port=\(Self.phoneRelayProbePort) reason=\(reason)"
        )
        return PhoneRelayEndpoint(host: relayHost, port: Int(Self.phoneRelayProbePort))
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
                stopPhoneRelayProbe(reason: "phone_action_send_failed_\(body.action)")
                phoneRelayProbe.stopExternalSourceRTP(reason: "phone_action_send_failed_\(body.action)")
                callRelayGatewayClient.close(reason: "phone_action_send_failed_\(body.action)")
            }
            phoneCallStatus = "\(Self.localizedPhoneAction(body.action))失敗"
            DiagnosticsLog.error("phone.mac.action_request_failed requestId=\(body.requestId) action=\(body.action)", error)
        }
    }

    private func handlePhoneRelayStartRequest(_ request: PhoneRelayStartRequestBody) {
        guard let session = currentSession, isConnected else {
            DiagnosticsLog.warn("phone.mac.relay_start_ignored requestId=\(request.requestId) reason=\(request.reason) not_connected")
            return
        }

        phoneCallStatus = "手機通話接到 Mac 中"
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            let credential = await self.ensureTurnCredentials(reason: "phone_relay_start")
            if credential != nil {
                DiagnosticsLog.info("phone.mac.turn_credentials_ready action=phone_relay_start")
            } else {
                DiagnosticsLog.warn("phone.mac.turn_credentials_missing action=phone_relay_start")
            }
            let endpoint = await self.preparePhoneRelayEndpoint(action: "phone_relay_start")
            let success = endpoint.host != nil
            let body = PhoneRelayEndpointBody(
                requestId: request.requestId,
                relayHost: endpoint.host,
                relayPort: endpoint.port,
                relaySessionId: endpoint.sessionId,
                relayControlPort: endpoint.controlPort,
                success: success,
                error: success ? nil : "relay_endpoint_unavailable",
                ts: Int64(Date().timeIntervalSince1970)
            )
            if success {
                self.isPhoneCallActive = true
                self.phoneCallStatus = "手機通話已接到 Mac"
            } else {
                self.stopPhoneCallRelayAudio(reason: "phone_relay_endpoint_unavailable")
                self.phoneCallStatus = "接手機通話失敗"
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
                    "sessionId=\(body.relaySessionId ?? "none")"
            )
        } catch {
            stopPhoneCallRelayAudio(reason: "phone_relay_endpoint_send_failed")
            isPhoneCallActive = false
            phoneCallStatus = "接手機通話失敗"
            DiagnosticsLog.error("phone.mac.relay_endpoint_send_failed requestId=\(body.requestId)", error)
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

        connectionTask?.cancel()
        currentChannel?.close()
        currentChannel = nil
        currentChannelGeneration = nil
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
                    }
                }

                DiagnosticsLog.info("relay.mac.connect_start hostId=\(identity.deviceId) clientId=\(peer.deviceId)")
                isConnected = false
                canDisconnect = true
                connectionStatus = "Connecting relay"
                let connectedChannel = try await relayTransport.connect(hostId: identity.deviceId, identity: identity)
                guard currentConnectionGeneration == connectionGeneration else {
                    connectedChannel.close()
                    return
                }
                channel = connectedChannel
                currentChannel = connectedChannel
                currentChannelGeneration = channelGeneration

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
                    onMiLinkCommandResult: { [weak self] result in
                        Task { @MainActor in
                            self?.handleMiLinkCommandResult(result)
                        }
                    }
                )
                let session = SecureSessionHost(
                    channel: connectedChannel,
                    identity: identity,
                    peer: peer,
                    dispatcher: dispatcher
                )

                connectionStatus = "Handshaking"
                try await session.connect()
                guard currentConnectionGeneration == connectionGeneration else {
                    connectedChannel.close()
                    return
                }
                DiagnosticsLog.info("relay.mac.handshake_ok hostId=\(identity.deviceId) clientId=\(peer.deviceId)")
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
                retryDelay = 1_000_000_000

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
            } catch {
                if Task.isCancelled || currentConnectionGeneration != connectionGeneration {
                    DiagnosticsLog.info("relay.mac.connect_cancelled hostId=\(identity.deviceId) clientId=\(peer.deviceId)")
                    return
                }
                DiagnosticsLog.error("relay.mac.disconnected hostId=\(identity.deviceId) clientId=\(peer.deviceId)", error)
                isConnected = false
                currentSession = nil
                screenSession.clearSender()
                screenSession.handleTransportInterrupted()
                stopPhoneRelayProbe(reason: "transport_interrupted")
                androidMicRelayArmed = false
                isPhoneCallActive = false
                connectionStatus = "Disconnected"
                try? await Task.sleep(nanoseconds: retryDelay)
                retryDelay = min(retryDelay * 2, 30_000_000_000)
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

            let pongAgeSeconds = Date().timeIntervalSince(lastSecurePongAt)
            if pongAgeSeconds >= Self.securePongTimeoutSeconds {
                DiagnosticsLog.warn(
                    "relay.mac.pong_timeout hostId=\(hostId) clientId=\(clientId) ageMs=\(Int(pongAgeSeconds * 1000)) timeoutMs=\(Int(Self.securePongTimeoutSeconds * 1000))"
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
                    self?.handleSystemSleep()
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

    private func handleSystemSleep() {
        DiagnosticsLog.info("runtime.mac.system_sleep")
        currentChannel?.close()
    }

    private func handleSystemWake() {
        DiagnosticsLog.info("runtime.mac.system_wake")
        currentChannel?.close()
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
        smsMessages.removeAll { $0.id == message.id }
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
        DiagnosticsLog.info(
            "milink.mac.frame_received clientNo=\(frame.clientNo) seq=\(frame.sequence) " +
                "bytes=\(frame.bytes) hasNext=\(frame.hasNext) route=\(frame.route)"
        )
    }

    private func handleMiLinkCommandResult(_ result: MiLinkCommandResultBody) {
        let isMirrorPending = Self.isPendingMiMirrorCommandResult(result)
        if result.command == "xiaomi.mirror.requestSourceRecovery" {
            if !isPhoneScreenSessionActive {
                xiaomiMiLinkCommandStatus = result.success ? "小米鏡像來源已刷新" : "小米鏡像來源刷新失敗"
            }
        } else if isMirrorPending {
            xiaomiMiLinkCommandStatus = "小米鏡像啟動中"
        } else {
            xiaomiMiLinkCommandStatus = result.success ? "小米服務已接手" : "小米服務失敗：\(result.message)"
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

        if isMirrorPending, let sourceEndpoint = Self.xiaomiMirrorAndroidSourceEndpoint(from: result) {
            xiaomiMiLinkCommandStatus = "小米鏡像連線中"
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
            xiaomiMiLinkCommandStatus = "小米鏡像未完成"
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
            xiaomiMiLinkCommandStatus = "小米鏡像失敗"
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
            smsSendStatus = "SMS 已送出佇列"
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
            smsSendStatus = "SMS 失敗：\(result.error ?? "未知錯誤")"
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
            phoneCallStatus = "通話已結束"
            DiagnosticsLog.info("phone.mac.call_status_all reason=\(status.reason) state=\(status.state)")
            return
        }

        let caller = Self.phoneCallCallerLabel(status)
        switch status.state {
        case "ringing":
            phoneCallStatuses[status.callId] = status
            incomingPhoneCallLabel = caller
            phoneCallStatus = "手機來電：\(caller)"
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
                phoneCallStatus = "通話已結束"
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
        phoneCallStatus = "接聽手機來電中"
        _ = answerPhoneCall()
        DiagnosticsLog.info("phone.mac.incoming_ui_answer callId=\(callId)")
    }

    private func handleIncomingCallUIHangUp(callId: String) {
        incomingPhoneCallLabel = ""
        phoneCallStatus = "拒接手機來電中"
        _ = hangUpPhoneCall()
        DiagnosticsLog.info("phone.mac.incoming_ui_hangup callId=\(callId)")
    }

    private func handlePhoneActionResult(_ result: PhoneActionResultBody) {
        let pendingAction = pendingPhoneActions.removeValue(forKey: result.requestId)
        if result.requestId == phoneRelayDebugDialRequestID && !result.success {
            phoneRelayDebugDialError = result.error ?? "unknown"
        }
        let action = Self.localizedPhoneAction(result.action)
        if result.success {
            if result.action == "dial" || result.action == "answer" {
                isPhoneCallActive = true
            }
            if result.action == "hangup" {
                let isRemoteHangup = pendingAction == nil
                stopPhoneCallRelayAudio(reason: isRemoteHangup ? "remote_phone_hangup" : "phone_action_result_hangup")
                isPhoneCallActive = false
                phoneCallStatus = isRemoteHangup ? "通話已結束" : "\(action)已送出"
                DiagnosticsLog.info(
                    "phone.mac.action_result requestId=\(result.requestId) action=\(result.action) " +
                        "success=true remoteHangup=\(isRemoteHangup)"
                )
                return
            }
            phoneCallStatus = "\(action)已送出"
            DiagnosticsLog.info("phone.mac.action_result requestId=\(result.requestId) action=\(result.action) success=true")
        } else {
            if result.action == "dial" || result.action == "answer" {
                stopPhoneCallRelayAudio(reason: "phone_action_failed_\(result.action)")
                isPhoneCallActive = false
            }
            phoneCallStatus = "\(action)失敗：\(result.error ?? "未知錯誤")"
            DiagnosticsLog.warn(
                "phone.mac.action_result requestId=\(result.requestId) action=\(result.action) success=false error=\(result.error ?? "unknown")"
            )
        }
    }

    private func stopPhoneCallRelayAudio(reason: String) {
        stopPhoneRelayProbe(reason: reason)
        phoneRelayProbe.stopExternalSourceRTP(reason: reason)
        callRelayGatewayClient.close(reason: reason)
    }

    private func handleAndroidMicStatus(_ status: AndroidMicStatusBody) {
        let source = status.sourceName ?? status.source.map(String.init) ?? "unknown"
        if status.active {
            androidMicRelayArmed = true
            ensurePhoneRelayProbeEnabled(reason: "android_mic_\(source)")
            phoneRelayProbe.armSourceRTP(reason: "android_mic_\(source)")
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

    private static func localizedPhoneAction(_ action: String) -> String {
        switch action {
        case "dial":
            return "撥號"
        case "answer":
            return "接聽"
        case "hangup":
            return "掛斷"
        case "dtmf":
            return "按鍵"
        default:
            return "電話操作"
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
        return "未知號碼"
    }

    private static func localizedPhoneCallStatus(_ status: PhoneCallStatusBody, caller: String) -> String {
        switch status.state {
        case "dialing":
            return "手機撥號中：\(caller)"
        case "connecting":
            return "手機通話連線中：\(caller)"
        case "held":
            return "手機通話保留中：\(caller)"
        case "active":
            return "手機通話中：\(caller)"
        default:
            return "手機通話：\(caller)"
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
    private static let phoneRelayProbePeerHostDefaultsKey = "phoneRelayProbePeerHost"
    private static let phoneRelayProbePeerPortDefaultsKey = "phoneRelayProbePeerPort"
    private static let phoneRelayProbePort: UInt16 = 7102
    private static let xiaomiScreenPrimaryRouteDefaultsKey = "xiaomiScreenPrimaryRouteEnabled"
    private static let xiaomiMirrorRTSPDiagnosticEnabledDefaultsKey = "xiaomiMirrorRTSPDiagnosticEnabled"
    private static let xiaomiMirrorRTSPDiagnosticPort: UInt16 = 7102
    private static let xiaomiMirrorRTSPDiagnosticLifetimeSeconds: TimeInterval = 45
    private static let xiaomiScreenRecoveryDelayNanoseconds: UInt64 = 150_000_000
    private static let xiaomiScreenRecoveryHighAttemptWarningThreshold = 3
    private static let xiaomiScreenSourceRecoveryMaxAttempts = 2
    private static let xiaomiScreenSessionRebuildAfterNoFrameSeconds: Double = 18
    private static let xiaomiScreenSessionRebuildAfterNoPacketSeconds: Double = 30
    private static let xiaomiScreenSourceRecoveryCooldownSeconds: TimeInterval = 10
    private static let xiaomiScreenSessionRebuildCooldownSeconds: TimeInterval = 45
    private static let xiaomiScreenSessionRebuildTimeoutMs = 12_000
    private static let phoneRelayDebugDefaultNumber = "800"
    private static let phoneRelayDebugMaxTimeoutSeconds: TimeInterval = 30

    private static func xiaomiMirrorRTSPDiagnosticEnabled() -> Bool {
        UserDefaults.standard.object(forKey: xiaomiMirrorRTSPDiagnosticEnabledDefaultsKey) as? Bool ?? true
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
    static let callRelayGatewayHost = "172.238.24.219"
    static let callRelayGatewayControlPort: UInt16 = 17104
}

private struct PhoneRelayEndpoint {
    let host: String?
    let port: Int
    let sessionId: String?
    let controlPort: Int?

    init(host: String?, port: Int, sessionId: String? = nil, controlPort: Int? = nil) {
        self.host = host
        self.port = port
        self.sessionId = sessionId
        self.controlPort = controlPort
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
}
