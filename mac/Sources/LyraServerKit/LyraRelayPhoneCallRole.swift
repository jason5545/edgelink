import CryptoKit
import EdgeLinkKit
import Foundation
import Network

// The phone's relayPhoneCall (com.android.phone) endpoint: accepts the Mac's
// LyraRelayCallDialer dial (phys sync → cookie → sync_info → P256 auth →
// encrypted logi request → responseOfPeerPort → channel), answers
// relay://dial with 200, and models TeleService's channel-pair lifecycle:
// each dial is a channel pair the phone releases either on the Mac's
// explicit logi disconnect or via a post-call-end timer — and the release
// handler clears deviceInRelay UNCONDITIONALLY, even when the next call
// already re-armed it (live 2026-08-10: call 1's pair, released ~85s after
// call 1 ended, clobbered call 2's relay state 4s into the call; TeleService
// then logged "createRelayChannel...No relay service created" /
// "callback enqueue" and never connected call 2's relay audio).
public final class LyraRelayPhoneCallRole: LyraServiceHandler {
    public static let relayPhoneCallServiceName = "com.android.phone:relayPhoneCall"
    public static let servicePackage = "com.android.phone"
    public let serviceName = LyraRelayPhoneCallRole.relayPhoneCallServiceName

    public var onEvent: (String) -> Void = { _ in }

    // Relay mode: when set (a LyraRelayTransportBridge channel flow on the
    // phone side), the dial channel rides the relay pipe instead of a real
    // UDP listener — mirrors AndroidLyraRelayTransportBridge's per-flow
    // channel socket that forwards to the phone's local channel listener.
    public var channelPipe: LyraVirtualChannelPipe?

    // MARK: - Assertion surface

    public struct DialRequest: Equatable {
        public var address: String
        public var requestDeviceId: String
    }

    public private(set) var dialRequests: [DialRequest] = []
    public private(set) var dialChannelUpConnIds: [UInt32] = []
    public private(set) var releases: [(connId: UInt32, reason: String)] = []
    public private(set) var deviceInRelay: String?
    // The TeleService bug: a stale pair's release cleared deviceInRelay
    // while a (new) call was active.
    public private(set) var deviceInRelayClearedWhileCallActive = 0

    // The dialer's mesh session key — the phone dials its return
    // (relayCall) channel on the same phys conn with it.
    public private(set) var sessionKey: SymmetricKey?

    // MARK: - TeleService call model knobs

    // How long after call end the phone holds the dial channel pair before
    // releasing it (live: ~85s). Tests shrink this.
    public var releaseDelayAfterCallEnd: TimeInterval = 85
    public private(set) var callActive = false

    public func noteCallActive() {
        queue.async { self.callActive = true }
    }

    // The call ended on the phone. The pair release timer starts now; the
    // Mac's explicit logi disconnect (LyraRelayCallDialer.callEnded)
    // releases the pair earlier, while no call is in flight.
    public func noteCallEnded() {
        queue.async {
            self.callActive = false
            let connId = self.currentConnId
            self.queue.asyncAfter(deadline: .now() + self.releaseDelayAfterCallEnd) { [weak self] in
                self?.releaseConn(connId: connId, reason: "post_call_idle")
            }
        }
    }

    // MARK: - Conn state

    private final class DialConn {
        var connId: UInt32 = 0
        var peerNetId: UInt32 = 1
        var clientRandom = Data()
        var serverRandom = Data()
        var transKey = Data()
        var clientChannelId: UInt64 = 7
        var serverChannelId: UInt64 = 0
        var channelListener: NWListener?
        var channelConnection: NWConnection?
        var channelSendSn: UInt32 = 0
        var channelRecvUna: UInt32 = 0
        var released = false
    }

    private let queue = DispatchQueue(label: "LyraRelayPhoneCallRole")
    // Listener state updates must not land on `queue`: listenDialChannel
    // spins on `queue` waiting for the bound port.
    private let listenerQueue = DispatchQueue(label: "LyraRelayPhoneCallRole.listener")
    private weak var server: LyraPhoneMeshServer?
    private var conns: [UInt32: DialConn] = [:]
    private var currentConnId: UInt32 = 0
    private var authEphPriv: P256.KeyAgreement.PrivateKey?
    private var authAccountPair = false

    public init() {}

    // AUTH-family HKDF salts (mirror LyraRelayCallDialer).
    private static let sessionSalt = Data([
        0x5e, 0xd5, 0xa3, 0xf8, 0x36, 0xf6, 0xb5, 0x4f,
        0x7b, 0x1e, 0xfa, 0xd0, 0x27, 0x14, 0xd5, 0x17,
        0x7b, 0x8a, 0x1f, 0x0f, 0x19, 0xe3, 0x69, 0xcc,
        0x0b, 0xe8, 0xd9, 0x8b, 0xa6, 0x29, 0x73, 0x17,
    ])
    private static let accountPairSessionSalt = Data([
        0x32, 0x9b, 0xfc, 0x53, 0x39, 0x36, 0x55, 0xd7,
        0x5a, 0xb0, 0x83, 0x98, 0xca, 0x91, 0x91, 0xef,
        0xfa, 0xa3, 0x37, 0xf2, 0xe0, 0xbe, 0xb5, 0x73,
        0xb1, 0xf9, 0xa3, 0xd0, 0x15, 0x57, 0x64, 0x80,
    ])

    // MARK: - LyraServiceHandler

    public func handleServiceSyncInfo(
        syncInfoData: Data, logiConn: LogiConnFrame, server: LyraPhoneMeshServer
    ) {
        queue.async {
            self.server = server
            let conn = DialConn()
            conn.connId = logiConn.logiConnId
            conn.peerNetId = logiConn.localNetId
            self.conns[conn.connId] = conn
            var syncInfo = Data()
            LyraProtoWriter.appendVarintField(1, value: 15000, to: &syncInfo)
            LyraProtoWriter.appendVarintField(2, value: 48, to: &syncInfo)
            LyraProtoWriter.appendVarintField(3, value: 1, to: &syncInfo)
            LyraProtoWriter.appendLengthDelimitedField(4, value: Data(Self.relayPhoneCallServiceName.utf8), to: &syncInfo)
            let inner = LogiConnInnerFrame(frameType: 5, payload: .syncInfo(syncInfo))
            server.sendLogi(connId: conn.connId, inner: inner)
            self.onEvent("relaydial sync_info answered connId=\(conn.connId)")
        }
    }

    public func handleServiceLogiConn(_ logiConn: LogiConnFrame, server: LyraPhoneMeshServer) {
        queue.async {
            guard let conn = self.conns[logiConn.logiConnId] else { return }
            if logiConn.flag {
                self.handleEncryptedLogiConn(logiConn, conn: conn, server: server)
                return
            }
            guard let inner = LogiConnInnerFrame(parsing: logiConn.inner) else { return }
            if case let .upgrade(data) = inner.payload {
                self.handleAuthUpgrade(data, conn: conn, server: server)
            }
        }
    }

    public func handleServiceMeshCommand(payload: Data, server: LyraPhoneMeshServer) -> Bool {
        false
    }

    // MARK: - Auth (lenient: signatures are logged, never verified — the
    // dialer proceeds regardless, so the mock only needs the frame shapes)

    private func handleAuthUpgrade(_ data: Data, conn: DialConn, server: LyraPhoneMeshServer) {
        guard let handshake = LyraAuthHandshake.lengthDelimited(2, in: data),
              let authFrame = LyraAuthHandshake.lengthDelimited(7, in: handshake)
                ?? LyraAuthHandshake.lengthDelimited(6, in: handshake),
              let step = LyraAuthHandshake.varint(1, in: authFrame)
        else { return }
        let handshakeId = LyraAuthHandshake.varint(1, in: data) ?? 1
        authAccountPair = LyraAuthHandshake.lengthDelimited(7, in: handshake) == nil
        switch step {
        case 1:
            handleClientNotify(authFrame: authFrame, handshakeId: handshakeId, conn: conn, server: server)
        case 3:
            // client_finished: contents are not verified. Reply
            // server_finished (step 4); the proof blob is never validated
            // by the dialer either.
            var serverFinished = Data()
            LyraProtoWriter.appendLengthDelimitedField(1, value: randomBytes(40), to: &serverFinished)
            var outAuth = Data()
            LyraProtoWriter.appendVarintField(1, value: 4, to: &outAuth)
            LyraProtoWriter.appendLengthDelimitedField(5, value: serverFinished, to: &outAuth)
            var handshakeOut = Data()
            LyraProtoWriter.appendVarintField(1, value: 6, to: &handshakeOut)
            LyraProtoWriter.appendVarintField(2, value: 7, to: &handshakeOut)
            LyraProtoWriter.appendLengthDelimitedField(7, value: outAuth, to: &handshakeOut)
            var upgrade = Data()
            LyraProtoWriter.appendVarintField(1, value: handshakeId, to: &upgrade)
            LyraProtoWriter.appendLengthDelimitedField(2, value: handshakeOut, to: &upgrade)
            let inner = LogiConnInnerFrame(frameType: 6, payload: .upgrade(upgrade))
            server.sendLogi(connId: conn.connId, inner: inner)
            onEvent("relaydial auth server_finished connId=\(conn.connId)")
        default:
            break
        }
    }

    private func handleClientNotify(
        authFrame: Data, handshakeId: UInt64, conn: DialConn, server: LyraPhoneMeshServer
    ) {
        guard let clientNotify = LyraAuthHandshake.lengthDelimited(2, in: authFrame),
              let cipherSuite = LyraAuthHandshake.lengthDelimited(1, in: clientNotify),
              let clientRandom = LyraAuthHandshake.lengthDelimited(2, in: cipherSuite),
              let pkMsg = LyraAuthHandshake.lengthDelimited(5, in: cipherSuite),
              let clientEph = LyraAuthHandshake.lengthDelimited(2, in: pkMsg),
              let peerKey = try? P256.KeyAgreement.PublicKey(x963Representation: clientEph)
        else {
            onEvent("relaydial client_notify parse failed")
            return
        }
        let eph = P256.KeyAgreement.PrivateKey()
        guard let secret = try? eph.sharedSecretFromKeyAgreement(with: peerKey)
            .withUnsafeBytes({ Data($0) })
        else { return }
        authEphPriv = eph
        conn.clientRandom = clientRandom
        let serverRandom = randomBytes(32)
        conn.serverRandom = serverRandom
        sessionKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            salt: authAccountPair ? Self.accountPairSessionSalt : Self.sessionSalt,
            info: clientRandom + serverRandom,
            outputByteCount: 32
        )

        var outPkMsg = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &outPkMsg)
        LyraProtoWriter.appendLengthDelimitedField(2, value: eph.publicKey.x963Representation, to: &outPkMsg)
        var selected = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &selected)
        LyraProtoWriter.appendLengthDelimitedField(2, value: serverRandom, to: &selected)
        LyraProtoWriter.appendVarintField(3, value: 32, to: &selected)
        LyraProtoWriter.appendVarintField(4, value: 2, to: &selected)
        LyraProtoWriter.appendLengthDelimitedField(5, value: outPkMsg, to: &selected)
        var serverNotify = Data()
        LyraProtoWriter.appendLengthDelimitedField(1, value: selected, to: &serverNotify)
        if authAccountPair {
            // encSig must exist for the dialer's account-pair path; its
            // contents are only logged, never gated on.
            LyraProtoWriter.appendLengthDelimitedField(2, value: randomBytes(48), to: &serverNotify)
        }
        var outAuth = Data()
        LyraProtoWriter.appendVarintField(1, value: 2, to: &outAuth)
        LyraProtoWriter.appendLengthDelimitedField(3, value: serverNotify, to: &outAuth)
        var handshakeOut = Data()
        LyraProtoWriter.appendVarintField(1, value: 5, to: &handshakeOut)
        LyraProtoWriter.appendVarintField(2, value: 6, to: &handshakeOut)
        LyraProtoWriter.appendLengthDelimitedField(7, value: outAuth, to: &handshakeOut)
        var upgrade = Data()
        LyraProtoWriter.appendVarintField(1, value: handshakeId, to: &upgrade)
        LyraProtoWriter.appendLengthDelimitedField(2, value: handshakeOut, to: &upgrade)
        let inner = LogiConnInnerFrame(frameType: 6, payload: .upgrade(upgrade))
        server.sendLogi(connId: conn.connId, inner: inner)
        onEvent("relaydial auth server_notify connId=\(conn.connId) accountPair=\(authAccountPair)")
    }

    // MARK: - Encrypted logi (post-auth)

    private func handleEncryptedLogiConn(_ logiConn: LogiConnFrame, conn: DialConn, server: LyraPhoneMeshServer) {
        guard let key = sessionKey,
              let plaintext = LyraAuthHandshake.gcmOpen(logiConn.inner, using: key),
              let inner = LogiConnInnerFrame(parsing: plaintext)
        else { return }
        switch inner.payload {
        case let .request(requestData):
            // logi conn request: userInfo{10: peerPortRequest{1: channelId, 4: transKey}}
            let userInfo = LyraAuthHandshake.lengthDelimited(3, in: requestData) ?? Data()
            if let peerPortRequest = LyraAuthHandshake.lengthDelimited(10, in: userInfo) {
                let fields = (try? LyraProtoReader.readFields(from: peerPortRequest)) ?? []
                for field in fields {
                    switch field.number {
                    case 1: conn.clientChannelId = field.varintValue ?? 7
                    case 4: conn.transKey = field.lengthDelimitedValue ?? Data()
                    default: break
                    }
                }
            }
            currentConnId = conn.connId
            var responseData = Data()
            LyraProtoWriter.appendVarintField(1, value: 1, to: &responseData)
            let response = LogiConnInnerFrame(frameType: 2, payload: .response(responseData))
            server.sendLogi(connId: conn.connId, inner: response, encryptWith: key)
            onEvent("relaydial logi response connId=\(conn.connId)")
            listenDialChannel(conn: conn)
            sendPeerPortResponse(conn: conn, server: server)
        case let .disconnect(data):
            let code = LyraAuthHandshake.varint(1, in: data) ?? 0
            onEvent("relaydial disconnect connId=\(conn.connId) code=\(code)")
            releaseConn(connId: conn.connId, reason: "mac_disconnect")
        default:
            break
        }
    }

    private func sendPeerPortResponse(conn: DialConn, server: LyraPhoneMeshServer) {
        let channelPort: UInt16?
        if let pipe = channelPipe {
            channelPort = pipe.boundPort
        } else {
            channelPort = conn.channelListener?.port?.rawValue
        }
        guard let key = sessionKey, let port = channelPort, port != 0 else { return }
        conn.serverChannelId = UInt64.random(in: 40...60)
        var body = Data()
        LyraProtoWriter.appendVarintField(2, value: conn.serverChannelId, to: &body)
        LyraProtoWriter.appendVarintField(3, value: UInt64(port), to: &body)
        let command = LyraChannelProtocol.encode(type: .responseOfPeerPort, body: body)
        guard let sealed = LyraAuthHandshake.gcmSeal(command, using: key) else { return }
        var payload = Data([0x01, 0x00])
        payload.append(sealed)
        server.sendToPeer(frame: LyraMeshPack.Frame(packType: 5, payload: payload))
        onEvent("relaydial peer_port_tx port=\(port) connId=\(conn.connId)")
    }

    // MARK: - Dial channel server

    private func listenDialChannel(conn: DialConn) {
        if let pipe = channelPipe {
            // Relay pipe mode: the pipe terminates KCP, answers the client
            // negotiation TLV itself, and delivers decrypted payloads.
            pipe.onNegotiated = { [weak self] _, _ in
                guard let self else { return }
                self.queue.async {
                    if !self.dialChannelUpConnIds.contains(conn.connId) {
                        self.dialChannelUpConnIds.append(conn.connId)
                    }
                    self.onEvent("relaydial channel negotiated connId=\(conn.connId) relayPipe=true")
                }
            }
            pipe.onMessage = { [weak self] message, _ in
                self?.queue.async { self?.handleDialChannelMessage(message, conn: conn) }
            }
            do {
                // The pipe ignores serverChannelId; boundPort = defaultPort.
                try pipe.start(socketKey: conn.transKey, serverChannelId: 0)
                onEvent("relaydial channel pipe up port=\(pipe.boundPort ?? 0) connId=\(conn.connId)")
            } catch {
                onEvent("relaydial channel pipe start failed: \(error)")
            }
            return
        }
        do {
            let listener = try NWListener(using: .udp, on: .any)
            conn.channelListener = listener
            listener.newConnectionHandler = { [weak self, weak conn] connection in
                self?.queue.async {
                    guard let conn else { return }
                    conn.channelConnection?.cancel()
                    conn.channelConnection = connection
                    conn.channelSendSn = 0
                    conn.channelRecvUna = 0
                    connection.start(queue: self!.queue)
                    self?.receiveDialChannel(on: connection, conn: conn)
                }
            }
            listener.start(queue: listenerQueue)
            // NWListener reports port 0 until bound; spin briefly (same
            // pattern as LyraMirrorCallAudioSource.start).
            var waited = 0
            while (listener.port?.rawValue ?? 0) == 0, waited < 100 {
                Thread.sleep(forTimeInterval: 0.01)
                waited += 1
            }
        } catch {
            onEvent("relaydial channel listen failed: \(error)")
        }
    }

    private func receiveDialChannel(on connection: NWConnection, conn: DialConn) {
        connection.receiveMessage { [weak self] content, _, _, error in
            guard let self else { return }
            if let content, !content.isEmpty,
               let segment = try? LyraMeshDatagram.decodeSegment(content),
               segment.command == LyraMeshDatagram.commandPush,
               segment.sn >= conn.channelRecvUna
            {
                conn.channelRecvUna = segment.sn &+ 1
                let ack = LyraMeshDatagram.encodeAck(
                    tick: LyraMeshSocket.tick(), sn: segment.sn, una: conn.channelRecvUna
                )
                connection.send(content: ack, completion: .idempotent)
                self.handleDialChannelPayload(segment.payload, conn: conn)
            }
            if error == nil, !conn.released {
                self.receiveDialChannel(on: connection, conn: conn)
            }
        }
    }

    private func sendDialChannel(_ payload: Data, conn: DialConn) {
        let datagram = LyraMeshDatagram.encode(
            tick: LyraMeshSocket.tick(), sn: conn.channelSendSn, una: conn.channelRecvUna, payload: payload
        )
        conn.channelSendSn &+= 1
        conn.channelConnection?.send(content: datagram, completion: .idempotent)
    }

    private func handleDialChannelPayload(_ payload: Data, conn: DialConn) {
        let bytes = Array(payload)
        if bytes.count >= 2, bytes[0] == 0x01, bytes[1] == 0x01 {
            // TLV client negotiation: reply selectedTag 4 echoing the channel id.
            guard let (selectedTag, children) = LyraChannelSocket.parseOneOf(payload),
                  selectedTag == 0, let channelId = children.first
            else { return }
            let reply = LyraExpressTLV.oneOfNode(
                tag: 0xFFFF,
                selectedTag: 4,
                child: LyraExpressTLV.containerNode(tag: 4, children: [
                    LyraExpressTLV.int32Node(tag: 0, value: channelId),
                    LyraExpressTLV.int32Node(tag: 1, value: 0xFF00),
                ])
            )
            sendDialChannel(reply, conn: conn)
            if !dialChannelUpConnIds.contains(conn.connId) {
                dialChannelUpConnIds.append(conn.connId)
            }
            onEvent("relaydial channel negotiated connId=\(conn.connId)")
            return
        }
        guard bytes.count >= 2, bytes[0] == 0x81, bytes[1] == 0x04,
              let (plaintext, _) = try? LyraSocketPacket.decode(payload, key: SymmetricKey(data: conn.transKey)),
              let (tag, child) = try? LyraExpressTLVParser.parseOneOf(plaintext), tag == 1,
              let payloadNode = LyraExpressTLVParser.firstChild(0, in: LyraExpressTLVParser.children(of: child)),
              let text = String(data: payloadNode.payload, encoding: .utf8)
        else { return }
        onEvent("relaydial uri rx \(text)")
        handleDialURI(text, conn: conn)
    }

    private func handleDialURI(_ text: String, conn: DialConn) {
        guard text.hasPrefix("relay://dial:"), text.contains("/request?"),
              let query = text.split(separator: "?", maxSplits: 1).last,
              let data = String(query).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        let methodId = String(text.dropFirst("relay://dial:".count).prefix(while: { $0 != "/" }))
        let address = object["address"] as? String ?? ""
        let deviceId = object["requestDeviceId"] as? String ?? ""
        dialRequests.append(DialRequest(address: address, requestDeviceId: deviceId))
        // TeleService handleRelayDialRequest: setDeviceInRelay runs on every
        // dial, unconditionally.
        deviceInRelay = deviceId
        let json =
            "{\"hostDeviceName\":\"FakePhone\",\"address\":\"\(address)\"," +
            "\"callstate\":-1,\"code\":200,\"msg\":\"ok\",\"responseDeviceId\":\"4995163F\"}"
        sendChannelText("relay://dial:\(methodId)/response?\(json)", conn: conn)
        onEvent("relaydial dial answered connId=\(conn.connId) address=\(address)")
    }

    // Pipe-mode entry: KCP/negotiation/81-04 layers already terminated by
    // the pipe; the message is the decrypted channel frame.
    private func handleDialChannelMessage(_ message: Data, conn: DialConn) {
        guard let (tag, child) = try? LyraExpressTLVParser.parseOneOf(message), tag == 1,
              let payloadNode = LyraExpressTLVParser.firstChild(0, in: LyraExpressTLVParser.children(of: child)),
              let text = String(data: payloadNode.payload, encoding: .utf8)
        else { return }
        onEvent("relaydial uri rx \(text)")
        handleDialURI(text, conn: conn)
    }

    private func sendChannelText(_ text: String, conn: DialConn) {
        guard !conn.transKey.isEmpty else { return }
        if let pipe = channelPipe {
            do {
                try pipe.sendVariant(
                    channelFrame: LyraChannelSocket.wrapChannelFrame(Data(text.utf8)),
                    key: conn.transKey,
                    singleLayer: true
                )
            } catch {
                onEvent("relaydial channel pipe tx failed: \(error)")
            }
            return
        }
        do {
            let packet = try LyraSocketPacket.encode(
                plaintext: LyraChannelSocket.wrapChannelFrame(Data(text.utf8)),
                key: SymmetricKey(data: conn.transKey)
            )
            sendDialChannel(packet, conn: conn)
        } catch {
            onEvent("relaydial channel tx failed: \(error)")
        }
    }

    // MARK: - TeleService pair release

    private func releaseConn(connId: UInt32, reason: String) {
        guard let conn = conns[connId], !conn.released else { return }
        conn.released = true
        conn.channelConnection?.cancel()
        conn.channelListener?.cancel()
        releases.append((connId: connId, reason: reason))
        // TeleService PhoneContinuityController.onChannelRelease clears the
        // relay state unconditionally — even if a NEW call already re-armed
        // it. That is the live 2026-08-10 clobber.
        if deviceInRelay != nil {
            deviceInRelay = nil
            if callActive {
                deviceInRelayClearedWhileCallActive += 1
            }
        }
        onEvent("relaydial pair released connId=\(connId) reason=\(reason) callActive=\(callActive)")
    }

    private func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress { arc4random_buf(base, count) }
        }
        return data
    }
}
