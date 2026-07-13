import AppKit
import Combine
import CryptoKit
import EdgeLinkKit
import Foundation

@MainActor
final class EdgeLinkRuntime: ObservableObject {
    private static let secureKeepaliveIntervalNanoseconds: UInt64 = 5_000_000_000
    private static let securePongTimeoutSeconds: TimeInterval = 15

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
    @Published private(set) var latestMiLinkStatus: MiLinkStatusBody?
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
    private let verificationCodeBridge = MacVerificationCodeBridge()
    private let macNotificationSource = MacNotificationDatabaseSource()
    private let screenSession = MacScreenSession()
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

    init(
        workerBaseURL: URL = EdgeLinkConfig.workerBaseURL,
        relayURL: URL = EdgeLinkConfig.relayURL,
        pairingWebSocketURL: URL = EdgeLinkConfig.pairingWebSocketURL
    ) {
        macNotificationSyncEnabled = UserDefaults.standard.object(forKey: Self.macNotificationSyncDefaultsKey) as? Bool ?? true
        verificationCodeSystemBridgeEnabled = UserDefaults.standard.object(forKey: Self.verificationCodeSystemBridgeDefaultsKey) as? Bool ?? true
        verificationCodeAutoCopyEnabled = UserDefaults.standard.object(forKey: Self.verificationCodeAutoCopyDefaultsKey) as? Bool ?? true
        pairingStore = try? ApplicationSupportPairingStore()
        registrar = WorkerDeviceRegistrar(baseURL: workerBaseURL)
        relayTransport = RelayTransport(endpoint: relayURL)
        pairingTransport = PairingTransport(baseURL: workerBaseURL, webSocketURL: pairingWebSocketURL)
        notificationPresenter.onCopyVerificationCode = { [weak self] code in
            Task { @MainActor in
                self?.copyVerificationCode(code, reason: "notification_action")
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
        observeSystemSleepWake()
        verificationCodeBridge.warmObservers()
        task = Task { await run() }
    }

    deinit {
        task?.cancel()
        pairingTask?.cancel()
        connectionTask?.cancel()
        currentChannel?.close()
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
        screenSession.openAndStart()
        isPhoneScreenSessionActive = true
        isPhoneScreenViewerVisible = true
        hasViewedPhoneScreen = true
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

        let shouldSendRemoteStop = isConnected
        screenSession.hideWindowAndStop(sendRemoteStop: shouldSendRemoteStop)
        currentChannel?.close()
        currentChannel = nil
        currentChannelGeneration = nil
        currentSession = nil
        screenSession.clearSender()
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

    private func run() async {
        do {
            connectionStatus = "Registering"
            let identity = try await loadOrRegisterIdentity()
            localIdentity = identity
            localDeviceId = DeviceID.display(identity.deviceId)
            DiagnosticsLog.info("runtime.mac.identity deviceId=\(identity.deviceId) pkfp=\(DiagnosticsLog.fingerprint(identity.publicKey))")

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
                    onMiLinkStatus: { [weak self] status in
                        Task { @MainActor in
                            self?.handleMiLinkStatus(status)
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
        DiagnosticsLog.info(
            "milink.mac.status available=\(status.available) route=\(status.route) " +
                "officialDiscoveryRequired=\(status.officialDiscoveryRequired) " +
                "root=\(status.rootProbeOk) attribution=\(status.attributionProbeOk) " +
                "messenger=\(status.messengerTransportOk) cast=\(status.castServiceOk)"
        )
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

    private static func fingerprint(_ value: String) -> String {
        DiagnosticsLog.fingerprint(Data(value.utf8))
    }

    private static let macNotificationSyncDefaultsKey = "macNotificationSyncEnabled"
    private static let verificationCodeSystemBridgeDefaultsKey = "verificationCodeSystemBridgeEnabled"
    private static let verificationCodeAutoCopyDefaultsKey = "verificationCodeAutoCopyEnabled"
}

enum EdgeLinkConfig {
    static let workerBaseURL = URL(string: "https://edgelink-worker.black-hill-f944.workers.dev")!
    static let relayURL = URL(string: "wss://edgelink-worker.black-hill-f944.workers.dev/v1/connect")!
    static let pairingWebSocketURL = URL(string: "wss://edgelink-worker.black-hill-f944.workers.dev/v1/pair/ws")!
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
