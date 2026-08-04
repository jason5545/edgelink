import CryptoKit
import EdgeLinkKit
import Foundation

// Composition root of the mock phone: identity + oracle + mesh endpoint +
// the phone's client roles (reverse sync task, TeleService relayCall).
// Drives scenarios and exposes the assertion surface for tests.
public final class LyraPhoneServer {
    public enum Event {
        case log(String)
        case physSynced
        case announceAuthenticated
        case deviceUpdated(LyraDevRepoOracle.DeviceRecord)
        case relayCallState(LyraRelayCallRole.State)
        case syncTaskState(LyraSyncTaskRole.State)
    }

    public var onEvent: (Event) -> Void = { _ in }

    public let identity: LyraPhoneIdentity
    public let oracle: LyraDevRepoOracle
    public let mesh: LyraPhoneMeshServer
    public let syncTask: LyraSyncTaskRole
    public let relayCall: LyraRelayCallRole
    public let cast: LyraCastRole

    public init(identity: LyraPhoneIdentity, castChannelPort: UInt16 = 0, wfdPort: UInt16 = 7236) {
        self.identity = identity
        oracle = LyraDevRepoOracle()
        mesh = LyraPhoneMeshServer(identity: identity, oracle: oracle)
        syncTask = LyraSyncTaskRole(identity: identity, oracle: oracle)
        relayCall = LyraRelayCallRole(identity: identity)
        cast = LyraCastRole(identity: identity, castChannelPort: castChannelPort, wfdPort: wfdPort)
        mesh.register(cast)
        mesh.onEvent = { [weak self] event in
            self?.handleMeshEvent(event)
        }
        syncTask.onEvent = { [weak self] text in
            self?.onEvent(.log("synctask: \(text)"))
        }
        relayCall.onEvent = { [weak self] text in
            self?.onEvent(.log("relaycall: \(text)"))
        }
        cast.onEvent = { [weak self] text in
            self?.onEvent(.log("cast: \(text)"))
        }
    }

    public func start(port: UInt16) throws {
        try mesh.start(port: port)
    }

    public func stop() {
        mesh.stop()
        cast.stop()
    }

    public var boundPort: UInt16? { mesh.boundPort }

    // Pair the phone with the Mac's lyra identity (the TA/PasskeyPair result
    // on a real phone): its pubkey verifies AuthHandshake client_finished
    // and cred features.
    public func pair(withMacIdentityPubKey pubKey: Data) {
        if !oracle.trustedPeerIdentities.contains(pubKey) {
            oracle.trustedPeerIdentities.append(pubKey)
        }
    }

    // TeleService's trigger: an online device advertising relayCall gets
    // dialed. Returns false when the gate fails ("No relay service").
    @discardableResult
    public func dialRelayCallIfOnline() -> Bool {
        guard oracle.relayServiceDevice() != nil, let sessionKey = mesh.peer.sessionKey
        else {
            onEvent(.log("relayCall gate: No relay service"))
            return false
        }
        relayCall.dial(server: mesh, sessionKey: sessionKey)
        return true
    }

    // Force the relayCall dial regardless of the online gate (negative
    // tests: the Mac should still answer, its own gates decide).
    public func forceRelayCallDial() {
        guard let sessionKey = mesh.peer.sessionKey else {
            onEvent(.log("relayCall dial without announce session"))
            return
        }
        relayCall.dial(server: mesh, sessionKey: sessionKey)
    }

    // The phone's reverse sync task: dial the Mac responder's quick-conn
    // server and push our TrustedDeviceInfo.
    public func runSyncTask(host: String, port: UInt16) {
        syncTask.dial(server: mesh, host: host, port: port)
    }

    // Simulates an incoming call: dials relayCall when needed, then rings.
    public func simulateIncomingCall(number: String) {
        if relayCall.state == .idle {
            if !dialRelayCallIfOnline() {
                forceRelayCallDial()
            }
        }
        relayCall.sendRing(number: number)
    }

    private func handleMeshEvent(_ event: LyraPhoneMeshServer.Event) {
        switch event {
        case .log(let text):
            onEvent(.log(text))
        case .physSynced:
            onEvent(.physSynced)
        case .announceAuthenticated:
            onEvent(.announceAuthenticated)
        case .announceReceived(let device):
            if let record = oracle.records[device.fullDeviceIdHex] {
                onEvent(.deviceUpdated(record))
            }
        case .payloadReceived:
            break
        case .serviceDialed(let service, _):
            onEvent(.log("service dialed: \(service)"))
        case .disconnected:
            onEvent(.log("peer disconnected"))
        }
    }
}
