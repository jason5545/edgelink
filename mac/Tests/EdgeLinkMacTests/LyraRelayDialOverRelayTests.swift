import CryptoKit
import EdgeLinkKit
import Foundation
import LyraServerKit
import XCTest

// Mac-dials-phone over the cloud relay — the 2026-09-02 regression: the
// native relay dialer was hardwired to a LAN UDP socket, so off-LAN
// (hotspot / cloud relay) it phys-synced stale WiFi endpoints, got silence,
// and its 20s timeout sat in .idle — the one state whose stopLocked() path
// ate the failure outcome, so the bridge-dial fallback never fired either.
// The phone never saw anything: "call can send, but phone not responding".
//
// Here every mesh and channel datagram crosses an E2EE relay session pair
// (the worker stand-in) through LyraRelayTransportBridges: the production
// LyraRelayCallDialer runs on fresh relay mesh/channel flows against
// LyraRelayPhoneCallRole (the phone's relayPhoneCall server), whose dial
// channel rides the phone-side bridge's channel flow.
final class LyraRelayDialOverRelayTests: XCTestCase {
    private static let defaultsKeys = [
        "xiaomiTrustIdentityPrivHex",
        "xiaomiTrustIdentityPubB64",
        "xiaomiTrustPeerIdentityPubB64",
        "xiaomiTrustPeerAccountPubB64",
        "xiaomiTrustDeviceUUID",
        "xiaomiTrustSessionKeyHex",
        "xiaomiTrustTicketHex",
        "xiaomiTrustCloneDeviceId",
    ]

    // The production runtime randomizes dial flow indexes per dial above
    // LyraRelayTransportBridge.dialFlowIndexFloor; the tests pin fixed ones.
    private static let meshFlowIndex = LyraRelayTransportBridge.dialFlowIndexFloor
    private static let channelFlowIndex = LyraRelayTransportBridge.dialFlowIndexFloor + 1

    private var savedValues: [String: Any?] = [:]
    private let macIdentity = P256.Signing.PrivateKey()

    private var phone: LyraPhoneServer?
    private var role: LyraRelayPhoneCallRole?
    private var dialer: LyraRelayCallDialer?
    private var phoneMeshPort: UInt16 = 0
    private var hostSession: LyraRelaySession?
    private var clientSession: LyraRelaySession?
    private var hostBridge: LyraRelayTransportBridge?
    private var clientBridge: LyraRelayTransportBridge?
    private var pair: LoopbackChannelPair?
    private var hostLoop: Task<Void, Error>?
    private var clientLoop: Task<Void, Error>?

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        let defaults = UserDefaults.standard
        for key in Self.defaultsKeys {
            savedValues[key] = defaults.object(forKey: key)
        }
        defaults.set(UUID().uuidString, forKey: "xiaomiTrustDeviceUUID")
        defaults.set(macIdentity.rawRepresentation.map { String(format: "%02x", $0) }.joined(),
                     forKey: "xiaomiTrustIdentityPrivHex")
        defaults.set(macIdentity.publicKey.x963Representation.base64EncodedString(),
                     forKey: "xiaomiTrustIdentityPubB64")
        defaults.set(LyraPhoneIdentity.fixtureAccountPubB64, forKey: "xiaomiTrustPeerAccountPubB64")
        defaults.removeObject(forKey: "xiaomiTrustSessionKeyHex")
        defaults.removeObject(forKey: "xiaomiTrustTicketHex")
        defaults.removeObject(forKey: "xiaomiTrustCloneDeviceId")
        MiTrustTicketStore.lastAuthSessionKeyData = nil
    }

    override func tearDown() {
        hostLoop?.cancel()
        clientLoop?.cancel()
        hostLoop = nil
        clientLoop = nil
        dialer?.stop()
        dialer = nil
        phone?.stop()
        phone = nil
        role = nil
        pair?.hostSide.close()
        pair?.clientSide.close()
        pair = nil
        hostBridge = nil
        clientBridge = nil
        hostSession = nil
        clientSession = nil
        let defaults = UserDefaults.standard
        for key in Self.defaultsKeys {
            if let value = savedValues[key] ?? nil {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        savedValues = [:]
        MiTrustTicketStore.lastAuthSessionKeyData = nil
        super.tearDown()
    }

    // MARK: - Harness (relay session pair + waitFor, same shape as the
    // incoming-call over-relay tests)

    private func establishRelaySession() async throws {
        let pair = LoopbackChannelPair()
        self.pair = pair
        let hostIdentity = LocalIdentity(
            deviceId: "123456789", name: "FakeServer",
            signingKey: Curve25519.Signing.PrivateKey()
        )
        let clientIdentity = LocalIdentity(
            deviceId: "987654321", name: "FakePhone",
            signingKey: Curve25519.Signing.PrivateKey()
        )

        let hostSessionBox = SessionBox()
        let hostBridge = LyraRelayTransportBridge(sendHandler: { data in
            try await hostSessionBox.session?.sendPlaintext(data)
        })
        let hostSession = LyraRelaySession(
            channel: pair.hostSide,
            identity: hostIdentity,
            onEnvelope: { type, plaintext in
                if LyraRelayTransportBridge.handles(type) {
                    hostBridge.handleEnvelope(type: type, plaintext: plaintext)
                }
            }
        )
        hostSessionBox.session = hostSession

        let clientSessionBox = SessionBox()
        let clientBridge = LyraRelayTransportBridge(sendHandler: { data in
            try await clientSessionBox.session?.sendPlaintext(data)
        })
        let clientSession = LyraRelaySession(
            channel: pair.clientSide,
            identity: clientIdentity,
            onEnvelope: { type, plaintext in
                if LyraRelayTransportBridge.handles(type) {
                    clientBridge.handleEnvelope(type: type, plaintext: plaintext)
                }
            }
        )
        clientSessionBox.session = clientSession

        self.hostBridge = hostBridge
        self.clientBridge = clientBridge
        self.hostSession = hostSession
        self.clientSession = clientSession

        async let hostAccept: Void = hostSession.acceptAsHost(pinnedClientPublicKey: clientIdentity.publicKey)
        async let clientConnect: Void = clientSession.connectAsClient(pinnedHostPublicKey: hostIdentity.publicKey)
        _ = try await (hostAccept, clientConnect)

        hostLoop = Task { try await hostSession.receiveLoop() }
        clientLoop = Task { try await clientSession.receiveLoop() }
    }

    // The phone end: its mesh server on the dial mesh flow, the
    // relayPhoneCall role's dial channel on the dial channel flow — exactly
    // what AndroidLyraRelayTransportBridge's per-flow sockets model.
    private func startPhoneDialServer() async throws {
        let clientBridge = try XCTUnwrap(clientBridge)
        let phone = LyraPhoneServer(
            identity: LyraPhoneIdentity.generate(),
            meshTransport: clientBridge.meshFlow(index: Self.meshFlowIndex)
        )
        let role = LyraRelayPhoneCallRole()
        role.channelPipe = clientBridge.channelFlow(index: Self.channelFlowIndex)
        role.onEvent = { print("[relaydial-mock] \($0)") }
        phone.mesh.register(role)
        self.phone = phone
        self.role = role
        try phone.start(port: 0)
        phoneMeshPort = try XCTUnwrap(phone.boundPort)
    }

    private func startDialer() {
        dialer = LyraRelayCallDialer(
            deviceIdHexProvider: { "721572C3" },
            displayNameProvider: { "EdgeLinkMacTests" }
        )
    }

    private func waitFor(
        _ description: String, timeout: TimeInterval = 15,
        _ predicate: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() > deadline {
                XCTFail("timed out waiting for: \(description)")
                return
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    // MARK: - Tests

    // The fix: the whole dial chain (phys sync → cookie → sync_info → P256
    // auth → encrypted logi request → responseOfPeerPort → channel
    // negotiation → relay://dial URI → 200) round-trips over the relay with
    // zero LAN sockets involved.
    func testDialOverCloudRelay() async throws {
        try await establishRelaySession()
        try await startPhoneDialServer()
        let role = try XCTUnwrap(self.role)
        let hostBridge = try XCTUnwrap(hostBridge)

        hostBridge.meshFlow(index: Self.meshFlowIndex).peerPort = phoneMeshPort
        startDialer()
        let dialer = try XCTUnwrap(self.dialer)
        dialer.dial(
            number: "800", host: "127.0.0.1", ports: [phoneMeshPort],
            meshTransport: hostBridge.meshFlow(index: Self.meshFlowIndex),
            channelTransport: hostBridge.channelFlow(index: Self.channelFlowIndex)
        )

        await waitFor("dial answered by the phone over the relay") {
            role.dialRequests.count == 1 && dialer.state == .done
        }
        XCTAssertEqual(role.dialRequests.first?.address, "800")
        XCTAssertEqual(role.dialChannelUpConnIds.count, 1, "the dial channel must ride the relay flow")

        // The audio-arming redial is gone (2026-09-03: on current firmware
        // the call goes active within ~1s, so the +1.2s/+2.2s re-dials
        // landed past the DIALING window as a real second placeCall — one
        // call held, hangup killed the wrong one). Nothing more may be
        // dialed past the old redial window.
        try await Task.sleep(nanoseconds: 2_600_000_000)
        XCTAssertEqual(role.dialRequests.count, 1, "no redial may follow a completed dial")
    }

    // Channel-flow isolation: a live cast-style channel on flow 0 must keep
    // working while the dial channel rides its own indexed flow (the shared
    // pipe's handlers would otherwise be clobbered mid-mirror).
    func testDialOverCloudRelayKeepsSharedChannelFlowIntact() async throws {
        try await establishRelaySession()
        try await startPhoneDialServer()
        let role = try XCTUnwrap(self.role)
        let hostBridge = try XCTUnwrap(hostBridge)
        let clientBridge = try XCTUnwrap(clientBridge)

        // A "cast channel" stand-in on the shared flow-0 pipes.
        let castKey = Data(repeating: 0x5A, count: 32)
        try clientBridge.channel.start(socketKey: castKey, serverChannelId: 5)
        let castNegotiated = LockedBox<Int>(0)
        clientBridge.channel.onNegotiated = { _, _ in castNegotiated.with { $0 += 1 } }
        let hostCastNegotiated = LockedBox<Int>(0)
        hostBridge.channel.onNegotiated = { _, _ in hostCastNegotiated.with { $0 += 1 } }
        try hostBridge.channel.connect(host: "127.0.0.1", port: 5000, socketKey: castKey)
        try hostBridge.channel.sendClientNegotiation(channelId: 11, version: 1, mtu: 0xFF00)
        await waitFor("flow-0 channel negotiated before the dial") {
            hostCastNegotiated.value == 1
        }

        hostBridge.meshFlow(index: Self.meshFlowIndex).peerPort = phoneMeshPort
        startDialer()
        let dialer = try XCTUnwrap(self.dialer)
        dialer.dial(
            number: "800", host: "127.0.0.1", ports: [phoneMeshPort],
            meshTransport: hostBridge.meshFlow(index: Self.meshFlowIndex),
            channelTransport: hostBridge.channelFlow(index: Self.channelFlowIndex)
        )
        await waitFor("dial answered while flow 0 is busy") {
            role.dialRequests.count == 1 && dialer.state == .done
        }

        // Flow 0 still round-trips after the dial ran on its own flow.
        try hostBridge.channel.sendClientNegotiation(channelId: 12, version: 1, mtu: 0xFF00)
        await waitFor("flow-0 channel still alive after the dial") {
            hostCastNegotiated.value >= 2
        }
        XCTAssertEqual(castNegotiated.value, 2, "the phone-side flow-0 pipe must see both negotiations")
    }

    // The second half of the live bug: a dial that gets NO answer at all
    // (off-LAN stale endpoints) times out in .idle, and that path used to
    // eat the failure outcome — the bridge-dial fallback never fired.
    func testDialTimeoutFromIdleReportsOutcome() async throws {
        startDialer()
        let dialer = try XCTUnwrap(self.dialer)
        let savedTimeout = LyraRelayCallDialer.overallTimeout
        LyraRelayCallDialer.overallTimeout = 1.5
        defer { LyraRelayCallDialer.overallTimeout = savedTimeout }

        let outcomes = LockedBox<[Bool]>([])
        dialer.onDialOutcome = { sent in outcomes.with { $0.append(sent) } }
        // Nothing listens on 127.0.0.1:9 — phys sync is answered by silence.
        dialer.dial(number: "800", host: "127.0.0.1", ports: [9])

        await waitFor("timeout reports the failure outcome", timeout: 10) {
            outcomes.value == [false]
        }
    }
}

// MARK: - Loopback relay channel pair (worker stand-in; same shape as the
// incoming-call over-relay harness)

private final class LoopbackEndpoint: ByteChannel, @unchecked Sendable {
    private let incoming: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let peer: () -> LoopbackEndpoint?

    init(peer: @escaping () -> LoopbackEndpoint?) {
        var continuation: AsyncStream<Data>.Continuation!
        incoming = AsyncStream { continuation = $0 }
        self.continuation = continuation
        self.peer = peer
    }

    func send(_ bytes: Data) async throws {
        guard let peer = peer() else {
            throw LoopbackChannelError.closed
        }
        peer.deliver(bytes)
    }

    func receive() async throws -> Data? {
        for await data in incoming {
            return data
        }
        return nil
    }

    func close() {
        continuation.finish()
    }

    fileprivate func deliver(_ data: Data) {
        continuation.yield(data)
    }
}

private enum LoopbackChannelError: Error {
    case closed
}

private final class LoopbackChannelPair {
    let hostSide: LoopbackEndpoint
    let clientSide: LoopbackEndpoint

    init() {
        var host: LoopbackEndpoint!
        var client: LoopbackEndpoint!
        host = LoopbackEndpoint { client }
        client = LoopbackEndpoint { host }
        hostSide = host
        clientSide = client
    }
}

private final class SessionBox: @unchecked Sendable {
    var session: LyraRelaySession?
}

final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ initial: Value) {
        storage = initial
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func with(_ mutate: (inout Value) -> Void) {
        lock.lock()
        mutate(&storage)
        lock.unlock()
    }
}
