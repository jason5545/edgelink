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
    @Published private(set) var pairingSAS = ""
    @Published private(set) var pairingPeerName = ""
    @Published private(set) var pairingStatus = ""
    @Published private(set) var isPairing = false
    @Published private(set) var canAcceptPairing = false
    @Published private(set) var macNotificationSyncEnabled: Bool
    @Published private(set) var smsMessages: [SmsMessageBody] = []
    @Published private(set) var smsSendStatus = ""

    private let identityStore = KeychainIdentityStore()
    private let pairingStore: ApplicationSupportPairingStore?
    private let registrar: WorkerDeviceRegistrar
    private let relayTransport: RelayTransport
    private let pairingTransport: PairingTransport
    private let clipboardSync = ClipboardSync()
    private let notificationPresenter = MacNotificationPresenter()
    private let macNotificationSource = MacNotificationDatabaseSource()
    private let screenSession = MacScreenSession()
    private let encoder = JSONEncoder()
    private var currentSession: SecureSessionHost?
    private var localIdentity: LocalIdentity?
    private var pairingTask: Task<Void, Never>?
    private var pendingPairing: MacPendingPairing?
    private var task: Task<Void, Never>?
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
        pairingStore = try? ApplicationSupportPairingStore()
        registrar = WorkerDeviceRegistrar(baseURL: workerBaseURL)
        relayTransport = RelayTransport(endpoint: relayURL)
        pairingTransport = PairingTransport(baseURL: workerBaseURL, webSocketURL: pairingWebSocketURL)
        observeSystemSleepWake()
        task = Task { await run() }
    }

    deinit {
        task?.cancel()
        pairingTask?.cancel()
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

    func viewPhoneScreen() {
        guard isConnected else {
            DiagnosticsLog.warn("screen.mac.start_ignored not_connected")
            return
        }
        screenSession.openAndStart()
    }

    func sendSms(to rawRecipient: String, text rawText: String) {
        let recipient = rawRecipient.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !recipient.isEmpty, !text.isEmpty else {
            smsSendStatus = "SMS needs recipient and text"
            return
        }
        guard let session = currentSession, isConnected else {
            smsSendStatus = "SMS unavailable"
            DiagnosticsLog.warn("sms.mac.send_ignored not_connected")
            return
        }

        let requestId = UUID().uuidString
        let body = SmsSendBody(requestId: requestId, to: recipient, text: text)
        pendingSmsSends[requestId] = body
        smsSendStatus = "Sending SMS"

        Task {
            do {
                let data = try encoder.encode(Envelope(t: EnvelopeType.smsSend, b: body))
                try await session.sendPlaintext(data)
                DiagnosticsLog.info("sms.mac.send_requested requestId=\(requestId) toFp=\(Self.fingerprint(recipient))")
            } catch {
                await MainActor.run {
                    self.pendingSmsSends.removeValue(forKey: requestId)
                    self.smsSendStatus = "SMS send failed"
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

            guard let peer = try pairingStore?.loadPeers().first else {
                DiagnosticsLog.info("runtime.mac.no_paired_peer")
                connectionStatus = "No paired Android"
                return
            }

            DiagnosticsLog.info("runtime.mac.loaded_peer clientId=\(peer.deviceId) pkfp=\(DiagnosticsLog.fingerprint(peer.publicKey))")
            peerName = peer.name
            peerDeviceId = DeviceID.display(peer.deviceId)
            await connectLoop(identity: identity, peer: peer)
        } catch {
            DiagnosticsLog.error("runtime.mac.setup_failed", error)
            isConnected = false
            connectionStatus = "Setup failed"
        }
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
            await connectLoop(identity: identity, peer: peer)
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

    private func connectLoop(identity: LocalIdentity, peer: PinnedPeer) async {
        var retryDelay: UInt64 = 1_000_000_000

        while !Task.isCancelled {
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
                connectionStatus = "Connecting relay"
                let connectedChannel = try await relayTransport.connect(hostId: identity.deviceId, identity: identity)
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
                DiagnosticsLog.info("relay.mac.handshake_ok hostId=\(identity.deviceId) clientId=\(peer.deviceId)")
                currentSession = session
                lastSecurePongAt = Date()
                screenSession.setSender { [weak self] data in
                    Task { @MainActor in
                        await self?.sendScreenPlaintext(data)
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
                        screenSession.stop(sendRemoteStop: false)
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
                DiagnosticsLog.error("relay.mac.disconnected hostId=\(identity.deviceId) clientId=\(peer.deviceId)", error)
                isConnected = false
                currentSession = nil
                screenSession.clearSender()
                screenSession.stop(sendRemoteStop: false)
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
        if smsMessages.count > 30 {
            smsMessages.removeLast(smsMessages.count - 30)
        }

        DiagnosticsLog.info("sms.mac.message_received id=\(message.id) addressFp=\(Self.fingerprint(message.address)) backfill=\(message.isBackfill)")
        if !message.isBackfill && message.direction == "inbound" {
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

    private func handleSmsSendResult(_ result: SmsSendResultBody) {
        let pending = pendingSmsSends.removeValue(forKey: result.requestId)
        if result.success {
            smsSendStatus = "SMS queued"
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
            smsSendStatus = "SMS failed: \(result.error ?? "unknown")"
            DiagnosticsLog.warn("sms.mac.send_result requestId=\(result.requestId) success=false error=\(result.error ?? "unknown")")
        }
    }

    private static func fingerprint(_ value: String) -> String {
        DiagnosticsLog.fingerprint(Data(value.utf8))
    }

    private static let macNotificationSyncDefaultsKey = "macNotificationSyncEnabled"
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
