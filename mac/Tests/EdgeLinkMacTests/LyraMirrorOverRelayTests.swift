import CryptoKit
import EdgeLinkKit
import Foundation
import LyraServerKit
import Network
import XCTest

// Same mirror control-plane chain as MirrorFlowE2ETests — phys sync → cookie
// → sync auth → upgrade → logi request → peer port → channel negotiation →
// duo.screen status → OPEN_MIRROR_SCREEN → WFD M1-M8 → UDP video — but every
// mesh and channel datagram crosses the E2EE relay session (the cloud-relay
// transport). The session dispatch also routes tunnel envelopes (route b),
// and the WFD RTSP dialog rides a real local forward through the tunnel to
// the phone's loopback RTSP server. The fake phone (LyraPhoneServer +
// LyraCastRole) and the Mac production classes (LyraCastTrustSession +
// MacTrustManager + XiaomiMirrorFlowController + XiaomiMirrorWFDClient) sit
// on either side of a LyraRelaySession pair wired through
// LyraRelayTransportBridges.
@MainActor
final class LyraMirrorOverRelayTests: XCTestCase {
    private static let defaultsKeys = [
        "xiaomiTrustDeviceUUID",
    ]

    private var savedValues: [String: Any?] = [:]

    private var phone: LyraPhoneServer?
    private var trustManager: MacTrustManager?
    private var session: LyraCastTrustSession?
    private var controller: XiaomiMirrorFlowController?
    private var wfdClient: XiaomiMirrorWFDClient?
    private var videoListener: NWListener?
    private var videoConnection: NWConnection?
    private var videoDatagramsReceived = 0
    private var tunnelManager: TunnelManager?

    private var hostSession: LyraRelaySession?
    private var clientSession: LyraRelaySession?
    private var hostBridge: LyraRelayTransportBridge?
    private var clientBridge: LyraRelayTransportBridge?
    private var phoneTunnel: LyraTunnelBridge?
    private var pair: LoopbackChannelPair?
    private var impairedPair: ImpairedChannelPair?
    private var hostLoop: Task<Void, Error>?
    private var clientLoop: Task<Void, Error>?
    private var savedIsExpectedPhoneHost: ((String) -> Bool)?
    private var savedActiveRelayBridge: (() -> LyraRelayTransportBridge?)?
    private var relayAnnouncer: LyraMeshAnnouncer?
    private var phoneAnnounceMesh: LyraPhoneMeshServer?
    // LAN-hybrid scenario (castOverLAN): the cast session dials the phone's
    // real UDP mesh like a LAN desk while the announcer stays relay-fed.
    private var castIsLAN = false
    private var lanPhoneMeshPort: UInt16 = 0
    private var lanCastChannelPort: UInt16 = 0

    // When set, the relay session pair crosses an impaired link (cloud-relay
    // conditions) instead of the perfect loopback. Configure before calling
    // establishRelaySession().
    var impairmentHostToClient: RelayImpairmentProfile?
    var impairmentClientToHost: RelayImpairmentProfile?

    // Unique port block per test (the WFD TCP listener and the video UDP
    // listener bind real sockets; the previous test's release is async).
    // Class-wide range 30_101...30_999 — must not overlap the other
    // harnesses' ranges (29_101+ MirrorFlowE2ETests, 31_101+ call relay,
    // 32_101+ dial-end, 33_101+ dual-transport, 34_101+ media load):
    // parallel workers are separate processes, so colliding ports double-
    // bind across processes (2026-08-12 flake: this class's video UDP
    // 29_342 collided with MirrorFlowE2ETests' cast-channel UDP 29_342 and
    // wedged both tests).
    private static var portBlockIndex: UInt16 = 0
    private var wfdPort: UInt16!
    private var clientVideoPort: UInt16!
    private var phoneMeshPort: UInt16 = 0

    override func setUp() {
        super.setUp()
        Self.portBlockIndex += 1
        let base = 30_101 + Self.portBlockIndex * 10
        wfdPort = base
        clientVideoPort = base + 1
        continueAfterFailure = false
        let defaults = UserDefaults.standard
        for key in Self.defaultsKeys {
            savedValues[key] = defaults.object(forKey: key)
        }
        // trustDeviceUUID() reads a generic-password item owned by the real
        // app — in the test process that keychain read blocks on an ACL
        // prompt. Override it so tests never touch that item.
        defaults.set(UUID().uuidString, forKey: "xiaomiTrustDeviceUUID")
        // Production pins the phone's LAN IP once a LAN session exists; the
        // pin goes stale when the phone drops to cellular-only, and the
        // relay-carried peer presents 127.0.0.1. Reproduce that here: the
        // relay flow must complete despite a pin that rejects 127.0.0.1.
        savedIsExpectedPhoneHost = LyraCastTrustSession.isExpectedPhoneHost
        LyraCastTrustSession.isExpectedPhoneHost = { $0 == "10.9.9.9" }
        savedActiveRelayBridge = LyraCastTrustSession.activeRelayBridge
    }

    override func tearDown() {
        hostLoop?.cancel()
        clientLoop?.cancel()
        hostLoop = nil
        clientLoop = nil
        controller?.stop()
        wfdClient?.stop(reason: "teardown")
        videoListener?.cancel()
        videoConnection?.cancel()
        session?.cancel()
        relayAnnouncer?.stop()
        relayAnnouncer = nil
        phoneAnnounceMesh?.stop()
        phoneAnnounceMesh = nil
        phone?.stop()
        pair?.hostSide.close()
        pair?.clientSide.close()
        pair = nil
        impairedPair?.hostSide.close()
        impairedPair?.clientSide.close()
        impairedPair = nil
        hostBridge = nil
        clientBridge = nil
        phoneTunnel = nil
        tunnelManager = nil
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
        if let savedIsExpectedPhoneHost {
            LyraCastTrustSession.isExpectedPhoneHost = savedIsExpectedPhoneHost
        }
        if let savedActiveRelayBridge {
            LyraCastTrustSession.activeRelayBridge = savedActiveRelayBridge
        }
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

        let tunnelManager = TunnelManager()
        self.tunnelManager = tunnelManager

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
            channel: clientChannel,
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

    // Wires the fake phone (client end) and the production mirror classes
    // (host end) onto the established relay session. `ackFramedResponses`
    // reproduces the real phone's mesh service behavior seen on the cloud
    // relay: responses leave as ack-command datagrams carrying the payload
    // (0x52 + data) instead of pushes.
    private func startMirrorEnds(
        locked: Bool, ackFramedResponses: Bool = false, mitrustViaAnnounceFlow: Bool = false,
        castOverLAN: Bool = false
    ) async throws {
        let clientBridge = try XCTUnwrap(clientBridge)
        let hostBridge = try XCTUnwrap(hostBridge)
        castIsLAN = castOverLAN

        // Production wiring: the cast trust dial rides mesh flow 1 (the
        // announce/relayCall dial owns flow 0) so the phone sees a fresh peer
        // for its phys sync, like a brand-new LAN UDP socket.
        if ackFramedResponses {
            clientBridge.meshFlow(index: 1).dataCommand = LyraMeshDatagram.commandAck
            clientBridge.channel.dataCommand = LyraMeshDatagram.commandAck
        }
        let phone: LyraPhoneServer
        if castOverLAN {
            // LAN-hybrid (live 2026-08-13): the phone is dual-homed — the
            // secure session and its relay-fed announcer ride the cloud
            // relay, but the mirror's cast session dials the phone's real
            // LAN mesh (LAN-first policy). The phone's mesh/cast channel
            // are real UDP sockets here.
            lanPhoneMeshPort = 30_101 + Self.portBlockIndex * 10 + 2
            lanCastChannelPort = 30_101 + Self.portBlockIndex * 10 + 3
            phone = LyraPhoneServer(
                identity: LyraPhoneIdentity.generate(),
                castChannelPort: lanCastChannelPort,
                wfdPort: wfdPort,
                clientVideoPort: clientVideoPort
            )
        } else {
            phone = LyraPhoneServer(
                identity: LyraPhoneIdentity.generate(),
                castChannelPort: 0,
                wfdPort: wfdPort,
                meshTransport: clientBridge.meshFlow(index: 1),
                castChannelTransport: clientBridge.channel,
                clientVideoPort: clientVideoPort
            )
        }
        // The real phone's mitrust channel dial crosses the relay too: the
        // phone bridge's reverse listener stamps the advertised Mac port onto
        // every envelope, and the Mac bridge routes by that stamp. Mimic it
        // with a bridge channel pipe keyed by the dialed port.
        phone.cast.mitrustChannelFactory = { [weak clientBridge] port in
            clientBridge?.channelPipe(port: port)
        }
        phone.cast.setLocked(locked)
        phone.onEvent = { event in
            if case .log(let text) = event {
                DiagnosticsLog.info("fakephone.\(text)")
            }
        }
        // Live-phone behavior: the WFD RTSP listener comes up asynchronously
        // after the phone processes OPEN_MIRROR_SCREEN, so the tunnel's first
        // dial lands before it listens. The phone-side dial must retry
        // (connection-refused) or the relay mirror deadlocks here.
        phone.cast.wfdServerStartupDelay = 1.5
        self.phone = phone
        try phone.start(port: castOverLAN ? lanPhoneMeshPort : 0)
        // LAN sockets bind asynchronously (NWListener ready callback); the
        // LAN variant dialed a fixed port so there is nothing to wait for.
        phoneMeshPort = castOverLAN ? lanPhoneMeshPort : try XCTUnwrap(phone.boundPort)

        if mitrustViaAnnounceFlow {
            // Live 2026-08-12: the real phone's trustservice dials
            // mitrustservice on whichever phys conn its score-based reuse
            // judge picks — sometimes the ANNOUNCE flow's, not the cast
            // flow's. Run the production relay announcer on mesh flow 0 and
            // route the phone's mitrust adoption over it.
            let announceMesh = LyraPhoneMeshServer(
                identity: phone.identity, oracle: phone.oracle,
                meshTransport: clientBridge.meshFlow(index: 0)
            )
            try announceMesh.start(port: 0)
            phoneAnnounceMesh = announceMesh
            phone.cast.mitrustMeshServerOverride = announceMesh
            let announcer = LyraMeshAnnouncer(
                deviceIdHexProvider: { "721572C3" },
                displayNameProvider: { "EdgeLinkMacTests" },
                meshTransport: hostBridge.meshFlow(index: 0)
            )
            let announcePort = try XCTUnwrap(announceMesh.boundPort)
            hostBridge.meshFlow(index: 0).peerPort = announcePort
            announcer.start(host: "127.0.0.1", port: announcePort)
            relayAnnouncer = announcer
        }

        // The mesh pipe presents the peer endpoint to the trust session;
        // point it at the phone's mesh port before dialing.
        if !castOverLAN {
            hostBridge.meshFlow(index: 1).peerPort = phoneMeshPort
        }

        let trustManager = MacTrustManager()
        trustManager.statusRetryDelay = 0.1
        trustManager.maxStatusRetries = 3
        self.trustManager = trustManager
        if castOverLAN {
            // The LAN cast session's phys-sync reply comes from the phone's
            // loopback UDP socket in this harness — accept it as the pinned
            // phone host.
            LyraCastTrustSession.isExpectedPhoneHost = { $0 == "10.9.9.9" || $0 == "127.0.0.1" }
            // Production wiring (EdgeLinkRuntime): the runtime's current
            // relay bridge, consulted when a relay-fed phys conn adopts
            // mitrustservice into a LAN-routed session.
            LyraCastTrustSession.activeRelayBridge = { [weak self] in self?.hostBridge }
            attachLANSession()
        } else {
            attachSession()
        }

        let controller = XiaomiMirrorFlowController(trustManager: trustManager)
        controller.sessionProvider = { [weak self] in self?.session }
        controller.sessionFactory = { [weak self] _ in
            self?.rebuildCastSession()
        }
        controller.biometricEvaluate = {}
        controller.openMirrorScreen = { [weak self] session in
            guard let self else { return }
            let sessionId = UInt64(Date().timeIntervalSince1970 * 1000)
            session.sendScreenAction(.openMirrorScreen(sessionId: sessionId))
            if self.castIsLAN {
                self.startWFDClientDirect()
            } else {
                self.startWFDClientViaTunnel()
            }
        }
        controller.hasRemoteVideo = { [weak self] in
            (self?.videoDatagramsReceived ?? 0) > 0
        }
        self.controller = controller
        startVideoListener()
    }

    private func attachSession() {
        guard let hostBridge else { return }
        let trustManager = trustManager ?? MacTrustManager()
        let session = LyraCastTrustSession(
            endpoints: [("127.0.0.1", phoneMeshPort)],
            deviceIdHex: "721572C3",
            displayName: "EdgeLinkMacTests",
            trustManager: trustManager,
            meshTransport: hostBridge.meshFlow(index: 1),
            channelTransport: hostBridge.channel,
            relayBridge: hostBridge
        )
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
                if self.castRebuildPending {
                    self.castRebuildPending = false
                    self.redialCastSessionOnFreshPipes()
                }
            }
        }
        self.session = session
    }

    // LAN variant: the session dials the phone's real UDP mesh socket — no
    // relay pipes, relayBridge == nil, exactly the production LAN-first
    // mirror session.
    private func attachLANSession() {
        let trustManager = trustManager ?? MacTrustManager()
        let session = LyraCastTrustSession(
            endpoints: [("127.0.0.1", lanPhoneMeshPort)],
            deviceIdHex: "721572C3",
            displayName: "EdgeLinkMacTests",
            trustManager: trustManager
        )
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
                if self.castRebuildPending {
                    self.castRebuildPending = false
                    self.attachLANSession()
                    self.session?.start()
                }
            }
        }
        self.session = session
    }

    private var castRebuildPending = false

    // Production dials each cast session from a fresh peer (on the relay
    // transport a fresh random flow index), so the phone restarts its KCP
    // sn at 0 and neither side's dedupe carries stale state across dials.
    // The harness reuses flow 1, so the rebuild must reset both flow pipes
    // — and it must wait for the old session's teardown first: cancel()
    // asynchronously stops the SHARED bridge pipes from the old session's
    // queue, and a rebuild that doesn't wait races that stop into the fresh
    // dial (the late stop resets nextSendSn mid-dial; the phone drops the
    // regressed sn behind its recvUna and the dial wedges — the 2026-08-12
    // "OPEN_MIRROR_SCREEN after rebuild" flake).
    private func rebuildCastSession() {
        if let old = session {
            guard !castRebuildPending else { return }
            castRebuildPending = true
            old.cancel()
            return
        }
        redialCastSessionOnFreshPipes()
    }

    private func redialCastSessionOnFreshPipes() {
        if castIsLAN {
            attachLANSession()
            session?.start()
            return
        }
        clientBridge?.meshFlow(index: 1).stop()
        try? clientBridge?.meshFlow(index: 1).start(preferredPort: phoneMeshPort)
        hostBridge?.meshFlow(index: 1).stop()
        try? hostBridge?.meshFlow(index: 1).start(preferredPort: nil)
        attachSession()
        session?.start()
    }

    // The WFD RTSP dialog rides the EdgeLink TCP tunnel (route b), exactly the
    // production no-LAN route: the Mac opens a local forward to the phone's
    // RTSP port, the phone-side LyraTunnelBridge dials its own loopback WFD
    // server, and the WFD client talks to the tunnel's local port.
    private func startWFDClientViaTunnel() {
        Task { @MainActor [weak self] in
            guard let self, let tunnelManager = self.tunnelManager else { return }
            do {
                let localPort = try await tunnelManager.startLocalForward(
                    targetHost: "127.0.0.1",
                    targetPort: Int(self.wfdPort),
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

    // LAN variant: the WFD dialog dials the phone's RTSP listener directly
    // (no tunnel), exactly the production LAN mirror.
    private func startWFDClientDirect() {
        wfdClient?.stop(reason: "replace")
        let client = XiaomiMirrorWFDClient()
        client.onSessionEstablished = { [weak self] _ in
            Task { @MainActor in
                self?.controller?.notifyVideoFrame()
            }
        }
        wfdClient = client
        client.start(host: "127.0.0.1", rtspPort: wfdPort, clientRTPPort: clientVideoPort)
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

    // MARK: - Tests

    // Full chain over the relay session: cast trust handshake → channel →
    // duo.screen status → OPEN_MIRROR_SCREEN → RTSP over the TCP tunnel →
    // video datagrams → streaming with the mask cleared.
    func testMirrorFlowOverCloudRelay() async throws {
        try await establishRelaySession()
        try await startMirrorEnds(locked: false)
        let phone = try XCTUnwrap(self.phone)
        let session = try XCTUnwrap(self.session)
        let controller = try XCTUnwrap(self.controller)
        session.start()
        controller.start()

        try await waitFor("cast channel ready over relay") { [weak session] in
            session?.isChannelReady == true
        }
        try await waitFor("duo.screen status over relay channel") {
            phone.cast.statusActionCount >= 1
        }
        try await waitFor("OPEN_MIRROR_SCREEN over relay channel") {
            phone.cast.openMirrorScreenCount >= 1
        }
        try await waitFor("WFD established over the TCP tunnel") {
            phone.cast.wfdSessionEstablished
        }
        try await waitFor("video datagrams flowing") {
            self.videoDatagramsReceived >= 3
        }
        try await waitFor("controller streaming, mask cleared") {
            controller.stage == .streaming && controller.mask == nil
        }
    }

    // Same full chain, but the fake phone frames every response as an
    // ack-command datagram with payload — the exact wire behavior the real
    // phone's mesh service showed on the relay (a 0x52 phys-sync response
    // with a 227-byte payload), which the push-only receive guard dropped and
    // wedged the cast dial at physSync.
    func testMirrorFlowOverCloudRelayWithAckFramedResponses() async throws {
        try await establishRelaySession()
        try await startMirrorEnds(locked: false, ackFramedResponses: true)
        let phone = try XCTUnwrap(self.phone)
        let session = try XCTUnwrap(self.session)
        let controller = try XCTUnwrap(self.controller)
        session.start()
        controller.start()

        try await waitFor("cast channel ready over relay (ack-framed)") { [weak session] in
            session?.isChannelReady == true
        }
        try await waitFor("duo.screen status over relay channel") {
            phone.cast.statusActionCount >= 1
        }
        try await waitFor("OPEN_MIRROR_SCREEN over relay channel") {
            phone.cast.openMirrorScreenCount >= 1
        }
        try await waitFor("WFD established over the TCP tunnel") {
            phone.cast.wfdSessionEstablished
        }
        try await waitFor("video datagrams flowing") {
            self.videoDatagramsReceived >= 3
        }
        try await waitFor("controller streaming, mask cleared") {
            controller.stage == .streaming && controller.mask == nil
        }
    }

    // The phone releases the cast logi conn mid-stream (logi disconnect). The
    // session's finishLocked() stops the virtual pipes from inside the pipe's
    // own frame handler — this deadlocked the pipe queue and killed the app
    // three times on 2026-08-08. The session must now finish cleanly.
    func testPhoneReleaseDuringRelaySessionFinishesCleanly() async throws {
        try await establishRelaySession()
        try await startMirrorEnds(locked: false)
        let phone = try XCTUnwrap(self.phone)
        let session = try XCTUnwrap(self.session)
        let controller = try XCTUnwrap(self.controller)
        session.start()
        controller.start()

        try await waitFor("cast channel ready over relay") { [weak session] in
            session?.isChannelReady == true
        }

        phone.cast.releaseCastChannel()

        // Depending on whether a mitrust conn was adopted the session either
        // finishes or just marks the channel dead; both paths used to crash
        // on the sync pipe stop, and both must complete cleanly now.
        try await waitFor("channel marked dead after phone release") { [weak self, weak session] in
            guard let self else { return true }
            return self.session == nil || session?.isChannelReady == false
        }
    }

    // User stop round-trips on the relay-carried channel: CLOSE_SCREEN lands
    // on the phone, its RTSP server tears down, and the flow returns to idle.
    func testCloseScreenRoundTripsOverCloudRelay() async throws {
        try await establishRelaySession()
        try await startMirrorEnds(locked: false)
        let phone = try XCTUnwrap(self.phone)
        let session = try XCTUnwrap(self.session)
        let controller = try XCTUnwrap(self.controller)
        session.start()
        controller.start()

        try await waitFor("controller streaming") {
            controller.stage == .streaming && controller.mask == nil
        }

        session.sendScreenAction(.closeScreen(sessionId: 1))
        wfdClient?.stop(reason: "user_stop")
        controller.stop()

        try await waitFor("phone tore down its RTSP server") {
            phone.cast.closeScreenCount == 1 && !phone.cast.wfdSessionEstablished
        }
        XCTAssertEqual(controller.stage, .idle)
        XCTAssertNil(controller.mask)
    }

    // MARK: - Trust Unlocked over the cloud relay

    // Trust Unlocked over the relay: locked phone, every mesh and channel
    // datagram crossing the relay session. 解除鎖定 runs Touch ID → the 562
    // duo.screen authAction rides the relay-carried cast channel → the phone
    // dials mitrustservice over the relay-carried mesh and drives
    // 595/546/562 → auth event → mask clears → video streams.
    func testTrustUnlockOverCloudRelay() async throws {
        try await establishRelaySession()
        try await startMirrorEnds(locked: true)
        try await driveUnlockToStreaming()
    }

    // Same unlock, but at the measured HiNet↔Cloudflare WAN latency: the
    // mitrust KeyAgree + peer-port + channel exchange adds several WAN round
    // trips and must still complete inside the flow's patience.
    func testTrustUnlockOverCloudRelayAtWANLatency() async throws {
        impairmentHostToClient = .hiNetCloudflareWANOrdered
        impairmentClientToHost = .hiNetCloudflareWANOrdered
        try await establishRelaySession()
        try await startMirrorEnds(locked: true)
        try await driveUnlockToStreaming()
    }

    // Same unlock over an unordered link: reordered relay frames must not
    // kill the session (sliding-window anti-replay) nor wedge the mitrust
    // dial's KCP reassembly.
    func testTrustUnlockOverCloudRelayToleratesReordering() async throws {
        impairmentHostToClient = .hiNetCloudflareWAN
        impairmentClientToHost = .hiNetCloudflareWAN
        try await establishRelaySession()
        try await startMirrorEnds(locked: true)
        try await driveUnlockToStreaming()
    }

    // Same unlock, but the phone speaks the official 82 58 packet format on
    // the relay-carried mitrust channel (live 2026-08-11: the phone's
    // HeteroChannel client sent every post-negotiation frame as 82 58; the
    // pipe wiped them as unknown prefixes and the 562 never arrived). The
    // pipe must decode official frames and answer in the same format.
    func testTrustUnlockOverCloudRelayWithOfficialPacketFormat() async throws {
        try await establishRelaySession()
        try await startMirrorEnds(locked: true)
        let phone = try XCTUnwrap(self.phone)
        phone.cast.mitrustSpeaksOfficial = true
        try await driveUnlockToStreaming()
    }

    // Live 2026-08-12: the phone's trustservice dialed mitrustservice
    // reusing the ANNOUNCE flow's phys conn (score-based reuse), not the cast
    // flow's. The announcer must adopt the mitrust conn into the live trust
    // session — pre-fix those sync_infos fell into announcer_stray_conn and
    // the unlock timed out (phone: "remote device is not responding").
    func testTrustUnlockOverCloudRelayWhenMitrustDialsAnnounceFlow() async throws {
        try await establishRelaySession()
        try await startMirrorEnds(locked: true, mitrustViaAnnounceFlow: true)
        try await driveUnlockToStreaming()
    }

    // Live 2026-08-13 04:13–04:18: dual-homed phone (secure session over the
    // cloud relay, mirror on LAN per the LAN-first policy). The phone's
    // trustservice score-based reuse dialed mitrustservice on the RELAY-fed
    // announce phys conn while the cast session was LAN-routed. The session
    // keyed the mitrust server channel off its OWN transport (relayBridge ==
    // nil → plain LAN UDP socket) and advertised that port on the adopted
    // relay conn; the phone's channel client, bound to the relay phys conn's
    // addressing, dialed through its relay bridge — the Mac bridge had no
    // pipe for the port and dropped every datagram. No channel, 562 went
    // nowhere, ~10s kcp trans timeout → authEvent code=1 → hard 解鎖失敗
    // mask. Which phys conn the phone picked was effectively random, hence
    // the alternating success/code=1. The mitrust channel transport must
    // follow the ADOPTION conn: relay-fed adoption → bridge pipe on the
    // runtime's current relay bridge.
    func testTrustUnlockWhenRelayFedAdoptionMeetsLANCastSession() async throws {
        try await establishRelaySession()
        try await startMirrorEnds(locked: true, mitrustViaAnnounceFlow: true, castOverLAN: true)
        let phone = try XCTUnwrap(self.phone)
        let session = try XCTUnwrap(self.session)
        let controller = try XCTUnwrap(self.controller)
        // The stuck-ceremony watchdog mirrors the real phone's ~10s kcp
        // trans timeout; 8s leaves the loopback-relay ceremony ample room
        // under parallel test load while still failing fast on a regression.
        phone.cast.mitrustUnlockTimeout = 8
        session.start()
        controller.start()

        try await waitFor("cast channel ready over LAN") { [weak session] in
            session?.isChannelReady == true
        }
        try await waitFor("lock mask from truthful locked status") {
            controller.mask == .locked
        }
        try await waitFor("OPEN sent even while locked (official)") {
            phone.cast.openMirrorScreenCount >= 1
        }

        controller.unlockRequested()

        try await waitFor("phone received duo.screen authAction (562)") {
            phone.cast.authActionCount >= 1
        }
        // The phone adopted mitrustservice on the relay-fed announce conn;
        // its channel dial crosses the relay. The session must register the
        // server channel on the current relay bridge so the dial lands.
        try await waitFor("phone verified auth_token_A (562/563) via relay-fed mitrust channel") {
            phone.cast.mitrustUnlockCompleted && phone.cast.lastAuthTokenA != nil
        }
        XCTAssertEqual(
            phone.cast.mitrustUnlockTimedOutCount, 0,
            "the relay-fed channel dial must connect — no kcp-timeout code=1"
        )
        try await waitFor("mask cleared via confirmed unlock") {
            controller.mask == nil
        }
        try await waitFor("controller streaming") {
            controller.stage == .streaming && controller.mask == nil
        }
    }

    // Live 2026-08-13 05:53 (LAN 直連): the phone's Mirror app idle-auto-
    // released the cast channel (~5s), the redial went unanswered,
    // redial_timeout failed the session, and the session teardown killed the
    // mitrust server channel — but the phone's mitrust channel CLIENT only
    // learns a dead conn from the phys heartbeat (~17-20s). A 562 landing in
    // that zombie window went nowhere and the phone's quickAuth shared-auth
    // wait expired ~10s later: authEvent code=1, a user-perceived stall
    // (a manual retry after the window succeeded). The session teardown
    // must actively release the adopted mitrustservice conn (logi
    // disconnect, the official server→phone 52011 precedent) so the phone
    // drops the zombie immediately and the next unlock drives a fresh
    // adoption.
    func testTrustUnlockAfterSessionRebuildClearsZombieMitrustChannel() async throws {
        try await establishRelaySession()
        try await startMirrorEnds(locked: true, castOverLAN: true)
        let phone = try XCTUnwrap(self.phone)
        let firstSession = try XCTUnwrap(self.session)
        let controller = try XCTUnwrap(self.controller)
        // Pure-LAN adoption: the real phone's channel client dials the
        // advertised Mac UDP port directly, not a relay bridge pipe.
        phone.cast.mitrustChannelFactory = nil
        phone.cast.mitrustUnlockTimeout = 5
        firstSession.start()
        controller.start()

        try await waitFor("cast channel ready") { [weak firstSession] in
            firstSession?.isChannelReady == true
        }
        try await waitFor("lock mask from truthful locked status") { [weak controller] in
            controller?.mask == .locked
        }
        controller.unlockRequested()
        try await waitFor("first unlock completed") {
            phone.cast.mitrustUnlockCompleted
        }
        try await waitFor("phone mitrust channel client live") {
            phone.cast.mitrustChannelClientLive
        }

        // Session fail (idle auto-release → redial unanswered →
        // redial_timeout): the flow drops the dead session and builds a
        // fresh one. The dead session's teardown must actively release the
        // phone's mitrust channel client, or it stays a zombie.
        controller.sessionFactory("session_fail_rebuild")
        try await waitFor("fresh session rebuilt") { [weak self] in
            guard let session = self?.session else { return false }
            return session !== firstSession
        }
        try await waitFor("phone dropped the zombie mitrust channel client") {
            phone.cast.mitrustDisconnectCount == 1 && !phone.cast.mitrustChannelClientLive
        }
        try await waitFor("rebuilt cast channel ready") { [weak self] in
            self?.session?.isChannelReady == true
        }

        // The phone's screen timeout re-armed the keyguard in the gap; the
        // user re-opens the mirror window (fresh flow on the rebuilt
        // session) and unlocks again.
        phone.cast.setLocked(true)
        controller.stop()
        controller.start()
        try await waitFor("lock mask on rebuilt session") { [weak controller] in
            controller?.mask == .locked
        }
        controller.unlockRequested()
        try await waitFor("second unlock completed via fresh adoption") {
            phone.cast.mitrustUnlockCount == 2
        }
        XCTAssertEqual(
            phone.cast.mitrustUnlockTimedOutCount, 0,
            "no zombie-window kcp-timeout code=1 — teardown must release the phone's channel client"
        )
        try await waitFor("mask cleared after second unlock") { [weak controller] in
            controller?.mask == nil
        }
    }

    // authEvent code=1 (terminalAlt) is the phone's quickAuth shared-auth
    // TRANSPORT timeout (its 562 went into a dead-end mitrust channel), not
    // an unlock refusal — the cast channel itself is healthy, usually still
    // streaming. It must return to the retryable locked state, not the hard
    // .failed → connectFailed path.
    func testAuthEventTerminalAltReturnsToRetryableLocked() async throws {
        let trustManager = MacTrustManager()
        trustManager.sendFrame = { _ in }
        trustManager.start()
        var auth = TrustAuthStatus()
        auth.features = [DuoScreenTrustFeature.unlockDevice]
        auth.enableStatus = DuoScreenTrustEnableStatus.enabled.rawValue
        auth.bindStatus = DuoScreenTrustBindStatus.bound.rawValue
        var status = TrustStatusEvent()
        status.code = DuoScreenTrustCode.success
        status.localKeyguardStatus = DuoScreenKeyguardStatus.valid
        status.remoteKeyguardStatus = 1
        status.auth = auth
        trustManager.handleFrame(DuoScreenProtocolV1.encodeFrame(
            type: DuoScreenProtocolV1.typeTrust,
            payload: DuoScreenTrustProto.encode(DuoScreenTrust(sessionID: 0, msg: .statusEvent(status)))
        ))
        guard case .ready(locked: true) = trustManager.state else {
            XCTFail("expected ready(locked: true), got \(trustManager.state)")
            return
        }
        trustManager.touchIdPreauthorized = true
        await trustManager.requestUnlock()
        XCTAssertEqual(trustManager.state, .authenticating)

        let event = TrustAuthEvent(
            feature: DuoScreenTrustFeature.unlockDevice, code: DuoScreenTrustCode.terminalAlt
        )
        trustManager.handleFrame(DuoScreenProtocolV1.encodeFrame(
            type: DuoScreenProtocolV1.typeTrust,
            payload: DuoScreenTrustProto.encode(DuoScreenTrust(sessionID: 0, msg: .authEvent(event)))
        ))
        XCTAssertEqual(
            trustManager.state, .ready(locked: true),
            "code=1 is a transport timeout — the lock mask must stay retryable, not connectFailed"
        )
        XCTAssertFalse(trustManager.awaitingAuthEvent)
    }

    private func driveUnlockToStreaming() async throws {
        let phone = try XCTUnwrap(self.phone)
        let session = try XCTUnwrap(self.session)
        let controller = try XCTUnwrap(self.controller)
        session.start()
        controller.start()

        try await waitFor("cast channel ready over relay") { [weak session] in
            session?.isChannelReady == true
        }
        try await waitFor("lock mask from truthful locked status") {
            controller.mask == .locked
        }
        try await waitFor("OPEN sent even while locked (official)") {
            phone.cast.openMirrorScreenCount >= 1
        }

        controller.unlockRequested()

        try await waitFor("phone received duo.screen authAction (562) over relay") {
            phone.cast.authActionCount >= 1
        }
        try await waitFor("phone verified auth_token_A (562/563) over relay") {
            phone.cast.mitrustUnlockCompleted && phone.cast.lastAuthTokenA != nil
        }
        try await waitFor("mask cleared via confirmed unlock") {
            controller.mask == nil
        }
        try await waitFor("video datagrams flowing after unlock") {
            self.videoDatagramsReceived >= 3
        }
        try await waitFor("controller streaming") {
            controller.stage == .streaming && controller.mask == nil
        }
    }

    // Demux proof: the mitrust channel is dialed while the cast channel is
    // alive, and after the unlock completes the cast channel still carries
    // CLOSE_SCREEN — the p-stamped mitrust datagrams must not bleed into the
    // cast pipe (they fail cast transKey decryption and vanish silently).
    func testTrustUnlockOverCloudRelayKeepsCastChannelAlive() async throws {
        try await establishRelaySession()
        try await startMirrorEnds(locked: true)
        try await driveUnlockToStreaming()
        let phone = try XCTUnwrap(self.phone)
        let session = try XCTUnwrap(self.session)

        session.sendScreenAction(.closeScreen(sessionId: 1))

        try await waitFor("CLOSE_SCREEN still lands on the cast channel after unlock") {
            phone.cast.closeScreenCount == 1
        }
    }

    // Transport flip end-to-end: the relay session is torn down wholesale
    // (worker reconnect / WiFi→5G), then production invalidates everything
    // riding it (9ddc75ac0) and re-registers from scratch — fresh relay
    // handshake, fresh mesh/channel pipes, fresh cast dial. The full mirror
    // flow must come back without any state leaking from the old session.
    func testMirrorFlowRecoversAfterRelaySessionReplaced() async throws {
        try await establishRelaySession()
        try await startMirrorEnds(locked: false)
        try await driveMirrorFlowToStreaming()

        // Wholesale teardown of everything bound to the old relay session.
        hostLoop?.cancel()
        clientLoop?.cancel()
        hostLoop = nil
        clientLoop = nil
        controller?.stop()
        wfdClient?.stop(reason: "transport_flip")
        videoListener?.cancel()
        videoListener = nil
        videoConnection?.cancel()
        videoConnection = nil
        videoDatagramsReceived = 0
        session?.cancel()
        session = nil
        phone?.stop()
        phone = nil
        pair?.hostSide.close()
        pair?.clientSide.close()
        pair = nil
        hostBridge = nil
        clientBridge = nil
        phoneTunnel = nil
        tunnelManager = nil
        hostSession = nil
        clientSession = nil

        try await establishRelaySession()
        try await startMirrorEnds(locked: false)
        try await driveMirrorFlowToStreaming()
    }

    private func driveMirrorFlowToStreaming() async throws {
        let phone = try XCTUnwrap(self.phone)
        let session = try XCTUnwrap(self.session)
        let controller = try XCTUnwrap(self.controller)
        session.start()
        controller.start()

        try await waitFor("cast channel ready over relay") { [weak session] in
            session?.isChannelReady == true
        }
        try await waitFor("OPEN_MIRROR_SCREEN over relay") {
            phone.cast.openMirrorScreenCount >= 1
        }
        try await waitFor("WFD established over the TCP tunnel") {
            phone.cast.wfdSessionEstablished
        }
        try await waitFor("video datagrams flowing") {
            self.videoDatagramsReceived >= 3
        }
        try await waitFor("controller streaming, mask cleared") {
            controller.stage == .streaming && controller.mask == nil
        }
    }

    // MARK: - Limit tests: impaired cloud-relay link

    // Measured Mac(HiNet)↔Cloudflare SIN detour (docs/relay-analysis.md):
    // ~67ms RTT, order preserved. The full mirror control plane must
    // complete at production WAN latency, not just on a perfect loopback.
    func testMirrorFlowOverCloudRelayAtWANLatency() async throws {
        impairmentHostToClient = .hiNetCloudflareWANOrdered
        impairmentClientToHost = .hiNetCloudflareWANOrdered
        try await establishRelaySession()
        try await startMirrorEnds(locked: false)
        let phone = try XCTUnwrap(self.phone)
        let session = try XCTUnwrap(self.session)
        let controller = try XCTUnwrap(self.controller)
        session.start()
        controller.start()

        try await waitFor("cast channel ready over WAN relay") { [weak session] in
            session?.isChannelReady == true
        }
        try await waitFor("OPEN_MIRROR_SCREEN over WAN relay") {
            phone.cast.openMirrorScreenCount >= 1
        }
        try await waitFor("WFD established over the TCP tunnel") {
            phone.cast.wfdSessionEstablished
        }
        try await waitFor("video datagrams flowing") {
            self.videoDatagramsReceived >= 3
        }
        try await waitFor("controller streaming, mask cleared") {
            controller.stage == .streaming && controller.mask == nil
        }
    }

    // The production relay data channel is unordered: jitter makes consecutive
    // envelopes swap. If a mesh KCP segment arrives after a newer one, the
    // pipe's sn dedupe drops it and the missing chunk wedges frame reassembly
    // forever — the dial must still recover (session-level retry), not hang.
    func testMirrorFlowOverCloudRelayToleratesReordering() async throws {
        impairmentHostToClient = .hiNetCloudflareWAN
        impairmentClientToHost = .hiNetCloudflareWAN
        try await establishRelaySession()
        try await startMirrorEnds(locked: false)
        let phone = try XCTUnwrap(self.phone)
        let session = try XCTUnwrap(self.session)
        let controller = try XCTUnwrap(self.controller)
        session.start()
        controller.start()

        try await waitFor("cast channel ready despite reordering", timeout: 45) { [weak session] in
            session?.isChannelReady == true
        }
        try await waitFor("OPEN_MIRROR_SCREEN despite reordering", timeout: 45) {
            phone.cast.openMirrorScreenCount >= 1
        }
        try await waitFor("controller streaming despite reordering", timeout: 45) {
            controller.stage == .streaming && controller.mask == nil
        }
    }

    // Frame-loss limit probe. The production relay legs are TCP WebSockets
    // (lossless), so this documents the boundary: a lost relay frame drops a
    // KCP segment the mesh pipe never retransmits, so a dial caught in a
    // loss burst wedges permanently — the production recovery is the
    // watchdog + session rebuild (transport flips rebuild the relay session
    // anyway). Assert exactly that: the burst wedges the first dial, and the
    // rebuild path recovers the flow once the link has healed.
    func testMirrorFlowOverCloudRelayRecoversAfterBurstyLoss() async throws {
        impairmentHostToClient = .hiNetCloudflareWANOrdered
        impairmentClientToHost = .hiNetCloudflareWANOrdered
        try await establishRelaySession()
        try await startMirrorEnds(locked: false)
        let phone = try XCTUnwrap(self.phone)
        let session = try XCTUnwrap(self.session)
        let controller = try XCTUnwrap(self.controller)

        // Burst: 25% loss on both legs for the first 2.5s of the dial.
        let pair = try XCTUnwrap(impairedPair)
        pair.hostSide.updateProfile { $0.loss = 0.25 }
        pair.clientSide.updateProfile { $0.loss = 0.25 }

        session.start()
        controller.start()

        try await Task.sleep(nanoseconds: 2_500_000_000)
        pair.hostSide.updateProfile { $0.loss = 0 }
        pair.clientSide.updateProfile { $0.loss = 0 }
        XCTAssertGreaterThan(pair.hostSide.stats.dropped + pair.clientSide.stats.dropped, 0,
                             "test must actually drop frames")

        // Give the first dial a chance to prove the wedge, then drive the
        // production recovery: rebuild the session on the healed link.
        try await Task.sleep(nanoseconds: 3_000_000_000)
        controller.sessionFactory("loss_burst_rebuild")

        try await waitFor("cast channel ready after rebuild on healed link", timeout: 60) { [weak self] in
            self?.session?.isChannelReady == true
        }
        try await waitFor("OPEN_MIRROR_SCREEN after rebuild", timeout: 60) {
            phone.cast.openMirrorScreenCount >= 1
        }
        try await waitFor("controller streaming after rebuild", timeout: 60) {
            controller.stage == .streaming && controller.mask == nil
        }
    }

    // WiFi→5G transport flip (live 2026-08-09 root cause): the relay path
    // drops every datagram for seconds while the phone re-registers. The
    // session must survive the blackout without crashing or wedging, and the
    // control plane must answer again once the link heals.
    func testMirrorFlowOverCloudRelaySurvivesTransportFlipBlackout() async throws {
        // Perfect baseline link; the blackout is the only impairment.
        impairmentHostToClient = .perfect
        impairmentClientToHost = .perfect
        try await establishRelaySession()
        try await startMirrorEnds(locked: false)
        let phone = try XCTUnwrap(self.phone)
        let session = try XCTUnwrap(self.session)
        let controller = try XCTUnwrap(self.controller)
        session.start()
        controller.start()

        try await waitFor("streaming before the flip") {
            controller.stage == .streaming && controller.mask == nil
        }

        let pair = try XCTUnwrap(impairedPair)
        pair.hostSide.blackout(for: 3)
        pair.clientSide.blackout(for: 3)

        // During the blackout a user stop must not crash or deadlock the
        // session; the CLOSE is simply lost.
        session.sendScreenAction(.closeScreen(sessionId: 99))
        try await Task.sleep(nanoseconds: 3_500_000_000)

        // Link healed: the channel must still round-trip. Re-drive a status
        // query by re-arming the flow's trust manager.
        try await waitFor("channel still ready after blackout") { [weak session] in
            session?.isChannelReady == true
        }
        session.sendScreenAction(.openMirrorScreen(sessionId: 100))
        try await waitFor("phone answers again after blackout") {
            phone.cast.openMirrorScreenCount >= 2
        }
    }

    // Retired flows were resurrected by late duplicate datagrams on 5G
    // (fa6d2b5b8): the pipes must dedupe by KCP sn, so heavy duplication
    // must not corrupt the control plane or double-fire OPEN handling.
    func testMirrorFlowOverCloudRelayWithDuplicates() async throws {
        impairmentHostToClient = .hiNetCloudflareWAN
        var dup = RelayImpairmentProfile.hiNetCloudflareWAN
        dup.duplicate = 0.2
        impairmentClientToHost = dup
        try await establishRelaySession()
        try await startMirrorEnds(locked: false)
        let phone = try XCTUnwrap(self.phone)
        let session = try XCTUnwrap(self.session)
        let controller = try XCTUnwrap(self.controller)
        session.start()
        controller.start()

        try await waitFor("streaming with 20% duplicated datagrams", timeout: 40) {
            controller.stage == .streaming && controller.mask == nil
        }
        XCTAssertEqual(phone.cast.openMirrorScreenCount, 1, "duplicate OPENs must be deduped by the phone's flow guard")
        let stats = impairedPair?.clientSide.stats
        XCTAssertGreaterThan(stats?.duplicated ?? 0, 0, "test must actually inject duplicates")
    }
}

// MARK: - Tunnel envelope routing helper

enum TunnelBridgeEnvelopes {
    static func isTunnelType(_ type: String) -> Bool {
        switch type {
        case EnvelopeType.tunnelOpen,
             EnvelopeType.tunnelOpenResult,
             EnvelopeType.tunnelData,
             EnvelopeType.tunnelClose,
             EnvelopeType.tunnelError,
             EnvelopeType.tunnelFlow:
            return true
        default:
            return false
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
