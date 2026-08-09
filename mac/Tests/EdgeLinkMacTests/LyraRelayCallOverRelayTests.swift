import CryptoKit
import EdgeLinkKit
import Foundation
import LyraServerKit
import XCTest

// Same native-calls registration chain as LyraPhoneServerIntegrationTests —
// announce auth → sync push → online → relayCall dial → channel → ring — but
// every mesh and channel datagram crosses the E2EE relay session (the
// cloud-relay transport) instead of loopback UDP. The fake phone (client end)
// and the fake server (host end: production announcer + relayCall session)
// both sit on LyraRelaySessions wired through LyraRelayTransportBridges.
final class LyraRelayCallOverRelayTests: XCTestCase {
    private static let defaultsKeys = [
        "xiaomiTrustIdentityPrivHex",
        "xiaomiTrustIdentityPubB64",
        "xiaomiTrustPeerIdentityPubB64",
        "xiaomiTrustPeerAccountPubB64",
        "xiaomiTrustSessionKeyHex",
        "xiaomiTrustTicketHex",
        "xiaomiTrustUidHashB64",
        "xiaomiTrustLyraKeyIndex",
        "xiaomiTrustDeviceKeyHex",
        "xiaomiTrustCredCertHex",
        "xiaomiTrustCredPrivHex",
        "xiaomiRelayCallAdvertise",
        "xiaomiTrustCloneDeviceId",
        "xiaomiTrustLocalNodeIdHex",
        "xiaomiMeshRegion",
        "xiaomiMeshAnnounceDisabled",
        "xiaomiDeviceTypeOverride",
    ]

    private var savedValues: [String: Any?] = [:]
    private let macIdentity = P256.Signing.PrivateKey()
    private let credKey = P256.Signing.PrivateKey()
    private let certBytes = Data("edgelink-relay-call-over-relay-cert".utf8)

    private var phone: LyraPhoneServer?
    private var announcer: LyraMeshAnnouncer?
    private var hostSession: LyraRelaySession?
    private var clientSession: LyraRelaySession?
    private var hostBridge: LyraRelayTransportBridge?
    private var clientBridge: LyraRelayTransportBridge?
    private var pair: LoopbackChannelPair?
    private var impairedPair: ImpairedChannelPair?
    private var hostLoop: Task<Void, Error>?
    private var clientLoop: Task<Void, Error>?

    // When set, the relay session pair crosses an impaired link (cloud-relay
    // conditions) instead of the perfect loopback. Configure before calling
    // establishRelaySession().
    var impairmentHostToClient: RelayImpairmentProfile?
    var impairmentClientToHost: RelayImpairmentProfile?

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        for key in Self.defaultsKeys {
            savedValues[key] = defaults.object(forKey: key)
        }
        defaults.set(macIdentity.rawRepresentation.map { String(format: "%02x", $0) }.joined(),
                     forKey: "xiaomiTrustIdentityPrivHex")
        defaults.set(macIdentity.publicKey.x963Representation.base64EncodedString(),
                     forKey: "xiaomiTrustIdentityPubB64")
        defaults.removeObject(forKey: "xiaomiTrustSessionKeyHex")
        defaults.removeObject(forKey: "xiaomiTrustTicketHex")
        defaults.set(Data(SHA256.hash(data: Data("relay-call-over-relay-uid".utf8))).base64EncodedString(),
                     forKey: "xiaomiTrustUidHashB64")
        defaults.set(certBytes.map { String(format: "%02x", $0) }.joined(),
                     forKey: "xiaomiTrustCredCertHex")
        defaults.set(credKey.rawRepresentation.map { String(format: "%02x", $0) }.joined(),
                     forKey: "xiaomiTrustCredPrivHex")
        defaults.set(true, forKey: "xiaomiRelayCallAdvertise")
        // The mock phone signs AuthHandshake client_finished with its account
        // identity (Mijia cert fixture) — seed it like the production default.
        defaults.set(
            LyraPhoneIdentity.fixtureAccountPubB64, forKey: "xiaomiTrustPeerAccountPubB64"
        )
        MiTrustTicketStore.lastAuthSessionKeyData = nil
    }

    override func tearDown() {
        hostLoop?.cancel()
        clientLoop?.cancel()
        hostLoop = nil
        clientLoop = nil
        pair?.hostSide.close()
        pair?.clientSide.close()
        pair = nil
        impairedPair?.hostSide.close()
        impairedPair?.clientSide.close()
        impairedPair = nil
        announcer?.stop()
        announcer = nil
        phone?.stop()
        phone = nil
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
        MiTrustTicketStore.lastAuthSessionKeyData = nil
        super.tearDown()
    }

    // MARK: - Relay session pair (the cloud relay stand-in)

    private func establishRelaySession() async throws {
        let hostChannel: ByteChannel
        let clientChannel: ByteChannel
        if impairmentHostToClient != nil || impairmentClientToHost != nil {
            let pair = ImpairedChannelPair(
                hostToClient: impairmentHostToClient ?? .perfect,
                clientToHost: impairmentClientToHost ?? .perfect
            )
            impairedPair = pair
            hostChannel = pair.hostSide
            clientChannel = pair.clientSide
        } else {
            let pair = LoopbackChannelPair()
            self.pair = pair
            hostChannel = pair.hostSide
            clientChannel = pair.clientSide
        }
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
            channel: hostChannel,
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
            channel: clientChannel,
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

    // Wires the fake phone (client end) and the production announcer +
    // relayCall session (host end) onto the established relay session.
    private func startCallEnds(registerCert: Bool) async throws {
        let clientBridge = try XCTUnwrap(clientBridge)
        let hostBridge = try XCTUnwrap(hostBridge)

        let phone = LyraPhoneServer(
            identity: LyraPhoneIdentity.generate(),
            meshTransport: clientBridge.mesh,
            relayCallChannelTransport: clientBridge.channel
        )
        phone.pair(withMacIdentityPubKey: macIdentity.publicKey.x963Representation)
        if registerCert {
            phone.oracle.trustedCerts[certBytes] = credKey.publicKey.x963Representation
        }
        self.phone = phone
        try phone.start(port: 0)
        let phoneMeshPort = try XCTUnwrap(phone.boundPort)

        // The announcer pins its dial port from the peer endpoint, so point
        // the host mesh pipe at the phone's mesh port before it starts.
        hostBridge.mesh.peerPort = phoneMeshPort
        let announcer = LyraMeshAnnouncer(
            deviceIdHexProvider: { "721572C3" },
            displayNameProvider: { "MacBook Pro" },
            meshTransport: hostBridge.mesh
        )
        announcer.relayCallChannelTransport = hostBridge.channel
        self.announcer = announcer
        announcer.start(host: "127.0.0.1", port: phoneMeshPort)
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

    // Full chain over the relay session: announce online → relayCall dial →
    // channel negotiation → ring → 200 response.
    func testIncomingRingOverCloudRelay() async throws {
        try await establishRelaySession()
        try await startCallEnds(registerCert: true)
        let phone = try XCTUnwrap(self.phone)

        await waitFor("Mac online in oracle") {
            phone.oracle.onlineDevices().contains { $0.device.hasService("relayCall") }
        }
        XCTAssertTrue(phone.dialRelayCallIfOnline())
        await waitFor("relayCall channel up") {
            phone.relayCall.state == .channelUp
        }
        phone.relayCall.sendRing(number: "0912345678")
        await waitFor("ring response 200") {
            phone.relayCall.lastRingResponse?.contains("\"code\":200") == true
        }
    }

    // Mid-call state update rides the same relay-carried channel.
    func testCallStateIdleOverCloudRelay() async throws {
        try await establishRelaySession()
        try await startCallEnds(registerCert: true)
        let phone = try XCTUnwrap(self.phone)

        await waitFor("Mac online in oracle") {
            phone.oracle.onlineDevices().contains { $0.device.hasService("relayCall") }
        }
        XCTAssertTrue(phone.dialRelayCallIfOnline())
        await waitFor("relayCall channel up") {
            phone.relayCall.state == .channelUp
        }
        phone.relayCall.sendRing(number: "0912345678")
        await waitFor("ring response 200") {
            phone.relayCall.lastRingResponse?.contains("\"code\":200") == true
        }
        phone.relayCall.sendCallStateIdle()
        await waitFor("idle response 200") {
            phone.relayCall.lastRingResponse?.contains("call_state_idle") == true
                && phone.relayCall.lastRingResponse?.contains("\"code\":200") == true
        }
    }

    // Without the cred cert registered, the oracle gate holds over the relay
    // transport too — the Mac never goes online and the relayCall dial is
    // refused by the phone-side gate.
    func testUnregisteredCertKeepsMacOfflineOverRelay() async throws {
        try await establishRelaySession()
        try await startCallEnds(registerCert: false)
        let phone = try XCTUnwrap(self.phone)

        await waitFor("Mac record exists") { !phone.oracle.records.isEmpty }
        // Give the push exchange a moment to settle, then assert the gate.
        try await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertTrue(phone.oracle.onlineDevices().isEmpty)
        let record = try XCTUnwrap(phone.oracle.records.values.first)
        XCTAssertEqual(record.trustedType, 0)
        XCTAssertFalse(phone.dialRelayCallIfOnline())
    }

    // MARK: - Limit tests: impaired cloud-relay link

    // Transport flip end-to-end: the relay session dies (worker reconnect /
    // WiFi→5G) and everything on it is rebuilt from scratch — fresh relay
    // handshake, fresh announce, fresh registration. The Mac must come back
    // online in the phone's oracle and the ring must round-trip again, like
    // the live re-registration recoveries of 2026-08-05/06.
    func testRelayCallReregistersAfterRelaySessionReplaced() async throws {
        try await establishRelaySession()
        try await startCallEnds(registerCert: true)
        try await driveRingToTwoHundred()

        // Wholesale teardown of everything bound to the old relay session.
        hostLoop?.cancel()
        clientLoop?.cancel()
        hostLoop = nil
        clientLoop = nil
        announcer?.stop()
        announcer = nil
        phone?.stop()
        phone = nil
        pair?.hostSide.close()
        pair?.clientSide.close()
        pair = nil
        hostBridge = nil
        clientBridge = nil
        hostSession = nil
        clientSession = nil

        try await establishRelaySession()
        try await startCallEnds(registerCert: true)
        try await driveRingToTwoHundred()
    }

    private func driveRingToTwoHundred() async throws {
        let phone = try XCTUnwrap(self.phone)
        await waitFor("Mac online in oracle", timeout: 30) {
            phone.oracle.onlineDevices().contains { $0.device.hasService("relayCall") }
        }
        XCTAssertTrue(phone.dialRelayCallIfOnline())
        await waitFor("relayCall channel up", timeout: 30) {
            phone.relayCall.state == .channelUp
        }
        phone.relayCall.sendRing(number: "0912345678")
        await waitFor("ring response 200", timeout: 30) {
            phone.relayCall.lastRingResponse?.contains("\"code\":200") == true
        }
    }

    // The full registration + ring chain at the measured HiNet↔Cloudflare
    // WAN latency (ordered, like the production WebSocket relay legs).
    func testIncomingRingOverCloudRelayAtWANLatency() async throws {
        impairmentHostToClient = .hiNetCloudflareWANOrdered
        impairmentClientToHost = .hiNetCloudflareWANOrdered
        try await establishRelaySession()
        try await startCallEnds(registerCert: true)
        let phone = try XCTUnwrap(self.phone)

        await waitFor("Mac online in oracle at WAN latency", timeout: 30) {
            phone.oracle.onlineDevices().contains { $0.device.hasService("relayCall") }
        }
        XCTAssertTrue(phone.dialRelayCallIfOnline())
        await waitFor("relayCall channel up at WAN latency", timeout: 30) {
            phone.relayCall.state == .channelUp
        }
        phone.relayCall.sendRing(number: "0912345678")
        await waitFor("ring response 200 at WAN latency", timeout: 30) {
            phone.relayCall.lastRingResponse?.contains("\"code\":200") == true
        }
    }

    // Unordered delivery: reordered relay frames must not kill the session
    // nor the announce/dial handshake riding it.
    func testIncomingRingOverCloudRelayToleratesReordering() async throws {
        impairmentHostToClient = .hiNetCloudflareWAN
        impairmentClientToHost = .hiNetCloudflareWAN
        try await establishRelaySession()
        try await startCallEnds(registerCert: true)
        let phone = try XCTUnwrap(self.phone)

        await waitFor("Mac online in oracle despite reordering", timeout: 30) {
            phone.oracle.onlineDevices().contains { $0.device.hasService("relayCall") }
        }
        XCTAssertTrue(phone.dialRelayCallIfOnline())
        await waitFor("relayCall channel up despite reordering", timeout: 30) {
            phone.relayCall.state == .channelUp
        }
        phone.relayCall.sendRing(number: "0912345678")
        await waitFor("ring response 200 despite reordering", timeout: 30) {
            phone.relayCall.lastRingResponse?.contains("\"code\":200") == true
        }
    }

    // Heavy duplication (5G late-datagram redelivery): the pipes dedupe by
    // KCP sn and the session by the anti-replay window; the chain completes.
    func testIncomingRingOverCloudRelayWithDuplicates() async throws {
        var dup = RelayImpairmentProfile.hiNetCloudflareWAN
        dup.duplicate = 0.2
        impairmentHostToClient = .hiNetCloudflareWAN
        impairmentClientToHost = dup
        try await establishRelaySession()
        try await startCallEnds(registerCert: true)
        let phone = try XCTUnwrap(self.phone)

        await waitFor("Mac online in oracle with duplicates", timeout: 30) {
            phone.oracle.onlineDevices().contains { $0.device.hasService("relayCall") }
        }
        XCTAssertTrue(phone.dialRelayCallIfOnline())
        await waitFor("relayCall channel up with duplicates", timeout: 30) {
            phone.relayCall.state == .channelUp
        }
        phone.relayCall.sendRing(number: "0912345678")
        await waitFor("ring response 200 with duplicates", timeout: 30) {
            phone.relayCall.lastRingResponse?.contains("\"code\":200") == true
        }
        XCTAssertGreaterThan(impairedPair?.clientSide.stats.duplicated ?? 0, 0,
                             "test must actually inject duplicates")
    }

    // WiFi→5G transport flip mid-call: the relay path drops every datagram
    // for seconds. The channel must not die, and a ring sent after the link
    // heals must still round-trip.
    func testCallRingOverCloudRelaySurvivesTransportFlipBlackout() async throws {
        impairmentHostToClient = .perfect
        impairmentClientToHost = .perfect
        try await establishRelaySession()
        try await startCallEnds(registerCert: true)
        let phone = try XCTUnwrap(self.phone)

        await waitFor("Mac online in oracle before the flip") {
            phone.oracle.onlineDevices().contains { $0.device.hasService("relayCall") }
        }
        XCTAssertTrue(phone.dialRelayCallIfOnline())
        await waitFor("relayCall channel up before the flip") {
            phone.relayCall.state == .channelUp
        }

        let pair = try XCTUnwrap(impairedPair)
        pair.hostSide.blackout(for: 3)
        pair.clientSide.blackout(for: 3)
        // A ring during the blackout is simply lost — it must not wedge the
        // channel or crash the session.
        phone.relayCall.sendRing(number: "0912345678")
        try await Task.sleep(nanoseconds: 3_500_000_000)
        XCTAssertNil(phone.relayCall.lastRingResponse, "the blackout ring must stay unanswered")

        phone.relayCall.sendRing(number: "0987654321")
        await waitFor("ring response 200 after the blackout", timeout: 30) {
            phone.relayCall.lastRingResponse?.contains("\"code\":200") == true
        }
    }
}

// MARK: - Loopback channel pair (the worker stand-in)

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
