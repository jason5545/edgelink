import CryptoKit
import EdgeLinkKit
import Foundation
import Network

// The phone's MiShare RECEIVER (Mac's share-sheet "send to phone"): the Mac's
// LyraFileSendSession dials com.miui.mishare.connectivity:miLyraShareTransfer
// on the phone's mesh port — phys sync and the cookie exchange ride
// LyraPhoneMeshServer's built-ins — then this role answers the sync_info
// (Curve25519 cred), the P256 family-5 upgrade (deriving the CS/SC channel
// keys), the encrypted conn request (encrypted .response), and the packType-5
// requestOfPeerPort with a real channel listener + responseOfPeerPort.
//
// On the channel it plays the receiver the send session expects: express
// handshake (TCP listener + 16-byte data key), file-send accept (tag 2),
// rcvBegin (event 4), AES-GCM streamlets off the express link, rcvEnd
// (event 5), done (tag 8) — the mirror image of LyraMiShareSenderRole, wired
// to the same wire format the Mac's own LyraMeshResponder speaks.
//
// Stream bytes are checked per chunk through `chunkValidator` (invoked on the
// role queue), so tests can push 10GB without ever holding the file in
// memory; the validator also gets the exact stream offset, catching seek /
// 64-bit-offset bugs past the 4GB boundary.
public final class LyraMiShareReceiverRole: LyraServiceHandler {
    public static let defaultServiceName = "com.miui.mishare.connectivity:miLyraShareTransfer"

    public let serviceName: String

    public enum State: Sendable, Equatable {
        case idle
        case upgrading
        case connRequestWait
        case peerPortWait
        case channelWait
        case fileRequestWait
        case streamBeginWait
        case streaming
        case completeWait
        case transferDone
        case failed(String)
    }

    public struct ReceivedFile: Sendable, Equatable {
        public let streamId: UInt32
        public let name: String
        public let bytes: Int64

        public init(streamId: UInt32, name: String, bytes: Int64) {
            self.streamId = streamId
            self.name = name
            self.bytes = bytes
        }
    }

    public var onEvent: (String) -> Void = { _ in }
    public private(set) var state: State = .idle
    // Files declared in the Mac's file-send request (name + declared size).
    public private(set) var declaredFiles: [(name: String, size: Int64)] = []
    // Streams that ran to their EOF streamlet, in arrival order.
    public private(set) var receivedFiles: [ReceivedFile] = []
    public private(set) var receivedBytes: Int64 = 0
    // Per-chunk content check (streamId, offset, bytes) on the role queue;
    // returning false fails the transfer with a chunk-mismatch error.
    public var chunkValidator: ((UInt32, Int64, Data) -> Bool)?

    private let identity: LyraPhoneIdentity
    private let queue = DispatchQueue(label: "lyra.mishare.receiver", qos: .userInitiated)
    private var connId: UInt32 = 0
    private var channelKeyCS: SymmetricKey?
    private var channelKeySC: SymmetricKey?
    private var transKey = Data()
    private let serverChannelId: UInt32 = 5
    private var channelSocket: LyraChannelSocket?
    private var channelNegotiated = false
    private var expressListener: NWListener?
    private var expressDataKey = Data()
    private var expressConnections: [ObjectIdentifier: NWConnection] = [:]
    private var expressBuffers: [ObjectIdentifier: Data] = [:]
    private var eventBytesBuffer = Data()
    private var requestId: UInt64 = 0
    private var jobId = ""
    // The send session round-robins its chunks across 8 parallel express TCP
    // connections, so streamlets (and even the EOF streamlet) can land out of
    // order. Accounting is therefore offset-based — like the responder's
    // seek-write — with EOF stashed until the tail chunks catch up.
    private struct StreamState {
        var name: String
        var received: Int64 = 0
        var eofOffset: Int64?
    }

    private var activeStreams: [UInt32: StreamState] = [:]

    public init(
        identity: LyraPhoneIdentity,
        serviceName: String = LyraMiShareReceiverRole.defaultServiceName
    ) {
        self.identity = identity
        self.serviceName = serviceName
    }

    deinit {
        stop()
    }

    public func stop() {
        for connection in expressConnections.values {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
        expressConnections.removeAll()
        expressBuffers.removeAll()
        expressListener?.stateUpdateHandler = nil
        expressListener?.newConnectionHandler = nil
        expressListener?.cancel()
        expressListener = nil
        channelSocket?.stop()
        channelSocket = nil
    }

    // MARK: - LyraServiceHandler

    // The Mac's syncAuth hello: answer with our own sync_info carrying a
    // Curve25519 cred so its sync-key derivation has a peer key.
    public func handleServiceSyncInfo(
        syncInfoData: Data, logiConn: LogiConnFrame, server: LyraPhoneMeshServer
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            self.connId = logiConn.logiConnId
            var cred = Data()
            LyraProtoWriter.appendLengthDelimitedField(1, value: Self.randomBytes(8), to: &cred)
            let syncAuthKey = Curve25519.KeyAgreement.PrivateKey()
            LyraProtoWriter.appendLengthDelimitedField(
                2, value: syncAuthKey.publicKey.rawRepresentation, to: &cred
            )
            var syncInfo = Data()
            LyraProtoWriter.appendVarintField(1, value: 15000, to: &syncInfo)
            LyraProtoWriter.appendVarintField(2, value: 48, to: &syncInfo)
            LyraProtoWriter.appendVarintField(3, value: 1, to: &syncInfo)
            LyraProtoWriter.appendLengthDelimitedField(4, value: Data(self.serviceName.utf8), to: &syncInfo)
            LyraProtoWriter.appendLengthDelimitedField(5, value: cred, to: &syncInfo)
            server.sendLogi(
                connId: self.connId,
                inner: LogiConnInnerFrame(frameType: 5, payload: .syncInfo(syncInfo))
            )
            self.state = .upgrading
            self.onEvent("mishare receiver sync_info answered")
        }
    }

    public func handleServiceLogiConn(_ logiConn: LogiConnFrame, server: LyraPhoneMeshServer) {
        queue.async { [weak self] in
            guard let self else { return }
            if logiConn.flag {
                guard let key = self.channelKeyCS,
                      let plaintext = LyraAuthHandshake.gcmOpen(logiConn.inner, using: key),
                      let inner = LogiConnInnerFrame(parsing: plaintext)
                else { return }
                switch inner.payload {
                case .request:
                    // The Mac's conn request; our encrypted .response lets it
                    // proceed to responseAck + requestOfPeerPort.
                    server.sendLogi(
                        connId: self.connId,
                        inner: LogiConnInnerFrame(frameType: 2, payload: .response(Data())),
                        encryptWith: self.channelKeySC
                    )
                    self.state = .peerPortWait
                    self.onEvent("mishare receiver conn request answered")
                case let .disconnect(data):
                    self.state = .failed("disconnect \(data.map { String(format: "%02x", $0) }.joined())")
                    self.onEvent("mishare receiver disconnect")
                default:
                    break
                }
                return
            }
            guard let inner = LogiConnInnerFrame(parsing: logiConn.inner),
                  case let .upgrade(upgradeData) = inner.payload
            else { return }
            self.handleUpgrade(upgradeData: upgradeData, server: server)
        }
    }

    // packType-5: the Mac's requestOfPeerPort arrives encrypted with the CS
    // channel key (its announces ride the sync-key candidates we never
    // derived — those fail the decrypt and stay unhandled).
    public func handleServiceMeshCommand(payload: Data, server: LyraPhoneMeshServer) -> Bool {
        guard let key = channelKeyCS, payload.count > 2,
              payload[payload.index(after: payload.startIndex)] == 1,
              let plaintext = LyraAuthHandshake.gcmOpen(Data(payload.dropFirst(2)), using: key),
              let (header, body) = try? LyraChannelProtocol.decode(plaintext),
              header.type == LyraChannelProtocol.CommandType.requestOfPeerPort.rawValue
        else { return false }
        let peerTransKey = LyraAuthHandshake.lengthDelimited(4, in: body) ?? Data()
        queue.async { [weak self] in
            self?.startChannelListener(transKey: peerTransKey, server: server)
        }
        return true
    }

    // MARK: - Upgrade (family-5 server hello)

    private func handleUpgrade(upgradeData: Data, server: LyraPhoneMeshServer) {
        guard state == .upgrading,
              let handshakeFrame = LyraAuthHandshake.lengthDelimited(2, in: upgradeData),
              let family = LyraAuthHandshake.varint(1, in: handshakeFrame),
              let pairFrame = LyraAuthHandshake.lengthDelimited(family == 5 ? 8 : 6, in: handshakeFrame),
              let clientNotify = LyraAuthHandshake.lengthDelimited(2, in: pairFrame),
              let cipherSuite = LyraAuthHandshake.lengthDelimited(1, in: clientNotify),
              let clientRandom = LyraAuthHandshake.lengthDelimited(2, in: cipherSuite),
              clientRandom.count == 32,
              let publicKeyMessage = LyraAuthHandshake.lengthDelimited(5, in: cipherSuite),
              let clientPubData = LyraAuthHandshake.lengthDelimited(2, in: publicKeyMessage),
              let clientPub = try? P256.KeyAgreement.PublicKey(x963Representation: clientPubData)
        else {
            state = .failed("bad client hello")
            onEvent("mishare receiver client hello parse failed")
            return
        }
        let handshakeId = LyraAuthHandshake.varint(1, in: upgradeData) ?? 0
        let messageClass = LyraAuthHandshake.varint(2, in: handshakeFrame) ?? 0

        let privateKey = P256.KeyAgreement.PrivateKey()
        guard let secret = try? privateKey.sharedSecretFromKeyAgreement(with: clientPub)
            .withUnsafeBytes({ Data($0) })
        else {
            state = .failed("ECDH failed")
            onEvent("mishare receiver ecdh failed")
            return
        }
        let serverRandom = Self.randomBytes(32)
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

        var serverPublicKeyMessage = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &serverPublicKeyMessage)
        LyraProtoWriter.appendLengthDelimitedField(
            2, value: privateKey.publicKey.x963Representation, to: &serverPublicKeyMessage
        )
        var serverCipherSuite = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &serverCipherSuite)
        LyraProtoWriter.appendLengthDelimitedField(2, value: serverRandom, to: &serverCipherSuite)
        LyraProtoWriter.appendVarintField(3, value: family == 5 ? 32 : 16, to: &serverCipherSuite)
        LyraProtoWriter.appendVarintField(4, value: family == 5 ? 2 : 8, to: &serverCipherSuite)
        LyraProtoWriter.appendLengthDelimitedField(5, value: serverPublicKeyMessage, to: &serverCipherSuite)
        var serverNotify = Data()
        LyraProtoWriter.appendLengthDelimitedField(1, value: serverCipherSuite, to: &serverNotify)
        var serverPairFrame = Data()
        LyraProtoWriter.appendLengthDelimitedField(3, value: serverNotify, to: &serverPairFrame)
        var serverHandshake = Data()
        LyraProtoWriter.appendVarintField(1, value: family, to: &serverHandshake)
        LyraProtoWriter.appendVarintField(2, value: messageClass, to: &serverHandshake)
        LyraProtoWriter.appendLengthDelimitedField(
            family == 5 ? 8 : 6, value: serverPairFrame, to: &serverHandshake
        )
        var upgrade = Data()
        LyraProtoWriter.appendVarintField(1, value: handshakeId, to: &upgrade)
        LyraProtoWriter.appendLengthDelimitedField(2, value: serverHandshake, to: &upgrade)
        server.sendLogi(
            connId: connId,
            inner: LogiConnInnerFrame(frameType: 6, payload: .upgrade(upgrade))
        )
        state = .connRequestWait
        onEvent("mishare receiver server hello sent")
    }

    // MARK: - Channel listener + responseOfPeerPort

    private func startChannelListener(transKey: Data, server: LyraPhoneMeshServer) {
        guard state == .peerPortWait, channelSocket == nil, !transKey.isEmpty else { return }
        self.transKey = transKey
        let socket = LyraChannelSocket()
        socket.onStateChanged = { [weak self] listenerState in
            guard case .ready = listenerState else { return }
            self?.queue.async { self?.sendPeerPortResponse(server: server) }
        }
        socket.onNegotiated = { [weak self] _, _ in
            self?.queue.async { self?.handleChannelNegotiated() }
        }
        socket.onMessage = { [weak self] message, _ in
            self?.queue.async { self?.handleChannelMessage(message) }
        }
        socket.onDecryptFailure = { [weak self] reason in
            self?.queue.async { self?.onEvent("mishare receiver channel decrypt failed: \(reason)") }
        }
        do {
            try socket.start(socketKey: transKey, serverChannelId: serverChannelId)
            channelSocket = socket
        } catch {
            state = .failed("channel listener failed")
            onEvent("mishare receiver channel listener failed")
        }
    }

    private func sendPeerPortResponse(server: LyraPhoneMeshServer) {
        guard state == .peerPortWait, let port = channelSocket?.boundPort else { return }
        var body = Data()
        LyraProtoWriter.appendVarintField(2, value: UInt64(serverChannelId), to: &body)
        LyraProtoWriter.appendVarintField(3, value: UInt64(port), to: &body)
        let command = LyraChannelProtocol.encode(type: .responseOfPeerPort, body: body)
        server.sendEncryptedPayload(command, using: channelKeySC)
        state = .channelWait
        onEvent("mishare receiver responseOfPeerPort port=\(port)")
    }

    private func handleChannelNegotiated() {
        guard !channelNegotiated, state == .channelWait else { return }
        channelNegotiated = true
        var key = Data(count: 16)
        key.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress { arc4random_buf(base, 16) }
        }
        expressDataKey = key
        do {
            let listener = try NWListener(using: .tcp, on: .any)
            listener.newConnectionHandler = { [weak self] connection in
                self?.acceptExpress(connection)
            }
            listener.stateUpdateHandler = { [weak self] listenerState in
                guard let self, case .ready = listenerState,
                      let port = listener.port?.rawValue, port != 0
                else { return }
                // Beat the Mac's negotiation-reply processing: its handshake
                // handler only arms in .expressHandshakeWait.
                self.queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.sendExpressHandshake(port: UInt32(port))
                }
            }
            listener.start(queue: queue)
            expressListener = listener
        } catch {
            state = .failed("express listener failed")
            onEvent("mishare receiver express listener failed")
        }
    }

    private func sendExpressHandshake(port: UInt32) {
        guard state == .channelWait else { return }
        let tlv = LyraExpressTLV.handshakeEventFrame(dataPort: port, key: expressDataKey)
        let frame = LyraChannelSocket.wrapChannelFrame(tlv)
        do {
            try channelSocket?.sendVariant(channelFrame: frame, key: transKey, singleLayer: true)
            state = .fileRequestWait
            onEvent("mishare receiver express handshake sent port=\(port)")
        } catch {
            state = .failed("express handshake send failed")
            onEvent("mishare receiver express handshake send failed")
        }
    }

    // MARK: - Channel messages (file protocol + stream events)

    private func handleChannelMessage(_ message: Data) {
        guard let (frameTag, frameChild) = try? LyraExpressTLVParser.parseOneOf(message), frameTag == 1,
              let payloadNode = LyraExpressTLVParser.firstChild(
                  0, in: LyraExpressTLVParser.children(of: frameChild)
              ),
              let (eventTag, eventChild) = try? LyraExpressTLVParser.parseOneOf(payloadNode.payload)
        else { return }
        let children = LyraExpressTLVParser.children(of: eventChild)
        switch eventTag {
        case 2:
            let chunk = LyraExpressTLVParser.firstChild(1, in: children)?.payload ?? Data()
            eventBytesBuffer.append(chunk)
            if let complete = Self.completedFileMessage(eventBytesBuffer) {
                eventBytesBuffer = Data()
                handleFileProtocolMessage(complete)
            }
        case 3:
            handleStreamBegin(children)
        default:
            break
        }
    }

    private func handleFileProtocolMessage(_ data: Data) {
        guard let outerFields = try? LyraProtoReader.readFields(from: data),
              let envelope = outerFields.first(where: { $0.number == 2 && $0.wireType == 2 })?.lengthDelimitedValue,
              let fields = try? LyraProtoReader.readFields(from: envelope)
        else { return }
        let messageTag = outerFields.first(where: { $0.number == 1 && $0.wireType == 0 })?.varintValue ?? 0
        switch messageTag {
        case 1:
            handleFileRequest(fields)
        case 7:
            handleFileComplete(fields)
        default:
            break
        }
    }

    private func handleFileRequest(_ fields: [LyraProtoReader.Field]) {
        guard state == .fileRequestWait else { return }
        requestId = fields.first(where: { $0.number == 1 && $0.wireType == 0 })?.varintValue ?? 0
        jobId = fields.first(where: { $0.number == 3 && $0.wireType == 2 })?
            .lengthDelimitedValue.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        declaredFiles = fields.filter { $0.number == 5 && $0.wireType == 2 }.compactMap { field in
            guard let info = try? LyraProtoReader.readFields(from: field.lengthDelimitedValue ?? Data())
            else { return nil }
            let name = info.first(where: { $0.number == 1 && $0.wireType == 2 })?
                .lengthDelimitedValue.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let size = info.first(where: { $0.number == 2 && $0.wireType == 0 })?.varintValue ?? 0
            return (name: name, size: Int64(bitPattern: size))
        }
        var body = Data()
        LyraProtoWriter.appendVarintField(1, value: requestId, to: &body)
        LyraProtoWriter.appendLengthDelimitedField(2, value: Data(jobId.utf8), to: &body)
        LyraProtoWriter.appendVarintField(3, value: 0, to: &body)
        sendFileProtocolMessage(tag: 2, body: body)
        state = .streamBeginWait
        onEvent(
            "mishare receiver accepted requestId=\(requestId) files=\(declaredFiles.count) " +
                "sizes=\(declaredFiles.map { String($0.size) }.joined(separator: ","))"
        )
    }

    private func handleFileComplete(_ fields: [LyraProtoReader.Field]) {
        guard state == .completeWait || state == .streamBeginWait else { return }
        let completeRequestId = fields.first(where: { $0.number == 1 && $0.wireType == 0 })?.varintValue ?? 0
        var body = Data()
        LyraProtoWriter.appendVarintField(1, value: completeRequestId, to: &body)
        sendFileProtocolMessage(tag: 8, body: body)
        state = .transferDone
        onEvent("mishare receiver transfer done bytes=\(receivedBytes)")
    }

    private func handleStreamBegin(_ children: [LyraExpressTLVNode]) {
        guard state == .streamBeginWait || state == .streaming else { return }
        let streamId = LyraExpressTLVParser.firstChild(1, in: children)?.int32Value ?? 0
        let name = LyraExpressTLVParser.firstChild(4, in: children)
            .flatMap { String(data: $0.payload, encoding: .utf8) } ?? ""
        activeStreams[streamId] = StreamState(name: name)
        sendStreamEvent(oneOfTag: 4, child: LyraExpressTLV.containerNode(tag: 4, children: [
            LyraExpressTLV.int32Node(tag: 0, value: 2),
            LyraExpressTLV.int32Node(tag: 1, value: streamId),
            LyraExpressTLV.int32Node(tag: 2, value: 1)
        ]))
        state = .streaming
        onEvent("mishare receiver stream begin streamId=\(streamId) name=\(name)")
    }

    // MARK: - Express link (AES-GCM streamlets)

    private func acceptExpress(_ connection: NWConnection) {
        connection.start(queue: queue)
        let id = ObjectIdentifier(connection)
        expressConnections[id] = connection
        expressBuffers[id] = Data()
        receiveExpress(connection, id: id)
    }

    private func receiveExpress(_ connection: NWConnection, id: ObjectIdentifier) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) {
            [weak self] content, _, isComplete, error in
            guard let self else { return }
            if let content, !content.isEmpty {
                var buffer = self.expressBuffers[id] ?? Data()
                buffer.append(content)
                self.drainExpressFrames(&buffer)
                self.expressBuffers[id] = buffer
            }
            if error != nil || isComplete {
                self.expressBuffers.removeValue(forKey: id)
                self.expressConnections.removeValue(forKey: id)
                return
            }
            self.receiveExpress(connection, id: id)
        }
    }

    private func drainExpressFrames(_ buffer: inout Data) {
        while true {
            guard buffer.count >= 10 else { return }
            let header = Array(buffer.prefix(10))
            guard header[0] == 0, header[1] == 0, header[2] == 0,
                  header[3] == 0, header[4] == 0, header[5] == 0
            else {
                buffer = Data()
                return
            }
            let payloadLength = (Int(header[6]) << 24) | (Int(header[7]) << 16) | (Int(header[8]) << 8) | Int(header[9])
            guard buffer.count >= 10 + payloadLength else { return }
            let payload = Data(buffer[buffer.index(buffer.startIndex, offsetBy: 10)..<buffer.index(buffer.startIndex, offsetBy: 10 + payloadLength)])
            buffer.removeFirst(10 + payloadLength)
            decryptExpressFrame(payload)
        }
    }

    private func decryptExpressFrame(_ payload: Data) {
        guard payload.count > 28, !expressDataKey.isEmpty else { return }
        let nonce = payload.prefix(12)
        let tag = payload[payload.index(payload.startIndex, offsetBy: 12)..<payload.index(payload.startIndex, offsetBy: 28)]
        let ciphertext = payload[payload.index(payload.startIndex, offsetBy: 28)...]
        guard let sealedBox = try? AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: Data(nonce)),
            ciphertext: Data(ciphertext),
            tag: Data(tag)
        ), let plaintext = try? AES.GCM.open(sealedBox, using: SymmetricKey(data: expressDataKey))
        else {
            state = .failed("express decrypt failed")
            onEvent("mishare receiver express decrypt failed bytes=\(payload.count)")
            return
        }
        guard plaintext.count >= 2 else { return }
        let trailerOffset = plaintext.count - 2
        let tlvLength = (Int(plaintext[trailerOffset]) << 8) | Int(plaintext[trailerOffset + 1])
        guard tlvLength <= trailerOffset else { return }
        let tlv = Data(plaintext[(trailerOffset - tlvLength)..<trailerOffset])
        let chunkData = Data(plaintext[..<(trailerOffset - tlvLength)])
        guard let (streamletTag, child) = try? LyraExpressTLVParser.parseOneOf(tlv), streamletTag == 0x100
        else { return }
        handleStreamlet(LyraExpressTLVParser.children(of: child), data: chunkData)
    }

    private func handleStreamlet(_ children: [LyraExpressTLVNode], data: Data) {
        let streamId = LyraExpressTLVParser.firstChild(1, in: children)?.int32Value ?? 0
        let offset = Int64(bitPattern: LyraExpressTLVParser.firstChild(2, in: children)?.int64Value ?? 0)
        let streamletSize = Int32(bitPattern: LyraExpressTLVParser.firstChild(3, in: children)?.int32Value ?? 0)
        guard var stream = activeStreams[streamId] else { return }
        if streamletSize > 0 {
            if let chunkValidator, !chunkValidator(streamId, offset, data) {
                state = .failed("chunk mismatch stream=\(streamId) offset=\(offset)")
                onEvent("mishare receiver chunk mismatch streamId=\(streamId) offset=\(offset)")
                return
            }
            stream.received += Int64(data.count)
            receivedBytes += Int64(data.count)
            activeStreams[streamId] = stream
            finishStreamIfComplete(streamId)
            return
        }
        if streamletSize == 0 {
            stream.eofOffset = offset
            activeStreams[streamId] = stream
            finishStreamIfComplete(streamId)
            return
        }
        state = .failed("stream error code=\(streamletSize)")
        onEvent("mishare receiver stream error streamId=\(streamId) code=\(streamletSize)")
    }

    // The EOF streamlet can overtake tail chunks riding other express
    // connections; the stream only completes once the byte count catches up
    // to the EOF offset (overrun means duplicated/lost chunks — a real bug).
    private func finishStreamIfComplete(_ streamId: UInt32) {
        guard let stream = activeStreams[streamId], let eofOffset = stream.eofOffset else { return }
        if stream.received > eofOffset {
            state = .failed("stream overrun stream=\(streamId) received=\(stream.received) eof=\(eofOffset)")
            onEvent("mishare receiver stream overrun streamId=\(streamId)")
            return
        }
        guard stream.received == eofOffset else { return }
        activeStreams.removeValue(forKey: streamId)
        receivedFiles.append(ReceivedFile(streamId: streamId, name: stream.name, bytes: stream.received))
        sendStreamEvent(oneOfTag: 5, child: LyraExpressTLV.containerNode(tag: 5, children: [
            LyraExpressTLV.int32Node(tag: 0, value: 0),
            LyraExpressTLV.int32Node(tag: 1, value: streamId),
            LyraExpressTLV.int32Node(tag: 2, value: 1)
        ]))
        state = receivedFiles.count >= declaredFiles.count ? .completeWait : .streamBeginWait
        onEvent("mishare receiver stream complete streamId=\(streamId) bytes=\(stream.received)")
    }

    // MARK: - Sends

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
        sendChannelFrame(LyraChannelSocket.wrapChannelFrame(event))
    }

    private func sendStreamEvent(oneOfTag: UInt16, child: Data) {
        let inner = LyraExpressTLV.oneOfNode(tag: 0xFFFF, selectedTag: oneOfTag, child: child)
        sendChannelFrame(LyraChannelSocket.wrapChannelFrame(inner))
    }

    private func sendChannelFrame(_ frame: Data) {
        do {
            try channelSocket?.sendVariant(channelFrame: frame, key: transKey, singleLayer: true)
        } catch {
            onEvent("mishare receiver channel send failed")
        }
    }

    // Same framing check as the responder / sender role: field-1 varint tag,
    // field-2 bytes envelope; complete once the declared envelope length is
    // buffered.
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

    private static func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress { arc4random_buf(base, count) }
        }
        return data
    }
}
