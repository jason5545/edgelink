import CryptoKit
import EdgeLinkKit
import Foundation
import Network

// The phone's cast (妙享桌面) endpoint: accepts the Mac's
// com.xiaomi.mirror:cast dial (X25519 sync-auth cred + P256 upgrade →
// AES-GCM channel keys), serves the encrypted cast channel (TLV negotiation,
// duo.screen trust messages, keyboard/mouse, screen actions), and sources
// the WFD RTSP stream with UDP video when the mirror screen opens.
//
// Ported from FakeXiaomiPhone (mirror E2E harness) so the standalone
// lyra-server can serve screen sharing; behavior hooks mirror it 1:1.
public final class LyraCastRole: LyraServiceHandler {
    public static let castServiceName = "com.xiaomi.mirror:cast"
    public let serviceName = LyraCastRole.castServiceName

    public var onEvent: (String) -> Void = { _ in }

    // MARK: - Assertion surface / behavior hooks

    public private(set) var locked: Bool
    public private(set) var statusActionCount = 0
    public private(set) var authActionCount = 0
    public private(set) var verifyActionCount = 0
    public private(set) var bindActionCount = 0
    public private(set) var openMirrorScreenCount = 0
    public private(set) var openMirrorScreenTotal = 0
    public private(set) var closeScreenCount = 0
    public private(set) var wfdSessionEstablished = false
    public private(set) var wfdPlayCount = 0
    public private(set) var videoDatagramsSent = 0
    public private(set) var idrRequestCount = 0
    public private(set) var mitrustBindCompleted = false
    public private(set) var mitrustUnlockCompleted = false
    public private(set) var mitrustUnlockCount = 0
    public private(set) var lastAuthTokenA: Data?

    public var bound = true
    public var conflictingStatus = false
    public var truthfulAfterQueries: Int?
    public var wfdServerStartupDelay: TimeInterval = 0
    public var withholdVideoUntilIDRRequest = false
    public var releaseChannelAfterOpenCount = 0
    public var releaseChannelAfterOpenDelay: TimeInterval = 0.2

    public func setLocked(_ value: Bool) {
        locked = value
    }

    // Raw cast-channel frame hook (type, payload after LyraCastMessageCodec
    // decode): lets sibling roles (mirror-call relay) ride the same channel.
    public var onCastFrame: ((UInt8, Data) -> Void)?

    public let castChannelPort: UInt16
    public let wfdPort: UInt16
    public let clientVideoPort: UInt16

    private let identity: LyraPhoneIdentity
    private weak var server: LyraPhoneMeshServer?
    private let queue = DispatchQueue(label: "LyraCastRole")
    // Relay-transport harness: the cast channel rides this pipe (cloud-relay
    // path) instead of the local UDP listener when set.
    private let channelTransport: LyraChannelDatagramPipe?
    private var channelTransportStarted = false

    public init(
        identity: LyraPhoneIdentity,
        castChannelPort: UInt16 = 0,
        wfdPort: UInt16 = 7236,
        clientVideoPort: UInt16 = 15_550,
        locked: Bool = true,
        channelTransport: LyraChannelDatagramPipe? = nil
    ) {
        self.identity = identity
        self.castChannelPort = castChannelPort
        self.wfdPort = wfdPort
        self.clientVideoPort = clientVideoPort
        self.locked = locked
        self.channelTransport = channelTransport
    }

    // MARK: - Conn state

    private var connId: UInt32 = 0
    private var peerNetId: UInt32 = 1
    private var channelKeyCS: SymmetricKey?
    private var channelKeySC: SymmetricKey?
    private var castTransKey = Data()
    private var castChannelId: UInt64 = 0

    // MARK: - LyraServiceHandler

    public func handleServiceSyncInfo(
        syncInfoData: Data, logiConn: LogiConnFrame, server: LyraPhoneMeshServer
    ) {
        self.server = server
        connId = logiConn.logiConnId
        peerNetId = logiConn.localNetId
        let phoneConnId = randomBytes(8)
        let phoneKey = Curve25519.KeyAgreement.PrivateKey()
        var cred = Data()
        LyraProtoWriter.appendLengthDelimitedField(1, value: phoneConnId, to: &cred)
        LyraProtoWriter.appendLengthDelimitedField(2, value: phoneKey.publicKey.rawRepresentation, to: &cred)
        var syncInfo = Data()
        LyraProtoWriter.appendVarintField(1, value: 15000, to: &syncInfo)
        LyraProtoWriter.appendVarintField(2, value: 48, to: &syncInfo)
        LyraProtoWriter.appendVarintField(3, value: 1, to: &syncInfo)
        LyraProtoWriter.appendLengthDelimitedField(4, value: Data(Self.castServiceName.utf8), to: &syncInfo)
        LyraProtoWriter.appendLengthDelimitedField(5, value: cred, to: &syncInfo)
        let inner = LogiConnInnerFrame(frameType: 5, payload: .syncInfo(syncInfo))
        server.sendLogi(connId: connId, inner: inner)
        listenCastChannel()
        onEvent("cast sync_info answered connId=\(connId)")
    }

    public func handleServiceLogiConn(_ logiConn: LogiConnFrame, server: LyraPhoneMeshServer) {
        if logiConn.logiConnId == mitrustConnId, mitrustConnId != 0 {
            handleMitrustLogiConn(logiConn, server: server)
            return
        }
        if logiConn.flag {
            handleEncryptedLogiConn(logiConn, server: server)
            return
        }
        guard let inner = LogiConnInnerFrame(parsing: logiConn.inner) else { return }
        if case let .upgrade(data) = inner.payload {
            handleCastUpgrade(data, server: server)
        }
    }

    private func handleCastUpgrade(_ data: Data, server: LyraPhoneMeshServer) {
        guard let handshakeFrame = lengthDelimited(2, in: data),
              let handshakeId = varint(1, in: data),
              let pairFrame = lengthDelimited(8, in: handshakeFrame),
              let clientNotify = lengthDelimited(2, in: pairFrame),
              let cipherSuite = lengthDelimited(1, in: clientNotify),
              let clientRandom = lengthDelimited(2, in: cipherSuite),
              let publicKeyMessage = lengthDelimited(5, in: cipherSuite),
              let publicKey = lengthDelimited(2, in: publicKeyMessage),
              let peerKey = try? P256.KeyAgreement.PublicKey(x963Representation: publicKey)
        else {
            onEvent("cast upgrade parse failed")
            return
        }
        let phoneKey = P256.KeyAgreement.PrivateKey()
        guard let secret = try? phoneKey.sharedSecretFromKeyAgreement(with: peerKey)
            .withUnsafeBytes({ Data($0) })
        else { return }
        let serverRandom = randomBytes(32)
        channelKeyCS = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            salt: LyraMeshHkdf.salt,
            info: clientRandom + serverRandom,
            outputByteCount: 32
        )
        channelKeySC = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            salt: LyraMeshHkdf.salt,
            info: serverRandom + clientRandom,
            outputByteCount: 32
        )
        var outPkMsg = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &outPkMsg)
        LyraProtoWriter.appendLengthDelimitedField(2, value: phoneKey.publicKey.x963Representation, to: &outPkMsg)
        var outCipher = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &outCipher)
        LyraProtoWriter.appendLengthDelimitedField(2, value: serverRandom, to: &outCipher)
        LyraProtoWriter.appendVarintField(3, value: 32, to: &outCipher)
        LyraProtoWriter.appendVarintField(4, value: 2, to: &outCipher)
        LyraProtoWriter.appendLengthDelimitedField(5, value: outPkMsg, to: &outCipher)
        var serverNotify = Data()
        LyraProtoWriter.appendLengthDelimitedField(1, value: outCipher, to: &serverNotify)
        var outPair = Data()
        LyraProtoWriter.appendLengthDelimitedField(3, value: serverNotify, to: &outPair)
        var handshake = Data()
        LyraProtoWriter.appendVarintField(1, value: 5, to: &handshake)
        LyraProtoWriter.appendVarintField(2, value: 6, to: &handshake)
        LyraProtoWriter.appendLengthDelimitedField(8, value: outPair, to: &handshake)
        var authFrame = Data()
        LyraProtoWriter.appendVarintField(1, value: handshakeId, to: &authFrame)
        LyraProtoWriter.appendLengthDelimitedField(2, value: handshake, to: &authFrame)
        let inner = LogiConnInnerFrame(frameType: 6, payload: .upgrade(authFrame))
        server.sendLogi(connId: connId, inner: inner)
        onEvent("cast upgrade answered")
    }

    private func handleEncryptedLogiConn(_ logiConn: LogiConnFrame, server: LyraPhoneMeshServer) {
        guard let key = channelKeyCS, let innerData = gcmOpen(logiConn.inner, key: key),
              let frame = LogiConnInnerFrame(parsing: innerData)
        else { return }
        if case let .request(requestData) = frame.payload {
            let privateData = lengthDelimited(3, in: requestData) ?? Data()
            if let peerPortRequest = lengthDelimited(10, in: privateData) {
                let fields = (try? LyraProtoReader.readFields(from: peerPortRequest)) ?? []
                for field in fields {
                    switch field.number {
                    case 1: castChannelId = field.varintValue ?? 0
                    case 4: castTransKey = field.lengthDelimitedValue ?? Data()
                    default: break
                    }
                }
                startChannelTransportIfNeeded()
            }
            guard let scKey = channelKeySC else { return }
            var responseData = Data()
            LyraProtoWriter.appendVarintField(1, value: 1, to: &responseData)
            let response = LogiConnInnerFrame(frameType: 2, payload: .response(responseData))
            guard let sealed = gcmSeal(response.serialized(), key: scKey) else { return }
            let responseConn = LogiConnFrame(
                logiConnId: connId, localNetId: identity.netId, remoteNetId: peerNetId,
                flag: true, inner: sealed
            )
            let miFrame = MiConnectFrame(version: 0, logiConnFrames: [responseConn])
            server.sendToPeer(frame: LyraMeshPack.Frame(packType: 2, payload: miFrame.serialized()))
            onEvent("cast logi response sent channelId=\(castChannelId)")
        }
    }

    // packType-5: the Mac's requestOfPeerPort arrives encrypted with the
    // cast channel key; answer with the cast channel port.
    public func handleServiceMeshCommand(payload: Data, server: LyraPhoneMeshServer) -> Bool {
        guard payload.count > 14, payload[payload.index(after: payload.startIndex)] == 1,
              let key = channelKeyCS
        else { return false }
        let body = Data(payload.dropFirst(2))
        guard let command = gcmOpen(body, key: key),
              let (header, commandBody) = try? LyraChannelProtocol.decode(command),
              header.type == LyraChannelProtocol.CommandType.requestOfPeerPort.rawValue
        else { return false }
        // The same channelId/transKey also ride the logi request; parse them
        // here too so the relay-carried channel starts whichever lands first.
        for field in (try? LyraProtoReader.readFields(from: commandBody)) ?? [] {
            switch field.number {
            case 1: castChannelId = field.varintValue ?? castChannelId
            case 4: castTransKey = field.lengthDelimitedValue ?? castTransKey
            default: break
            }
        }
        startChannelTransportIfNeeded()
        var responseBody = Data()
        LyraProtoWriter.appendVarintField(2, value: castChannelId, to: &responseBody)
        LyraProtoWriter.appendVarintField(3, value: UInt64(effectiveCastChannelPort), to: &responseBody)
        let response = LyraChannelProtocol.encode(type: .responseOfPeerPort, body: responseBody)
        guard let scKey = channelKeySC, let sealed = gcmSeal(response, key: scKey) else { return true }
        var out = Data()
        out.append(payload[payload.startIndex])
        out.append(1)
        out.append(sealed)
        server.sendToPeer(frame: LyraMeshPack.Frame(packType: 5, payload: out))
        onEvent("cast peer port answered port=\(effectiveCastChannelPort)")
        return true
    }

    private var effectiveCastChannelPort: UInt16 {
        if castChannelPort != 0 {
            return castChannelPort
        }
        // Relay-carried channel: the port is decorative (the Mac dials through
        // the transport pipe, not a real UDP port) — report the pipe's bound
        // port so the peer-port answer is non-zero.
        if channelTransportStarted, let pipePort = channelTransport?.boundPort {
            return pipePort
        }
        return channelListener?.port?.rawValue ?? 0
    }

    // Simulates the phone releasing the cast logi conn mid-stream (the
    // unencrypted inner disconnect payload {1: 52011}).
    public func releaseCastChannel() {
        guard let server, connId != 0 else { return }
        let payload = Data([0x08, 0xAB, 0x96, 0x03])
        let inner = LogiConnInnerFrame(frameType: 4, payload: .disconnect(payload))
        server.sendLogi(connId: connId, inner: inner)
        openMirrorScreenCount = 0
    }

    // MARK: - Cast channel server

    private var channelListener: NWListener?
    private var channelConnection: NWConnection?
    private var channelSendSn: UInt32 = 0
    private var channelRecvUna: UInt32 = 0
    private var stopped = false

    // Starts the relay-carried channel pipe once the trans key is known
    // (logi request or packType-5 peer-port request). The pipe answers the
    // plaintext negotiation TLV itself; decoded channel frames land in
    // handleChannelPipeMessage.
    private func startChannelTransportIfNeeded() {
        guard let transport = channelTransport, !channelTransportStarted,
              !castTransKey.isEmpty
        else { return }
        channelTransportStarted = true
        transport.onNegotiated = { [weak self] channelId, mtu in
            self?.onEvent("cast channel negotiated channelId=\(channelId) mtu=\(mtu)")
        }
        transport.onMessage = { [weak self] message, _ in
            self?.handleChannelPipeMessage(message)
        }
        do {
            try transport.start(socketKey: castTransKey, serverChannelId: UInt32(castChannelId))
            onEvent("cast channel transport started")
        } catch {
            channelTransportStarted = false
            onEvent("cast channel transport start failed: \(error)")
        }
    }

    private func handleChannelPipeMessage(_ message: Data) {
        guard let (tag, child) = try? LyraExpressTLVParser.parseOneOf(message), tag == 1,
              let payloadNode = LyraExpressTLVParser.firstChild(
                  0, in: LyraExpressTLVParser.children(of: child)
              )
        else { return }
        handleDecodedChannelFrame(payloadNode.payload)
    }

    private func listenCastChannel() {
        guard channelListener == nil, channelTransport == nil else { return }
        let nwPort = castChannelPort != 0 ? NWEndpoint.Port(rawValue: castChannelPort) : nil
        let listener = try? NWListener(using: .udp, on: nwPort ?? .any)
        listener?.newConnectionHandler = { [weak self] connection in
            self?.queue.async {
                guard let self else { return }
                self.channelConnection?.cancel()
                self.channelConnection = connection
                self.channelSendSn = 0
                self.channelRecvUna = 0
                connection.start(queue: self.queue)
                self.receiveChannel(on: connection)
            }
        }
        listener?.start(queue: queue)
        channelListener = listener
    }

    private func receiveChannel(on connection: NWConnection) {
        connection.receiveMessage { [weak self] content, _, _, error in
            guard let self else { return }
            if let content, !content.isEmpty,
               let segment = try? LyraMeshDatagram.decodeSegment(content),
               segment.command == LyraMeshDatagram.commandPush
            {
                let isDuplicate = segment.sn < self.channelRecvUna
                if !isDuplicate {
                    self.channelRecvUna = segment.sn &+ 1
                    self.handleChannelPayload(segment.payload)
                }
            }
            if error == nil, !self.stopped {
                self.receiveChannel(on: connection)
            }
        }
    }

    private func sendChannel(_ payload: Data) {
        let datagram = LyraMeshDatagram.encode(
            tick: LyraMeshSocket.tick(), sn: channelSendSn, una: channelRecvUna, payload: payload
        )
        channelSendSn &+= 1
        channelConnection?.send(content: datagram, completion: .idempotent)
    }

    private func handleChannelPayload(_ payload: Data) {
        let bytes = Array(payload)
        if bytes.count >= 2, bytes[0] == 0x01, bytes[1] == 0x01 {
            guard bytes.count >= 18 else { return }
            let channelId = readUInt32BE(payload, at: 26)
            let reply = LyraExpressTLV.oneOfNode(
                tag: 0xFFFF,
                selectedTag: 4,
                child: LyraExpressTLV.containerNode(tag: 4, children: [
                    LyraExpressTLV.int32Node(tag: 0, value: channelId),
                    LyraExpressTLV.int32Node(tag: 1, value: 0xFF00),
                ])
            )
            sendChannel(reply)
            return
        }
        guard bytes.count >= 2, bytes[0] == 0x81, bytes[1] == 0x04,
              let decodedPacket = try? LyraSocketPacket.decode(
                  Data(payload), key: SymmetricKey(data: castTransKey)
              ),
              let (tag, child) = try? LyraExpressTLVParser.parseOneOf(decodedPacket.plaintext),
              tag == 1,
              let payloadNode = LyraExpressTLVParser.firstChild(
                  0, in: LyraExpressTLVParser.children(of: child)
              )
        else { return }
        handleDecodedChannelFrame(payloadNode.payload)
    }

    private func handleDecodedChannelFrame(_ message: Data) {
        guard let (type, framePayload) = try? LyraCastMessageCodec.decodeFrame(message) else { return }
        onCastFrame?(type, framePayload)
        switch type {
        case LyraCastMessageType.trust:
            handleTrustFrame(framePayload)
        case LyraCastMessageType.screenAction:
            guard let action = try? LyraCastScreenAction.decode(framePayload) else { return }
            onEvent("cast screen_action \(action.action)")
            if action.action == LyraCastScreenAction.Action.openMirrorScreen.rawValue {
                openMirrorScreenCount += 1
                openMirrorScreenTotal += 1
                if releaseChannelAfterOpenCount > 0 {
                    releaseChannelAfterOpenCount -= 1
                    queue.asyncAfter(deadline: .now() + releaseChannelAfterOpenDelay) { [weak self] in
                        self?.releaseCastChannel()
                    }
                }
                if wfdListener != nil {
                    tearDownWFDServer()
                    queue.asyncAfter(deadline: .now() + 0.3 + wfdServerStartupDelay) { [weak self] in
                        self?.startWFDServer()
                    }
                    return
                }
                guard wfdServerStartupDelay > 0 else {
                    startWFDServer()
                    return
                }
                queue.asyncAfter(deadline: .now() + wfdServerStartupDelay) { [weak self] in
                    self?.startWFDServer()
                }
            } else if action.action == LyraCastScreenAction.Action.closeScreen.rawValue {
                closeScreenCount += 1
                tearDownWFDServer()
            }
        default:
            break
        }
    }

    // Public wrapper so sibling roles (mirror-call relay) can push their own
    // duo.screen frames over the established cast channel.
    public func sendCastFrame(type: UInt8, payload: Data) {
        queue.async { [weak self] in
            self?.sendChannelMessage(type: type, payload: payload)
        }
    }

    private func sendChannelMessage(type: UInt8, payload: Data) {
        let frame = LyraChannelSocket.wrapChannelFrame(LyraCastMessageCodec.encodeFrame(type: type, payload: payload))
        if let transport = channelTransport, channelTransportStarted {
            try? transport.sendVariant(channelFrame: frame, key: castTransKey, singleLayer: true)
            return
        }
        guard let packet = try? LyraSocketPacket.encode(
            plaintext: frame, key: SymmetricKey(data: castTransKey)
        ) else { return }
        sendChannel(packet)
    }

    // MARK: - duo.screen trust

    private func sendStatusEvent(sessionID: UInt64, keyguardOverride: Int32? = nil, enableOverride: Int32? = nil) {
        var auth = TrustAuthStatus()
        auth.features = [DuoScreenTrustFeature.unlockDevice]
        auth.enableStatus = enableOverride ?? DuoScreenTrustEnableStatus.enabled.rawValue
        auth.bindStatus = (bound ? DuoScreenTrustBindStatus.bound : DuoScreenTrustBindStatus.notBound).rawValue
        var event = TrustStatusEvent()
        event.code = DuoScreenTrustCode.success
        event.localKeyguardStatus = DuoScreenKeyguardStatus.valid
        event.remoteKeyguardStatus = keyguardOverride ?? (locked ? 1 : DuoScreenKeyguardStatus.valid)
        event.auth = auth
        sendChannelMessage(type: LyraCastMessageType.trust, payload: DuoScreenTrustProto.encode(
            DuoScreenTrust(sessionID: sessionID, msg: .statusEvent(event))
        ))
    }

    private func handleTrustFrame(_ payload: Data) {
        guard let trust = try? DuoScreenTrustProto.decode(payload), let msg = trust.msg else { return }
        switch msg {
        case .statusAction:
            statusActionCount += 1
            let lying = conflictingStatus
                && (truthfulAfterQueries == nil || statusActionCount <= truthfulAfterQueries!)
            if lying {
                var denied = TrustStatusEvent()
                denied.code = DuoScreenTrustCode.disabledBySetting
                sendChannelMessage(type: LyraCastMessageType.trust, payload: DuoScreenTrustProto.encode(
                    DuoScreenTrust(sessionID: trust.sessionID, msg: .statusEvent(denied))
                ))
                queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.sendStatusEvent(
                        sessionID: trust.sessionID,
                        keyguardOverride: DuoScreenKeyguardStatus.valid,
                        enableOverride: DuoScreenTrustEnableStatus.unset.rawValue
                    )
                }
            } else {
                sendStatusEvent(sessionID: trust.sessionID)
            }
        case .bindAction(let action):
            guard action.feature == DuoScreenTrustFeature.unlockDevice else { return }
            bindActionCount += 1
            bound = true
            var event = TrustBindEvent()
            event.feature = DuoScreenTrustFeature.unlockDevice
            event.code = DuoScreenTrustCode.success
            sendChannelMessage(type: LyraCastMessageType.trust, payload: DuoScreenTrustProto.encode(
                DuoScreenTrust(sessionID: trust.sessionID, msg: .bindEvent(event))
            ))
            sendStatusEvent(sessionID: trust.sessionID)
        case .verifyAction(let action):
            guard action.feature == DuoScreenTrustFeature.unlockDevice else { return }
            verifyActionCount += 1
            let event = TrustVerifyEvent(feature: DuoScreenTrustFeature.unlockDevice, code: DuoScreenTrustCode.success)
            sendChannelMessage(type: LyraCastMessageType.trust, payload: DuoScreenTrustProto.encode(
                DuoScreenTrust(sessionID: trust.sessionID, msg: .verifyEvent(event))
            ))
        case .authAction(let action):
            guard action.feature == DuoScreenTrustFeature.unlockDevice else { return }
            authActionCount += 1
            if !locked {
                let event = TrustAuthEvent(feature: DuoScreenTrustFeature.unlockDevice, code: DuoScreenTrustCode.success)
                sendChannelMessage(type: LyraCastMessageType.trust, payload: DuoScreenTrustProto.encode(
                    DuoScreenTrust(sessionID: trust.sessionID, msg: .authEvent(event))
                ))
            } else {
                // The real phone's trustservice answers the 562 authAction by
                // dialing the Mac's mitrustservice and driving the
                // 595/546/562 JSON auth on the adopted channel.
                runMitrustUnlock()
            }
        default:
            break
        }
    }

    // MARK: - mitrustservice adoption (phone-initiated, like the real phone)
    //
    // Ported from FakeXiaomiPhone: after the Mac's duo.screen authAction the
    // phone's trustservice dials com.xiaomi.trustservice:mitrustservice,
    // upgrades with KeyAgree (P256 ECDH + HKDF), requests a peer port, and
    // drives the 595/546/562 JSON auth on the adopted channel. On 563 the
    // phone verifies auth_token_A, unlocks, and reports the auth event.

    private var mitrustConnId: UInt32 = 0
    private var mitrustKeyAgreePriv: P256.KeyAgreement.PrivateKey?
    private var mitrustClientRandom = Data()
    private var mitrustSessionKey: SymmetricKey?
    private var mitrustTransKey = Data()
    private let mitrustClientChannelId: UInt64 = 13
    private var mitrustServerPort: UInt16 = 0
    private var mitrustConnection: NWConnection?
    // Relay-path mitrust channel: when set, the mitrust channel client rides
    // a virtual channel pipe from this factory (keyed by the advertised
    // server port) instead of a loopback UDP socket — the exact route the
    // real phone takes when the session is relay-carried (the phone bridge's
    // reverse listener stamps the dialed port onto each envelope).
    public var mitrustChannelFactory: ((UInt16) -> LyraChannelDatagramPipe?)?
    // Models the real phone's score-based phys-conn reuse dialing the
    // mitrustservice adoption on the ANNOUNCE conn instead of the cast conn
    // (live 2026-08-12: the Mac announcer dropped those sync_infos as
    // announcer_stray_conn and the unlock never reached the mitrust server).
    public var mitrustMeshServerOverride: LyraPhoneMeshServer?
    // Models the real phone's relay-path channel client (HeteroChannel
    // quick-conn) speaking ONLY the official 82 58 packet format on the
    // mitrust channel (live 2026-08-11). Applies to the pipe dial path.
    public var mitrustSpeaksOfficial = false
    private var mitrustPipe: LyraChannelDatagramPipe?
    private var mitrustSendSn: UInt32 = 0
    private var mitrustRecvUna: UInt32 = 0
    private var mitrustSessionKeyHex: String?
    private var saidB = Data()

    // Live 2026-08-13: when the 562's mitrust channel never completes (the
    // Mac advertised an endpoint this phys conn's transport can't reach),
    // the phone's channel client kcp-times-out ~10s after the authAction and
    // the authEvent comes back code=1 (terminalAlt) — the alternating
    // success/code=1 pattern depended on which phys conn carried the
    // adoption. 0 disables the watchdog (ceremony always completes in tests
    // that never exercise the stuck path within the default window).
    public var mitrustUnlockTimeout: TimeInterval = 10
    private var mitrustUnlockEpoch: UInt64 = 0
    private var mitrustRunCompleted = false
    public private(set) var mitrustUnlockTimedOutCount = 0

    private func runMitrustUnlock() {
        mitrustUnlockEpoch &+= 1
        let epoch = mitrustUnlockEpoch
        mitrustRunCompleted = false
        queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.startMitrustAdoption()
        }
        queue.asyncAfter(deadline: .now() + mitrustUnlockTimeout) { [weak self] in
            guard let self, !self.stopped,
                  self.mitrustUnlockEpoch == epoch, !self.mitrustRunCompleted
            else { return }
            self.mitrustUnlockTimedOutCount += 1
            self.onEvent("mitrust unlock stuck → authEvent code=1 (kcp trans timeout)")
            let event = TrustAuthEvent(
                feature: DuoScreenTrustFeature.unlockDevice, code: DuoScreenTrustCode.terminalAlt
            )
            self.sendChannelMessage(type: LyraCastMessageType.trust, payload: DuoScreenTrustProto.encode(
                DuoScreenTrust(sessionID: 0, msg: .authEvent(event))
            ))
        }
    }

    private func startMitrustAdoption() {
        guard let server = mitrustMeshServerOverride ?? server else { return }
        mitrustConnId = UInt32.random(in: 1...UInt32.max)
        // Each unlock run adopts a fresh mitrustservice conn and dials a fresh
        // channel on it — drop the previous run's (now stale) connection and
        // sequence state so a re-locked phone can unlock again.
        mitrustConnection?.cancel()
        mitrustConnection = nil
        mitrustPipe?.stop()
        mitrustPipe = nil
        mitrustServerPort = 0
        mitrustSendSn = 0
        mitrustRecvUna = 0
        server.adoptOutboundConn(connId: mitrustConnId, handler: self)

        let phoneConnId = randomBytes(8)
        let phoneKey = Curve25519.KeyAgreement.PrivateKey()
        var cred = Data()
        LyraProtoWriter.appendLengthDelimitedField(1, value: phoneConnId, to: &cred)
        LyraProtoWriter.appendLengthDelimitedField(2, value: phoneKey.publicKey.rawRepresentation, to: &cred)
        var syncInfo = Data()
        LyraProtoWriter.appendVarintField(1, value: 10000, to: &syncInfo)
        LyraProtoWriter.appendVarintField(2, value: 48, to: &syncInfo)
        LyraProtoWriter.appendVarintField(3, value: 1, to: &syncInfo)
        LyraProtoWriter.appendLengthDelimitedField(
            4, value: Data("com.xiaomi.trustservice:mitrustservice".utf8), to: &syncInfo
        )
        LyraProtoWriter.appendLengthDelimitedField(5, value: cred, to: &syncInfo)
        let inner = LogiConnInnerFrame(frameType: 5, payload: .syncInfo(syncInfo))
        server.sendLogi(connId: mitrustConnId, inner: inner)

        // responseOfPeerPort arrives as a plaintext packType-5 command.
        let previousHandler = server.plaintextCommandHandler
        server.plaintextCommandHandler = { [weak self] command in
            guard let self, self.handleMitrustPlaintextCommand(command) else {
                return previousHandler?(command) ?? false
            }
            return true
        }
        onEvent("mitrust adoption dialed connId=\(mitrustConnId)")
    }

    private func handleMitrustLogiConn(_ logiConn: LogiConnFrame, server: LyraPhoneMeshServer) {
        if logiConn.flag, let key = mitrustSessionKey,
           let plaintext = LyraAuthHandshake.gcmOpen(logiConn.inner, using: key),
           let inner = LogiConnInnerFrame(parsing: plaintext)
        {
            // Mac answered our mitrust logi request; ack so it sends its
            // responseOfPeerPort (it holds the answer until response_ack).
            if case .response = inner.payload {
                let ack = LogiConnInnerFrame(frameType: 3, payload: .responseAck(Data()))
                server.sendLogi(connId: mitrustConnId, inner: ack, encryptWith: key)
            }
            return
        }
        guard !logiConn.flag, let inner = LogiConnInnerFrame(parsing: logiConn.inner) else { return }
        switch inner.payload {
        case .syncInfo:
            sendMitrustKeyAgree(server: server)
        case .upgrade(let data):
            handleMitrustKeyAgreeReply(data, server: server)
        default:
            break
        }
    }

    private func sendMitrustKeyAgree(server: LyraPhoneMeshServer) {
        let phoneKey = P256.KeyAgreement.PrivateKey()
        mitrustKeyAgreePriv = phoneKey
        let clientRandom = randomBytes(32)
        mitrustClientRandom = clientRandom
        var pkMsg = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &pkMsg)
        LyraProtoWriter.appendLengthDelimitedField(2, value: phoneKey.publicKey.x963Representation, to: &pkMsg)
        var cipher = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &cipher)
        LyraProtoWriter.appendLengthDelimitedField(2, value: clientRandom, to: &cipher)
        LyraProtoWriter.appendVarintField(3, value: 32, to: &cipher)
        LyraProtoWriter.appendVarintField(4, value: 2, to: &cipher)
        LyraProtoWriter.appendLengthDelimitedField(5, value: pkMsg, to: &cipher)
        var clientNotify = Data()
        LyraProtoWriter.appendLengthDelimitedField(1, value: cipher, to: &clientNotify)
        var pairFrame = Data()
        LyraProtoWriter.appendLengthDelimitedField(2, value: clientNotify, to: &pairFrame)
        var handshake = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &handshake)
        LyraProtoWriter.appendVarintField(2, value: 6, to: &handshake)
        LyraProtoWriter.appendLengthDelimitedField(8, value: pairFrame, to: &handshake)
        var authFrame = Data()
        LyraProtoWriter.appendVarintField(1, value: UInt64.random(in: 1...UInt64(UInt32.max)), to: &authFrame)
        LyraProtoWriter.appendLengthDelimitedField(2, value: handshake, to: &authFrame)
        let inner = LogiConnInnerFrame(frameType: 6, payload: .upgrade(authFrame))
        server.sendLogi(connId: mitrustConnId, inner: inner)
    }

    private func handleMitrustKeyAgreeReply(_ data: Data, server: LyraPhoneMeshServer) {
        guard let handshakeFrame = LyraAuthHandshake.lengthDelimited(2, in: data),
              let pairFrame = LyraAuthHandshake.lengthDelimited(8, in: handshakeFrame),
              let serverNotify = LyraAuthHandshake.lengthDelimited(3, in: pairFrame),
              let cipherSuite = LyraAuthHandshake.lengthDelimited(1, in: serverNotify),
              let serverRandom = LyraAuthHandshake.lengthDelimited(2, in: cipherSuite),
              let publicKeyMessage = LyraAuthHandshake.lengthDelimited(5, in: cipherSuite),
              let publicKey = LyraAuthHandshake.lengthDelimited(2, in: publicKeyMessage),
              let serverKey = try? P256.KeyAgreement.PublicKey(x963Representation: publicKey),
              let phoneKey = mitrustKeyAgreePriv,
              let secret = try? phoneKey.sharedSecretFromKeyAgreement(with: serverKey)
                .withUnsafeBytes({ Data($0) })
        else {
            onEvent("mitrust keyagree_reply_parse_failed")
            return
        }
        mitrustSessionKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            salt: LyraMeshHkdf.salt,
            info: mitrustClientRandom + serverRandom,
            outputByteCount: 32
        )
        // Send the mitrustservice logi request (encrypted) with our
        // requestOfPeerPort embedded in UserInfo f10, like the real phone.
        mitrustTransKey = randomBytes(32)
        var peerPortRequest = Data()
        LyraProtoWriter.appendVarintField(1, value: mitrustClientChannelId, to: &peerPortRequest)
        LyraProtoWriter.appendLengthDelimitedField(4, value: mitrustTransKey, to: &peerPortRequest)
        LyraProtoWriter.appendLengthDelimitedField(5, value: randomBytes(32), to: &peerPortRequest)
        var userInfo = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &userInfo)
        LyraProtoWriter.appendLengthDelimitedField(2, value: Data("com.xiaomi.trustservice".utf8), to: &userInfo)
        LyraProtoWriter.appendLengthDelimitedField(
            3, value: Data(Self.colonHex(randomBytes(32)).utf8), to: &userInfo
        )
        LyraProtoWriter.appendLengthDelimitedField(10, value: peerPortRequest, to: &userInfo)
        var requestData = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &requestData)
        LyraProtoWriter.appendLengthDelimitedField(
            2, value: Data("com.xiaomi.trustservice:mitrustservice".utf8), to: &requestData
        )
        LyraProtoWriter.appendLengthDelimitedField(3, value: userInfo, to: &requestData)
        let request = LogiConnInnerFrame(frameType: 1, payload: .request(requestData))
        guard let key = mitrustSessionKey else { return }
        server.sendLogi(connId: mitrustConnId, inner: request, encryptWith: key)
    }

    private func handleMitrustPlaintextCommand(_ command: Data) -> Bool {
        guard let (header, body) = try? LyraChannelProtocol.decode(command),
              header.type == LyraChannelProtocol.CommandType.responseOfPeerPort.rawValue
        else { return false }
        let fields = (try? LyraProtoReader.readFields(from: body)) ?? []
        var port: UInt16 = 0
        for field in fields where field.number == 3 {
            port = UInt16(field.varintValue ?? 0)
        }
        guard port != 0 else { return false }
        mitrustServerPort = port
        onEvent("mitrust peer_port port=\(port)")
        connectMitrustChannel()
        return true
    }

    // MARK: - mitrust channel client (595/546/562)

    private func connectMitrustChannel() {
        if let pipe = mitrustChannelFactory.flatMap({ $0(mitrustServerPort) }) {
            connectMitrustChannelViaPipe(pipe)
            return
        }
        guard mitrustServerPort != 0, mitrustConnection == nil else { return }
        let port = NWEndpoint.Port(rawValue: mitrustServerPort)!
        let connection = NWConnection(host: "127.0.0.1", port: port, using: .udp)
        mitrustConnection = connection
        connection.stateUpdateHandler = { [weak self] state in
            self?.queue.async {
                if case .ready = state {
                    self?.sendMitrustNegotiation()
                }
            }
        }
        connection.start(queue: queue)
        receiveMitrust(on: connection)
    }

    // Relay-path dial: the pipe stands in for the phone bridge's reverse
    // listener + the Mac's mitrust pipe — negotiation TLV and trans-key
    // packets cross the relay session as p-stamped channel envelopes.
    private func connectMitrustChannelViaPipe(_ pipe: LyraChannelDatagramPipe) {
        guard mitrustServerPort != 0, mitrustPipe == nil else { return }
        if mitrustSpeaksOfficial, let virtualPipe = pipe as? LyraVirtualChannelPipe {
            virtualPipe.forceOfficialFormat = true
        }
        mitrustPipe = pipe
        pipe.onNegotiated = { [weak self] _, _ in
            self?.queue.async {
                self?.sendMitrustJSON(["event_name": 595, "client_hello": "client_hello"])
            }
        }
        pipe.onMessage = { [weak self] message, _ in
            self?.queue.async { self?.handleMitrustChannelFrame(message) }
        }
        do {
            try pipe.connect(host: "127.0.0.1", port: mitrustServerPort, socketKey: mitrustTransKey)
            try pipe.sendClientNegotiation(
                channelId: UInt32(mitrustClientChannelId), version: 1, mtu: 0xFF00
            )
        } catch {
            onEvent("mitrust pipe dial failed: \(error)")
        }
    }

    private func sendMitrustNegotiation() {
        let tlv = LyraExpressTLV.oneOfNode(
            tag: 0xFFFF,
            selectedTag: 0,
            child: LyraExpressTLV.containerNode(tag: 0, children: [
                LyraExpressTLV.int32Node(tag: 0, value: UInt32(mitrustClientChannelId)),
                LyraExpressTLV.int32Node(tag: 1, value: 1),
                LyraExpressTLV.int32Node(tag: 2, value: 0xFF00)
            ])
        )
        sendMitrustPacket(tlv)
        queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.sendMitrustJSON(["event_name": 595, "client_hello": "client_hello"])
        }
    }

    private func sendMitrustPacket(_ payload: Data) {
        let datagram = LyraMeshDatagram.encode(
            tick: LyraMeshSocket.tick(), sn: mitrustSendSn, una: mitrustRecvUna, payload: payload
        )
        mitrustSendSn &+= 1
        mitrustConnection?.send(content: datagram, completion: .idempotent)
    }

    private func sendMitrustJSON(_ object: [String: Any]) {
        guard let json = try? JSONSerialization.data(withJSONObject: object) else { return }
        let frame = LyraChannelSocket.wrapChannelFrame(json)
        if let pipe = mitrustPipe {
            try? pipe.sendVariant(
                channelFrame: frame, key: mitrustTransKey, singleLayer: true
            )
            return
        }
        guard let packet = try? LyraSocketPacket.encode(
            plaintext: frame, key: SymmetricKey(data: mitrustTransKey)
        ) else { return }
        sendMitrustPacket(packet)
    }

    private func receiveMitrust(on connection: NWConnection) {
        connection.receiveMessage { [weak self] content, _, _, error in
            guard let self else { return }
            if let content, !content.isEmpty,
               let segment = try? LyraMeshDatagram.decodeSegment(content),
               segment.command == LyraMeshDatagram.commandPush
            {
                let isDuplicate = segment.sn < self.mitrustRecvUna
                if !isDuplicate {
                    self.mitrustRecvUna = segment.sn &+ 1
                    self.queue.async { self.handleMitrustPacket(segment.payload) }
                }
            }
            if error == nil {
                self.receiveMitrust(on: connection)
            }
        }
    }

    private func handleMitrustPacket(_ payload: Data) {
        let bytes = Array(payload)
        guard bytes.count >= 2 else { return }
        if bytes[0] == 0x01, bytes[1] == 0x01 {
            return // negotiation reply
        }
        guard bytes[0] == 0x81, bytes[1] == 0x04,
              let decodedPacket = try? LyraSocketPacket.decode(
                  Data(payload), key: SymmetricKey(data: mitrustTransKey)
              )
        else { return }
        handleMitrustChannelFrame(decodedPacket.plaintext)
    }

    // Handles one decrypted channel frame (wrapChannelFrame-wrapped JSON),
    // from either the UDP socket (after LyraSocketPacket.decode) or the
    // relay-path channel pipe (already decrypted by the pipe).
    private func handleMitrustChannelFrame(_ frame: Data) {
        guard let (tag, child) = try? LyraExpressTLVParser.parseOneOf(frame), tag == 1,
              let payloadNode = LyraExpressTLVParser.firstChild(
                  0, in: LyraExpressTLVParser.children(of: child)
              ),
              let object = try? JSONSerialization.jsonObject(with: payloadNode.payload) as? [String: Any],
              let eventName = (object["event_name"] as? NSNumber)?.intValue
        else { return }
        onEvent("mitrust rx event=\(eventName)")
        switch eventName {
        case 593:
            guard let key = object["sessionkey"] as? String else { return }
            mitrustSessionKeyHex = key
            sendMitrustJSON(["event_name": 594, "sessionkey": key, "client_key_exchange": "client_key_exchange"])
            sendMitrustJSON(["event_name": 546, "shared_auth_id_B": saidBHex()])
        case 547:
            mitrustBindCompleted = true
            var tokenB = Data([0x01])
            tokenB.append(0x12)
            var length = UInt32(32).littleEndian
            tokenB.append(Data(bytes: &length, count: 4))
            tokenB.append(randomBytes(32))
            sendMitrustJSON([
                "event_name": 562,
                "shared_auth_id_B": saidBHex(),
                "auth_token_B": tokenB.map { String(format: "%02x", $0) }.joined(),
                "auth_type": 5,
                "auth_level": 2
            ])
        case 563:
            guard let tokenAHex = object["auth_token_A"] as? String,
                  let tokenA = Self.data(fromHex: tokenAHex) else { return }
            lastAuthTokenA = tokenA
            mitrustUnlockCompleted = true
            mitrustRunCompleted = true
            mitrustUnlockCount += 1
            locked = false
            onEvent("mitrust unlocked")
            let event = TrustAuthEvent(feature: DuoScreenTrustFeature.unlockDevice, code: DuoScreenTrustCode.success)
            sendChannelMessage(type: LyraCastMessageType.trust, payload: DuoScreenTrustProto.encode(
                DuoScreenTrust(sessionID: 0, msg: .authEvent(event))
            ))
        default:
            break
        }
    }

    private func saidBHex() -> String {
        if saidB.isEmpty {
            saidB = randomBytes(32)
        }
        return saidB.map { String(format: "%02x", $0) }.joined()
    }

    private static func colonHex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    private static func data(fromHex hex: String) -> Data? {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    // MARK: - WFD RTSP server

    private var wfdListener: NWListener?
    private var wfdConnection: NWConnection?
    private var wfdBuffer = Data()
    private var videoConnection: NWConnection?
    private var videoTimer: DispatchSourceTimer?
    private var wfdCSeq = 0
    private var wfdSentGetParameter = false
    private var wfdSentTrigger = false
    private var videoWithheld = false

    private func tearDownWFDServer() {
        wfdConnection?.cancel()
        wfdConnection = nil
        wfdListener?.cancel()
        wfdListener = nil
        wfdBuffer.removeAll()
        wfdSessionEstablished = false
        wfdSentGetParameter = false
        wfdSentTrigger = false
        videoTimer?.cancel()
        videoTimer = nil
        videoConnection?.cancel()
        videoConnection = nil
    }

    private func startWFDServer() {
        guard wfdListener == nil, let port = NWEndpoint.Port(rawValue: wfdPort) else { return }
        let listener = try? NWListener(using: .tcp, on: port)
        listener?.newConnectionHandler = { [weak self] connection in
            self?.queue.async {
                guard let self else { return }
                self.wfdConnection?.cancel()
                self.wfdConnection = connection
                self.wfdBuffer.removeAll()
                connection.start(queue: self.queue)
                self.receiveWFD(on: connection)
                self.sendWFDOptions()
            }
        }
        listener?.start(queue: queue)
        wfdListener = listener
        onEvent("wfd listening port=\(wfdPort)")
    }

    private func receiveWFD(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_535) { [weak self] data, _, isComplete, error in
            self?.queue.async {
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.wfdBuffer.append(data)
                    self.drainWFD()
                }
                if error == nil, !isComplete, !self.stopped {
                    self.receiveWFD(on: connection)
                }
            }
        }
    }

    private func sendWFDOptions() {
        wfdCSeq += 1
        let authMsg = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        sendWFDRaw("OPTIONS * RTSP/1.0\r\nCSeq: \(wfdCSeq)\r\nRequire: org.wfa.wfd1.0\r\nauthMsg:\(authMsg)\r\n\r\n")
    }

    private func sendWFDRaw(_ text: String) {
        wfdConnection?.send(content: Data(text.utf8), completion: .idempotent)
    }

    private func drainWFD() {
        while let headerEnd = wfdBuffer.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) {
            let headerData = wfdBuffer.subdata(in: 0..<headerEnd.lowerBound)
            guard let headerText = String(data: headerData, encoding: .utf8) else {
                wfdBuffer.removeAll()
                return
            }
            var lines = headerText.components(separatedBy: "\r\n")
            let firstLine = lines.first ?? ""
            lines.removeFirst()
            var headers: [String: String] = [:]
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let contentLength = headers["content-length"].flatMap(Int.init) ?? 0
            let messageEnd = headerEnd.upperBound + contentLength
            guard wfdBuffer.count >= messageEnd else { return }
            let body = wfdBuffer.subdata(in: headerEnd.upperBound..<messageEnd)
            wfdBuffer.removeSubrange(0..<messageEnd)
            handleWFDMessage(firstLine: firstLine, headers: headers, body: body)
        }
    }

    private func handleWFDMessage(firstLine: String, headers: [String: String], body: Data) {
        let bodyText = String(data: body, encoding: .utf8) ?? ""
        if firstLine.hasPrefix("RTSP/") {
            if wfdSentGetParameter, !wfdSentTrigger {
                wfdSentTrigger = true
                wfdCSeq += 1
                sendWFDRaw("SET_PARAMETER rtsp://localhost/wfd1.0 RTSP/1.0\r\nCSeq: \(wfdCSeq)\r\nContent-Type: text/parameters\r\nContent-Length: 27\r\n\r\nwfd_trigger_method: SETUP\r\n")
            }
            return
        }
        let method = firstLine.split(separator: " ").first.map(String.init) ?? ""
        let cseq = headers["cseq"].flatMap(Int.init) ?? 0
        switch method {
        case "OPTIONS":
            let authMsg = headers["authmsg"] ?? ""
            let ack = Self.authMsgAck(for: authMsg)
            sendWFDRaw("RTSP/1.0 200 OK\r\nCSeq: \(cseq)\r\nPublic: org.wfa.wfd1.0, GET_PARAMETER, SET_PARAMETER\r\nauthKeyType: 2\r\nauthAlgorithmVal: 4\r\nauthMsgAck:\(ack)\r\n\r\n")
            wfdCSeq += 1
            wfdSentGetParameter = true
            sendWFDRaw("GET_PARAMETER rtsp://localhost/wfd1.0 RTSP/1.0\r\nCSeq: \(wfdCSeq)\r\nContent-Type: text/parameters\r\nContent-Length: 19\r\n\r\nwfd_video_formats\r\n")
        case "SETUP":
            sendWFDRaw("RTSP/1.0 200 OK\r\nCSeq: \(cseq)\r\nSession: 87654321\r\nTransport: RTP/AVP/MPT;unicast;server_port=15551\r\n\r\n")
        case "PLAY":
            sendWFDRaw("RTSP/1.0 200 OK\r\nCSeq: \(cseq)\r\nSession: 87654321\r\n\r\n")
            wfdSessionEstablished = true
            wfdPlayCount += 1
            if withholdVideoUntilIDRRequest {
                videoWithheld = true
            }
            startVideoSender()
        case "SET_PARAMETER":
            sendWFDRaw("RTSP/1.0 200 OK\r\nCSeq: \(cseq)\r\nContent-Length: 0\r\n\r\n")
            if bodyText.contains("wfd_idr_request") {
                idrRequestCount += 1
                videoWithheld = false
            }
        default:
            sendWFDRaw("RTSP/1.0 200 OK\r\nCSeq: \(cseq)\r\nContent-Length: 0\r\n\r\n")
        }
    }

    private func startVideoSender() {
        guard videoTimer == nil else { return }
        let connection = NWConnection(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: clientVideoPort)!, using: .udp
        )
        videoConnection = connection
        connection.start(queue: queue)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.2, repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self, !self.stopped, self.videoDatagramsSent < 2000 else {
                self?.videoTimer?.cancel()
                self?.videoTimer = nil
                return
            }
            guard !self.videoWithheld else { return }
            var packet = Data(count: 188)
            packet.withUnsafeMutableBytes { ptr in
                if let base = ptr.baseAddress {
                    base.storeBytes(of: UInt32(self.videoDatagramsSent).bigEndian, toByteOffset: 0, as: UInt32.self)
                }
            }
            connection.send(content: packet, completion: .idempotent)
            self.videoDatagramsSent += 1
        }
        videoTimer = timer
        timer.resume()
    }

    private static func authMsgAck(for authMsg: String) -> String {
        let key = SymmetricKey(data: MiplayPESCrypto.videoKey)
        let code = HMAC<SHA256>.authenticationCode(for: Data(authMsg.utf8), using: key)
        return code.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Teardown

    public func stop() {
        queue.sync {
            stopped = true
            channelListener?.cancel()
            channelConnection?.cancel()
            mitrustConnection?.cancel()
            mitrustConnection = nil
            mitrustPipe?.stop()
            mitrustPipe = nil
            if channelTransportStarted {
                channelTransport?.stop()
                channelTransportStarted = false
            }
            tearDownWFDServer()
        }
    }

    // MARK: - Helpers

    private func gcmSeal(_ plaintext: Data, key: SymmetricKey) -> Data? {
        LyraAuthHandshake.gcmSeal(plaintext, using: key)
    }

    private func gcmOpen(_ combined: Data, key: SymmetricKey) -> Data? {
        LyraAuthHandshake.gcmOpen(combined, using: key)
    }

    private func randomBytes(_ count: Int) -> Data {
        LyraPhoneIdentity.randomBytes(count)
    }

    private func varint(_ number: Int, in data: Data) -> UInt64? {
        LyraAuthHandshake.varint(number, in: data)
    }

    private func lengthDelimited(_ number: Int, in data: Data) -> Data? {
        LyraAuthHandshake.lengthDelimited(number, in: data)
    }

    private func readUInt32BE(_ data: Data, at offset: Int) -> UInt32 {
        let i = data.index(data.startIndex, offsetBy: offset)
        return (UInt32(data[i]) << 24) | (UInt32(data[i + 1]) << 16) | (UInt32(data[i + 2]) << 8) | UInt32(data[i + 3])
    }
}
