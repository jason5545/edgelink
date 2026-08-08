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
    private var hostLoop: Task<Void, Error>?
    private var clientLoop: Task<Void, Error>?
    private var savedIsExpectedPhoneHost: ((String) -> Bool)?

    // Unique port block per test (the WFD TCP listener and the video UDP
    // listener bind real sockets; the previous test's release is async).
    private static var portBlockIndex: UInt16 = 0
    private var wfdPort: UInt16!
    private var clientVideoPort: UInt16!
    private var phoneMeshPort: UInt16 = 0

    override func setUp() {
        super.setUp()
        Self.portBlockIndex += 1
        let base = 29_301 + Self.portBlockIndex * 10
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
        phone?.stop()
        pair?.hostSide.close()
        pair?.clientSide.close()
        pair = nil
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
        super.tearDown()
    }

    // MARK: - Relay session pair (the cloud relay stand-in)

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
        try await (hostAccept, clientConnect)

        hostLoop = Task { try await hostSession.receiveLoop() }
        clientLoop = Task { try await clientSession.receiveLoop() }
    }

    // Wires the fake phone (client end) and the production mirror classes
    // (host end) onto the established relay session. `ackFramedResponses`
    // reproduces the real phone's mesh service behavior seen on the cloud
    // relay: responses leave as ack-command datagrams carrying the payload
    // (0x52 + data) instead of pushes.
    private func startMirrorEnds(locked: Bool, ackFramedResponses: Bool = false) async throws {
        let clientBridge = try XCTUnwrap(clientBridge)
        let hostBridge = try XCTUnwrap(hostBridge)

        // Production wiring: the cast trust dial rides mesh flow 1 (the
        // announce/relayCall dial owns flow 0) so the phone sees a fresh peer
        // for its phys sync, like a brand-new LAN UDP socket.
        if ackFramedResponses {
            clientBridge.meshFlow(index: 1).dataCommand = LyraMeshDatagram.commandAck
            clientBridge.channel.dataCommand = LyraMeshDatagram.commandAck
        }
        let phone = LyraPhoneServer(
            identity: LyraPhoneIdentity.generate(),
            castChannelPort: 0,
            wfdPort: wfdPort,
            meshTransport: clientBridge.meshFlow(index: 1),
            castChannelTransport: clientBridge.channel,
            clientVideoPort: clientVideoPort
        )
        phone.cast.setLocked(locked)
        // Live-phone behavior: the WFD RTSP listener comes up asynchronously
        // after the phone processes OPEN_MIRROR_SCREEN, so the tunnel's first
        // dial lands before it listens. The phone-side dial must retry
        // (connection-refused) or the relay mirror deadlocks here.
        phone.cast.wfdServerStartupDelay = 1.5
        self.phone = phone
        try phone.start(port: 0)
        phoneMeshPort = try XCTUnwrap(phone.boundPort)

        // The mesh pipe presents the peer endpoint to the trust session;
        // point it at the phone's mesh port before dialing.
        hostBridge.meshFlow(index: 1).peerPort = phoneMeshPort

        let trustManager = MacTrustManager()
        trustManager.statusRetryDelay = 0.1
        trustManager.maxStatusRetries = 3
        self.trustManager = trustManager
        attachSession()

        let controller = XiaomiMirrorFlowController(trustManager: trustManager)
        controller.sessionProvider = { [weak self] in self?.session }
        controller.sessionFactory = { [weak self] _ in
            self?.session?.cancel()
            self?.session = nil
            self?.attachSession()
            self?.session?.start()
        }
        controller.biometricEvaluate = {}
        controller.openMirrorScreen = { [weak self] session in
            guard let self else { return }
            let sessionId = UInt64(Date().timeIntervalSince1970 * 1000)
            session.sendScreenAction(.openMirrorScreen(sessionId: sessionId))
            self.startWFDClientViaTunnel()
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
            channelTransport: hostBridge.channel
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
            }
        }
        self.session = session
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
