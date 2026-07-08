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

    private let identityStore = KeychainIdentityStore()
    private let pairingStore: ApplicationSupportPairingStore?
    private let registrar: WorkerDeviceRegistrar
    private let relayTransport: RelayTransport
    private let clipboardSync = ClipboardSync()
    private let encoder = JSONEncoder()
    private var currentSession: SecureSessionHost?
    private var task: Task<Void, Never>?

    init(
        workerBaseURL: URL = EdgeLinkConfig.workerBaseURL,
        relayURL: URL = EdgeLinkConfig.relayURL
    ) {
        pairingStore = try? ApplicationSupportPairingStore()
        registrar = WorkerDeviceRegistrar(baseURL: workerBaseURL)
        relayTransport = RelayTransport(endpoint: relayURL)
        task = Task { await run() }
    }

    deinit {
        task?.cancel()
    }

    private func run() async {
        do {
            connectionStatus = "Registering"
            let identity = try await loadOrRegisterIdentity()
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
}
