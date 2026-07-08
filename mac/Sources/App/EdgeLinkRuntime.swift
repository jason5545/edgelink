import Combine
import CryptoKit
import EdgeLinkKit
import Foundation

@MainActor
final class EdgeLinkRuntime: ObservableObject {
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

    private let identityStore = KeychainIdentityStore()
    private let pairingStore: ApplicationSupportPairingStore?
    private let registrar: WorkerDeviceRegistrar
    private let relayTransport: RelayTransport
    private let pairingTransport: PairingTransport
    private let clipboardSync = ClipboardSync()
    private let encoder = JSONEncoder()
    private var currentSession: SecureSessionHost?
    private var localIdentity: LocalIdentity?
    private var pairingTask: Task<Void, Never>?
    private var pendingPairing: MacPendingPairing?
    private var task: Task<Void, Never>?

    init(
        workerBaseURL: URL = EdgeLinkConfig.workerBaseURL,
        relayURL: URL = EdgeLinkConfig.relayURL,
        pairingWebSocketURL: URL = EdgeLinkConfig.pairingWebSocketURL
    ) {
        pairingStore = try? ApplicationSupportPairingStore()
        registrar = WorkerDeviceRegistrar(baseURL: workerBaseURL)
        relayTransport = RelayTransport(endpoint: relayURL)
        pairingTransport = PairingTransport(baseURL: workerBaseURL, webSocketURL: pairingWebSocketURL)
        task = Task { await run() }
    }

    deinit {
        task?.cancel()
        pairingTask?.cancel()
    }

    func startPairing() {
        guard let identity = localIdentity else {
            pairingStatus = "Registering"
            return
        }
        pairingTask?.cancel()
        pairingTask = Task { await runPairing(identity: identity) }
    }

    func acceptPairing() {
        guard let pendingPairing else { return }
        canAcceptPairing = false
        pairingStatus = "Waiting for Android"
        Task {
            do {
                try await pairingTransport.confirm(pendingPairing.confirmRequest())
            } catch {
                await MainActor.run {
                    self.pairingStatus = "Pairing failed"
                    self.isPairing = false
                }
            }
        }
    }

    private func run() async {
        do {
            connectionStatus = "Registering"
            let identity = try await loadOrRegisterIdentity()
            localIdentity = identity
            localDeviceId = DeviceID.display(identity.deviceId)

            guard let peer = try pairingStore?.loadPeers().first else {
                connectionStatus = "No paired Android"
                return
            }

            peerName = peer.name
            peerDeviceId = DeviceID.display(peer.deviceId)
            await connectLoop(identity: identity, peer: peer)
        } catch {
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

            try await pairingTransport.start(identity: identity)
            let channel = try await pairingTransport.connect(hostId: identity.deviceId)
            defer { channel.close() }

            let hostNonce = HandshakeSession.randomNonce()
            let commitment = Pairing.commitment(hostPublicKey: identity.publicKey, hostNonce: hostNonce)
            var pairedPeer: PinnedPeer?

            while let text = try await channel.receive() {
                switch try PairingWire.type(text) {
                case PairingType.ready:
                    try await channel.send(PairingWire.encodeCommit(commitment))
                case PairingType.revealClient:
                    let reveal = try PairingWire.decodeRevealClient(text)
                    guard
                        let clientPublicKey = Data(base64Encoded: reveal.clientPk),
                        let clientNonce = Data(base64Encoded: reveal.nonceC)
                    else {
                        throw PairingRuntimeError.invalidPeerMessage
                    }

                    let sas = Pairing.sas(
                        hostPublicKey: identity.publicKey,
                        clientPublicKey: clientPublicKey,
                        hostNonce: hostNonce,
                        clientNonce: clientNonce
                    )
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
                case PairingType.complete:
                    let complete = try PairingWire.decodeComplete(text)
                    if let pending = pendingPairing, complete.hostId == pending.hostId, complete.clientId == pending.clientId {
                        let peer = PinnedPeer(
                            deviceId: pending.clientId,
                            name: pending.clientName,
                            publicKey: pending.clientPublicKey,
                            pairedAt: Date()
                        )
                        pairedPeer = peer
                        try pairingStore.savePeer(peer)
                        break
                    }
                default:
                    continue
                }
            }

            guard let peer = pairedPeer else { return }
            pendingPairing = nil
            peerName = peer.name
            peerDeviceId = DeviceID.display(peer.deviceId)
            pairingSAS = ""
            pairingPeerName = ""
            pairingStatus = "Paired"
            isPairing = false
            canAcceptPairing = false
            await connectLoop(identity: identity, peer: peer)
        } catch {
            pairingStatus = "Pairing failed"
            isPairing = false
            canAcceptPairing = false
        }
    }

    private func loadOrRegisterIdentity() async throws -> LocalIdentity {
        if let identity = try identityStore.loadIdentity() {
            return identity
        }

        let name = Host.current().localizedName ?? "Jason's Mac"
        let signingKey = Curve25519.Signing.PrivateKey()
        let deviceId = try await registrar.register(
            pubkey: signingKey.publicKey.rawRepresentation,
            name: name,
            platform: "macos"
        )
        let identity = LocalIdentity(deviceId: deviceId, name: name, signingKey: signingKey)
        try identityStore.saveIdentity(identity)
        return identity
    }

    private func connectLoop(identity: LocalIdentity, peer: PinnedPeer) async {
        var retryDelay: UInt64 = 1_000_000_000

        while !Task.isCancelled {
            do {
                isConnected = false
                connectionStatus = "Connecting relay"
                let channel = try await relayTransport.connect(hostId: identity.deviceId, identity: identity)
                let dispatcher = CommandDispatcher(clipboardSync: clipboardSync)
                let session = SecureSessionHost(
                    channel: channel,
                    identity: identity,
                    peer: peer,
                    dispatcher: dispatcher
                )

                connectionStatus = "Handshaking"
                try await session.connect()
                currentSession = session
                isConnected = true
                connectionStatus = "Connected"
                retryDelay = 1_000_000_000

                let clipboardTask = Task { await clipboardLoop(session: session) }
                defer { clipboardTask.cancel() }
                try await session.receiveLoop()
            } catch {
                isConnected = false
                currentSession = nil
                connectionStatus = "Disconnected"
                try? await Task.sleep(nanoseconds: retryDelay)
                retryDelay = min(retryDelay * 2, 30_000_000_000)
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
                }
            }
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
    }
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
