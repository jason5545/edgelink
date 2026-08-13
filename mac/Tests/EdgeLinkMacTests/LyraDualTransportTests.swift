import CryptoKit
import EdgeLinkKit
import Foundation
import LyraServerKit
import Network
import XCTest

// Dual-transport scenarios: the same phone reachable over LAN UDP and the
// cloud relay at once. The phone's DevRepo must merge the two registrations
// into one device (it keys devices by ID, like mi_connect), and the mirror
// flow must survive a mid-stream transport flip in either direction — the
// dead transport's session must not race the fresh dial on the other.
@MainActor
final class LyraDualTransportTests: XCTestCase {
    private enum MirrorTransport { case lan, relay }

    private static let defaultsKeys = [
        "xiaomiTrustDeviceUUID",
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
    private let certBytes = Data("edgelink-dual-transport-cert".utf8)

    // Ports (own class-wide range 33_101...33_999; other harnesses use
    // 29_101+ / 30_101+ / 31_101+ / 32_101+ / 34_101+ — ranges must not
    // overlap across the parallel worker processes).
    private static var portBlockIndex: UInt16 = 0
    private var lanMeshPort: UInt16!
    private var lanCastChannelPort: UInt16!
    private var lanWfdPort: UInt16!
    private var relayWfdPort: UInt16!
    private var clientVideoPort: UInt16!

    // Shared mirror state (one controller across the flip, like production).
    private var trustManager: MacTrustManager!
    private var controller: XiaomiMirrorFlowController!
    private var session: LyraCastTrustSession?
    private var wfdClient: XiaomiMirrorWFDClient?
    private var videoListener: NWListener?
    private var videoConnection: NWConnection?
    private var videoDatagramsReceived = 0
    private var currentTransport: MirrorTransport = .lan

    // LAN leg
    private var lanPhone: FakeXiaomiPhone?

    // Relay leg
    private var relayPhone: LyraPhoneServer?
    private var hostSession: LyraRelaySession?
    private var clientSession: LyraRelaySession?
    private var hostBridge: LyraRelayTransportBridge?
    private var clientBridge: LyraRelayTransportBridge?
    private var phoneTunnel: LyraTunnelBridge?
    private var tunnelManager: TunnelManager?
    private var pair: LoopbackChannelPair?
    private var hostLoop: Task<Void, Error>?
    private var clientLoop: Task<Void, Error>?
    private var relayPhoneMeshPort: UInt16 = 0

    // Test A legs
    private var lanAnnouncePhone: LyraPhoneServer?
    private var lanAnnouncer: LyraMeshAnnouncer?
    private var relayAnnouncer: LyraMeshAnnouncer?

    override func setUp() {
        super.setUp()
        Self.portBlockIndex += 1
        let base = 33_101 + Self.portBlockIndex * 10
        lanMeshPort = base
        lanCastChannelPort = base + 1
        lanWfdPort = base + 2
        relayWfdPort = base + 3
        clientVideoPort = base + 4
        continueAfterFailure = false
        let defaults = UserDefaults.standard
        for key in Self.defaultsKeys {
            savedValues[key] = defaults.object(forKey: key)
        }
        defaults.set(UUID().uuidString, forKey: "xiaomiTrustDeviceUUID")
    }

    override func tearDown() {
        hostLoop?.cancel()
        clientLoop?.cancel()
        controller?.stop()
        wfdClient?.stop(reason: "teardown")
        videoListener?.cancel()
        videoConnection?.cancel()
        session?.cancel()
        lanPhone?.stop()
        relayPhone?.stop()
        lanAnnouncePhone?.stop()
        lanAnnouncer?.stop()
        relayAnnouncer?.stop()
        pair?.hostSide.close()
        pair?.clientSide.close()
        let defaults = UserDefaults.standard
        for key in Self.defaultsKeys {
            if let value = savedValues[key] ?? nil {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        savedValues = [:]
        super.tearDown()
    }

    // MARK: - Shared mirror wiring

    private func makeMirrorController() {
        trustManager = MacTrustManager()
        trustManager.statusRetryDelay = 0.1
        trustManager.maxStatusRetries = 3
        let controller = XiaomiMirrorFlowController(trustManager: trustManager)
        controller.sessionProvider = { [weak self] in self?.session }
        controller.sessionFactory = { [weak self] _ in
            guard let self else { return }
            self.session?.cancel()
            self.session = nil
            self.attachSession()
            self.session?.start()
        }
        controller.biometricEvaluate = {}
        controller.openMirrorScreen = { [weak self] session in
            guard let self else { return }
            let sessionId = UInt64(Date().timeIntervalSince1970 * 1000)
            session.sendScreenAction(.openMirrorScreen(sessionId: sessionId))
            self.startWFDForCurrentTransport()
        }
        controller.hasRemoteVideo = { [weak self] in
            (self?.videoDatagramsReceived ?? 0) > 0
        }
        self.controller = controller
        startVideoListener()
    }

    private func attachSession() {
        switch currentTransport {
        case .lan:
            let session = LyraCastTrustSession(
                endpoints: [("127.0.0.1", lanMeshPort)],
                deviceIdHex: "721572C3",
                displayName: "EdgeLinkMacTests",
                trustManager: trustManager
            )
            wireSessionCallbacks(session)
        case .relay:
            guard let hostBridge else { return }
            let session = LyraCastTrustSession(
                endpoints: [("127.0.0.1", relayPhoneMeshPort)],
                deviceIdHex: "721572C3",
                displayName: "EdgeLinkMacTests",
                trustManager: trustManager,
                meshTransport: hostBridge.meshFlow(index: 1),
                channelTransport: hostBridge.channel
            )
            wireSessionCallbacks(session)
        }
    }

    private func wireSessionCallbacks(_ session: LyraCastTrustSession) {
        session.retainPhysAfterAuth = true
        session.duoScreenStatusEnabled = true
        session.onChannelReady = { [weak self] in
            Task { @MainActor in
                self?.controller?.notifyChannelReady()
            }
        }
        session.onChannelReleased = { [weak self] in
            Task { @MainActor in
                self?.controller?.notifyChannelReleased()
            }
        }
        session.onFinish = { [weak self, weak session] in
            Task { @MainActor in
                guard let self, let session, self.session === session else { return }
                self.session = nil
            }
        }
        self.session = session
    }

    private func startWFDForCurrentTransport() {
        switch currentTransport {
        case .lan:
            wfdClient?.stop(reason: "replace")
            let client = XiaomiMirrorWFDClient()
            client.onSessionEstablished = { [weak self] _ in
                Task { @MainActor in
                    self?.controller?.notifyVideoFrame()
                }
            }
            wfdClient = client
            client.start(host: "127.0.0.1", rtspPort: lanWfdPort, clientRTPPort: clientVideoPort)
        case .relay:
            startWFDClientViaTunnel()
        }
    }

    private func startWFDClientViaTunnel() {
        Task { @MainActor [weak self] in
            guard let self, let tunnelManager = self.tunnelManager else { return }
            do {
                let localPort = try await tunnelManager.startLocalForward(
                    targetHost: "127.0.0.1",
                    targetPort: Int(self.relayWfdPort),
                    label: "wfd"
                )
                guard let rtspPort = UInt16(exactly: localPort) else {
                    XCTFail("wfd tunnel returned bad port \(localPort)")
                    return
                }
                self.wfdClient?.stop(reason: "replace")
                let client = XiaomiMirrorWFDClient()
                client.onSessionEstablished = { [weak self] _ in
                    Task { @MainActor in
                        self?.controller?.notifyVideoFrame()
                    }
                }
                self.wfdClient = client
                client.start(host: "127.0.0.1", rtspPort: rtspPort, clientRTPPort: self.clientVideoPort)
            } catch {
                XCTFail("wfd tunnel forward failed: \(error)")
            }
        }
    }

    private func startVideoListener() {
        let listener = try? NWListener(using: .udp, on: NWEndpoint.Port(rawValue: clientVideoPort)!)
        listener?.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global())
            Task { @MainActor in
                self?.videoConnection = connection
            }
            self?.receiveVideo(on: connection)
        }
        listener?.start(queue: .global())
        videoListener = listener
    }

    private nonisolated func receiveVideo(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            if data != nil {
                Task { @MainActor in
                    guard let self else { return }
                    self.videoDatagramsReceived += 1
                    if self.videoDatagramsReceived == 1 {
                        self.controller?.notifyVideoFrame()
                    }
                }
            }
            if error == nil {
                self?.receiveVideo(on: connection)
            }
        }
    }

    private func waitFor(
        _ description: String,
        timeout: TimeInterval = 20,
        condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("timeout waiting for: \(description)")
    }

    // MARK: - LAN leg

    private func startLANPhoneAndSession() throws {
        currentTransport = .lan
        let phone = FakeXiaomiPhone(
            meshPort: lanMeshPort,
            castChannelPort: lanCastChannelPort,
            wfdPort: lanWfdPort,
            clientVideoPort: clientVideoPort,
            locked: false
        )
        lanPhone = phone
        try phone.start()
        attachSession()
    }

    // MARK: - Relay leg

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

        let tunnelManager = TunnelManager()
        self.tunnelManager = tunnelManager

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
                } else if TunnelBridgeEnvelopes.isTunnelType(type) {
                    Task { await tunnelManager.handleEnvelope(type: type, plaintext: plaintext) }
                }
            }
        )
        hostSessionBox.session = hostSession
        await tunnelManager.setSendHandler { data in
            try await hostSessionBox.session?.sendPlaintext(data)
        }

        let clientSessionBox = SessionBox()
        let clientBridge = LyraRelayTransportBridge(sendHandler: { data in
            try await clientSessionBox.session?.sendPlaintext(data)
        })
        let phoneTunnel = LyraTunnelBridge(sendHandler: { data in
            try await clientSessionBox.session?.sendPlaintext(data)
        })
        let clientSession = LyraRelaySession(
            channel: pair.clientSide,
            identity: clientIdentity,
            onEnvelope: { type, plaintext in
                if LyraRelayTransportBridge.handles(type) {
                    clientBridge.handleEnvelope(type: type, plaintext: plaintext)
                } else if LyraTunnelBridge.handles(type) {
                    Task { await phoneTunnel.handleEnvelope(type: type, plaintext: plaintext) }
                }
            }
        )
        clientSessionBox.session = clientSession

        self.hostBridge = hostBridge
        self.clientBridge = clientBridge
        self.phoneTunnel = phoneTunnel
        self.hostSession = hostSession
        self.clientSession = clientSession

        async let hostAccept: Void = hostSession.acceptAsHost(pinnedClientPublicKey: clientIdentity.publicKey)
        async let clientConnect: Void = clientSession.connectAsClient(pinnedHostPublicKey: hostIdentity.publicKey)
        _ = try await (hostAccept, clientConnect)

        hostLoop = Task { try await hostSession.receiveLoop() }
        clientLoop = Task { try await clientSession.receiveLoop() }
    }

    private func startRelayPhoneAndSession() async throws {
        currentTransport = .relay
        let clientBridge = try XCTUnwrap(clientBridge)
        let hostBridge = try XCTUnwrap(hostBridge)
        let phone = LyraPhoneServer(
            identity: LyraPhoneIdentity.generate(),
            wfdPort: relayWfdPort,
            meshTransport: clientBridge.meshFlow(index: 1),
            castChannelTransport: clientBridge.channel,
            clientVideoPort: clientVideoPort
        )
        phone.cast.setLocked(false)
        phone.cast.wfdServerStartupDelay = 1.5
        phone.onEvent = { event in
            if case .log(let text) = event {
                DiagnosticsLog.info("fakephone.\(text)")
            }
        }
        relayPhone = phone
        try phone.start(port: 0)
        relayPhoneMeshPort = try XCTUnwrap(phone.boundPort)
        hostBridge.meshFlow(index: 1).peerPort = relayPhoneMeshPort
        attachSession()
    }

    private func teardownRelayLeg() {
        hostLoop?.cancel()
        clientLoop?.cancel()
        hostLoop = nil
        clientLoop = nil
        relayPhone?.stop()
        relayPhone = nil
        pair?.hostSide.close()
        pair?.clientSide.close()
        pair = nil
        hostBridge = nil
        clientBridge = nil
        phoneTunnel = nil
        tunnelManager = nil
        hostSession = nil
        clientSession = nil
    }

    private func driveMirrorFlowToStreaming(openCount: @escaping () -> Int) async throws {
        let session = try XCTUnwrap(self.session)
        session.start()
        controller.start()

        try await waitFor("cast channel ready") { [weak session] in
            session?.isChannelReady == true
        }
        try await waitFor("OPEN_MIRROR_SCREEN") {
            openCount() >= 1
        }
        try await waitFor("video datagrams flowing") {
            self.videoDatagramsReceived >= 3
        }
        try await waitFor("controller streaming, mask cleared") {
            self.controller.stage == .streaming && self.controller.mask == nil
        }
    }

    // MARK: - Test A: dual registration dedups into one device

    // The Mac announces over LAN UDP and the cloud relay simultaneously (the
    // phone is on WiFi AND logged into the same relay). Both announces carry
    // the same device identity: the phone's DevRepo must hold ONE online
    // device for this Mac, and the relayCall dial must work.
    func testDualTransportAnnounceRegistersSingleDevice() async throws {
        let defaults = UserDefaults.standard
        defaults.set(macIdentity.rawRepresentation.map { String(format: "%02x", $0) }.joined(),
                     forKey: "xiaomiTrustIdentityPrivHex")
        defaults.set(macIdentity.publicKey.x963Representation.base64EncodedString(),
                     forKey: "xiaomiTrustIdentityPubB64")
        defaults.removeObject(forKey: "xiaomiTrustSessionKeyHex")
        defaults.removeObject(forKey: "xiaomiTrustTicketHex")
        defaults.set(Data(SHA256.hash(data: Data("dual-transport-uid".utf8))).base64EncodedString(),
                     forKey: "xiaomiTrustUidHashB64")
        defaults.set(certBytes.map { String(format: "%02x", $0) }.joined(),
                     forKey: "xiaomiTrustCredCertHex")
        defaults.set(credKey.rawRepresentation.map { String(format: "%02x", $0) }.joined(),
                     forKey: "xiaomiTrustCredPrivHex")
        defaults.set(true, forKey: "xiaomiRelayCallAdvertise")
        defaults.set(LyraPhoneIdentity.fixtureAccountPubB64, forKey: "xiaomiTrustPeerAccountPubB64")
        MiTrustTicketStore.lastAuthSessionKeyData = nil

        try await establishRelaySession()
        let clientBridge = try XCTUnwrap(clientBridge)
        let hostBridge = try XCTUnwrap(hostBridge)

        // One phone brain (identity + DevRepo), two mesh endpoints.
        let identity = LyraPhoneIdentity.generate()
        let sharedOracle = LyraDevRepoOracle()
        let relayPhone = LyraPhoneServer(
            identity: identity,
            meshTransport: clientBridge.mesh,
            relayCallChannelTransport: clientBridge.channel,
            oracle: sharedOracle
        )
        relayPhone.pair(withMacIdentityPubKey: macIdentity.publicKey.x963Representation)
        relayPhone.oracle.trustedCerts[certBytes] = credKey.publicKey.x963Representation
        self.relayPhone = relayPhone
        try relayPhone.start(port: 0)
        let relayMeshPort = try XCTUnwrap(relayPhone.boundPort)

        let lanPhone = LyraPhoneServer(identity: identity, oracle: sharedOracle)
        lanPhone.pair(withMacIdentityPubKey: macIdentity.publicKey.x963Representation)
        lanAnnouncePhone = lanPhone
        try lanPhone.start(port: 0)
        try await waitFor("LAN phone listener ready") { lanPhone.boundPort != nil }
        let lanMeshPort = try XCTUnwrap(lanPhone.boundPort)

        // Mac announces over both transports.
        hostBridge.mesh.peerPort = relayMeshPort
        let relayAnnouncer = LyraMeshAnnouncer(
            deviceIdHexProvider: { "721572C3" },
            displayNameProvider: { "MacBook Pro" },
            meshTransport: hostBridge.mesh
        )
        relayAnnouncer.relayCallChannelTransport = hostBridge.channel
        self.relayAnnouncer = relayAnnouncer
        relayAnnouncer.start(host: "127.0.0.1", port: relayMeshPort)

        let lanAnnouncer = LyraMeshAnnouncer(
            deviceIdHexProvider: { "721572C3" },
            displayNameProvider: { "MacBook Pro" }
        )
        self.lanAnnouncer = lanAnnouncer
        lanAnnouncer.start(host: "127.0.0.1", port: lanMeshPort)

        try await waitFor("Mac online in the shared oracle") {
            sharedOracle.onlineDevices().contains { $0.device.hasService("relayCall") }
        }
        XCTAssertEqual(
            sharedOracle.onlineDevices().count, 1,
            "dual-transport announces must merge into one device record"
        )

        // The relayCall dial (over the relay leg) still works.
        XCTAssertTrue(relayPhone.dialRelayCallIfOnline())
        try await waitFor("relayCall channel up") {
            relayPhone.relayCall.state == .channelUp
        }
        relayPhone.relayCall.sendRing(number: "0912345678")
        try await waitFor("ring response 200") {
            relayPhone.relayCall.lastRingResponse?.contains("\"code\":200") == true
        }
    }

    // MARK: - Test B/C: mid-stream transport flip

    // LAN mirror streaming; the phone leaves the LAN (WiFi drops). The dead
    // LAN session is cancelled (runtime invalidation) and the flow rebuilds
    // over the cloud relay — streaming resumes and the torn-down LAN leg
    // plays no further part.
    func testMirrorFlowFlipsFromLANToRelayMidStream() async throws {
        makeMirrorController()
        try startLANPhoneAndSession()
        try await driveMirrorFlowToStreaming { self.lanPhone?.openMirrorScreenCount ?? 0 }

        // Phone leaves the LAN; the runtime invalidates the LAN-routed
        // session on the relay transport reconfigure.
        lanPhone?.stop()
        lanPhone = nil
        session?.cancel()
        session = nil
        videoDatagramsReceived = 0

        try await establishRelaySession()
        try await startRelayPhoneAndSession()

        controller.stop()
        try await driveMirrorFlowToStreaming { self.relayPhone?.cast.openMirrorScreenCount ?? 0 }
    }

    // Relay mirror streaming (phone on cellular); the phone returns to the
    // LAN. Symmetric flip: the relay session is torn down and the flow
    // rebuilds on the LAN path.
    func testMirrorFlowFlipsFromRelayToLANMidStream() async throws {
        makeMirrorController()
        try await establishRelaySession()
        try await startRelayPhoneAndSession()
        try await driveMirrorFlowToStreaming { self.relayPhone?.cast.openMirrorScreenCount ?? 0 }

        // Phone rejoins the LAN; the relay-routed session is invalidated on
        // the flip and the flow rebuilds over LAN.
        session?.cancel()
        session = nil
        teardownRelayLeg()
        videoDatagramsReceived = 0

        try startLANPhoneAndSession()

        controller.stop()
        try await driveMirrorFlowToStreaming { self.lanPhone?.openMirrorScreenCount ?? 0 }
    }
}

// MARK: - Relay pair support (worker stand-in)

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
