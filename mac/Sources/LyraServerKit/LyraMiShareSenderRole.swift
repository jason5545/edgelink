import CryptoKit
import EdgeLinkKit
import Foundation
import Network

// The phone's MiShare sender (gallery share-sheet "send to this Mac"): dials
// the Mac's miLyraShareTransfer service on a classic logi conn — sync_info
// (Curve25519 sync-auth cred), P256 upgrade, encrypted conn request,
// responseAck, then packType-5 requestOfPeerPort — and expects the Mac's
// responseOfPeerPort back on the same conn.
//
// The dial rides whatever phys conn the phone's score-based reuse picks:
// its own mesh conn, or the Mac's ANNOUNCER conn (live 2026-08-21: the
// announcer conn won, the Mac dropped the sync_info as announcer_stray_conn,
// and the phone's 15s kcp timeout surfaced as 「連線失敗」).
// `dial(server:toHost:port:)` targets the Mac's published mesh port directly;
// `dial(server:)` rides the established announce peer conn.
//
// After the channel port arrives the role can also push an actual file,
// mirroring the phone's send flow (same wire format the Mac's own
// LyraFileSendSession speaks): channel connect + negotiation, express
// handshake, file-send request, stream begin, AES-GCM streamlets over the
// express TCP link, EOF streamlet, file complete. Small files can ride the
// file message inline (the responder's no-stream path); large ones stream in
// chunks so tests can push 10GB without holding it in memory.
public final class LyraMiShareSenderRole: LyraServiceHandler {
    public static let defaultServiceName = "com.xiaomi.hyperConnect:miLyraShareTransfer"

    public let serviceName: String

    public enum State: Sendable, Equatable {
        case idle
        case dialing
        case upgrading
        case requesting
        case channelNegotiating
        case channelReady
        case channelConnecting
        case expressHandshakeWait
        case fileRequestWait
        case streamBeginWait
        case streaming
        case streamEndWait
        case completeWait
        case transferDone
        case failed(String)
    }

    public var onEvent: (String) -> Void = { _ in }
    public private(set) var state: State = .idle
    // The Mac's channel listener port, from its responseOfPeerPort.
    public private(set) var receivedChannelPort: UInt32?
    // Bytes pushed through the express link during the current transfer.
    public private(set) var transferredBytes: Int64 = 0

    private let identity: LyraPhoneIdentity
    private var connId: UInt32 = 0
    private var channelId: UInt32 = 0
    private var transKey = Data()
    private var transRandom = Data()
    private var p256Key: P256.KeyAgreement.PrivateKey?
    private var clientRandom = Data()
    private var channelKey: SymmetricKey?
    private var dialHost: String?
    private var dialPort: UInt16?

    // MARK: - Transfer state

    public enum TransferMode {
        // Small file: the bytes ride file-message field 4 and the responder
        // writes them without a stream (must stay under the ~64KB channel
        // fragment window).
        case inlineData(Data)
        // Large file: streamlets of `chunkSize` over the express TCP link;
        // chunkSource(offset, count) generates bytes on demand.
        case stream(size: Int64, chunkSize: Int, chunkSource: (Int64, Int) -> Data)
    }

    private let transferQueue = DispatchQueue(label: "lyra.mishare.sender.transfer", qos: .userInitiated)
    private var channelSocket: LyraChannelSocket?
    private var expressConnection: NWConnection?
    private var expressDataKey = Data()
    private var eventBytesBuffer = Data()
    private var transferMode: TransferMode?
    private var channelHost = "127.0.0.1"
    private var transferFileName = ""
    private var jobId = ""
    private var requestId: UInt64 = 0
    private var currentStreamId: UInt32 = 0
    private var sendOffset: Int64 = 0
    private var receivedServerChannelId: UInt32?

    public init(
        identity: LyraPhoneIdentity,
        serviceName: String = LyraMiShareSenderRole.defaultServiceName
    ) {
        self.identity = identity
        self.serviceName = serviceName
    }

    deinit {
        stopTransfer()
    }

    public func dial(server: LyraPhoneMeshServer, toHost host: String? = nil, port: UInt16? = nil) {
        state = .dialing
        receivedChannelPort = nil
        channelKey = nil
        p256Key = nil
        dialHost = host
        dialPort = port
        connId = UInt32.random(in: 1...UInt32.max)
        channelId = UInt32.random(in: 1...UInt32.max)
        transKey = Self.randomBytes(32)
        transRandom = Self.randomBytes(32)
        server.adoptOutboundConn(connId: connId, handler: self)

        var cred = Data()
        LyraProtoWriter.appendLengthDelimitedField(1, value: Self.randomBytes(8), to: &cred)
        let syncAuthKey = Curve25519.KeyAgreement.PrivateKey()
        LyraProtoWriter.appendLengthDelimitedField(
            2, value: syncAuthKey.publicKey.rawRepresentation, to: &cred
        )
        var syncInfo = Data()
        LyraProtoWriter.appendVarintField(1, value: 10000, to: &syncInfo)
        LyraProtoWriter.appendVarintField(2, value: 48, to: &syncInfo)
        LyraProtoWriter.appendVarintField(3, value: 7, to: &syncInfo)
        LyraProtoWriter.appendLengthDelimitedField(4, value: Data(serviceName.utf8), to: &syncInfo)
        LyraProtoWriter.appendLengthDelimitedField(5, value: cred, to: &syncInfo)
        send(inner: LogiConnInnerFrame(frameType: 5, payload: .syncInfo(syncInfo)), server: server)
        onEvent("mishare sender dialed")
    }

    // MARK: - LyraServiceHandler

    public func handleServiceSyncInfo(
        syncInfoData: Data, logiConn: LogiConnFrame, server: LyraPhoneMeshServer
    ) {
        // Outbound role: the Mac's sync_info REPLY arrives via
        // handleServiceLogiConn on the adopted outbound conn.
    }

    public func handleServiceLogiConn(_ logiConn: LogiConnFrame, server: LyraPhoneMeshServer) {
        if logiConn.flag {
            guard let key = channelKey,
                  let plaintext = LyraAuthHandshake.gcmOpen(logiConn.inner, using: key),
                  let inner = LogiConnInnerFrame(parsing: plaintext)
            else { return }
            switch inner.payload {
            case .response:
                // The Mac acked the conn request; the responseAck kicks off
                // its channel listener, then we ask for its port.
                send(
                    inner: LogiConnInnerFrame(frameType: 3, payload: .responseAck(Data())),
                    server: server, encryptWith: key
                )
                sendRequestOfPeerPort(server: server, key: key)
                state = .channelNegotiating
                onEvent("mishare sender responseAck + requestOfPeerPort sent")
            case let .disconnect(data):
                state = .failed("disconnect \(data.map { String(format: "%02x", $0) }.joined())")
                onEvent("mishare sender disconnect")
            default:
                break
            }
            return
        }
        guard let inner = LogiConnInnerFrame(parsing: logiConn.inner) else { return }
        switch inner.payload {
        case .syncInfo:
            // The Mac's sync-auth response (its Curve25519 cred); the receive
            // flow goes straight for the P256 channel-key upgrade.
            sendUpgrade(server: server)
        case let .upgrade(upgradeData):
            handleUpgradeReply(upgradeData: upgradeData, server: server)
        default:
            break
        }
    }

    // packType-5 commands the announce session key could not decrypt — the
    // Mac's responseOfPeerPort is encrypted with the channel key.
    public func handleServiceMeshCommand(payload: Data, server: LyraPhoneMeshServer) -> Bool {
        guard let key = channelKey, payload.count > 2,
              payload[payload.index(after: payload.startIndex)] == 1,
              let plaintext = LyraAuthHandshake.gcmOpen(Data(payload.dropFirst(2)), using: key),
              let (header, body) = try? LyraChannelProtocol.decode(plaintext),
              header.type == LyraChannelProtocol.CommandType.responseOfPeerPort.rawValue,
              let port = LyraAuthHandshake.varint(3, in: body)
        else { return false }
        receivedChannelPort = UInt32(port)
        receivedServerChannelId = LyraAuthHandshake.varint(2, in: body).map { UInt32($0) }
        state = .channelReady
        onEvent("mishare sender channel port=\(port)")
        return true
    }

    // MARK: - File transfer

    // Sends one file to the Mac. Requires .channelReady first. The transfer
    // state machine runs on transferQueue; progress is visible via `state`
    // and `transferredBytes`, completion via .transferDone / .failed.
    public func sendFile(name: String, mode: TransferMode, host: String? = nil) {
        transferQueue.async { [weak self] in
            self?.startTransfer(name: name, mode: mode, host: host)
        }
    }

    public func stopTransfer() {
        expressConnection?.stateUpdateHandler = nil
        expressConnection?.cancel()
        expressConnection = nil
        channelSocket?.stop()
        channelSocket = nil
    }

    private func startTransfer(name: String, mode: TransferMode, host: String?) {
        guard state == .channelReady,
              let port = receivedChannelPort,
              let channelPort = UInt16(exactly: port)
        else {
            state = .failed("sendFile before channelReady")
            onEvent("mishare sender sendFile rejected: no channel")
            return
        }
        transferFileName = name
        transferMode = mode
        transferredBytes = 0
        sendOffset = 0
        eventBytesBuffer = Data()
        requestId = UInt64.random(in: 1...1_000_000_000)
        jobId = UUID().uuidString
        currentStreamId = 1
        channelHost = host ?? dialHost ?? "127.0.0.1"
        state = .channelConnecting

        let socket = LyraChannelSocket()
        socket.onNegotiated = { [weak self] _, _ in
            self?.transferQueue.async {
                guard let self, self.state == .channelConnecting else { return }
                self.state = .expressHandshakeWait
                self.onEvent("mishare sender channel negotiated")
            }
        }
        socket.onMessage = { [weak self] message, _ in
            self?.transferQueue.async { self?.handleTransferChannelMessage(message) }
        }
        socket.onDecryptFailure = { [weak self] reason in
            self?.transferQueue.async { self?.onEvent("mishare sender channel decrypt failed: \(reason)") }
        }
        do {
            try socket.connect(host: channelHost, port: channelPort, socketKey: transKey)
            channelSocket = socket
        } catch {
            state = .failed("channel connect failed")
            onEvent("mishare sender channel connect failed")
            return
        }
        sendChannelNegotiation(attempt: 0)
    }

    private func sendChannelNegotiation(attempt: Int) {
        guard state == .channelConnecting, attempt < 5, let socket = channelSocket else { return }
        do {
            try socket.sendClientNegotiation(
                channelId: receivedServerChannelId ?? channelId, version: 1, mtu: 0xFF00
            )
        } catch {
            onEvent("mishare sender channel negotiation send failed")
        }
        transferQueue.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.sendChannelNegotiation(attempt: attempt + 1)
        }
    }

    private func handleTransferChannelMessage(_ message: Data) {
        guard let (frameTag, frameChild) = try? LyraExpressTLVParser.parseOneOf(message), frameTag == 1,
              let payloadNode = LyraExpressTLVParser.firstChild(
                  0, in: LyraExpressTLVParser.children(of: frameChild)
              ),
              let (eventTag, eventChild) = try? LyraExpressTLVParser.parseOneOf(payloadNode.payload)
        else { return }
        let children = LyraExpressTLVParser.children(of: eventChild)
        switch eventTag {
        case 1:
            handleExpressHandshake(children)
        case 2:
            let chunk = LyraExpressTLVParser.firstChild(1, in: children)?.payload ?? Data()
            eventBytesBuffer.append(chunk)
            if let complete = Self.completedFileMessage(eventBytesBuffer) {
                eventBytesBuffer = Data()
                handleFileProtocolMessage(complete)
            }
        case 4:
            handleRcvBegin(children)
        case 5:
            handleRcvEnd(children)
        default:
            break
        }
    }

    private func handleExpressHandshake(_ children: [LyraExpressTLVNode]) {
        guard state == .expressHandshakeWait || state == .channelConnecting else { return }
        let dataPort = LyraExpressTLVParser.firstChild(3, in: children)?.int32Value ?? 0
        let key = LyraExpressTLVParser.firstChild(4, in: children)?.payload ?? Data()
        guard dataPort != 0, key.count == 16, let port = UInt16(exactly: dataPort) else {
            state = .failed("bad express handshake")
            onEvent("mishare sender bad express handshake")
            return
        }
        expressDataKey = key
        let connection = NWConnection(
            host: NWEndpoint.Host(channelHost),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        expressConnection = connection
        connection.start(queue: transferQueue)
        onEvent("mishare sender express handshake port=\(dataPort)")
        sendFileSendRequest()
    }

    private func sendFileSendRequest() {
        state = .fileRequestWait
        var request = Data()
        LyraProtoWriter.appendVarintField(1, value: requestId, to: &request)
        LyraProtoWriter.appendLengthDelimitedField(2, value: Data("MiShareMockPhone".utf8), to: &request)
        LyraProtoWriter.appendLengthDelimitedField(3, value: Data(jobId.utf8), to: &request)
        var fileSize: Int64 = 0
        switch transferMode {
        case let .inlineData(data):
            fileSize = Int64(data.count)
            LyraProtoWriter.appendLengthDelimitedField(4, value: data, to: &request)
        case let .stream(size, _, _):
            fileSize = size
        case nil:
            break
        }
        var info = Data()
        LyraProtoWriter.appendLengthDelimitedField(1, value: Data(transferFileName.utf8), to: &info)
        LyraProtoWriter.appendVarintField(2, value: UInt64(bitPattern: fileSize), to: &info)
        LyraProtoWriter.appendLengthDelimitedField(3, value: Data(jobId.utf8), to: &info)
        LyraProtoWriter.appendLengthDelimitedField(5, value: Data("application/octet-stream".utf8), to: &info)
        LyraProtoWriter.appendLengthDelimitedField(5, value: info, to: &request)
        LyraProtoWriter.appendVarintField(14, value: 1, to: &request)
        sendFileProtocolMessage(tag: 1, body: request)
        onEvent("mishare sender file request sent name=\(transferFileName) size=\(fileSize)")
    }

    private func handleFileProtocolMessage(_ data: Data) {
        guard let outerFields = try? LyraProtoReader.readFields(from: data),
              let envelope = outerFields.first(where: { $0.number == 2 && $0.wireType == 2 })?.lengthDelimitedValue,
              let fields = try? LyraProtoReader.readFields(from: envelope)
        else { return }
        let messageTag = outerFields.first(where: { $0.number == 1 && $0.wireType == 0 })?.varintValue ?? 0
        switch messageTag {
        case 2:
            let rejectReason = fields.first(where: { $0.number == 3 && $0.wireType == 0 })?.varintValue ?? 0
            guard state == .fileRequestWait else { return }
            if rejectReason != 0 {
                state = .failed("receiver rejected (\(rejectReason))")
                onEvent("mishare sender rejected reason=\(rejectReason)")
                return
            }
            if case let .inlineData(data) = transferMode {
                transferredBytes = Int64(data.count)
                state = .transferDone
                onEvent("mishare sender inline file accepted bytes=\(data.count)")
            } else {
                sendStreamBegin()
            }
        case 8:
            guard state == .completeWait else { return }
            state = .transferDone
            onEvent("mishare sender transfer complete bytes=\(transferredBytes)")
        default:
            break
        }
    }

    private func sendStreamBegin() {
        state = .streamBeginWait
        let begin = LyraExpressTLV.oneOfNode(
            tag: 0xFFFF,
            selectedTag: 3,
            child: LyraExpressTLV.containerNode(tag: 3, children: [
                LyraExpressTLV.int32Node(tag: 0, value: 0),
                LyraExpressTLV.int32Node(tag: 1, value: currentStreamId),
                LyraExpressTLV.int64Node(tag: 2, value: UInt64(bitPattern: Int64(-1))),
                LyraExpressTLV.stringNode(tag: 3, value: Data()),
                LyraExpressTLV.stringNode(tag: 4, value: Data(transferFileName.utf8)),
                LyraExpressTLV.stringNode(tag: 5, value: Data(jobId.utf8))
            ])
        )
        sendEventFrame(begin)
        onEvent("mishare sender stream begin streamId=\(currentStreamId)")
    }

    private func handleRcvBegin(_ children: [LyraExpressTLVNode]) {
        let streamId = LyraExpressTLVParser.firstChild(1, in: children)?.int32Value ?? 0
        guard state == .streamBeginWait, streamId == currentStreamId else { return }
        state = .streaming
        onEvent("mishare sender streaming")
        sendNextChunk()
    }

    private func sendNextChunk() {
        guard state == .streaming,
              case let .stream(size, chunkSize, chunkSource) = transferMode,
              let connection = expressConnection
        else { return }
        let offset = sendOffset
        let chunk: Data
        if offset < size {
            chunk = chunkSource(offset, Int(min(Int64(chunkSize), size - offset)))
        } else {
            chunk = Data()
        }
        let isEOF = offset >= size || chunk.isEmpty
        let streamlet = LyraExpressTLV.oneOfNode(
            tag: 0xFFFF,
            selectedTag: 0x100,
            child: LyraExpressTLV.containerNode(tag: 0x100, children: [
                LyraExpressTLV.stringNode(tag: 0, value: Data()),
                LyraExpressTLV.int32Node(tag: 1, value: currentStreamId),
                LyraExpressTLV.int64Node(tag: 2, value: UInt64(bitPattern: offset)),
                LyraExpressTLV.int32Node(tag: 3, value: isEOF ? 0 : UInt32(chunk.count))
            ])
        )
        var plaintext = Data()
        if !isEOF {
            plaintext.append(chunk)
        }
        plaintext.append(streamlet)
        plaintext.append(UInt8((streamlet.count >> 8) & 0xFF))
        plaintext.append(UInt8(streamlet.count & 0xFF))
        do {
            let nonce = AES.GCM.Nonce()
            let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: expressDataKey), nonce: nonce)
            var payload = Data()
            payload.append(contentsOf: nonce.withUnsafeBytes { Data($0) })
            payload.append(sealed.tag)
            payload.append(sealed.ciphertext)
            var frame = Data(capacity: 10 + payload.count)
            frame.append(contentsOf: [0, 0, 0, 0, 0, 0])
            let length = UInt32(payload.count)
            frame.append(UInt8((length >> 24) & 0xFF))
            frame.append(UInt8((length >> 16) & 0xFF))
            frame.append(UInt8((length >> 8) & 0xFF))
            frame.append(UInt8(length & 0xFF))
            frame.append(payload)
            connection.send(content: frame, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if let error {
                    self.state = .failed("express send: \(error.localizedDescription)")
                    self.onEvent("mishare sender express send failed")
                    return
                }
                if isEOF {
                    self.state = .streamEndWait
                    self.onEvent("mishare sender stream eof bytes=\(self.sendOffset)")
                    return
                }
                self.sendOffset += Int64(chunk.count)
                self.transferredBytes += Int64(chunk.count)
                self.sendNextChunk()
            })
        } catch {
            state = .failed("express seal failed")
            onEvent("mishare sender express seal failed")
        }
    }

    private func handleRcvEnd(_ children: [LyraExpressTLVNode]) {
        let result = LyraExpressTLVParser.firstChild(0, in: children)?.int32Value ?? 0
        let streamId = LyraExpressTLVParser.firstChild(1, in: children)?.int32Value ?? 0
        guard state == .streamEndWait, streamId == currentStreamId else { return }
        guard result == 0 else {
            state = .failed("receiver stream failed (\(result))")
            onEvent("mishare sender stream failed result=\(result)")
            return
        }
        state = .completeWait
        var complete = Data()
        LyraProtoWriter.appendVarintField(1, value: requestId, to: &complete)
        LyraProtoWriter.appendLengthDelimitedField(2, value: Data(jobId.utf8), to: &complete)
        sendFileProtocolMessage(tag: 7, body: complete)
        onEvent("mishare sender file complete sent")
    }

    private func sendFileProtocolMessage(tag: UInt64, body: Data) {
        var protocolFrame = Data()
        LyraProtoWriter.appendVarintField(1, value: tag, to: &protocolFrame)
        LyraProtoWriter.appendLengthDelimitedField(2, value: body, to: &protocolFrame)
        let event = LyraExpressTLV.oneOfNode(
            tag: 0xFFFF,
            selectedTag: 2,
            child: LyraExpressTLV.containerNode(tag: 2, children: [
                LyraExpressTLV.int32Node(tag: 0, value: 0),
                LyraExpressTLV.stringNode(tag: 1, value: protocolFrame)
            ])
        )
        sendEventFrame(event)
    }

    private func sendEventFrame(_ inner: Data) {
        do {
            try channelSocket?.send(message: inner)
        } catch {
            onEvent("mishare sender event send failed")
        }
    }

    // Same framing check as the responder: field-1 varint tag, field-2 bytes
    // envelope; complete once the declared envelope length is buffered.
    private static func completedFileMessage(_ buffer: Data) -> Data? {
        let bytes = Array(buffer)
        guard bytes.count >= 6, bytes[0] == 0x08, bytes[2] == 0x12 else {
            return nil
        }
        var index = 3
        var length: UInt64 = 0
        var shift: UInt64 = 0
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            length |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 {
                break
            }
            shift += 7
        }
        let total = UInt64(index) + length
        guard total <= UInt64(Int.max), bytes.count >= Int(total) else {
            return nil
        }
        return Data(bytes.prefix(Int(total)))
    }

    // MARK: - Flow steps

    private func sendUpgrade(server: LyraPhoneMeshServer) {
        let privateKey = P256.KeyAgreement.PrivateKey()
        p256Key = privateKey
        clientRandom = Self.randomBytes(32)

        var publicKeyMessage = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &publicKeyMessage)
        LyraProtoWriter.appendLengthDelimitedField(
            2, value: privateKey.publicKey.x963Representation, to: &publicKeyMessage
        )
        var cipherSuites = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &cipherSuites)
        LyraProtoWriter.appendLengthDelimitedField(2, value: clientRandom, to: &cipherSuites)
        LyraProtoWriter.appendVarintField(3, value: 1, to: &cipherSuites)
        LyraProtoWriter.appendVarintField(4, value: 1, to: &cipherSuites)
        LyraProtoWriter.appendLengthDelimitedField(5, value: publicKeyMessage, to: &cipherSuites)
        var clientNotify = Data()
        LyraProtoWriter.appendLengthDelimitedField(1, value: cipherSuites, to: &clientNotify)
        var pairFrame = Data()
        LyraProtoWriter.appendLengthDelimitedField(2, value: clientNotify, to: &pairFrame)
        var handshakeFrame = Data()
        LyraProtoWriter.appendVarintField(1, value: 2, to: &handshakeFrame)
        LyraProtoWriter.appendVarintField(2, value: 4, to: &handshakeFrame)
        // family != 5 → the pair frame rides handshake field 6 (the shape the
        // Mac's parseAuthClientHello expects).
        LyraProtoWriter.appendLengthDelimitedField(6, value: pairFrame, to: &handshakeFrame)
        var authFrame = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &authFrame)
        LyraProtoWriter.appendLengthDelimitedField(2, value: handshakeFrame, to: &authFrame)
        send(inner: LogiConnInnerFrame(frameType: 6, payload: .upgrade(authFrame)), server: server)
        state = .upgrading
        onEvent("mishare sender upgrade sent")
    }

    private func handleUpgradeReply(upgradeData: Data, server: LyraPhoneMeshServer) {
        guard let handshakeFrame = LyraAuthHandshake.lengthDelimited(2, in: upgradeData),
              let family = LyraAuthHandshake.varint(1, in: handshakeFrame),
              let pairFrame = LyraAuthHandshake.lengthDelimited(family == 5 ? 8 : 6, in: handshakeFrame),
              let serverNotify = LyraAuthHandshake.lengthDelimited(3, in: pairFrame),
              let cipherSuite = LyraAuthHandshake.lengthDelimited(1, in: serverNotify),
              let serverRandom = LyraAuthHandshake.lengthDelimited(2, in: cipherSuite),
              serverRandom.count == 32,
              let publicKeyMessage = LyraAuthHandshake.lengthDelimited(5, in: cipherSuite),
              let serverPubData = LyraAuthHandshake.lengthDelimited(2, in: publicKeyMessage),
              let p256Key,
              let serverPub = try? P256.KeyAgreement.PublicKey(x963Representation: serverPubData),
              let secret = try? p256Key.sharedSecretFromKeyAgreement(with: serverPub)
                  .withUnsafeBytes({ Data($0) })
        else {
            state = .failed("bad upgrade reply")
            onEvent("mishare sender upgrade reply parse failed")
            return
        }
        // The Mac tries clientRandom+serverRandom ("cs") first and keeps the
        // variant that decrypts; it answers with that same variant.
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            salt: LyraMeshHkdf.salt,
            info: clientRandom + serverRandom,
            outputByteCount: 32
        )
        channelKey = key

        var channelRequest = Data()
        LyraProtoWriter.appendVarintField(1, value: UInt64(channelId), to: &channelRequest)
        LyraProtoWriter.appendLengthDelimitedField(4, value: transKey, to: &channelRequest)
        LyraProtoWriter.appendLengthDelimitedField(5, value: transRandom, to: &channelRequest)
        var privateData = Data()
        LyraProtoWriter.appendLengthDelimitedField(10, value: channelRequest, to: &privateData)
        var request = Data()
        LyraProtoWriter.appendLengthDelimitedField(2, value: Data(serviceName.utf8), to: &request)
        LyraProtoWriter.appendLengthDelimitedField(3, value: privateData, to: &request)
        send(
            inner: LogiConnInnerFrame(frameType: 1, payload: .request(request)),
            server: server, encryptWith: key
        )
        state = .requesting
        onEvent("mishare sender conn request sent")
    }

    private func sendRequestOfPeerPort(server: LyraPhoneMeshServer, key: SymmetricKey) {
        var body = Data()
        LyraProtoWriter.appendVarintField(1, value: UInt64(channelId), to: &body)
        LyraProtoWriter.appendLengthDelimitedField(4, value: transKey, to: &body)
        let command = LyraChannelProtocol.encode(type: .requestOfPeerPort, body: body)
        guard let sealed = LyraAuthHandshake.gcmSeal(command, using: key) else { return }
        var payload = Data()
        payload.append(UInt8(identity.netId & 0xFF))
        payload.append(1)
        payload.append(sealed)
        sendMeshFrame(LyraMeshPack.Frame(packType: 5, payload: payload), server: server)
    }

    // MARK: - Sends

    private func send(
        inner: LogiConnInnerFrame, server: LyraPhoneMeshServer, encryptWith key: SymmetricKey? = nil
    ) {
        if let host = dialHost, let port = dialPort {
            server.sendLogi(connId: connId, inner: inner, encryptWith: key, toHost: host, port: port)
        } else {
            server.sendLogi(connId: connId, inner: inner, encryptWith: key)
        }
    }

    private func sendMeshFrame(_ frame: LyraMeshPack.Frame, server: LyraPhoneMeshServer) {
        if let host = dialHost, let port = dialPort {
            server.send(frame: frame, to: host, port: port)
        } else {
            server.sendToPeer(frame: frame)
        }
    }

    private static func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress { arc4random_buf(base, count) }
        }
        return data
    }
}
