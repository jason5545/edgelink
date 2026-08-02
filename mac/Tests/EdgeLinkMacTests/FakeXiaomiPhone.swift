import CryptoKit
import EdgeLinkKit
import Foundation
import Network

// Scripted fake phone for end-to-end mirror-flow tests. Speaks the real
// protocols on loopback: lyra mesh (phys sync → cookie → syncAuth → upgrade →
// logi conn → peer port), the encrypted cast channel (TLV negotiation +
// AES-GCM frames), duo.screen trust messages, the mitrustservice adoption +
// 595/546/562 JSON auth, and the WFD RTSP source with UDP video.
final class FakeXiaomiPhone {
    private(set) var locked: Bool

    let meshPort: UInt16
    let castChannelPort: UInt16
    let wfdPort: UInt16
    let clientVideoPort: UInt16

    // Assertion surface
    private(set) var statusActionCount = 0
    private(set) var authActionCount = 0
    private(set) var bindActionCount = 0
    private(set) var openMirrorScreenCount = 0
    private(set) var closeScreenCount = 0
    private(set) var wfdSessionEstablished = false
    private(set) var wfdPlayCount = 0
    private(set) var videoDatagramsSent = 0
    private(set) var mitrustBindCompleted = false
    private(set) var mitrustUnlockCompleted = false
    private(set) var mitrustUnlockCount = 0
    private(set) var lastAuthTokenA: Data?

    // The real phone answers a status query with disabledBySetting, then
    // (~0.5-2s later, when its shared-auth query times out) sends a success
    // event with enableStatus=unset + remoteKeyguardStatus=valid — while
    // actually still locked (live, 2026-08-02). When its internal query does
    // resolve, the answer carries enableStatus=enabled and a TRUTHFUL
    // keyguard (official captures, 2026-07-31).
    var conflictingStatus = false
    // If set, the first N status queries get the placeholder (lie) treatment
    // and later ones the truthful answer — models the phone's slow
    // getSupportStatus resolving under the official-style retry.
    var truthfulAfterQueries: Int?

    var wfdServerStartupDelay: TimeInterval = 0

    // TDIF bind state reported in duo.screen status events. When false the
    // phone answers bindStatus=notBound; a bindAction flips it to true (the
    // official phone-side verification + TA registration) and a bindEvent
    // success plus a fresh truthful status event go out.
    var bound = true

    // Re-lock (or unlock) the phone mid-test, e.g. the user locking it again
    // after a successful Mac-driven unlock.
    func setLocked(_ value: Bool) {
        queue.async { self.locked = value }
    }

    var log: (String) -> Void = { _ in }

    private let queue = DispatchQueue(label: "FakeXiaomiPhone")
    private var stopped = false

    init(meshPort: UInt16, castChannelPort: UInt16, wfdPort: UInt16, clientVideoPort: UInt16 = 15_550, locked: Bool) {
        self.meshPort = meshPort
        self.castChannelPort = castChannelPort
        self.wfdPort = wfdPort
        self.clientVideoPort = clientVideoPort
        self.locked = locked
    }

    // MARK: - Lifecycle

    private var meshListener: NWListener?
    private var meshConnection: NWConnection?

    func start() throws {
        let listener = try NWListener(using: .udp, on: NWEndpoint.Port(rawValue: meshPort)!)
        listener.newConnectionHandler = { [weak self] connection in
            self?.queue.async {
                self?.meshConnection?.cancel()
                self?.meshConnection = connection
                connection.start(queue: self!.queue)
                self?.receiveMesh(on: connection)
            }
        }
        listener.start(queue: queue)
        meshListener = listener
        listenCastChannel()
    }

    func stop() {
        queue.sync {
            stopped = true
            meshListener?.cancel()
            meshConnection?.cancel()
            channelListener?.cancel()
            channelConnection?.cancel()
            wfdListener?.cancel()
            wfdConnection?.cancel()
            videoConnection?.cancel()
            mitrustConnection?.cancel()
        }
    }

    // MARK: - Mesh layer

    private var meshSendSn: UInt32 = 0
    private var meshRecvUna: UInt32 = 0
    private var logiConnId: UInt32 = 0
    private var phoneNetId: UInt32 = 2
    private var channelKeyCS: SymmetricKey?
    private var channelKeySC: SymmetricKey?
    private var castTransKey = Data()
    private var castChannelId: UInt64 = 0

    // mitrust adoption state
    private var mitrustConnId: UInt32 = 0
    private var mitrustPeerNetId: UInt32 = 2
    private var mitrustSessionKey: SymmetricKey?
    private var mitrustTransKey = Data()
    private var mitrustClientChannelId: UInt64 = 13
    private var mitrustServerPort: UInt16 = 0

    private func receiveMesh(on connection: NWConnection) {
        connection.receiveMessage { [weak self] content, _, _, error in
            guard let self else { return }
            if let content, !content.isEmpty,
               let segment = try? LyraMeshDatagram.decodeSegment(content),
               segment.command == LyraMeshDatagram.commandPush {
                let isDuplicate = segment.sn < self.meshRecvUna
                if !isDuplicate {
                    self.meshRecvUna = segment.sn &+ 1
                    let ack = LyraMeshDatagram.encodeAck(tick: LyraMeshSocket.tick(), sn: segment.sn, una: self.meshRecvUna)
                    connection.send(content: ack, completion: .idempotent)
                    if let decoded = try? LyraMeshPack.decode(segment.payload) {
                        self.handleMeshFrame(decoded.frame)
                    }
                }
            }
            if error == nil, !self.stopped {
                self.receiveMesh(on: connection)
            }
        }
    }

    private func sendMesh(packType: UInt8, payload: Data) {
        let frame = LyraMeshPack.Frame(packType: packType, payload: payload)
        guard let encoded = try? LyraMeshPack.encode(frame) else { return }
        let datagram = LyraMeshDatagram.encode(
            tick: LyraMeshSocket.tick(), sn: meshSendSn, una: meshRecvUna, payload: encoded
        )
        meshSendSn &+= 1
        meshConnection?.send(content: datagram, completion: .idempotent)
    }

    private func handleMeshFrame(_ frame: LyraMeshPack.Frame) {
        switch frame.packType {
        case 1:
            guard let miFrame = MiConnectFrame(parsing: frame.payload),
                  let physConn = miFrame.physConnFrame else { return }
            handlePhysConn(physConn)
        case 2:
            guard let miFrame = MiConnectFrame(parsing: frame.payload) else { return }
            for logiConn in miFrame.logiConnFrames {
                handleLogiConn(logiConn)
            }
        case 5:
            handleMeshCommand(frame.payload)
        default:
            break
        }
    }

    private func handlePhysConn(_ physConn: PhysConnFrame) {
        switch physConn.payload {
        case .syncDeviceInfoRequest:
            let response = PhysConnFrame(field2: 2, payload: .syncDeviceInfoResponse(Data([0x01])))
            let miFrame = MiConnectFrame(version: 0, logiConnFrames: [], physConnFrame: response)
            sendMesh(packType: 1, payload: miFrame.serialized())
        case .keepAliveRequest(let data) where physConn.field2 == 4:
            let fields = (try? LyraProtoReader.readFields(from: data)) ?? []
            let phase = fields.first { $0.number == 2 }?.varintValue ?? 0
            let tick = UInt64(LyraMeshSocket.tick())
            var responseData = Data()
            LyraProtoWriter.appendVarintField(1, value: tick, to: &responseData)
            LyraProtoWriter.appendVarintField(2, value: phase + 1, to: &responseData)
            LyraProtoWriter.appendVarintField(3, value: tick, to: &responseData)
            let response = PhysConnFrame(field2: 5, payload: .keepAliveResponse(responseData))
            let miFrame = MiConnectFrame(version: 0, logiConnFrames: [], physConnFrame: response)
            sendMesh(packType: 1, payload: miFrame.serialized())
        default:
            break
        }
    }

    // MARK: - Logi conn (cast sync auth / upgrade / encrypted)

    private func handleLogiConn(_ logiConn: LogiConnFrame) {
        if logiConn.flag {
            handleEncryptedLogiConn(logiConn)
            return
        }
        guard let inner = LogiConnInnerFrame(parsing: logiConn.inner) else { return }
        switch inner.payload {
        case .syncInfo:
            if logiConn.logiConnId == mitrustConnId, mitrustConnId != 0 {
                sendMitrustKeyAgree()
            } else {
                handleCastSyncAuthHello(logiConn: logiConn)
            }
        case .upgrade(let data):
            if logiConn.logiConnId == mitrustConnId, mitrustConnId != 0 {
                handleMitrustKeyAgreeReply(data)
            } else {
                handleCastUpgrade(data, logiConn: logiConn)
            }
        default:
            break
        }
    }

    private func handleCastSyncAuthHello(logiConn: LogiConnFrame) {
        logiConnId = logiConn.logiConnId
        phoneNetId = 2
        let phoneConnId = randomBytes(8)
        let phoneKey = Curve25519.KeyAgreement.PrivateKey()
        var cred = Data()
        LyraProtoWriter.appendLengthDelimitedField(1, value: phoneConnId, to: &cred)
        LyraProtoWriter.appendLengthDelimitedField(2, value: phoneKey.publicKey.rawRepresentation, to: &cred)
        var syncInfo = Data()
        LyraProtoWriter.appendVarintField(1, value: 15000, to: &syncInfo)
        LyraProtoWriter.appendVarintField(2, value: 48, to: &syncInfo)
        LyraProtoWriter.appendVarintField(3, value: 1, to: &syncInfo)
        LyraProtoWriter.appendLengthDelimitedField(4, value: Data("com.xiaomi.mirror:cast".utf8), to: &syncInfo)
        LyraProtoWriter.appendLengthDelimitedField(5, value: cred, to: &syncInfo)
        let inner = LogiConnInnerFrame(frameType: 5, payload: .syncInfo(syncInfo))
        let response = LogiConnFrame(
            logiConnId: logiConnId, localNetId: phoneNetId, remoteNetId: 1, inner: inner.serialized()
        )
        let miFrame = MiConnectFrame(version: 0, logiConnFrames: [response])
        sendMesh(packType: 2, payload: miFrame.serialized())
    }

    private func handleCastUpgrade(_ data: Data, logiConn: LogiConnFrame) {
        guard let handshakeFrame = lengthDelimited(2, in: data),
              let handshakeId = varintField(1, in: data),
              let pairFrame = lengthDelimited(8, in: handshakeFrame),
              let clientNotify = lengthDelimited(2, in: pairFrame),
              let cipherSuite = lengthDelimited(1, in: clientNotify),
              let clientRandom = lengthDelimited(2, in: cipherSuite),
              let publicKeyMessage = lengthDelimited(5, in: cipherSuite),
              let publicKey = lengthDelimited(2, in: publicKeyMessage),
              let peerKey = try? P256.KeyAgreement.PublicKey(x963Representation: publicKey)
        else {
            log("fakephone.cast_upgrade_parse_failed")
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
        let response = LogiConnFrame(
            logiConnId: logiConn.logiConnId, localNetId: phoneNetId, remoteNetId: 1, inner: inner.serialized()
        )
        let miFrame = MiConnectFrame(version: 0, logiConnFrames: [response])
        sendMesh(packType: 2, payload: miFrame.serialized())
    }

    private func handleEncryptedLogiConn(_ logiConn: LogiConnFrame) {
        if logiConn.logiConnId == mitrustConnId, mitrustConnId != 0 {
            guard let key = mitrustSessionKey, let inner = gcmOpen(logiConn.inner, key: key),
                  let frame = LogiConnInnerFrame(parsing: inner)
            else { return }
            if case .response = frame.payload {
                // Mac answered our mitrust logi request; ack so it sends its
                // responseOfPeerPort, then the channel comes to us.
                let ack = LogiConnInnerFrame(frameType: 3, payload: .responseAck(Data()))
                sendEncryptedLogiConn(inner: ack, connId: mitrustConnId, netId: mitrustPeerNetId, key: key)
            }
            return
        }
        guard let key = channelKeyCS, let inner = gcmOpen(logiConn.inner, key: key),
              let frame = LogiConnInnerFrame(parsing: inner)
        else { return }
        if case .request(let requestData) = frame.payload {
            // logi conn request: extract the embedded peer-port request
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
            }
            guard let scKey = channelKeySC else { return }
            var responseData = Data()
            LyraProtoWriter.appendVarintField(1, value: 1, to: &responseData)
            let response = LogiConnInnerFrame(frameType: 2, payload: .response(responseData))
            sendEncryptedLogiConn(inner: response, connId: logiConn.logiConnId, netId: phoneNetId, key: scKey)
        }
    }

    private func sendEncryptedLogiConn(inner: LogiConnInnerFrame, connId: UInt32, netId: UInt32, key: SymmetricKey) {
        guard let sealed = gcmSeal(inner.serialized(), key: key) else { return }
        let frame = LogiConnFrame(logiConnId: connId, localNetId: netId, remoteNetId: 1, flag: true, inner: sealed)
        let miFrame = MiConnectFrame(version: 0, logiConnFrames: [frame])
        sendMesh(packType: 2, payload: miFrame.serialized())
    }

    // MARK: - Peer-port command exchange (packType 5)

    private func handleMeshCommand(_ payload: Data) {
        guard payload.count > 2 else { return }
        let flag = payload[payload.index(after: payload.startIndex)]
        if flag == 0 {
            // Plaintext responseOfPeerPort for our mitrustservice channel.
            guard let (header, body) = try? LyraChannelProtocol.decode(Data(payload.dropFirst(2))),
                  header.type == LyraChannelProtocol.CommandType.responseOfPeerPort.rawValue
            else { return }
            let fields = (try? LyraProtoReader.readFields(from: body)) ?? []
            for field in fields where field.number == 3 {
                mitrustServerPort = UInt16(field.varintValue ?? 0)
            }
            log("fakephone.mitrust_peer_port port=\(self.mitrustServerPort)")
            connectMitrustChannel()
            return
        }
        guard flag == 1, payload.count > 14, let key = channelKeyCS else { return }
        let body = Data(payload.dropFirst(2))
        guard let command = gcmOpen(body, key: key),
              let (header, commandBody) = try? LyraChannelProtocol.decode(command),
              header.type == LyraChannelProtocol.CommandType.requestOfPeerPort.rawValue
        else { return }
        var responseBody = Data()
        LyraProtoWriter.appendVarintField(2, value: castChannelId, to: &responseBody)
        LyraProtoWriter.appendVarintField(3, value: UInt64(castChannelPort), to: &responseBody)
        let response = LyraChannelProtocol.encode(type: .responseOfPeerPort, body: responseBody)
        guard let scKey = channelKeySC, let sealed = gcmSeal(response, key: scKey) else { return }
        var out = Data()
        out.append(payload[payload.startIndex]) // netId echo
        out.append(1)
        out.append(sealed)
        sendMesh(packType: 5, payload: out)
    }

    // MARK: - Cast channel server

    private var channelListener: NWListener?
    private var channelConnection: NWConnection?
    private var channelSendSn: UInt32 = 0
    private var channelRecvUna: UInt32 = 0

    private func listenCastChannel() {
        guard let port = NWEndpoint.Port(rawValue: castChannelPort) else { return }
        let listener = try? NWListener(using: .udp, on: port)
        listener?.newConnectionHandler = { [weak self] connection in
            self?.queue.async {
                self?.channelConnection?.cancel()
                self?.channelConnection = connection
                connection.start(queue: self!.queue)
                self?.receiveChannel(on: connection)
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
               segment.command == LyraMeshDatagram.commandPush {
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
            // TLV negotiation: reply selectedTag 4 echoing the client channel id
            guard bytes.count >= 18 else { return }
            let channelId = readUInt32BE(payload, at: 26)
            let reply = LyraExpressTLV.oneOfNode(
                tag: 0xFFFF,
                selectedTag: 4,
                child: LyraExpressTLV.containerNode(tag: 4, children: [
                    LyraExpressTLV.int32Node(tag: 0, value: channelId),
                    LyraExpressTLV.int32Node(tag: 1, value: 0xFF00)
                ])
            )
            sendChannel(reply)
            return
        }
        guard bytes.count >= 2, bytes[0] == 0x81, bytes[1] == 0x04,
              let decodedPacket = try? LyraSocketPacket.decode(Data(payload), key: SymmetricKey(data: castTransKey)),
              let plaintext = Optional(decodedPacket.plaintext),
              let (tag, child) = try? LyraExpressTLVParser.parseOneOf(plaintext), tag == 1,
              let payloadNode = LyraExpressTLVParser.firstChild(0, in: LyraExpressTLVParser.children(of: child))
        else { return }
        let message = payloadNode.payload
        guard let (type, framePayload) = try? LyraCastMessageCodec.decodeFrame(message) else { return }
        switch type {
        case LyraCastMessageType.trust:
            handleTrustFrame(framePayload)
        case LyraCastMessageType.screenAction:
            if let action = try? LyraCastScreenAction.decode(framePayload) {
                log("fakephone.screen_action action=\(action.action) sessionId=\(action.sessionId)")
                if action.action == LyraCastScreenAction.Action.openMirrorScreen.rawValue {
                    openMirrorScreenCount += 1
                    if wfdListener != nil {
                        // The real phone tears down its RTSP server when a
                        // duplicate OPEN arrives (observed 2026-08-02 as
                        // "Connection reset by peer" mid-dialog).
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
                        // The old listener releases the port asynchronously;
                        // rebinding immediately fails with EADDRINUSE. The
                        // real phone has a rebuild window too — the client's
                        // pre-established retry rides through it.
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
                }
            }
        default:
            break
        }
    }

    private func sendChannelMessage(type: UInt8, payload: Data) {
        let frame = LyraChannelSocket.wrapChannelFrame(LyraCastMessageCodec.encodeFrame(type: type, payload: payload))
        guard let packet = try? LyraSocketPacket.encode(plaintext: frame, key: SymmetricKey(data: castTransKey)) else { return }
        sendChannel(packet)
    }

    private func sendStatusEvent(sessionID: UInt64, keyguardOverride: Int32? = nil, enableOverride: Int32? = nil) {
        var auth = TrustAuthStatus()
        auth.features = [DuoScreenTrustFeature.unlockDevice]
        auth.enableStatus = enableOverride ?? DuoScreenTrustEnableStatus.enabled.rawValue
        auth.bindStatus = (bound ? DuoScreenTrustBindStatus.bound : DuoScreenTrustBindStatus.notBound).rawValue
        auth.remoteRisk = 0
        var event = TrustStatusEvent()
        event.code = DuoScreenTrustCode.success
        event.localKeyguardStatus = DuoScreenKeyguardStatus.valid
        event.remoteKeyguardStatus = keyguardOverride ?? (locked ? 1 : DuoScreenKeyguardStatus.valid)
        event.auth = auth
        sendChannelMessage(type: LyraCastMessageType.trust, payload: DuoScreenTrustProto.encode(
            DuoScreenTrust(sessionID: sessionID, msg: .statusEvent(event))
        ))
    }

    // MARK: - duo.screen trust

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
                    // The flaky follow-up: enableStatus=unset (no real
                    // keyguard info) yet claims keyguard valid (unlocked)
                    // even when the phone is still locked.
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
            log("fakephone.bind_action")
            // The user completed the phone-side verification: TA registration
            // done, bind event success, then a fresh truthful status event.
            bound = true
            var event = TrustBindEvent()
            event.feature = DuoScreenTrustFeature.unlockDevice
            event.code = DuoScreenTrustCode.success
            sendChannelMessage(type: LyraCastMessageType.trust, payload: DuoScreenTrustProto.encode(
                DuoScreenTrust(sessionID: trust.sessionID, msg: .bindEvent(event))
            ))
            sendStatusEvent(sessionID: trust.sessionID)
        case .authAction(let action):
            guard action.feature == DuoScreenTrustFeature.unlockDevice else { return }
            authActionCount += 1
            log("fakephone.auth_action locked=\(self.locked)")
            if locked {
                runMitrustUnlock()
            } else {
                let event = TrustAuthEvent(feature: DuoScreenTrustFeature.unlockDevice, code: DuoScreenTrustCode.success)
                sendChannelMessage(type: LyraCastMessageType.trust, payload: DuoScreenTrustProto.encode(
                    DuoScreenTrust(sessionID: trust.sessionID, msg: .authEvent(event))
                ))
            }
        default:
            break
        }
    }

    // MARK: - mitrustservice adoption (phone-initiated, like the real phone)

    private var mitrustKeyAgreePriv: P256.KeyAgreement.PrivateKey?
    private var mitrustClientRandom = Data()

    private func startMitrustAdoption() {
        mitrustConnId = UInt32.random(in: 1...UInt32.max)
        mitrustPeerNetId = 2
        // Each unlock run adopts a fresh mitrustservice conn and dials a fresh
        // channel on it — drop the previous run's (now stale) connection and
        // sequence state so a re-locked phone can unlock again.
        mitrustConnection?.cancel()
        mitrustConnection = nil
        mitrustServerPort = 0
        mitrustSendSn = 0
        mitrustRecvUna = 0
        mitrustPacketBuffer.removeAll()
        let phoneConnId = randomBytes(8)
        let phoneKey = Curve25519.KeyAgreement.PrivateKey()
        var cred = Data()
        LyraProtoWriter.appendLengthDelimitedField(1, value: phoneConnId, to: &cred)
        LyraProtoWriter.appendLengthDelimitedField(2, value: phoneKey.publicKey.rawRepresentation, to: &cred)
        var syncInfo = Data()
        LyraProtoWriter.appendVarintField(1, value: 10000, to: &syncInfo)
        LyraProtoWriter.appendVarintField(2, value: 48, to: &syncInfo)
        LyraProtoWriter.appendVarintField(3, value: 1, to: &syncInfo)
        LyraProtoWriter.appendLengthDelimitedField(4, value: Data("com.xiaomi.trustservice:mitrustservice".utf8), to: &syncInfo)
        LyraProtoWriter.appendLengthDelimitedField(5, value: cred, to: &syncInfo)
        let inner = LogiConnInnerFrame(frameType: 5, payload: .syncInfo(syncInfo))
        let frame = LogiConnFrame(
            logiConnId: mitrustConnId, localNetId: mitrustPeerNetId, remoteNetId: 1, inner: inner.serialized()
        )
        let miFrame = MiConnectFrame(version: 0, logiConnFrames: [frame])
        sendMesh(packType: 2, payload: miFrame.serialized())
    }

    private func sendMitrustKeyAgree() {
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
        let frame = LogiConnFrame(
            logiConnId: mitrustConnId, localNetId: mitrustPeerNetId, remoteNetId: 1, inner: inner.serialized()
        )
        let miFrame = MiConnectFrame(version: 0, logiConnFrames: [frame])
        sendMesh(packType: 2, payload: miFrame.serialized())
    }

    private func handleMitrustKeyAgreeReply(_ data: Data) {
        guard let handshakeFrame = lengthDelimited(2, in: data),
              let pairFrame = lengthDelimited(8, in: handshakeFrame),
              let serverNotify = lengthDelimited(3, in: pairFrame),
              let cipherSuite = lengthDelimited(1, in: serverNotify),
              let serverRandom = lengthDelimited(2, in: cipherSuite),
              let publicKeyMessage = lengthDelimited(5, in: cipherSuite),
              let publicKey = lengthDelimited(2, in: publicKeyMessage),
              let serverKey = try? P256.KeyAgreement.PublicKey(x963Representation: publicKey),
              let phoneKey = mitrustKeyAgreePriv,
              let secret = try? phoneKey.sharedSecretFromKeyAgreement(with: serverKey)
                .withUnsafeBytes({ Data($0) })
        else {
            log("fakephone.keyagree_reply_parse_failed")
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
        LyraProtoWriter.appendLengthDelimitedField(3, value: Data(Self.colonHex(randomBytes(32)).utf8), to: &userInfo)
        LyraProtoWriter.appendLengthDelimitedField(10, value: peerPortRequest, to: &userInfo)
        var requestData = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &requestData)
        LyraProtoWriter.appendLengthDelimitedField(2, value: Data("com.xiaomi.trustservice:mitrustservice".utf8), to: &requestData)
        LyraProtoWriter.appendLengthDelimitedField(3, value: userInfo, to: &requestData)
        let request = LogiConnInnerFrame(frameType: 1, payload: .request(requestData))
        guard let key = mitrustSessionKey else { return }
        sendEncryptedLogiConn(inner: request, connId: mitrustConnId, netId: mitrustPeerNetId, key: key)
    }

    // MARK: - mitrust channel client (595/546/562)

    private var mitrustConnection: NWConnection?
    private var mitrustSendSn: UInt32 = 0
    private var mitrustRecvUna: UInt32 = 0
    private var mitrustPacketBuffer = Data()
    private var mitrustSessionKeyHex: String?
    private let saidB = Data((0..<32).map { _ in UInt8.random(in: 0...255) })

    private func runMitrustUnlock() {
        queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.startMitrustAdoption()
        }
    }

    private func connectMitrustChannel() {
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
        guard let packet = try? LyraSocketPacket.encode(plaintext: frame, key: SymmetricKey(data: mitrustTransKey)) else { return }
        sendMitrustPacket(packet)
    }

    private func receiveMitrust(on connection: NWConnection) {
        connection.receiveMessage { [weak self] content, _, _, error in
            guard let self else { return }
            if let content, !content.isEmpty,
               let segment = try? LyraMeshDatagram.decodeSegment(content),
               segment.command == LyraMeshDatagram.commandPush {
                let isDuplicate = segment.sn < self.mitrustRecvUna
                if !isDuplicate {
                    self.mitrustRecvUna = segment.sn &+ 1
                    self.handleMitrustPacket(segment.payload)
                }
            }
            if error == nil, !self.stopped {
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
              let decodedPacket = try? LyraSocketPacket.decode(Data(payload), key: SymmetricKey(data: mitrustTransKey)),
              let plaintext = Optional(decodedPacket.plaintext),
              let (tag, child) = try? LyraExpressTLVParser.parseOneOf(plaintext), tag == 1,
              let payloadNode = LyraExpressTLVParser.firstChild(0, in: LyraExpressTLVParser.children(of: child)),
              let object = try? JSONSerialization.jsonObject(with: payloadNode.payload) as? [String: Any],
              let eventName = (object["event_name"] as? NSNumber)?.intValue
        else { return }
        log("fakephone.mitrust_rx event=\(eventName)")
        switch eventName {
        case 593:
            guard let key = object["sessionkey"] as? String else { return }
            mitrustSessionKeyHex = key
            sendMitrustJSON(["event_name": 594, "sessionkey": key, "client_key_exchange": "client_key_exchange"])
            sendMitrustJSON(["event_name": 546, "shared_auth_id_B": saidB.map { String(format: "%02x", $0) }.joined()])
        case 547:
            mitrustBindCompleted = true
            var tokenB = Data([0x01])
            tokenB.append(0x12)
            var length = UInt32(32).littleEndian
            tokenB.append(Data(bytes: &length, count: 4))
            tokenB.append(randomBytes(32))
            sendMitrustJSON([
                "event_name": 562,
                "shared_auth_id_B": saidB.map { String(format: "%02x", $0) }.joined(),
                "auth_token_B": tokenB.map { String(format: "%02x", $0) }.joined(),
                "auth_type": 5,
                "auth_level": 2
            ])
        case 563:
            guard let tokenAHex = object["auth_token_A"] as? String,
                  let tokenA = Self.data(fromHex: tokenAHex) else { return }
            lastAuthTokenA = tokenA
            mitrustUnlockCompleted = true
            mitrustUnlockCount += 1
            locked = false
            log("fakephone.mitrust_unlocked")
            let event = TrustAuthEvent(feature: DuoScreenTrustFeature.unlockDevice, code: DuoScreenTrustCode.success)
            sendChannelMessage(type: LyraCastMessageType.trust, payload: DuoScreenTrustProto.encode(
                DuoScreenTrust(sessionID: 0, msg: .authEvent(event))
            ))
        default:
            break
        }
    }

    // MARK: - WFD RTSP server

    private var wfdListener: NWListener?
    private var wfdConnection: NWConnection?
    private var wfdBuffer = Data()
    private var videoConnection: NWConnection?
    private var videoTimer: DispatchSourceTimer?

    private func startWFDServer() {
        guard wfdListener == nil, let port = NWEndpoint.Port(rawValue: wfdPort) else { return }
        let listener = try? NWListener(using: .tcp, on: port)
        listener?.stateUpdateHandler = { [weak self] state in
            self?.log("fakephone.wfd_listener_state \(state)")
        }
        listener?.newConnectionHandler = { [weak self] connection in
            self?.queue.async {
                self?.wfdConnection?.cancel()
                self?.wfdConnection = connection
                self?.wfdBuffer.removeAll()
                connection.start(queue: self!.queue)
                self?.receiveWFD(on: connection)
                self?.sendWFDOptions()
            }
        }
        listener?.start(queue: queue)
        wfdListener = listener
        log("fakephone.wfd_listening port=\(self.wfdPort)")
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

    private var wfdCSeq = 0

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

    private var wfdSentGetParameter = false
    private var wfdSentTrigger = false

    // Real-phone behavior (om1, i-frame-interval=10 + low-latency encoder):
    // VPS/SPS/PPS only ride with an IDR, so a sink joining a stale encoder
    // mid-GOP gets undecodable video until it asks for an IDR. Modelled as
    // "no decodable datagrams until wfd_idr_request arrives", re-armed on
    // every PLAY (each new RTSP session joins the still-running encoder).
    var withholdVideoUntilIDRRequest = false
    private var videoWithheld = false
    private(set) var idrRequestCount = 0
    private(set) var lastIDRRequestLine: String?

    private func handleWFDMessage(firstLine: String, headers: [String: String], body: Data) {
        let bodyText = String(data: body, encoding: .utf8) ?? ""
        if firstLine.hasPrefix("RTSP/") {
            // Response to one of our requests: after the capability answer,
            // fire the SETUP trigger (this is what makes the client send
            // SETUP).
            if wfdSentGetParameter, !wfdSentTrigger {
                wfdSentTrigger = true
                wfdCSeq += 1
                sendWFDRaw("SET_PARAMETER rtsp://localhost/wfd1.0 RTSP/1.0\r\nCSeq: \(wfdCSeq)\r\nContent-Type: text/parameters\r\nContent-Length: 27\r\n\r\nwfd_trigger_method: SETUP\r\n")
            }
            return
        }
        let method = firstLine.split(separator: " ").first.map(String.init) ?? ""
        let cseq = headers["cseq"].flatMap(Int.init) ?? 0
        log("fakephone.wfd_rx method=\(method) cseq=\(cseq)")
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
                lastIDRRequestLine = firstLine
                videoWithheld = false
                log("fakephone.wfd_idr_request_rx")
            }
        default:
            sendWFDRaw("RTSP/1.0 200 OK\r\nCSeq: \(cseq)\r\nContent-Length: 0\r\n\r\n")
        }
    }

    private func startVideoSender() {
        guard videoTimer == nil else { return }
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: clientVideoPort)!, using: .udp)
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

    // MARK: - Helpers

    private func gcmSeal(_ plaintext: Data, key: SymmetricKey) -> Data? {
        guard let sealed = try? AES.GCM.seal(plaintext, using: key) else { return nil }
        var out = Data()
        out.append(contentsOf: sealed.nonce.withUnsafeBytes { Data($0) })
        out.append(sealed.ciphertext)
        out.append(sealed.tag)
        return out
    }

    private func gcmOpen(_ combined: Data, key: SymmetricKey) -> Data? {
        guard combined.count > 28 else { return nil }
        let nonce = combined.prefix(12)
        let ciphertext = combined.dropFirst(12).dropLast(16)
        let tag = combined.suffix(16)
        guard let box = try? AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: Data(nonce)), ciphertext: Data(ciphertext), tag: Data(tag)
        ), let plaintext = try? AES.GCM.open(box, using: key) else { return nil }
        return plaintext
    }

    private func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress {
                arc4random_buf(base, count)
            }
        }
        return data
    }

    private func varintField(_ number: Int, in data: Data) -> UInt64? {
        (try? LyraProtoReader.readFields(from: data))?
            .first { $0.number == number && $0.wireType == 0 }?.varintValue
    }

    private func lengthDelimited(_ number: Int, in data: Data) -> Data? {
        (try? LyraProtoReader.readFields(from: data))?
            .first { $0.number == number && $0.wireType == 2 }?.lengthDelimitedValue
    }

    private func readUInt32BE(_ data: Data, at offset: Int) -> UInt32 {
        let i = data.index(data.startIndex, offsetBy: offset)
        return (UInt32(data[i]) << 24) | (UInt32(data[i + 1]) << 16) | (UInt32(data[i + 2]) << 8) | UInt32(data[i + 3])
    }

    static func data(fromHex hex: String) -> Data? {
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

    static func colonHex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}
