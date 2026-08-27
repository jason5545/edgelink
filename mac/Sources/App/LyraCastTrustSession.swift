import CryptoKit
import EdgeLinkKit
import Foundation
import Network

final class LyraCastTrustSession {
    static weak var activeTrustSession: LyraCastTrustSession?

    // Wiring hooks so the session stays free of responder/UI dependencies
    // (assigned by the app at startup; defaults keep it unit-testable).
    static var parseEndpoint: (String) -> (host: String, port: UInt16)? = { description in
        guard let separator = description.lastIndex(of: ":") else { return nil }
        let host = String(description[description.startIndex..<separator])
        guard let port = UInt16(description[description.index(after: separator)...]), !host.isEmpty else {
            return nil
        }
        return (host, port)
    }
    static var isExpectedPhoneHost: (String) -> Bool = { _ in true }
    static var recordPhoneEndpoint: (String) -> Void = { _ in }
    // Runtime wiring (EdgeLinkRuntime): the current cloud-relay transport
    // bridge, nil on pure LAN. Consulted when a phone-dialed mitrustservice
    // conn was adopted from a relay-fed phys conn (the announcer's) while
    // THIS session is LAN-routed — the phone's channel client dials through
    // its relay bridge in that case, so the mitrust server channel must
    // listen on the Mac bridge, not on an unreachable LAN UDP port.
    static var activeRelayBridge: () -> LyraRelayTransportBridge? = { nil }
    static var onPasskeyCompare: ((String) -> Void)?
    static let officialMacSyncInfoSignature = Data([
        0x33, 0x85, 0xFB, 0xAA, 0x02, 0xFD, 0x4E, 0x2C, 0xE1, 0x95, 0x74, 0x3A,
        0xA8, 0xDD, 0x50, 0xDB, 0xC6, 0xB7, 0xA4, 0xEC, 0x36, 0x6F, 0x0B, 0xAA,
        0x98, 0xA7, 0x6C, 0xDA, 0x11, 0x7F, 0x94, 0x25, 0x9B, 0xD8, 0x32, 0xCE,
        0xB6, 0x73, 0x80, 0xB1, 0x3D, 0xFF, 0x13, 0x9A, 0xBE, 0x94, 0x55, 0x22,
        0x44, 0x88, 0xD4, 0x12, 0x70, 0x94, 0x1A, 0xB3, 0x3F, 0x9D, 0xCF, 0x5C,
        0x6D, 0xBA, 0xEF, 0x7A, 0x30, 0xB8, 0x8F, 0x28, 0x26, 0x16, 0x0E, 0xB4,
        0x61, 0xFA, 0x06, 0xB3, 0xB2, 0xB9, 0x4A, 0xB9, 0x6F, 0x8C, 0x7E, 0x9F,
        0x6A, 0x98, 0x05, 0x17, 0xF2, 0xA6, 0xE3, 0x3C, 0x8F, 0xE3, 0xE4, 0xC8,
        0xE2, 0x92, 0xF7, 0xB0, 0x02, 0x5D, 0x4A, 0x89, 0x37, 0xC3, 0x63, 0x9A,
        0xB9, 0xA6, 0xB1, 0x42, 0x7C, 0xC1, 0xFC, 0x65, 0xD3, 0xB2, 0x9C, 0x2F,
        0x3D, 0x5A, 0x76, 0xF6, 0xBC, 0xF0, 0x90, 0x20, 0x59, 0x1E, 0x47, 0xC5,
        0xDF, 0x82, 0xED, 0xC3, 0x9C, 0x9A, 0xBE, 0x30, 0xA1, 0x71, 0x60, 0x64
    ])

    enum Stage: Equatable {
        case physSync
        case cookie
        case syncAuth
        case upgrade
        case logiConnRequest
        case channelWait
        case channelNegotiate
        case ready
        case failed(String)
    }

    let trustManager: MacTrustManager

    var onStatus: ((String) -> Void)?
    var onFinish: (() -> Void)?

    private let queue = DispatchQueue(label: "edgelink.lyra.cast", qos: .userInitiated)
    // Test seam: the session mesh socket's bound port (nil until started).
    var meshSocketBoundPort: UInt16? { socket.boundPort }
    private var endpoints: [(host: String, port: UInt16)]
    private var host: String
    private var port: UInt16
    private let deviceIdHex: String
    private let displayName: String

    // Relay-transport harness: the mesh dial and the cast channel ride these
    // pipes (cloud-relay path) instead of local UDP sockets when set.
    private let socket: LyraMeshDatagramPipe
    private let channelTransport: LyraChannelDatagramPipe?
    // True when the dial rides relay pipes instead of a local UDP socket; a
    // relay bridge reconfigure leaves such a session's pipes dangling even
    // though isChannelReady stays true.
    var isRelayRouted: Bool { !(socket is LyraMeshSocket) }
    private var stage: Stage = .physSync
    private var lastProgress = Date()
    var lastInboundAt: Date { lastProgress }
    private var watchdog: DispatchSourceTimer?
    private var cancelled = false

    private var peerNetId: UInt32 = 0
    private var logiConnId: UInt32 = 0
    private var ourCookie: UInt64 = 0

    private var syncAuthPrivateKey: Curve25519.KeyAgreement.PrivateKey?
    private var syncAuthOurConnId = Data()
    private var syncKeyCandidates: [SymmetricKey] = []

    private var keyAgreementKey: P256.KeyAgreement.PrivateKey?
    private var authClientRandom = Data()
    private var authServerRandom = Data()
    private var channelKeyCS: SymmetricKey?
    private var channelKeySC: SymmetricKey?
    private var upgradeHandshakeId: UInt64 = 0

    private var channelId: UInt32 = 0
    private var serverChannelId: UInt32 = 0
    private var transKey = Data()
    private var transRandom = Data()

    private var channelSocket: LyraChannelDatagramPipe?
    private var channelReady = false
    var isChannelReady: Bool { channelReady }
    // Sticky: the channel negotiated at least once on this session. The
    // mirror flow's beginStart redials only a RELEASED channel — a fresh
    // mid-dial session must not get a redial (it aborts the in-flight
    // negotiation and strands the OPEN on a stale channelId).
    private(set) var channelWasEstablishedBefore = false
    var onChannelReady: (() -> Void)?
    var onChannelReleased: (() -> Void)?
    // When true, the phys/logi conn is kept alive after auth completes so a
    // follow-up mirror startShare finds the cast channel in place (the
    // phone-side stock share flow no-ops without it).
    var retainPhysAfterAuth = false
    // Channel-only sessions (mirror start) skip the duo.screen status query
    // so the mirror window never shows an unlock overlay when the phone is
    // already unlocked. The unlock flow re-enables it on the same session.
    var duoScreenStatusEnabled = true
    // Non-DuoScreen channel frames (capabilities, simple events, screen
    // actions) observed on the cast channel, delivered on the main queue as
    // (messageType, payload) after MessageCodec deframing.
    var onCastMessage: ((UInt8, Data) -> Void)?

    // Mirror-call relay (native DistAudio call uplink via the phone's own
    // MirrorCallService): created when the cast channel negotiates, fed the
    // simpleEvent frames, driven by call state from the relayCall URI flow.
    private(set) var mirrorCallRelay: LyraMirrorCallRelaySession?

    // The relayCall URI handler reports call state here (active = the
    // phone's MirrorCallService sinks our audio source for the call uplink).
    func notifyMirrorCallActive(_ active: Bool) {
        mirrorCallRelay?.setCallActive(active)
    }

    private var srvConnId: UInt32 = 0
    private var srvPeerNetId: UInt32 = 0
    private var srvSignKey: Curve25519.KeyAgreement.PrivateKey?
    private var srvOurConnId = Data()
    private var srvKeyCandidates: [SymmetricKey] = []
    private var srvKeyAgreementKey: P256.KeyAgreement.PrivateKey?
    private var srvClientRandom = Data()
    private var srvServerRandom = Data()
    private var srvKeyCS: SymmetricKey?
    private var srvKeySC: SymmetricKey?
    private var srvChannelSocket: LyraChannelDatagramPipe?
    // The relay bridge this session rides (nil on LAN) and the bridge port of
    // the mitrust server pipe, so teardown can unregister it.
    private let relayBridge: LyraRelayTransportBridge?
    private var srvChannelBridgePort: UInt16?
    // The bridge that actually owns the mitrust server pipe: this session's
    // own relayBridge when relay-routed, or the runtime's current bridge
    // when the adoption arrived on a relay-fed phys conn while the session
    // itself is LAN-routed (mitrustAdoptedViaRelay). Teardown must
    // unregister from the owning bridge, not the session's.
    private var srvChannelBridge: LyraRelayTransportBridge?
    private var srvReuseKey: SymmetricKey?
    private var srvChannelId: UInt32 = 0
    private var srvTransKey = Data()
    private var mitrustAuth: MiTrustAuthService?
    private var mitAuthClientRandom = Data()
    private var mitAuthServerRandom = Data()
    private var mitAuthSharedZ = Data()
    private var mitAuthServerEphPriv: P256.KeyAgreement.PrivateKey?
    private var mitAuthClientEphPub = Data()
    private var mitrustActivityAt = Date.distantPast
    private var mitrustPeerPortChannelId: UInt64 = 0
    private var mitrustPeerPort: UInt16?
    private var mitrustPeerPortResponseSent = false
    // When the peer-port request arrived embedded in the quick-conn logi
    // request, the phone's LogiConnClientHandler is not yet connected and
    // silently drops payloads ("DoLogiConnPayloadReceived: not connected").
    // Defer the response until the phone's response_ack (post-kConnected).
    private var mitrustPeerPortAwaitingAck = false
    private var passkeyPair: LyraPasskeyPairServer?
    // The phone's reverse sync task (service 00150323) reuses whichever phys
    // conn is up — with a mirror session live that is this session's socket.
    // Serve its classic logi dial here so the task stops timing out and our
    // reply (tdi.f15 cert cred) reaches the phone's cred-check path.
    private let syncTaskServer = LyraSyncTaskServer()
    // Set when the phone dialed our published mesh port directly (PIN-bind /
    // pairing flow) and the responder handed the mitrustservice conn to us.
    // Outbound frames then ride the responder's socket so the source port
    // matches the phys conn the phone established.
    private var adoptedSend: ((LyraMeshPack.Frame) -> Void)?
    // Whether the adopted mitrustservice conn rides a relay-fed phys conn
    // (the relay announcer's virtual pipe). The phone's channel client dials
    // through the same transport the adoption arrived on, so the mitrust
    // server channel must listen on the relay bridge when this is true —
    // even when the session itself is LAN-routed (live 2026-08-13: a LAN
    // session advertised a LAN UDP port on a relay-fed adoption, the phone's
    // dial crossed the relay and hit no pipe, and the 562 kcp-timed-out into
    // authEvent code=1).
    private var mitrustAdoptedViaRelay = false
    var onPairingPasskey: ((String) -> Void)?
    var onPairingCompareCode: ((String) -> Void)?
    var onPairingCompleted: (() -> Void)?

    private static let serviceName = "com.xiaomi.mirror:cast"
    private static let servicePackage = "com.xiaomi.mirror"
    private static let authTicketSalt = Data([
        0x0a, 0x5b, 0x87, 0x72, 0x08, 0xd4, 0xa1, 0xcf,
        0x76, 0xd3, 0x08, 0x09, 0x51, 0xdd, 0x1b, 0xb8,
        0x6b, 0x4e, 0x9e, 0xe2, 0x57, 0x92, 0x4b, 0xaf,
        0xdb, 0xa6, 0x2c, 0x5a, 0x67, 0x06, 0xe6, 0x18
    ])

    init(
        endpoints: [(host: String, port: UInt16)],
        deviceIdHex: String,
        displayName: String,
        trustManager: MacTrustManager,
        meshTransport: LyraMeshDatagramPipe? = nil,
        channelTransport: LyraChannelDatagramPipe? = nil,
        relayBridge: LyraRelayTransportBridge? = nil
    ) {
        self.endpoints = endpoints
        self.host = endpoints.first?.host ?? ""
        self.port = endpoints.first?.port ?? 0
        self.deviceIdHex = deviceIdHex
        self.displayName = displayName
        self.trustManager = trustManager
        self.socket = meshTransport ?? LyraMeshSocket()
        self.channelTransport = channelTransport
        self.relayBridge = relayBridge
        syncTaskServer.syncPayloadProvider = {
            LyraSyncReply.payload(deviceIdHex: deviceIdHex, displayName: displayName)
        }
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.socket.onFrame = { [weak self] frame, endpoint, reply in
                self?.handle(frame: frame, endpoint: endpoint, reply: reply)
            }
            self.socket.onRawDatagram = { content, endpoint in
                DiagnosticsLog.info(
                    "xiaomi.cast.trust_raw_rx bytes=\(content.count) from=\(endpoint.debugDescription) " +
                        "head=\(content.prefix(16).map { String(format: "%02x", $0) }.joined())"
                )
            }
            do {
                try self.socket.start(preferredPort: nil)
            } catch {
                self.fail(String(localized: "mesh socket 啟動失敗"))
                return
            }
            LyraCastTrustSession.activeTrustSession = self
            self.startWatchdog()
            self.sendPhysSyncRequest()
        }
    }

    func cancel() {
        queue.async { [weak self] in
            self?.finishLocked()
        }
    }

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self, !self.cancelled else { return }
            if self.stage != .ready, Date().timeIntervalSince(self.lastProgress) > 30 {
                self.fail(String(localized: "逾時（stage=\(self.stage)）"))
            }
        }
        watchdog = timer
        timer.resume()
    }

    private func progress(_ newStage: Stage, _ message: String) {
        lastProgress = Date()
        stage = newStage
        DiagnosticsLog.info("xiaomi.cast.trust_stage stage=\(newStage) \(message)")
        onStatus?(message)
    }

    private func fail(_ message: String) {
        DiagnosticsLog.warn("xiaomi.cast.trust_failed stage=\(stage) reason=\(message)")
        stage = .failed(message)
        onStatus?(String(localized: "連線失敗：\(message)"))
        finishLocked()
    }

    // Stops the mitrust server channel and unregisters its bridge pipe (when
    // the session is relay-routed) so late datagrams for the stale port fall
    // back to the cast pipe instead of a dead pipe.
    private func teardownServerChannelLocked() {
        srvChannelSocket?.stop()
        srvChannelSocket = nil
        if let port = srvChannelBridgePort {
            srvChannelBridge?.removeChannelPipe(port: port)
            srvChannelBridgePort = nil
            srvChannelBridge = nil
        }
    }

    // Actively releases the phone-dialed mitrustservice conn before our
    // socket dies. Without this the phone's mitrust channel client only
    // learns the conn is dead from the phys heartbeat (~17-20s); a 562
    // landing in that zombie window goes nowhere and the phone's quickAuth
    // shared-auth wait expires ~10s later → authEvent code=1, a
    // user-perceived stall (live 2026-08-13 05:53: cast-channel idle
    // auto-release → redial_timeout → session fail left the phone's mitrust
    // channel a zombie; the manual retry after the window succeeded). The
    // official server→phone disconnect precedent is the 52011 release
    // phones send us. With the conn released the phone tears its channel
    // client down NOW and the next 562 drives a fresh adoption.
    //
    // Returns true when a disconnect was sent: NWConnection.send is
    // asynchronous, so cancel()ing the socket in the same queue turn would
    // drop the queued datagram — the caller must then give the socket a
    // short flush beat before stopping it.
    @discardableResult
    private func sendMitrustDisconnectLocked() -> Bool {
        guard srvConnId != 0 else { return false }
        var payload = Data()
        LyraProtoWriter.appendVarintField(1, value: 52011, to: &payload)
        let inner = LogiConnInnerFrame(frameType: 4, payload: .disconnect(payload))
        let logiConn = LogiConnFrame(
            logiConnId: srvConnId, localNetId: 1, remoteNetId: srvPeerNetId,
            inner: inner.serialized()
        )
        let miFrame = MiConnectFrame(version: 0, logiConnFrames: [logiConn])
        send(frame: LyraMeshPack.Frame(packType: 2, payload: miFrame.serialized()), label: "mitrust_disconnect")
        srvConnId = 0
        return true
    }

    private func finishLocked() {
        cancelled = true
        if LyraCastTrustSession.activeTrustSession === self {
            LyraCastTrustSession.activeTrustSession = nil
        }
        watchdog?.cancel()
        watchdog = nil
        channelSocket?.stop()
        channelSocket = nil
        mirrorCallRelay?.teardown()
        mirrorCallRelay = nil
        teardownServerChannelLocked()
        if sendMitrustDisconnectLocked() {
            // Flush beat before the socket dies (see above). onFinish rides
            // the delayed stop: rebuilds keyed on onFinish replace this
            // session's (possibly shared relay) pipes, and a stop landing
            // after them would kill the fresh dial.
            queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self else { return }
                self.socket.stop()
                self.onFinish?()
            }
        } else {
            socket.stop()
            onFinish?()
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // A newer session may already have taken over the shared trust
            // manager by the time this deferred stop runs — resetting it
            // then clobbers the fresh session's in-flight status query
            // (live 2026-08-13: a relay flap killed the session mid-auth;
            // this stop landed after the rebuilt session's start() and
            // silenced it for ~70s).
            guard LyraCastTrustSession.activeTrustSession == nil else { return }
            self.trustManager.stop()
        }
    }

    private func teardownPhysAfterAuth() {
        guard !cancelled else { return }
        if retainPhysAfterAuth || Date().timeIntervalSince(mitrustActivityAt) < 45 {
            queue.asyncAfter(deadline: .now() + 15) { [weak self] in
                self?.teardownPhysAfterAuth()
            }
            return
        }
        DiagnosticsLog.info("xiaomi.cast.trust_teardown_after_auth")
        cancelled = true
        watchdog?.cancel()
        watchdog = nil
        channelSocket?.stop()
        channelSocket = nil
        mirrorCallRelay?.teardown()
        mirrorCallRelay = nil
        teardownServerChannelLocked()
        if sendMitrustDisconnectLocked() {
            // Flush beat before the socket dies (see sendMitrustDisconnectLocked).
            queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.socket.stop()
            }
        } else {
            socket.stop()
        }
    }

    private func send(frame: LyraMeshPack.Frame, label: String) {
        if let adoptedSend {
            adoptedSend(frame)
            DiagnosticsLog.info("xiaomi.cast.trust_tx label=\(label) to=adopted:\(self.host):\(self.port)")
            return
        }
        do {
            try socket.send(frame: frame, to: host, port: port)
            DiagnosticsLog.info("xiaomi.cast.trust_tx label=\(label) to=\(self.host):\(self.port)")
        } catch {
            DiagnosticsLog.error("xiaomi.cast.trust_tx_failed label=\(label)", error)
        }
    }

    // Coarse cross-queue gate (same convention as handlesAdoptedMitrust):
    // true while a phone-dialed mitrustservice conn is adopted and its
    // channel may still be open. The responder suppresses its plaintext
    // netId=1 announce during this window — the phone assigns netIds
    // sequentially from 1, so a live conn can own netId 1, and plaintext
    // payload-v2 frames landing on it are misparsed as channel commands
    // (52013 "channel invalid id" spam, e.g. f1 decoded as "Book" from our
    // device name).
    func mitrustConnActive() -> Bool {
        srvConnId != 0 && (srvChannelSocket != nil || Date().timeIntervalSince(mitrustActivityAt) < 120)
    }

    // Called by LyraMeshResponder when the phone opens a mitrustservice logi
    // conn on the published mesh port (phone-initiated bind/pair flow), or by
    // LyraMeshAnnouncer when it reuses the announcer's phys conn. viaRelay
    // tells us the adopting socket's transport: the phone's channel client
    // dials back over the same transport, which decides where the mitrust
    // server channel must listen.
    func adoptMitrustSyncInfo(
        syncInfoData: Data,
        logiConn: LogiConnFrame,
        endpoint: NWEndpoint,
        viaRelay: Bool = false,
        send: @escaping (LyraMeshPack.Frame) -> Void
    ) {
        queue.async { [weak self] in
            guard let self, !self.cancelled else { return }
            if let parsed = Self.parseEndpoint(endpoint.debugDescription) {
                self.host = parsed.host
                self.port = parsed.port
                self.endpoints = [parsed]
            }
            self.adoptedSend = send
            self.mitrustAdoptedViaRelay = viaRelay
            if self.stage == .physSync {
                self.progress(.syncAuth, String(localized: "手機信任服務連線…"))
            }
            self.handleMitrustSyncInfo(syncInfoData, logiConn: logiConn)
        }
    }

    // Called on the responder's queue. Returns true (and forwards) when the
    // frame belongs to the adopted mitrustservice conn.
    func handlesAdoptedMitrust(frame: LyraMeshPack.Frame, endpoint: NWEndpoint) -> Bool {
        guard adoptedSend != nil, srvConnId != 0,
              let parsed = Self.parseEndpoint(endpoint.debugDescription),
              parsed.host == host
        else { return false }
        switch frame.packType {
        case 5, 4:
            break
        case 2:
            guard let miFrame = MiConnectFrame(parsing: frame.payload),
                  miFrame.logiConnFrames.contains(where: { $0.logiConnId == srvConnId })
            else { return false }
        default:
            return false
        }
        queue.async { [weak self] in
            self?.handle(frame: frame, endpoint: endpoint, reply: { _ in })
        }
        return true
    }

    private func sendPhysSyncRequest(attempt: Int = 0) {
        if attempt == 0 {
            progress(.physSync, String(localized: "連接手機…"))
        }
        guard attempt < 8, stage == .physSync, !cancelled, !endpoints.isEmpty else { return }
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let deviceInfo = LyraDeviceInfo(
            deviceId: deviceIdHex,
            deviceType: 14,
            uidHash: "61F2",
            displayName: displayName,
            osVersion: "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)",
            connMediumTypes: 0x40182,
            romVersion: "5.1.208.10.fullCnRelease.0512164"
        )
        var request = Data()
        LyraProtoWriter.appendVarintField(
            1, value: UInt64(Date().timeIntervalSince1970 * 1000), to: &request
        )
        LyraProtoWriter.appendLengthDelimitedField(2, value: deviceInfo.serialized(), to: &request)
        let physConn = PhysConnFrame(
            field1: .random(in: 1...UInt32.max),
            field2: 1,
            payload: .syncDeviceInfoRequest(request)
        )
        let miFrame = MiConnectFrame(version: 0, logiConnFrames: [], physConnFrame: physConn)
        let frame = LyraMeshPack.Frame(packType: 1, payload: miFrame.serialized())
        for target in endpoints {
            host = target.host
            port = target.port
            send(frame: frame, label: "phys_sync")
        }
        if let first = endpoints.first {
            host = first.host
            port = first.port
        }
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.sendPhysSyncRequest(attempt: attempt + 1)
        }
    }

    // Sends a phys keep-alive request; the phone answers within a second or
    // two when the conn is alive. Used by the supervisor to distinguish a
    // legitimately quiet channel from a dead one before rebuilding.
    func probeLiveness() {
        queue.async { [weak self] in
            guard let self, !self.cancelled else { return }
            var cookieData = Data()
            LyraProtoWriter.appendVarintField(1, value: UInt64(Self.tickNow()), to: &cookieData)
            LyraProtoWriter.appendVarintField(2, value: 1, to: &cookieData)
            let physConn = PhysConnFrame(field2: 4, payload: .keepAliveRequest(cookieData))
            let miFrame = MiConnectFrame(version: 0, logiConnFrames: [], physConnFrame: physConn)
            self.send(frame: LyraMeshPack.Frame(packType: 1, payload: miFrame.serialized()), label: "liveness_probe")
        }
    }

    private static func tickNow() -> UInt32 {
        UInt32(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }

    private func sendCookie(phase: UInt64) {
        if ourCookie == 0 {
            ourCookie = UInt64.random(in: 1...UInt64(UInt32.max))
        }
        var cookieData = Data()
        LyraProtoWriter.appendVarintField(1, value: ourCookie, to: &cookieData)
        LyraProtoWriter.appendVarintField(2, value: phase, to: &cookieData)
        let physConn = PhysConnFrame(field2: 4, payload: .keepAliveRequest(cookieData))
        let miFrame = MiConnectFrame(version: 0, logiConnFrames: [], physConnFrame: physConn)
        send(frame: LyraMeshPack.Frame(packType: 1, payload: miFrame.serialized()), label: "cookie_p\(phase)")
    }

    private func sendSyncAuthHello() {
        progress(.syncAuth, String(localized: "同步認證…"))
        logiConnId = .random(in: 1...UInt32.max)
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        syncAuthPrivateKey = privateKey
        var connId = Data()
        for _ in 0..<8 {
            connId.append(UInt8.random(in: 0...255))
        }
        syncAuthOurConnId = connId
        var cred = Data()
        LyraProtoWriter.appendLengthDelimitedField(1, value: connId, to: &cred)
        LyraProtoWriter.appendLengthDelimitedField(2, value: privateKey.publicKey.rawRepresentation, to: &cred)
        var syncInfo = Data()
        LyraProtoWriter.appendVarintField(1, value: 15000, to: &syncInfo)
        LyraProtoWriter.appendVarintField(2, value: 48, to: &syncInfo)
        LyraProtoWriter.appendVarintField(3, value: 1, to: &syncInfo)
        LyraProtoWriter.appendLengthDelimitedField(4, value: Data(Self.serviceName.utf8), to: &syncInfo)
        LyraProtoWriter.appendLengthDelimitedField(5, value: cred, to: &syncInfo)
        LyraProtoWriter.appendLengthDelimitedField(
            6, value: Self.officialMacSyncInfoSignature, to: &syncInfo
        )
        let inner = LogiConnInnerFrame(frameType: 5, payload: .syncInfo(syncInfo))
        let logiConn = LogiConnFrame(logiConnId: logiConnId, localNetId: 1, remoteNetId: peerNetId, inner: inner.serialized())
        let miFrame = MiConnectFrame(version: 0, logiConnFrames: [logiConn])
        send(frame: LyraMeshPack.Frame(packType: 2, payload: miFrame.serialized()), label: "sync_auth_hello")
    }

    private func sendUpgrade() {
        progress(.upgrade, String(localized: "建立加密通道…"))
        let privateKey = P256.KeyAgreement.PrivateKey()
        keyAgreementKey = privateKey
        var clientRandom = Data(count: 32)
        clientRandom.withUnsafeMutableBytes { buffer in
            if let baseAddress = buffer.baseAddress {
                arc4random_buf(baseAddress, 32)
            }
        }
        authClientRandom = clientRandom
        upgradeHandshakeId = UInt64.random(in: 1...UInt64(UInt32.max))

        var publicKeyMessage = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &publicKeyMessage)
        LyraProtoWriter.appendLengthDelimitedField(2, value: privateKey.publicKey.x963Representation, to: &publicKeyMessage)

        var cipherSuite = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &cipherSuite)
        LyraProtoWriter.appendLengthDelimitedField(2, value: clientRandom, to: &cipherSuite)
        LyraProtoWriter.appendVarintField(3, value: 32, to: &cipherSuite)
        LyraProtoWriter.appendVarintField(4, value: 2, to: &cipherSuite)
        LyraProtoWriter.appendLengthDelimitedField(5, value: publicKeyMessage, to: &cipherSuite)

        var clientNotify = Data()
        LyraProtoWriter.appendLengthDelimitedField(1, value: cipherSuite, to: &clientNotify)

        var pairFrame = Data()
        LyraProtoWriter.appendLengthDelimitedField(2, value: clientNotify, to: &pairFrame)

        var handshakeFrame = Data()
        LyraProtoWriter.appendVarintField(1, value: 5, to: &handshakeFrame)
        LyraProtoWriter.appendVarintField(2, value: 6, to: &handshakeFrame)
        LyraProtoWriter.appendLengthDelimitedField(8, value: pairFrame, to: &handshakeFrame)

        var authFrame = Data()
        LyraProtoWriter.appendVarintField(1, value: upgradeHandshakeId, to: &authFrame)
        LyraProtoWriter.appendLengthDelimitedField(2, value: handshakeFrame, to: &authFrame)

        let inner = LogiConnInnerFrame(frameType: 6, payload: .upgrade(authFrame))
        let logiConn = LogiConnFrame(logiConnId: logiConnId, localNetId: 1, remoteNetId: peerNetId, inner: inner.serialized())
        let miFrame = MiConnectFrame(version: 0, logiConnFrames: [logiConn])
        send(frame: LyraMeshPack.Frame(packType: 2, payload: miFrame.serialized()), label: "upgrade_f5")
    }

    private struct AuthServerHello {
        var serverRandom: Data
        var publicKey: Data
    }

    private func parseAuthServerHello(_ data: Data) -> AuthServerHello? {
        func lengthDelimited(_ fieldNumber: Int, in data: Data) -> Data? {
            guard let fields = try? LyraProtoReader.readFields(from: data) else { return nil }
            return fields.first { $0.number == fieldNumber && $0.wireType == 2 }?.lengthDelimitedValue
        }
        func varint(_ fieldNumber: Int, in data: Data) -> UInt64? {
            guard let fields = try? LyraProtoReader.readFields(from: data) else { return nil }
            return fields.first { $0.number == fieldNumber && $0.wireType == 0 }?.varintValue
        }
        guard let handshakeFrame = lengthDelimited(2, in: data),
              let family = varint(1, in: handshakeFrame),
              let pairFrame = lengthDelimited(family == 5 ? 8 : 6, in: handshakeFrame),
              let serverNotify = lengthDelimited(3, in: pairFrame),
              let cipherSuite = lengthDelimited(1, in: serverNotify),
              let serverRandom = lengthDelimited(2, in: cipherSuite),
              let genericPublicKey = lengthDelimited(5, in: cipherSuite),
              let publicKey = lengthDelimited(2, in: genericPublicKey),
              publicKey.count == 65, publicKey.first == 0x04
        else {
            return nil
        }
        return AuthServerHello(serverRandom: serverRandom, publicKey: publicKey)
    }

    private func handleUpgradeResponse(_ data: Data) {
        guard let hello = parseAuthServerHello(data), let privateKey = keyAgreementKey else {
            DiagnosticsLog.warn("xiaomi.cast.trust_upgrade_parse_failed bytes=\(data.count)")
            return
        }
        authServerRandom = hello.serverRandom
        do {
            let peerPublicKey = try P256.KeyAgreement.PublicKey(x963Representation: hello.publicKey)
            let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: peerPublicKey)
            let secret = sharedSecret.withUnsafeBytes { Data($0) }
            channelKeyCS = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: SymmetricKey(data: secret),
                salt: LyraMeshHkdf.salt,
                info: authClientRandom + authServerRandom,
                outputByteCount: 32
            )
            channelKeySC = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: SymmetricKey(data: secret),
                salt: LyraMeshHkdf.salt,
                info: authServerRandom + authClientRandom,
                outputByteCount: 32
            )
            sendEncryptedAnnounces()
            queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, !self.cancelled else { return }
                self.sendLogiConnRequest()
            }
        } catch {
            fail(String(localized: "ECDH 失敗"))
        }
    }

    // Re-dials the cast logi conn on the still-alive phys conn after the
    // phone released it. Crucially this keeps the adopted mitrustservice
    // server socket alive: the phone drives the real 546/562 auth on the
    // channel it already has to us, and killing it strands the unlock.
    func redialCastChannel() {
        queue.async { [weak self] in
            guard let self, !self.cancelled, self.channelKeyCS != nil else {
                DiagnosticsLog.warn("xiaomi.cast.trust_channel_redial_impossible")
                return
            }
            DiagnosticsLog.info("xiaomi.cast.trust_channel_redial")
            // The phone rejects a logi request that reuses an already-
            // released conn id (live 2026-08-11: lyra-conn-logi "invalided
            // connection conflict local=1" — the redial went unanswered, the
            // session failed, and the adopted mitrustservice socket died
            // with it; the next unlock's 562 went into the phone's zombie
            // conn and the auth came back code=1). Dial with a fresh id.
            self.logiConnId = .random(in: 1...UInt32.max)
            self.sendLogiConnRequest()
            self.armRedialTimeout()
        }
    }

    // A redial the phone never answers would otherwise stall until the 30s
    // stage watchdog — and every mirror-flow retry resets that watchdog via
    // progress(), so a phys conn the phone already tore down (it releases
    // the cast logi conn ~6s after CLOSE_SCREEN, live 2026-08-04) zombied
    // the session for as long as the user kept retrying. Fail the session
    // fast: the runtime drops it and the flow builds a fresh one (full
    // phys handshake), which the phone does answer.
    var redialResponseTimeout: TimeInterval = 6

    private func armRedialTimeout() {
        queue.asyncAfter(deadline: .now() + redialResponseTimeout) { [weak self] in
            guard let self, !self.cancelled, self.stage != .ready else { return }
            DiagnosticsLog.warn("xiaomi.cast.trust_channel_redial_timeout stage=\(self.stage)")
            self.fail("redial_timeout")
        }
    }

    private func sendLogiConnRequest() {
        progress(.logiConnRequest, String(localized: "建立傳輸通道…"))
        channelId = UInt32.random(in: 100...60000)
        transKey = Self.randomBytes(32)
        transRandom = Self.randomBytes(32)
        let colonHex = Self.randomBytes(32).map { String(format: "%02x", $0) }.joined(separator: ":")

        var peerPortRequest = Data()
        LyraProtoWriter.appendVarintField(1, value: UInt64(channelId), to: &peerPortRequest)
        LyraProtoWriter.appendLengthDelimitedField(4, value: transKey, to: &peerPortRequest)
        LyraProtoWriter.appendLengthDelimitedField(5, value: transRandom, to: &peerPortRequest)

        var privateData = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &privateData)
        LyraProtoWriter.appendLengthDelimitedField(2, value: Data(Self.servicePackage.utf8), to: &privateData)
        LyraProtoWriter.appendLengthDelimitedField(3, value: Data(colonHex.utf8), to: &privateData)
        LyraProtoWriter.appendLengthDelimitedField(
            4, value: Data("AQH//wAAAB4AAQEAAAEAAAAUAAUAAAAAAAxBUUFBQUFBQUFBQT0=".utf8), to: &privateData
        )
        LyraProtoWriter.appendLengthDelimitedField(
            5,
            value: Data([
                0x01, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x15,
                0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0xFF, 0x00,
                0x00, 0x06, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x01
            ]),
            to: &privateData
        )
        LyraProtoWriter.appendVarintField(6, value: 1, to: &privateData)
        LyraProtoWriter.appendLengthDelimitedField(10, value: peerPortRequest, to: &privateData)

        var request = Data()
        LyraProtoWriter.appendLengthDelimitedField(2, value: Data(Self.serviceName.utf8), to: &request)
        LyraProtoWriter.appendLengthDelimitedField(3, value: privateData, to: &request)

        let requestInner = LogiConnInnerFrame(frameType: 1, payload: .request(request))
        sendEncryptedLogiConn(inner: requestInner, label: "logi_request")
    }

    private static let mitrustServiceName = "com.xiaomi.trustservice:mitrustservice"
    private static let keyAgreeSessionSalt = Data([
        0x5e, 0xd5, 0xa3, 0xf8, 0x36, 0xf6, 0xb5, 0x4f,
        0x7b, 0x1e, 0xfa, 0xd0, 0x27, 0x14, 0xd5, 0x17,
        0x7b, 0x8a, 0x1f, 0x0f, 0x19, 0xe3, 0x69, 0xcc,
        0x0b, 0xe8, 0xd9, 0x8b, 0xa6, 0x29, 0x73, 0x17
    ])

    private func isMitrustSyncInfo(_ data: Data) -> Bool {
        guard let fields = try? LyraProtoReader.readFields(from: data) else { return false }
        return fields.contains {
            $0.number == 4 && $0.lengthDelimitedValue.flatMap { String(data: $0, encoding: .utf8) } == Self.mitrustServiceName
        }
    }

    private static func syncServiceName(of data: Data) -> String {
        guard let fields = try? LyraProtoReader.readFields(from: data) else { return "" }
        return fields.first { $0.number == 4 && $0.wireType == 2 }?
            .lengthDelimitedValue.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    // Stable random uid (NOT the Xiaomi account uid) for the mitrustservice
    // sync_info — keeps the phone on the PasskeyPair route.
    private static func pairingUidFeatureInfo() -> Data {
        let defaults = UserDefaults.standard
        let uidRaw: Data
        if let b64 = defaults.string(forKey: "xiaomiTrustPairUidHashB64"),
           let stored = Data(base64Encoded: b64), stored.count == 32
        {
            uidRaw = stored
        } else {
            let generated = randomBytes(32)
            defaults.set(generated.base64EncodedString(), forKey: "xiaomiTrustPairUidHashB64")
            uidRaw = generated
        }
        let nonce = randomBytes(8)
        var feature = Data(SHA256.hash(data: nonce + uidRaw))
        var info = Data()
        LyraProtoWriter.appendLengthDelimitedField(1, value: nonce, to: &info)
        LyraProtoWriter.appendLengthDelimitedField(2, value: feature, to: &info)
        return info
    }

    private func handleMitrustSyncInfo(_ data: Data, logiConn: LogiConnFrame) {
        mitrustActivityAt = Date()
        if srvConnId != 0, srvConnId != logiConn.logiConnId {
            // The phone reopened the mitrustservice conn (retry/new phys).
            // Its latest conn wins — drop the stale channel state so the new
            // requestOfPeerPort isn't ignored.
            teardownServerChannelLocked()
            mitrustAuth = nil
            srvTransKey = Data()
            mitrustPeerPortChannelId = 0
            mitrustPeerPort = nil
            mitrustPeerPortResponseSent = false
            mitrustPeerPortAwaitingAck = false
        }
        srvConnId = logiConn.logiConnId
        srvPeerNetId = logiConn.localNetId
        let ticketStore = MiTrustTicketStore.current()
        let fields = (try? LyraProtoReader.readFields(from: data)) ?? []
        var peerCred = Data()
        var peerKeyIndex: UInt64 = 0
        var peerEncryptedCred = Data()
        for field in fields {
            switch field.number {
            case 3: peerKeyIndex = field.varintValue ?? 0
            case 5: peerCred = field.lengthDelimitedValue ?? Data()
            case 6: peerEncryptedCred = field.lengthDelimitedValue ?? Data()
            default: continue
            }
        }
        DiagnosticsLog.info(
            "xiaomi.cast.mitrust_peer_sync_info keyIndex=\(peerKeyIndex) credBytes=\(peerCred.count) encCredBytes=\(peerEncryptedCred.count)"
        )
        if !peerEncryptedCred.isEmpty {
            if let plaintext = ticketStore.decryptCredBlob(peerEncryptedCred) {
                DiagnosticsLog.info(
                    "xiaomi.cast.mitrust_peer_cred_decrypted bytes=\(plaintext.count) hex=\(plaintext.map { String(format: "%02x", $0) }.joined())"
                )
            } else {
                DiagnosticsLog.warn(
                    "xiaomi.cast.mitrust_peer_cred_decrypt_failed blobHead=\(peerEncryptedCred.prefix(40).map { String(format: "%02x", $0) }.joined())"
                )
            }
        }
        var peerConnId = Data()
        var peerPubKey = Data()
        for field in (try? LyraProtoReader.readFields(from: peerCred)) ?? [] {
            switch (field.number, field.wireType) {
            case (1, 2): peerConnId = field.lengthDelimitedValue ?? Data()
            case (2, 2): peerPubKey = field.lengthDelimitedValue ?? Data()
            default: continue
            }
        }
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        srvSignKey = privateKey
        var connId = Data()
        for _ in 0..<8 {
            connId.append(UInt8.random(in: 0...255))
        }
        srvOurConnId = connId
        if peerPubKey.count == 32,
           let peerKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPubKey),
           let sharedSecret = try? privateKey.sharedSecretFromKeyAgreement(with: peerKey)
        {
            let secret = sharedSecret.withUnsafeBytes { Data($0) }
            let ourPub = privateKey.publicKey.rawRepresentation
            let infos: [Data] = [
                peerConnId + connId,
                connId + peerConnId,
                peerPubKey + ourPub,
                ourPub + peerPubKey,
                Data()
            ]
            srvKeyCandidates = infos.map {
                HKDF<SHA256>.deriveKey(
                    inputKeyMaterial: SymmetricKey(data: secret),
                    salt: LyraMeshHkdf.salt,
                    info: $0,
                    outputByteCount: 32
                )
            }
        }
        var syncInfo = Data()
        LyraProtoWriter.appendVarintField(1, value: 10000, to: &syncInfo)
        if ticketStore.isEnabled {
            srvReuseKey = ticketStore.ticketKey
            // Present as a NOT-same-account peer (TL 0x30 + non-matching uid):
            // claiming the account uid (TL 0x10) makes the phone pick
            // AccountPair, which we cannot satisfy (needs Xiaomi account
            // certs). Stranger presentation routes it to PasskeyPair instead.
            LyraProtoWriter.appendVarintField(2, value: 48, to: &syncInfo)
            LyraProtoWriter.appendVarintField(3, value: ticketStore.myKeyIndex, to: &syncInfo)
            LyraProtoWriter.appendLengthDelimitedField(5, value: Self.pairingUidFeatureInfo(), to: &syncInfo)
            if let ourEncCred = ticketStore.encryptLocalCred() {
                LyraProtoWriter.appendLengthDelimitedField(6, value: ourEncCred, to: &syncInfo)
                DiagnosticsLog.info("xiaomi.cast.mitrust_our_cred_tx bytes=\(ourEncCred.count)")
            }
        } else {
            var cred = Data()
            LyraProtoWriter.appendLengthDelimitedField(1, value: connId, to: &cred)
            LyraProtoWriter.appendLengthDelimitedField(2, value: privateKey.publicKey.rawRepresentation, to: &cred)
            LyraProtoWriter.appendVarintField(2, value: 48, to: &syncInfo)
            LyraProtoWriter.appendVarintField(3, value: 1, to: &syncInfo)
            LyraProtoWriter.appendLengthDelimitedField(4, value: Data(Self.mitrustServiceName.utf8), to: &syncInfo)
            LyraProtoWriter.appendLengthDelimitedField(5, value: cred, to: &syncInfo)
            LyraProtoWriter.appendLengthDelimitedField(
                6, value: Self.officialMacSyncInfoSignature, to: &syncInfo
            )
        }
        let inner = LogiConnInnerFrame(frameType: 5, payload: .syncInfo(syncInfo))
        let frame = LogiConnFrame(logiConnId: srvConnId, localNetId: 1, remoteNetId: srvPeerNetId, inner: inner.serialized())
        let miFrame = MiConnectFrame(version: 0, logiConnFrames: [frame])
        send(frame: LyraMeshPack.Frame(packType: 2, payload: miFrame.serialized()), label: "mitrust_sync_info")
        DiagnosticsLog.info("xiaomi.cast.mitrust_sync_info_rx connId=\(self.srvConnId) peerNetId=\(self.srvPeerNetId)")
    }

    private func upgradeLengthDelimited(_ fieldNumber: Int, in data: Data) -> Data? {
        guard let fields = try? LyraProtoReader.readFields(from: data) else { return nil }
        return fields.first { $0.number == fieldNumber && $0.wireType == 2 }?.lengthDelimitedValue
    }

    private func upgradeVarint(_ fieldNumber: Int, in data: Data) -> UInt64? {
        guard let fields = try? LyraProtoReader.readFields(from: data) else { return nil }
        return fields.first { $0.number == fieldNumber && $0.wireType == 0 }?.varintValue
    }

    private func handleMitrustUpgrade(_ data: Data) {
        mitrustActivityAt = Date()
        guard let handshakeFrame = upgradeLengthDelimited(2, in: data),
              let messageType = upgradeVarint(2, in: handshakeFrame),
              let handshakeId = upgradeVarint(1, in: data)
        else {
            DiagnosticsLog.warn(
                "xiaomi.cast.mitrust_upgrade_parse_failed bytes=\(data.count) hex=\(data.map { String(format: "%02x", $0) }.joined())"
            )
            return
        }
        switch messageType {
        case 6:
            handleKeyAgreeUpgrade(handshakeFrame: handshakeFrame, handshakeId: handshakeId)
        case 2:
            handlePasskeyPairUpgrade(handshakeFrame: handshakeFrame, handshakeId: handshakeId)
        case 5:
            handleAuthUpgrade(
                handshakeFrame: handshakeFrame, handshakeId: handshakeId,
                authField: 7, responseFamily: 4, responseType: 5
            )
        case 4:
            handleAuthUpgrade(
                handshakeFrame: handshakeFrame, handshakeId: handshakeId,
                authField: 6, responseFamily: 2, responseType: 4
            )
        case 1:
            let alert = upgradeLengthDelimited(3, in: handshakeFrame) ?? Data()
            let alertType = upgradeVarint(2, in: alert) ?? upgradeVarint(1, in: alert) ?? 0
            let desc = (upgradeLengthDelimited(1, in: alert) ?? upgradeLengthDelimited(2, in: alert))
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            DiagnosticsLog.warn("xiaomi.cast.mitrust_alert_rx type=\(alertType) desc=\(desc)")
        default:
            DiagnosticsLog.warn(
                "xiaomi.cast.mitrust_upgrade_unhandled_type messageType=\(messageType) " +
                    "hex=\(data.prefix(200).map { String(format: "%02x", $0) }.joined())"
            )
        }
    }

    private func sendMitrustUpgradePayload(handshake: Data, handshakeId: UInt64, label: String) {
        var authFrame = Data()
        LyraProtoWriter.appendVarintField(1, value: handshakeId, to: &authFrame)
        LyraProtoWriter.appendLengthDelimitedField(2, value: handshake, to: &authFrame)
        let inner = LogiConnInnerFrame(frameType: 6, payload: .upgrade(authFrame))
        let frame = LogiConnFrame(logiConnId: srvConnId, localNetId: 1, remoteNetId: srvPeerNetId, inner: inner.serialized())
        let miFrame = MiConnectFrame(version: 0, logiConnFrames: [frame])
        send(frame: LyraMeshPack.Frame(packType: 2, payload: miFrame.serialized()), label: label)
        DiagnosticsLog.info("xiaomi.cast.mitrust_upgrade_tx label=\(label)")
    }

    private func handleKeyAgreeUpgrade(handshakeFrame: Data, handshakeId: UInt64) {
        guard let family = upgradeVarint(1, in: handshakeFrame),
              let pairFrame = upgradeLengthDelimited(8, in: handshakeFrame),
              let clientNotify = upgradeLengthDelimited(2, in: pairFrame),
              let cipherSuite = upgradeLengthDelimited(1, in: clientNotify),
              let clientRandom = upgradeLengthDelimited(2, in: cipherSuite),
              let publicKeyMessage = upgradeLengthDelimited(5, in: cipherSuite),
              let publicKey = upgradeLengthDelimited(2, in: publicKeyMessage),
              publicKey.count == 65, publicKey.first == 0x04
        else {
            DiagnosticsLog.warn("xiaomi.cast.mitrust_keyagree_parse_failed")
            return
        }
        let privateKey = P256.KeyAgreement.PrivateKey()
        srvKeyAgreementKey = privateKey
        srvClientRandom = clientRandom
        let serverRandom = Self.randomBytes(32)
        srvServerRandom = serverRandom
        do {
            let peerPublicKey = try P256.KeyAgreement.PublicKey(x963Representation: publicKey)
            let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: peerPublicKey)
            let secret = sharedSecret.withUnsafeBytes { Data($0) }
            srvKeyCS = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: SymmetricKey(data: secret),
                salt: Self.keyAgreeSessionSalt,
                info: clientRandom + serverRandom,
                outputByteCount: 32
            )
            srvKeySC = srvKeyCS
            // KeyAgree supersedes the ticket/reuse key: all frameType 1/2/3/7
            // traffic after this point is encrypted with the fresh session
            // key. Keeping the stale ticket key here makes the phone drop
            // the conn with 15071 (decrypt failed).
            srvReuseKey = srvKeyCS
            let compareCode = LyraKeyAgreeCompareCode.generate(
                z: secret, clientRandom: clientRandom, serverRandom: serverRandom
            )
            DiagnosticsLog.info("xiaomi.cast.mitrust_keyagree_compare code=\(compareCode)")
            // The compare code is a UI-layer nicety only meaningful when the
            // phone also displays it during manual pairing. The phone-dialed
            // bind/unlock flow confirms on the phone side, so a modal alert
            // here is pure noise (it fires on every mitrust KeyAgree).
            onPairingCompareCode?(compareCode)
        } catch {
            DiagnosticsLog.error("xiaomi.cast.mitrust_upgrade_ecdh_failed", error)
            return
        }

        var outPublicKeyMessage = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &outPublicKeyMessage)
        LyraProtoWriter.appendLengthDelimitedField(2, value: privateKey.publicKey.x963Representation, to: &outPublicKeyMessage)

        var outCipherSuite = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &outCipherSuite)
        LyraProtoWriter.appendLengthDelimitedField(2, value: serverRandom, to: &outCipherSuite)
        LyraProtoWriter.appendVarintField(3, value: 32, to: &outCipherSuite)
        LyraProtoWriter.appendVarintField(4, value: 2, to: &outCipherSuite)
        LyraProtoWriter.appendLengthDelimitedField(5, value: outPublicKeyMessage, to: &outCipherSuite)

        var serverNotify = Data()
        LyraProtoWriter.appendLengthDelimitedField(1, value: outCipherSuite, to: &serverNotify)

        var outPairFrame = Data()
        LyraProtoWriter.appendVarintField(1, value: 2, to: &outPairFrame)
        LyraProtoWriter.appendLengthDelimitedField(3, value: serverNotify, to: &outPairFrame)

        var handshake = Data()
        LyraProtoWriter.appendVarintField(1, value: family, to: &handshake)
        LyraProtoWriter.appendVarintField(2, value: 6, to: &handshake)
        LyraProtoWriter.appendLengthDelimitedField(8, value: outPairFrame, to: &handshake)
        sendMitrustUpgradePayload(handshake: handshake, handshakeId: handshakeId, label: "mitrust_keyagree")
    }

    private func handlePasskeyPairUpgrade(handshakeFrame: Data, handshakeId: UInt64) {
        if passkeyPair == nil {
            guard let identityKey = Self.p2pIdentityPrivateKey() else {
                DiagnosticsLog.warn("xiaomi.cast.mitrust_passkeypair_no_identity")
                return
            }
            let server = LyraPasskeyPairServer(identityPrivateKey: identityKey)
            server.onSend = { [weak self] handshake in
                self?.sendMitrustUpgradePayload(
                    handshake: handshake, handshakeId: handshakeId, label: "mitrust_passkeypair"
                )
            }
            server.onEvent = { [weak self] event in
                guard let self else { return }
                switch event {
                case let .displayPasskey(code):
                    DiagnosticsLog.info("xiaomi.cast.mitrust_passkeypair_passkey_displayed")
                    if let onPairingPasskey {
                        onPairingPasskey(code)
                    } else {
                        Self.onPasskeyCompare?(code)
                    }
                case let .completed(peerIdentityPubKey):
                    DiagnosticsLog.info("xiaomi.cast.mitrust_passkeypair_completed")
                    UserDefaults.standard.set(
                        peerIdentityPubKey.base64EncodedString(), forKey: "xiaomiTrustP2PPeerIdentityPubB64"
                    )
                    self.onPairingCompleted?()
                case let .failed(code, message):
                    DiagnosticsLog.warn("xiaomi.cast.mitrust_passkeypair_failed code=\(code) msg=\(message)")
                    self.passkeyPair = nil
                }
            }
            passkeyPair = server
            server.begin()
        }
        passkeyPair?.handle(handshakeFrame: handshakeFrame)
    }

    // Dedicated "lyra-identity-p2p-pair-keypair": our OWN identity the phone
    // stores as a type-2 cred after PasskeyPair. Persisted so re-auth keeps
    // working across launches.
    private static func p2pIdentityPrivateKey() -> P256.Signing.PrivateKey? {
        let defaults = UserDefaults.standard
        if let hex = defaults.string(forKey: "xiaomiTrustP2PIdentityPrivHex"),
           let data = MiTrustTicketStore.data(fromHex: hex),
           let key = try? P256.Signing.PrivateKey(rawRepresentation: data)
        {
            return key
        }
        let key = P256.Signing.PrivateKey()
        let hex = key.rawRepresentation.map { String(format: "%02x", $0) }.joined()
        defaults.set(hex, forKey: "xiaomiTrustP2PIdentityPrivHex")
        DiagnosticsLog.info("xiaomi.cast.mitrust_p2p_identity_generated")
        return key
    }

    private func handleAuthUpgrade(
        handshakeFrame: Data,
        handshakeId: UInt64,
        authField: Int,
        responseFamily: Int,
        responseType: Int
    ) {
        guard let authFrame = upgradeLengthDelimited(authField, in: handshakeFrame),
              let frameType = upgradeVarint(1, in: authFrame)
        else {
            DiagnosticsLog.warn("xiaomi.cast.mitrust_auth_parse_failed")
            return
        }
        switch frameType {
        case 1:
            handleAuthClientNotify(
                authFrame: authFrame, handshakeId: handshakeId,
                responseFamily: responseFamily, responseType: responseType, responseField: authField
            )
        case 3:
            handleAuthClientFinished(
                authFrame: authFrame, handshakeId: handshakeId,
                responseFamily: responseFamily, responseType: responseType, responseField: authField
            )
        default:
            DiagnosticsLog.warn("xiaomi.cast.mitrust_auth_unhandled frameType=\(frameType)")
        }
    }

    private func handleAuthClientNotify(
        authFrame: Data,
        handshakeId: UInt64,
        responseFamily: Int,
        responseType: Int,
        responseField: Int
    ) {
        guard let clientNotify = upgradeLengthDelimited(2, in: authFrame),
              let cipherSuite = upgradeLengthDelimited(1, in: clientNotify),
              let clientRandom = upgradeLengthDelimited(2, in: cipherSuite),
              clientRandom.count == 32,
              let publicKeyMessage = upgradeLengthDelimited(5, in: cipherSuite),
              let publicKey = upgradeLengthDelimited(2, in: publicKeyMessage),
              publicKey.count == 65, publicKey.first == 0x04
        else {
            DiagnosticsLog.warn("xiaomi.cast.mitrust_auth_notify_parse_failed")
            return
        }
        let offeredP3 = upgradeVarint(3, in: cipherSuite)
        let offeredP4 = upgradeVarint(4, in: cipherSuite)
        let ticketStore = MiTrustTicketStore.current()
        let p2pPaired = UserDefaults.standard.string(forKey: "xiaomiTrustP2PPeerIdentityPubB64") != nil
        let identityKey = p2pPaired ? Self.p2pIdentityPrivateKey() : ticketStore.identityPrivateKey
        guard let identityKey else {
            DiagnosticsLog.warn("xiaomi.cast.mitrust_auth_no_identity")
            return
        }
        let privateKey = P256.KeyAgreement.PrivateKey()
        let serverRandom = Self.randomBytes(32)
        let serverPub = privateKey.publicKey.x963Representation
        let secret: Data
        do {
            let peerPublicKey = try P256.KeyAgreement.PublicKey(x963Representation: publicKey)
            secret = try privateKey.sharedSecretFromKeyAgreement(with: peerPublicKey).withUnsafeBytes { Data($0) }
        } catch {
            DiagnosticsLog.error("xiaomi.cast.mitrust_auth_ecdh_failed", error)
            return
        }
        mitAuthClientRandom = clientRandom
        mitAuthServerRandom = serverRandom
        mitAuthSharedZ = secret
        mitAuthServerEphPriv = privateKey
        mitAuthClientEphPub = publicKey
        guard let signature = try? identityKey.signature(for: SHA256.hash(data: serverPub + publicKey)) else {
            DiagnosticsLog.warn("xiaomi.cast.mitrust_auth_sign_failed")
            return
        }
        let encSig: Data
        do {
            let nonce = AES.GCM.Nonce()
            let sealed = try AES.GCM.seal(signature.derRepresentation, using: SymmetricKey(data: secret), nonce: nonce)
            var blob = Data()
            blob.append(contentsOf: nonce.withUnsafeBytes { Data($0) })
            blob.append(sealed.ciphertext)
            blob.append(sealed.tag)
            encSig = blob
        } catch {
            DiagnosticsLog.error("xiaomi.cast.mitrust_auth_enc_failed", error)
            return
        }

        var outPublicKeyMessage = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &outPublicKeyMessage)
        LyraProtoWriter.appendLengthDelimitedField(2, value: serverPub, to: &outPublicKeyMessage)

        var selected = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &selected)
        LyraProtoWriter.appendLengthDelimitedField(2, value: serverRandom, to: &selected)
        LyraProtoWriter.appendVarintField(3, value: offeredP3 ?? 0x40, to: &selected)
        LyraProtoWriter.appendVarintField(4, value: offeredP4 ?? 2, to: &selected)
        LyraProtoWriter.appendLengthDelimitedField(5, value: outPublicKeyMessage, to: &selected)

        var truth = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &truth)

        var serverNotify = Data()
        LyraProtoWriter.appendLengthDelimitedField(1, value: selected, to: &serverNotify)
        LyraProtoWriter.appendLengthDelimitedField(2, value: encSig, to: &serverNotify)
        LyraProtoWriter.appendLengthDelimitedField(4, value: truth, to: &serverNotify)
        LyraProtoWriter.appendLengthDelimitedField(5, value: truth, to: &serverNotify)

        var outAuthFrame = Data()
        LyraProtoWriter.appendVarintField(1, value: 2, to: &outAuthFrame)
        LyraProtoWriter.appendLengthDelimitedField(3, value: serverNotify, to: &outAuthFrame)

        var handshake = Data()
        LyraProtoWriter.appendVarintField(1, value: UInt64(responseFamily), to: &handshake)
        LyraProtoWriter.appendVarintField(2, value: UInt64(responseType), to: &handshake)
        LyraProtoWriter.appendLengthDelimitedField(responseField, value: outAuthFrame, to: &handshake)
        sendMitrustUpgradePayload(handshake: handshake, handshakeId: handshakeId, label: "mitrust_auth_server_notify")
    }

    private func handleAuthClientFinished(
        authFrame: Data,
        handshakeId: UInt64,
        responseFamily: Int,
        responseType: Int,
        responseField: Int
    ) {
        guard let clientFinished = upgradeLengthDelimited(4, in: authFrame),
              let encSigC = upgradeLengthDelimited(1, in: clientFinished),
              !encSigC.isEmpty
        else {
            DiagnosticsLog.warn("xiaomi.cast.mitrust_auth_finished_parse_failed")
            return
        }
        let ticketStore = MiTrustTicketStore.current()
        guard let serverEphPub = mitAuthServerEphPriv?.publicKey.x963Representation,
              !mitAuthSharedZ.isEmpty, !mitAuthClientEphPub.isEmpty
        else {
            DiagnosticsLog.warn("xiaomi.cast.mitrust_auth_finished_no_state")
            return
        }
        let zKey = SymmetricKey(data: mitAuthSharedZ)
        guard let sigC = ticketStore.decrypt(encSigC, with: zKey) else {
            DiagnosticsLog.warn("xiaomi.cast.mitrust_auth_sig_decrypt_failed")
            return
        }
        do {
            let p2pPeerB64 = UserDefaults.standard.string(forKey: "xiaomiTrustP2PPeerIdentityPubB64")
            let peerPubData = p2pPeerB64.flatMap { Data(base64Encoded: $0) } ?? ticketStore.peerIdentityPubKey
            let peerIdentity = try P256.Signing.PublicKey(x963Representation: peerPubData)
            let signature = try P256.Signing.ECDSASignature(derRepresentation: sigC)
            guard peerIdentity.isValidSignature(signature, for: SHA256.hash(data: mitAuthClientEphPub + serverEphPub)) else {
                DiagnosticsLog.warn("xiaomi.cast.mitrust_auth_sig_invalid")
                return
            }
        } catch {
            DiagnosticsLog.error("xiaomi.cast.mitrust_auth_sig_verify_failed", error)
            return
        }
        let sessionKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: zKey,
            salt: Self.keyAgreeSessionSalt,
            info: mitAuthClientRandom + mitAuthServerRandom,
            outputByteCount: 32
        )
        let ticket = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: zKey,
            salt: Self.authTicketSalt,
            info: mitAuthClientRandom + mitAuthServerRandom,
            outputByteCount: 32
        )
        let sessionKeyData = sessionKey.withUnsafeBytes { Data($0) }
        let ticketData = ticket.withUnsafeBytes { Data($0) }
        MiTrustTicketStore.recordAuthSession(sessionKey: sessionKeyData, ticket: ticketData)
        srvKeyCS = sessionKey
        srvKeySC = sessionKey
        srvReuseKey = sessionKey

        var serverFinished = Data()
        do {
            let nonce = AES.GCM.Nonce()
            let sealed = try AES.GCM.seal(mitAuthSharedZ + serverEphPub, using: sessionKey, nonce: nonce)
            var blob = Data()
            blob.append(contentsOf: nonce.withUnsafeBytes { Data($0) })
            blob.append(sealed.ciphertext)
            blob.append(sealed.tag)
            LyraProtoWriter.appendLengthDelimitedField(1, value: blob, to: &serverFinished)
        } catch {
            DiagnosticsLog.error("xiaomi.cast.mitrust_auth_finish_enc_failed", error)
            return
        }

        var outAuthFrame = Data()
        LyraProtoWriter.appendVarintField(1, value: 4, to: &outAuthFrame)
        LyraProtoWriter.appendLengthDelimitedField(5, value: serverFinished, to: &outAuthFrame)

        var handshake = Data()
        LyraProtoWriter.appendVarintField(1, value: UInt64(responseFamily), to: &handshake)
        LyraProtoWriter.appendVarintField(2, value: UInt64(responseType), to: &handshake)
        LyraProtoWriter.appendLengthDelimitedField(responseField, value: outAuthFrame, to: &handshake)
        sendMitrustUpgradePayload(handshake: handshake, handshakeId: handshakeId, label: "mitrust_auth_server_finished")
        DiagnosticsLog.info("xiaomi.cast.mitrust_auth_completed")
    }

    private func mitrustDecrypt(_ logiConn: LogiConnFrame, key: SymmetricKey) -> LogiConnInnerFrame? {
        let inner = logiConn.inner
        guard inner.count > 28 else { return nil }
        let nonce = inner.prefix(12)
        let ciphertext = inner.dropFirst(12).dropLast(16)
        let tag = inner.suffix(16)
        guard let sealedBox = try? AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: Data(nonce)),
            ciphertext: Data(ciphertext),
            tag: Data(tag)
        ), let plaintext = try? AES.GCM.open(sealedBox, using: key) else {
            return nil
        }
        return LogiConnInnerFrame(parsing: plaintext)
    }

    private func mitrustSendEncrypted(inner: LogiConnInnerFrame, label: String) {
        guard let sendKey = srvReuseKey ?? srvKeySC else { return }
        do {
            let nonce = AES.GCM.Nonce()
            let sealed = try AES.GCM.seal(inner.serialized(), using: sendKey, nonce: nonce)
            var encryptedInner = Data()
            encryptedInner.append(contentsOf: nonce.withUnsafeBytes { Data($0) })
            encryptedInner.append(sealed.ciphertext)
            encryptedInner.append(sealed.tag)
            let frame = LogiConnFrame(
                logiConnId: srvConnId,
                localNetId: 1,
                remoteNetId: srvPeerNetId,
                flag: true,
                inner: encryptedInner
            )
            let miFrame = MiConnectFrame(version: 0, logiConnFrames: [frame])
            send(frame: LyraMeshPack.Frame(packType: 2, payload: miFrame.serialized()), label: label)
        } catch {
            DiagnosticsLog.error("xiaomi.cast.mitrust_encrypt_failed label=\(label)", error)
        }
    }

    private func handleMitrustEncrypted(_ logiConn: LogiConnFrame) {
        mitrustActivityAt = Date()
        for key in [srvReuseKey].compactMap({ $0 }) + [srvKeyCS, srvKeySC].compactMap({ $0 }) + srvKeyCandidates {
            guard let inner = mitrustDecrypt(logiConn, key: key) else {
                continue
            }
            if case .request(let requestData) = inner.payload {
                handleMitrustLogiRequest(requestData)
                return
            }
            if inner.frameType == 3 {
                DiagnosticsLog.info("xiaomi.cast.mitrust_logi_response_ack_rx")
                mitrustPeerPortAwaitingAck = false
                sendMitrustPeerPortResponseIfReady()
                return
            }
            let payloadData = inner.payload?.data ?? Data()
            if let (header, commandBody) = try? LyraChannelProtocol.decode(payloadData) {
                DiagnosticsLog.info("xiaomi.cast.mitrust_logi_command type=\(header.type) frameType=\(inner.frameType)")
                if header.type == LyraChannelProtocol.CommandType.requestOfPeerPort.rawValue {
                    handleMitrustPeerPortRequest(commandBody)
                }
                return
            }
            DiagnosticsLog.info(
                "xiaomi.cast.mitrust_logi_other frameType=\(inner.frameType) bytes=\(payloadData.count) " +
                    "head=\(payloadData.prefix(32).map { String(format: "%02x", $0) }.joined())"
            )
            return
        }
        DiagnosticsLog.warn("xiaomi.cast.mitrust_decrypt_failed bytes=\(logiConn.inner.count)")
    }

    // Official servers send their OWN 32B node id (95-char colon-hex) in the
    // response UserInfo f3. Echoing the phone's id trips the phone's
    // channel-client guard and it never sends requestOfPeerPort.
    private static var mitrustServerFingerprint: String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: "xiaomiTrustLocalNodeIdHex"), existing.count == 95 {
            return existing
        }
        let generated = randomBytes(32).map { String(format: "%02X", $0) }.joined(separator: ":")
        defaults.set(generated, forKey: "xiaomiTrustLocalNodeIdHex")
        return generated
    }

    private func handleMitrustLogiRequest(_ requestData: Data) {
        DiagnosticsLog.info(
            "xiaomi.cast.mitrust_logi_request_rx bytes=\(requestData.count) " +
                "hex=\(requestData.prefix(400).map { String(format: "%02x", $0) }.joined())"
        )
        let userInfo = upgradeLengthDelimited(3, in: requestData) ?? Data()
        let peerPortRequest = upgradeLengthDelimited(10, in: userInfo)
        DiagnosticsLog.info("xiaomi.cast.mitrust_logi_request_userinfo bytes=\(userInfo.count) hasPeerPort=\(peerPortRequest != nil)")

        let serverInfo = LyraMitrustResponse.serverUserInfo(
            package: "com.xiaomi.trustservice",
            nodeIdColonHex: Self.mitrustServerFingerprint
        )
        let responseFrame = LyraMitrustResponse.logiConnResponse(userInfo: serverInfo)
        let response = LogiConnInnerFrame(frameType: 2, payload: .response(responseFrame))
        mitrustSendEncrypted(inner: response, label: "mitrust_logi_response")

        if let peerPortRequest {
            mitrustPeerPortAwaitingAck = true
            handleMitrustPeerPortRequest(peerPortRequest)
        }
    }

    private func handleMitrustPeerPortRequest(_ body: Data) {
        mitrustActivityAt = Date()
        let fields = (try? LyraProtoReader.readFields(from: body)) ?? []
        var channelId: UInt64 = 0
        var transKey = Data()
        for field in fields {
            switch (field.number, field.wireType) {
            case (1, 0): channelId = field.varintValue ?? 0
            case (4, 2): transKey = field.lengthDelimitedValue ?? Data()
            default: continue
            }
        }
        guard !transKey.isEmpty else {
            DiagnosticsLog.warn("xiaomi.cast.mitrust_peer_port_bad_request")
            return
        }
        guard srvChannelSocket == nil else {
            DiagnosticsLog.info("xiaomi.cast.mitrust_peer_port_ignored channelId=\(channelId) (channel exists)")
            return
        }
        srvTransKey = transKey
        let authService = MiTrustAuthService(deviceIdHex: deviceIdHex) { [weak self] jsonData in
            self?.sendMitrustChannelMessage(jsonData)
        }
        mitrustAuth = authService
        // The phone's channel client dials back over the transport the
        // mitrustservice conn rides — not necessarily this session's own.
        // Relay-routed session: the phone cannot reach a Mac UDP socket (its
        // channel client dials the relay bridge's loopback forward), so the
        // mitrust server listens on a virtual channel pipe attached to the
        // bridge. The advertised port is the bridge demux key: the phone
        // bridge snoops it from the responseOfPeerPort and stamps it onto
        // the phone-dialed datagrams. LAN sessions keep the real UDP socket
        // — EXCEPT when the adoption itself arrived on a relay-fed phys
        // conn (score-based reuse picking the relay announcer's conn on a
        // dual-homed phone): then the phone's dial crosses the relay even
        // though this session is LAN-routed, and only a pipe on the
        // runtime's current bridge is reachable (live 2026-08-13: a LAN
        // socket port advertised on the relay-fed adoption made the phone's
        // dial vanish at the Mac bridge → 562 kcp-timeout → authEvent
        // code=1, alternating with successes whenever the phone happened to
        // pick the LAN conn).
        let mitrustChannelBridge = relayBridge ?? (mitrustAdoptedViaRelay ? Self.activeRelayBridge() : nil)
        let socket: LyraChannelDatagramPipe
        if let bridge = mitrustChannelBridge {
            let bridgePort = bridge.allocateChannelPort()
            socket = bridge.channelPipe(port: bridgePort)
            srvChannelBridgePort = bridgePort
            srvChannelBridge = bridge
        } else {
            socket = LyraChannelSocket()
            srvChannelBridgePort = nil
            srvChannelBridge = nil
        }
        socket.onMessage = { [weak self] message, _ in
            self?.handleMitrustChannelMessage(message)
        }
        socket.onPeerConnected = { from in
            DiagnosticsLog.info("xiaomi.cast.mitrust_socket_peer from=\(from.debugDescription)")
        }
        socket.onNegotiated = { serverChannelId, mtu in
            DiagnosticsLog.info("xiaomi.cast.mitrust_channel_negotiated serverChannelId=\(serverChannelId) mtu=\(mtu)")
        }
        if let udpSocket = socket as? LyraChannelSocket {
            udpSocket.onRawDatagram = { datagram, from in
                DiagnosticsLog.info("xiaomi.cast.mitrust_socket_raw from=\(from.debugDescription) bytes=\(datagram.count)")
            }
            udpSocket.onDecryptFailure = { reason in
                DiagnosticsLog.warn("xiaomi.cast.mitrust_socket_decrypt_failed \(reason)")
            }
        }
        if let pipe = socket as? LyraVirtualChannelPipe {
            pipe.onDiagnostic = { detail in
                DiagnosticsLog.info("xiaomi.cast.mitrust_pipe \(detail)")
            }
        }
        do {
            try socket.start(socketKey: transKey, serverChannelId: 6)
            srvChannelSocket = socket
            srvChannelId = 6
        } catch {
            DiagnosticsLog.error("xiaomi.cast.mitrust_channel_start_failed", error)
            if let port = srvChannelBridgePort {
                srvChannelBridge?.removeChannelPipe(port: port)
                srvChannelBridgePort = nil
                srvChannelBridge = nil
            }
            return
        }
        guard let port = socket.boundPort ?? {
            guard let udpSocket = socket as? LyraChannelSocket else { return nil }
            let semaphore = DispatchSemaphore(value: 0)
            var bound: UInt16?
            udpSocket.onStateChanged = { state in
                if case .ready = state {
                    bound = udpSocket.boundPort
                    semaphore.signal()
                }
            }
            _ = semaphore.wait(timeout: .now() + 1)
            return bound
        }() else {
            DiagnosticsLog.warn("xiaomi.cast.mitrust_channel_no_port")
            srvChannelSocket = nil
            if let bridgePort = srvChannelBridgePort {
                srvChannelBridge?.removeChannelPipe(port: bridgePort)
                srvChannelBridgePort = nil
                srvChannelBridge = nil
            }
            return
        }
        mitrustPeerPortChannelId = channelId
        mitrustPeerPort = port
        // Bind the phone bridge's reverse listener out-of-band BEFORE the
        // responseOfPeerPort teaches the phone's trustservice the port. The
        // phone bridge's snooper taps that response off the mesh stream, but
        // the tap is loss-fragile (mid-ceremony relay rebuild / reassembly
        // gap reset — live 2026-08-13 07:01: snoop missed, no reverse
        // listener, the phone's channel-client dial went into a loopback
        // void, ~10s kcp trans timeout → authEvent code=1). The ordered
        // send chain puts this envelope ahead of the response, so a
        // listen-capable phone bridge is guaranteed to be bound before the
        // channel client can dial.
        srvChannelBridge?.announceChannelListener(port: port)
        sendMitrustPeerPortResponseIfReady()
    }

    private func sendMitrustPeerPortResponseIfReady() {
        // Official servers fire responseOfPeerPort only after the phone's logi
        // conn is connected — earlier payloads are silently dropped by the
        // phone's LogiConnClientHandler ("not connected"). For requests that
        // arrived embedded in the quick-conn sync we wait for response_ack;
        // explicit post-connect 99B requests are answered immediately.
        guard !mitrustPeerPortAwaitingAck else { return }
        guard !mitrustPeerPortResponseSent,
              mitrustPeerPortChannelId != 0,
              let port = mitrustPeerPort,
              srvChannelSocket != nil
        else { return }
        mitrustPeerPortResponseSent = true
        let responseBody = LyraMitrustResponse.peerPortResponseBody(
            clientChannelId: mitrustPeerPortChannelId,
            serverChannelId: UInt64(srvChannelId),
            port: port,
            serverKey: Self.randomBytes(32)
        )
        let command = LyraChannelProtocol.encode(type: .responseOfPeerPort, body: responseBody)
        var payload = Data()
        // netId routes the command to the phone's channel handler — it must be
        // the PHONE's localNet for this conn (official uses the same netId in
        // both directions), otherwise the phone drops it with 52013.
        payload.append(UInt8(srvPeerNetId & 0xFF))
        payload.append(0) // flag=0: plaintext, no AES layer
        payload.append(command)
        send(frame: LyraMeshPack.Frame(packType: 5, payload: payload), label: "mitrust_peer_port_response")
        DiagnosticsLog.info("xiaomi.cast.mitrust_peer_port_tx port=\(port) channelId=\(self.srvChannelId)")
    }

    private func sendMitrustChannelMessage(_ message: Data) {
        guard let socket = srvChannelSocket, !srvTransKey.isEmpty else {
            DiagnosticsLog.warn("xiaomi.cast.mitrust_tx_no_channel")
            return
        }
        do {
            try socket.sendVariant(
                channelFrame: LyraChannelSocket.wrapChannelFrame(message),
                key: srvTransKey,
                singleLayer: true
            )
            DiagnosticsLog.info("xiaomi.cast.mitrust_channel_tx bytes=\(message.count)")
        } catch {
            DiagnosticsLog.error("xiaomi.cast.mitrust_channel_tx_failed", error)
        }
    }

    private func handleMitrustChannelMessage(_ message: Data) {
        mitrustActivityAt = Date()
        lastProgress = Date()
        var payload = message
        if let (tag, child) = try? LyraExpressTLVParser.parseOneOf(message), tag == 1,
           let payloadNode = LyraExpressTLVParser.firstChild(0, in: LyraExpressTLVParser.children(of: child))
        {
            payload = payloadNode.payload
        }
        if let authService = mitrustAuth {
            authService.handleChannelPayload(payload)
            return
        }
        DiagnosticsLog.info(
            "xiaomi.cast.mitrust_channel_rx bytes=\(message.count) " +
                "hex=\(message.prefix(48).map { String(format: "%02x", $0) }.joined())"
        )
    }

    private static func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { buffer in
            if let baseAddress = buffer.baseAddress {
                arc4random_buf(baseAddress, count)
            }
        }
        return data
    }

    private func sendEncryptedLogiConn(inner: LogiConnInnerFrame, label: String) {
        guard let channelKeyCS else {
            fail(String(localized: "缺少通道金鑰"))
            return
        }
        do {
            let nonce = AES.GCM.Nonce()
            let sealed = try AES.GCM.seal(inner.serialized(), using: channelKeyCS, nonce: nonce)
            var encryptedInner = Data()
            encryptedInner.append(contentsOf: nonce.withUnsafeBytes { Data($0) })
            encryptedInner.append(sealed.ciphertext)
            encryptedInner.append(sealed.tag)
            let logiConn = LogiConnFrame(
                logiConnId: logiConnId,
                localNetId: 1,
                remoteNetId: peerNetId,
                flag: true,
                inner: encryptedInner
            )
            let miFrame = MiConnectFrame(version: 0, logiConnFrames: [logiConn])
            send(frame: LyraMeshPack.Frame(packType: 2, payload: miFrame.serialized()), label: label)
        } catch {
            fail(String(localized: "通道加密失敗"))
        }
    }

    private func decryptLogiConnInner(_ logiConn: LogiConnFrame) -> LogiConnInnerFrame? {
        let inner = logiConn.inner
        guard inner.count > 28 else { return nil }
        let nonce = inner.prefix(12)
        let ciphertext = inner.dropFirst(12).dropLast(16)
        let tag = inner.suffix(16)
        for key in [channelKeySC, channelKeyCS].compactMap({ $0 }) {
            guard let sealedBox = try? AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: Data(nonce)),
                ciphertext: Data(ciphertext),
                tag: Data(tag)
            ), let plaintext = try? AES.GCM.open(sealedBox, using: key) else {
                continue
            }
            return LogiConnInnerFrame(parsing: plaintext)
        }
        return nil
    }

    private func handle(frame: LyraMeshPack.Frame, endpoint: NWEndpoint, reply: LyraMeshSocket.ReplyHandler) {
        lastProgress = Date()
        DiagnosticsLog.info("xiaomi.cast.trust_frame_rx packType=\(frame.packType) bytes=\(frame.payload.count)")
        if frame.packType == 5 {
            // The phone's score-based reuse can land its miLyraShareTransfer
            // receive-flow dial on THIS socket (live 2026-08-27: the cast
            // trust session swallowed the sync_info at stage != .syncAuth
            // and the phone hit its 15s kcp timeout, 連線失敗). The
            // responder claims packType-5 only once it adopted that conn.
            if let responder = LyraMeshResponder.shared,
               responder.handleAnnouncerPayloadV2(frame: frame, endpoint: endpoint)
            {
                return
            }
            handlePayloadV2(frame: frame)
            return
        }
        if frame.packType == 4 {
            handleLogiPayload(frame: frame)
            return
        }
        guard let miFrame = MiConnectFrame(parsing: frame.payload) else {
            return
        }
        if let physConn = miFrame.physConnFrame {
            handlePhysConn(physConn, frame: frame, endpoint: endpoint, reply: reply)
        }
        for logiConn in miFrame.logiConnFrames {
            handleLogiConn(logiConn, frame: frame, endpoint: endpoint, reply: reply)
        }
    }

    private func handlePhysConn(
        _ physConn: PhysConnFrame,
        frame: LyraMeshPack.Frame,
        endpoint: NWEndpoint,
        reply: LyraMeshSocket.ReplyHandler
    ) {
        switch physConn.payload {
        case .syncDeviceInfoResponse:
            if stage == .physSync {
                if let separator = endpoint.debugDescription.lastIndex(of: ":") {
                    let replyHost = String(endpoint.debugDescription[endpoint.debugDescription.startIndex..<separator])
                    // Relay-carried mesh: the pipe presents the peer as a
                    // virtual endpoint (127.0.0.1), which never matches the
                    // LAN-pinned phone IP. The relay session's identity pin
                    // already authenticates the peer, so skip the host pin.
                    if socket is LyraMeshSocket, !Self.isExpectedPhoneHost(replyHost) {
                        DiagnosticsLog.info("xiaomi.cast.trust_endpoint_ignored host=\(replyHost) (not the EdgeLink phone)")
                        return
                    }
                    if let replyPort = UInt16(endpoint.debugDescription[endpoint.debugDescription.index(after: separator)...]),
                       !replyHost.isEmpty
                    {
                        host = replyHost
                        port = replyPort
                        endpoints = [(replyHost, replyPort)]
                        Self.recordPhoneEndpoint("\(replyHost):\(replyPort)")
                        DiagnosticsLog.info("xiaomi.cast.trust_endpoint_locked host=\(replyHost) port=\(replyPort)")
                    }
                }
                progress(.cookie, String(localized: "cookie 交握…"))
                sendCookie(phase: 1)
            }
        case let .keepAliveResponse(responseData) where physConn.field2 == 5:
            guard stage == .cookie else { return }
            let fields = (try? LyraProtoReader.readFields(from: responseData)) ?? []
            var phase: UInt64 = 0
            for field in fields where field.number == 2 && field.wireType == 0 {
                phase = field.varintValue ?? 0
            }
            if phase < 2 {
                sendCookie(phase: phase + 1)
            } else {
                sendSyncAuthHello()
            }
        case .keepAliveRequest:
            let tick = UInt64(LyraMeshSocket.tick())
            var responsePayload = Data()
            LyraProtoWriter.appendVarintField(1, value: tick, to: &responsePayload)
            LyraProtoWriter.appendVarintField(2, value: 2, to: &responsePayload)
            LyraProtoWriter.appendVarintField(3, value: tick, to: &responsePayload)
            let responsePhysConn = PhysConnFrame(field2: 5, payload: .keepAliveResponse(responsePayload))
            let miResponse = MiConnectFrame(version: 0, logiConnFrames: [], physConnFrame: responsePhysConn)
            try? reply(LyraMeshPack.Frame(packType: frame.packType, payload: miResponse.serialized()))
        default:
            break
        }
    }

    private func handleLogiConn(
        _ logiConn: LogiConnFrame,
        frame: LyraMeshPack.Frame,
        endpoint: NWEndpoint,
        reply: LyraMeshSocket.ReplyHandler
    ) {
        // Offer the frame to the MiShare responder before anything else can
        // consume it (the stage-guarded sync_info catch-all, or the encrypted
        // decrypt attempt below): the phone's miLyraShareTransfer dial may be
        // bound to this socket by phys-conn reuse. The responder claims only
        // its adopted conn or a fresh miLyraShareTransfer sync_info; answers
        // ride this socket's reply/send.
        if let responder = LyraMeshResponder.shared,
           responder.handleAnnouncerLogiConn(
               frame: frame, logiConn: logiConn, endpoint: endpoint, reply: reply,
               send: { [weak self] responseFrame in
                   // Sends without a reply context (responseOfPeerPort, sync
                   // announce) must ride the inbound connection (this
                   // listener's port as the source) — a fresh outbound
                   // connection leaves from an ephemeral port the phone's
                   // socket never delivers.
                   self?.socket.sendInboundAsync(
                       frame: responseFrame, toEndpointDescription: endpoint.debugDescription
                   )
               }
           )
        {
            return
        }
        if syncTaskServer.handles(logiConn: logiConn) {
            let replies = syncTaskServer.handleLogiConn(logiConn)
            if !replies.isEmpty {
                let miResponse = MiConnectFrame(version: 0, logiConnFrames: replies)
                let responseFrame = LyraMeshPack.Frame(
                    packType: frame.packType, payload: miResponse.serialized()
                )
                do {
                    try reply(responseFrame)
                } catch {
                    DiagnosticsLog.error("xiaomi.cast.synctask_reply_failed", error)
                }
            }
            return
        }
        if let relaySession = LyraRelayCallSession.activeRelaySession, relaySession.handles(logiConn: logiConn) {
            relaySession.handleFrame(logiConn)
            return
        }
        if let distSession = LyraDistHardwareSession.activeSession, distSession.handles(logiConn: logiConn) {
            distSession.handleFrame(logiConn)
            return
        }
        if let rpcSession = LyraDistAudioRpcSession.activeSession, rpcSession.handles(logiConn: logiConn) {
            rpcSession.handleFrame(logiConn)
            return
        }
        if logiConn.flag {
            if srvConnId != 0, logiConn.logiConnId == srvConnId {
                handleMitrustEncrypted(logiConn)
                return
            }
            guard let inner = decryptLogiConnInner(logiConn) else {
                DiagnosticsLog.warn("xiaomi.cast.trust_logi_enc_decrypt_failed bytes=\(logiConn.inner.count)")
                return
            }
            if case .response = inner.payload {
                DiagnosticsLog.info("xiaomi.cast.trust_logi_response_rx")
                let ack = LogiConnInnerFrame(frameType: 3, payload: .responseAck(Data()))
                sendEncryptedLogiConn(inner: ack, label: "logi_response_ack")
                sendEncryptedAnnounces()
                queue.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    guard let self, !self.cancelled else { return }
                    self.sendPeerPortRequest()
                    self.progress(.channelWait, String(localized: "等待手機通道端口…"))
                }
            } else {
                DiagnosticsLog.info(
                    "xiaomi.cast.trust_logi_enc_other frameType=\(inner.frameType) bytes=\(logiConn.inner.count)"
                )
            }
            return
        }
        guard let inner = LogiConnInnerFrame(parsing: logiConn.inner) else {
            return
        }
        switch inner.payload {
        case let .syncInfo(syncInfoData):
            if isMitrustSyncInfo(syncInfoData) {
                // The phone dialed mitrustservice on THIS session's own phys
                // conn — the channel dial follows this socket's transport.
                mitrustAdoptedViaRelay = isRelayRouted
                handleMitrustSyncInfo(syncInfoData, logiConn: logiConn)
            } else if Self.syncServiceName(of: syncInfoData) == LyraSyncTaskServer.syncServiceName {
                let responseLogiConn = syncTaskServer.handleClassicSyncInfo(
                    syncInfoData: syncInfoData, logiConn: logiConn
                )
                let miResponse = MiConnectFrame(version: 0, logiConnFrames: [responseLogiConn])
                let responseFrame = LyraMeshPack.Frame(
                    packType: frame.packType, payload: miResponse.serialized()
                )
                do {
                    try reply(responseFrame)
                } catch {
                    DiagnosticsLog.error("xiaomi.cast.synctask_sync_info_reply_failed", error)
                }
            } else if Self.syncServiceName(of: syncInfoData) == LyraRelayCallSession.serviceName {
                // TeleService relayCall dials also reuse the live phys conn —
                // adopt them here or channel creation dies at kAuthClient.
                DiagnosticsLog.info(
                    "xiaomi.cast.relaycall_sync_info connId=\(logiConn.logiConnId) " +
                        "peerNetId=\(logiConn.localNetId)"
                )
                LyraRelayCallSession.adopt(
                    syncInfoData: syncInfoData,
                    logiConn: logiConn,
                    endpoint: endpoint,
                    sessionKey: MiTrustTicketStore.current().sessionKey
                ) { [weak self] frame, label in
                    self?.send(frame: frame, label: label)
                }
            } else {
                handleSyncInfoResponse(syncInfoData, logiConn: logiConn)
            }
        case let .upgrade(upgradeData):
            if srvConnId != 0, logiConn.logiConnId == srvConnId {
                handleMitrustUpgrade(upgradeData)
            } else {
                handleUpgradeResponse(upgradeData)
            }
        case let .disconnect(payload):
            DiagnosticsLog.info(
                "xiaomi.cast.trust_logi_disconnect bytes=\(payload.count) " +
                    "hex=\(payload.prefix(32).map { String(format: "%02x", $0) }.joined())"
            )
            if logiConn.logiConnId == logiConnId {
                // The phone released our cast channel (52011 "channel peer
                // sdk release" after idle). Mark it dead — writing into it
                // silently goes nowhere (UDP) and leaves the unlock UI stuck
                // at queryingStatus.
                channelReady = false
                channelSocket?.stop()
                channelSocket = nil
                mirrorCallRelay?.teardown()
                mirrorCallRelay = nil
                DiagnosticsLog.info("xiaomi.cast.trust_channel_released_by_peer")
                let releasedHandler = onChannelReleased
                DispatchQueue.main.async {
                    releasedHandler?()
                }
                // The phone releases the cast logi conn right after the trust
                // exchange but keeps the adopted mitrustservice conn to run
                // the actual 595/546/562 auth on it — finishing here would
                // kill the unlock mid-flight. Only finish when no mitrust
                // conn was adopted; the mirror flow force-rebuilds stale
                // sessions on demand, so this never wedges the next start.
                if srvConnId == 0 {
                    finishLocked()
                }
            }
        default:
            DiagnosticsLog.info(
                "xiaomi.cast.trust_logi_other frameType=\(inner.frameType) bytes=\(logiConn.inner.count)"
            )
        }
    }

    private func sendEncryptedAnnounces() {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let deviceInfo = LyraTrustedDeviceInfo.deviceInfoFrame(
            deviceName: displayName,
            deviceType: 4,
            deviceId: deviceIdHex,
            uidHash: "61F2",
            hwModel: Self.hardwareModel(),
            lyraVersion: "5.1.208.10.fullCnRelease.0512164",
            services: [
                LyraTrustedDeviceInfo.Service(name: "miLyraShare", package: "com.edgelink.mac"),
                LyraTrustedDeviceInfo.Service(name: "miShareBasic", package: "com.edgelink.mac"),
                LyraTrustedDeviceInfo.Service(name: "miLyraShareTransfer", package: "com.edgelink.mac"),
                LyraTrustedDeviceInfo.Service(name: "cast", package: Self.servicePackage)
            ],
            ipAddress: Self.primaryIPv4Address(),
            osVersion: "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
        )
        let inner = LyraTrustedDeviceInfo.plaintextAnnounce(deviceInfo: deviceInfo)
        for (index, key) in syncKeyCandidates.enumerated() {
            do {
                let nonce = AES.GCM.Nonce()
                let sealed = try AES.GCM.seal(inner, using: key, nonce: nonce)
                var payload = Data()
                payload.append(UInt8(peerNetId & 0xFF))
                payload.append(1)
                payload.append(contentsOf: nonce.withUnsafeBytes { Data($0) })
                payload.append(sealed.ciphertext)
                payload.append(sealed.tag)
                send(frame: LyraMeshPack.Frame(packType: 5, payload: payload), label: "announce_c\(index)")
            } catch {
                DiagnosticsLog.error("xiaomi.cast.trust_announce_failed", error)
            }
        }
    }

    private static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }

    private static func primaryIPv4Address() -> String? {
        var address: String?
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return nil }
        defer { freeifaddrs(interfaces) }
        var current = interfaces
        while let interface = current {
            let flags = Int32(interface.pointee.ifa_flags)
            let name = String(cString: interface.pointee.ifa_name)
            if name == "en0", flags & IFF_UP != 0, interface.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(
                    interface.pointee.ifa_addr,
                    socklen_t(interface.pointee.ifa_addr.pointee.sa_len),
                    &host,
                    socklen_t(host.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
                address = String(cString: host)
                break
            }
            current = interface.pointee.ifa_next
        }
        return address
    }

    private func handleSyncInfoResponse(_ data: Data, logiConn: LogiConnFrame) {
        let fields = (try? LyraProtoReader.readFields(from: data)) ?? []
        var serviceName = ""
        var peerCred = Data()
        for field in fields {
            switch (field.number, field.wireType) {
            case (4, 2):
                serviceName = field.lengthDelimitedValue.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            case (5, 2):
                peerCred = field.lengthDelimitedValue ?? Data()
            default:
                continue
            }
        }
        guard stage == .syncAuth else {
            DiagnosticsLog.info(
                "xiaomi.cast.trust_sync_info_ignored stage=\(self.stage) service=\(serviceName)"
            )
            return
        }
        peerNetId = logiConn.localNetId
        DiagnosticsLog.info(
            "xiaomi.cast.trust_sync_info_rx peerNetId=\(peerNetId) service=\(serviceName) credBytes=\(peerCred.count)"
        )
        var peerConnId = Data()
        var peerPubKey = Data()
        for field in (try? LyraProtoReader.readFields(from: peerCred)) ?? [] {
            switch (field.number, field.wireType) {
            case (1, 2): peerConnId = field.lengthDelimitedValue ?? Data()
            case (2, 2): peerPubKey = field.lengthDelimitedValue ?? Data()
            default: continue
            }
        }
        deriveSyncKeys(peerConnId: peerConnId, peerPubKey: peerPubKey)
        sendUpgrade()
    }

    private func deriveSyncKeys(peerConnId: Data, peerPubKey: Data) {
        guard let privateKey = syncAuthPrivateKey, peerPubKey.count == 32,
              let peerKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPubKey),
              let sharedSecret = try? privateKey.sharedSecretFromKeyAgreement(with: peerKey)
        else {
            return
        }
        let secret = sharedSecret.withUnsafeBytes { Data($0) }
        let ours = syncAuthOurConnId
        let their = peerConnId
        let ourPub = privateKey.publicKey.rawRepresentation
        let infos: [Data] = [
            their + ours,
            ours + their,
            peerPubKey + ourPub,
            ourPub + peerPubKey,
            Data()
        ]
        syncKeyCandidates = infos.map {
            HKDF<SHA256>.deriveKey(
                inputKeyMaterial: SymmetricKey(data: secret),
                salt: LyraMeshHkdf.salt,
                info: $0,
                outputByteCount: 32
            )
        }
    }

    private func handleLogiPayload(frame: LyraMeshPack.Frame) {
        let body = frame.payload
        if let miFrame = MiConnectFrame(parsing: body) {
            for logiConn in miFrame.logiConnFrames {
                if let (header, commandBody) = try? LyraChannelProtocol.decode(logiConn.inner) {
                    if header.type == LyraChannelProtocol.CommandType.responseOfPeerPort.rawValue {
                        handlePeerPortResponse(commandBody)
                        return
                    }
                    if header.type == LyraChannelProtocol.CommandType.requestOfPeerPort.rawValue {
                        handleMitrustPeerPortRequest(commandBody)
                        return
                    }
                }
            }
        }
        for headerBytes in 1...2 where body.count > headerBytes + 28 {
            let nonce = body[body.index(body.startIndex, offsetBy: headerBytes)..<body.index(body.startIndex, offsetBy: headerBytes + 12)]
            let ciphertext = body[body.index(body.startIndex, offsetBy: headerBytes + 12)..<body.index(body.endIndex, offsetBy: -16)]
            let tag = body[body.index(body.endIndex, offsetBy: -16)..<body.endIndex]
            guard let sealedBox = try? AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: Data(nonce)),
                ciphertext: Data(ciphertext),
                tag: Data(tag)
            ) else {
                continue
            }
            var keys: [SymmetricKey] = [channelKeySC, channelKeyCS].compactMap { $0 }
            keys.append(contentsOf: syncKeyCandidates)
            keys.append(contentsOf: [srvKeyCS, srvKeySC].compactMap { $0 })
            keys.append(contentsOf: srvKeyCandidates)
            for key in keys {
                guard let plaintext = try? AES.GCM.open(sealedBox, using: key) else {
                    continue
                }
                if let (header, commandBody) = try? LyraChannelProtocol.decode(plaintext) {
                    if header.type == LyraChannelProtocol.CommandType.responseOfPeerPort.rawValue {
                        handlePeerPortResponse(commandBody)
                        return
                    }
                    if header.type == LyraChannelProtocol.CommandType.requestOfPeerPort.rawValue {
                        handleMitrustPeerPortRequest(commandBody)
                        return
                    }
                }
            }
        }
    }

    private func handlePayloadV2(frame: LyraMeshPack.Frame) {
        let body = frame.payload
        guard body.count > 2 else {
            DiagnosticsLog.warn("xiaomi.cast.trust_payload_v2_short bytes=\(body.count)")
            return
        }
        let flag = body[body.index(body.startIndex, offsetBy: 1)]
        if flag == 0 {
            // Official phones send the explicit requestOfPeerPort as a PLAINTEXT
            // payload-v2 frame: [netId][flag=0][16B ChannelProtocol header][body].
            let command = body.subdata(in: body.index(body.startIndex, offsetBy: 2)..<body.endIndex)
            guard let (header, commandBody) = try? LyraChannelProtocol.decode(command) else {
                DiagnosticsLog.warn("xiaomi.cast.trust_payload_v2_plain_decode_failed bytes=\(command.count)")
                return
            }
            mitrustActivityAt = Date()
            DiagnosticsLog.info("xiaomi.cast.trust_payload_v2_plain type=\(header.type) bytes=\(command.count)")
            if header.type == LyraChannelProtocol.CommandType.requestOfPeerPort.rawValue {
                handleMitrustPeerPortRequest(commandBody)
            } else if header.type == LyraChannelProtocol.CommandType.responseOfPeerPort.rawValue {
                handlePeerPortResponse(commandBody)
            }
            return
        }
        guard body.count > 30 else {
            DiagnosticsLog.warn("xiaomi.cast.trust_payload_v2_short bytes=\(body.count)")
            return
        }
        let nonce = body[body.index(body.startIndex, offsetBy: 2)..<body.index(body.startIndex, offsetBy: 14)]
        let ciphertext = body[body.index(body.startIndex, offsetBy: 14)..<body.index(body.endIndex, offsetBy: -16)]
        let tag = body[body.index(body.endIndex, offsetBy: -16)..<body.endIndex]
        guard let sealedBox = try? AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: Data(nonce)),
            ciphertext: Data(ciphertext),
            tag: Data(tag)
        ) else {
            DiagnosticsLog.warn("xiaomi.cast.trust_payload_v2_sealed_box_invalid bytes=\(body.count)")
            return
        }
        var keys: [SymmetricKey] = [channelKeySC, channelKeyCS].compactMap { $0 }
        keys.append(contentsOf: syncKeyCandidates)
        keys.append(contentsOf: [srvKeyCS, srvKeySC].compactMap { $0 })
        keys.append(contentsOf: srvKeyCandidates)
        for key in keys {
            guard let plaintext = try? AES.GCM.open(sealedBox, using: key) else {
                continue
            }
            guard let (header, commandBody) = try? LyraChannelProtocol.decode(plaintext) else {
                DiagnosticsLog.warn("xiaomi.cast.trust_payload_v2_decode_failed bytes=\(plaintext.count)")
                return
            }
            if header.type == LyraChannelProtocol.CommandType.responseOfPeerPort.rawValue {
                handlePeerPortResponse(commandBody)
            } else if header.type == LyraChannelProtocol.CommandType.requestOfPeerPort.rawValue {
                handleMitrustPeerPortRequest(commandBody)
            } else {
                DiagnosticsLog.info("xiaomi.cast.trust_payload_v2_unknown_type type=\(header.type)")
            }
            return
        }
        DiagnosticsLog.warn("xiaomi.cast.trust_payload_v2_decrypt_failed bytes=\(body.count) keys=\(keys.count)")
    }

    private func sendPeerPortRequest() {
        guard let channelKeyCS else { return }
        var body = Data()
        LyraProtoWriter.appendVarintField(1, value: UInt64(channelId), to: &body)
        LyraProtoWriter.appendLengthDelimitedField(4, value: transKey, to: &body)
        LyraProtoWriter.appendLengthDelimitedField(5, value: transRandom, to: &body)
        let command = LyraChannelProtocol.encode(type: .requestOfPeerPort, body: body)
        do {
            let nonce = AES.GCM.Nonce()
            let sealed = try AES.GCM.seal(command, using: channelKeyCS, nonce: nonce)
            var payload = Data()
            payload.append(UInt8(peerNetId & 0xFF))
            payload.append(1)
            payload.append(contentsOf: nonce.withUnsafeBytes { Data($0) })
            payload.append(sealed.ciphertext)
            payload.append(sealed.tag)
            send(frame: LyraMeshPack.Frame(packType: 5, payload: payload), label: "peer_port_request")
        } catch {
            DiagnosticsLog.error("xiaomi.cast.trust_peer_port_request_failed", error)
        }
    }

    private func handlePeerPortResponse(_ body: Data) {
        guard stage == .channelWait || stage == .logiConnRequest else {
            return
        }
        let fields = (try? LyraProtoReader.readFields(from: body)) ?? []
        var port: UInt64 = 0
        var serverChannelId: UInt64 = 0
        for field in fields {
            switch (field.number, field.wireType) {
            case (2, 0): serverChannelId = field.varintValue ?? 0
            case (3, 0): port = field.varintValue ?? 0
            default: continue
            }
        }
        guard port != 0, let nwPort = UInt16(exactly: port) else {
            DiagnosticsLog.warn("xiaomi.cast.trust_peer_port_invalid")
            return
        }
        self.serverChannelId = UInt32(serverChannelId)
        progress(.channelNegotiate, String(localized: "通道協商…"))
        DiagnosticsLog.info("xiaomi.cast.trust_peer_port port=\(port) serverChannelId=\(serverChannelId)")
        let socket: LyraChannelDatagramPipe = channelTransport ?? LyraChannelSocket()
        if let nativeSocket = socket as? LyraChannelSocket {
            nativeSocket.suppressNegotiationReply = true
            nativeSocket.debugHandler = { message in
                DiagnosticsLog.info("xiaomi.cast.trust_channel.\(message)")
            }
            nativeSocket.onDecryptFailure = { reason in
                DiagnosticsLog.warn("xiaomi.cast.trust_channel_decrypt_failed \(reason)")
            }
        }
        socket.onNegotiated = { [weak self] serverChannelId, mtu in
            // A cancelled session must not resurrect: pipe teardown is async,
            // so in-flight datagrams can still complete the negotiation after
            // cancel() — the ghost "ready" fires onChannelReady into a dead
            // session and steals the mirror flow from its replacement (live
            // 2026-08-08: double 通道已建立 in the same second as a release).
            guard let self, !self.cancelled else { return }
            DiagnosticsLog.info("xiaomi.cast.trust_channel_negotiated serverChannelId=\(serverChannelId) mtu=\(mtu)")
            self.channelReady = true
            self.channelWasEstablishedBefore = true
            if self.mirrorCallRelay == nil {
                self.mirrorCallRelay = LyraMirrorCallRelaySession { [weak self] type, payload in
                    self?.sendCastMessage(type: type, payload: payload)
                }
                // Official pads send their KeyData proactively on channel
                // setup; the phone does not always re-send its own.
                self.mirrorCallRelay?.start()
            }
            self.progress(.ready, String(localized: "通道已建立"))
            let readyHandler = self.onChannelReady
            DispatchQueue.main.async {
                readyHandler?()
                self.trustManager.sendFrame = { [weak self] frame in
                    self?.sendChannelMessage(frame)
                }
                self.trustManager.onAuthActionSent = { [weak self] in
                    self?.queue.asyncAfter(deadline: .now() + 10.0) { [weak self] in
                        self?.teardownPhysAfterAuth()
                    }
                }
                self.trustManager.onAuthEventHandled = { [weak self] in
                    self?.queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        self?.teardownPhysAfterAuth()
                    }
                }
                if self.duoScreenStatusEnabled {
                    self.trustManager.start()
                }
            }
        }
        socket.onMessage = { [weak self] message, _ in
            self?.handleChannelMessage(message)
        }
        do {
            try socket.connect(host: host, port: nwPort, socketKey: transKey)
            channelSocket = socket
        } catch {
            fail(String(localized: "通道連接失敗"))
            return
        }
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.sendChannelNegotiation(attempt: 0)
        }
    }

    private func sendChannelNegotiation(attempt: Int) {
        guard !cancelled, !channelReady, attempt < 3, let socket = channelSocket else { return }
        do {
            try socket.sendClientNegotiation(channelId: serverChannelId, version: 1, mtu: 0xFF00)
        } catch {
            DiagnosticsLog.error("xiaomi.cast.trust_channel_negotiation_failed", error)
        }
        queue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.sendChannelNegotiation(attempt: attempt + 1)
        }
    }

    private func sendChannelMessage(_ message: Data) {
        do {
            try channelSocket?.sendVariant(
                channelFrame: LyraChannelSocket.wrapChannelFrame(message),
                key: transKey,
                singleLayer: true
            )
        } catch {
            DiagnosticsLog.error("xiaomi.cast.trust_channel_send_failed", error)
        }
    }

    // Sends a MessageCodec-framed cast-channel message (screen action, simple
    // event, capabilities) through the same channel path DuoScreen uses.
    func sendCastMessage(type: UInt8, payload: Data) {
        sendChannelMessage(LyraCastMessageCodec.encodeFrame(type: type, payload: payload))
    }

    func sendScreenAction(_ action: LyraCastScreenAction) {
        sendCastMessage(type: LyraCastMessageType.screenAction, payload: action.encode())
        DiagnosticsLog.info(
            "xiaomi.cast.screen_action_tx action=\(action.action) sessionId=\(action.sessionId) screenId=\(action.screenId)"
        )
    }

    func sendKeyboard(_ message: LyraCastKeyboard) {
        sendCastMessage(type: LyraCastMessageType.keyboard, payload: message.encode())
    }

    func sendMouse(_ message: LyraCastMouse) {
        sendCastMessage(type: LyraCastMessageType.mouse, payload: message.encode())
    }

    func sendCommand(_ message: LyraCastCommand) {
        sendCastMessage(type: LyraCastMessageType.command, payload: message.encode())
    }

    private func handleChannelMessage(_ message: Data) {
        lastProgress = Date()
        var frame = message
        if let (tag, child) = try? LyraExpressTLVParser.parseOneOf(message), tag == 1,
           let payloadNode = LyraExpressTLVParser.firstChild(0, in: LyraExpressTLVParser.children(of: child))
        {
            frame = payloadNode.payload
        }
        guard let (type, payload) = try? DuoScreenProtocolV1.decodeFrame(frame) else {
            DiagnosticsLog.warn(
                "xiaomi.cast.trust_channel_rx_bad bytes=\(message.count) " +
                    "hex=\(message.prefix(24).map { String(format: "%02x", $0) }.joined())"
            )
            return
        }
        DiagnosticsLog.info("xiaomi.cast.trust_channel_rx type=\(type) bytes=\(frame.count)")
        if type == DuoScreenProtocolV1.typeTrust {
            DispatchQueue.main.async { [weak self] in
                self?.trustManager.handleFrame(frame)
            }
        } else {
            if type == LyraCastMessageType.simpleEvent,
               let event = try? LyraCastSimpleEvent.decode(payload)
            {
                mirrorCallRelay?.handleSimpleEvent(event)
            }
            DispatchQueue.main.async { [weak self] in
                self?.onCastMessage?(type, payload)
            }
        }
    }
}
