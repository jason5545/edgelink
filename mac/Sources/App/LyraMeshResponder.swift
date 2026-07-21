import CryptoKit
import EdgeLinkKit
import Foundation
import Network

final class LyraMeshResponder {
    private static let officialMacUidFeature = Data([
        0x0A, 0x08, 0x26, 0xFB, 0x1C, 0x8E, 0xAC, 0x7C, 0xFC, 0x1F, 0x12, 0x20,
        0x57, 0x65, 0xD7, 0xBF, 0xBD, 0xC3, 0xCA, 0x3C, 0x8B, 0x99, 0xF2, 0xA5,
        0x96, 0x08, 0xD3, 0x95, 0x8E, 0x2B, 0xC3, 0xEC, 0x1F, 0x64, 0x81, 0xEB,
        0x11, 0xB6, 0x56, 0x13, 0x08, 0x27, 0x21, 0xBF
    ])
    private static let officialMacSyncInfoSignature = Data([
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

    private let socket: LyraMeshSocket
    private let deviceIdHexProvider: () -> String?
    private let displayNameProvider: () -> String
    private var keyAgreementKey: P256.KeyAgreement.PrivateKey?
    private var authClientRandom = Data()
    private var authServerRandom = Data()
    private var authSharedSecret = Data()
    private var channelKey: SymmetricKey?
    private var expressHandshakeDone = false
    private var expressListener: NWListener?
    private let expressQueue = DispatchQueue(label: "edgelink.lyra.express")
    private var channelSocket: LyraChannelSocket?
    private var channelServerKey = Data()
    private var phoneTransKey = Data()
    private var peerChannelId: UInt32 = 0
    private var channelNegotiationStarted = false

    private static let hkdfSalt = Data([
        0x5E, 0xD5, 0xA3, 0xF8, 0x36, 0xF6, 0xB5, 0x4F,
        0x7B, 0x1E, 0xFA, 0xD0, 0x27, 0x14, 0xD5, 0x17,
        0x7B, 0x8A, 0x1F, 0x0F, 0x19, 0xE3, 0x69, 0xCC,
        0x0B, 0xE8, 0xD9, 0x8B, 0xA6, 0x29, 0x73, 0x17
    ])

    init(
        socket: LyraMeshSocket,
        deviceIdHexProvider: @escaping () -> String?,
        displayNameProvider: @escaping () -> String
    ) {
        self.socket = socket
        self.deviceIdHexProvider = deviceIdHexProvider
        self.displayNameProvider = displayNameProvider
    }

    func attach() {
        socket.onFrame = { [weak self] frame, endpoint, reply in
            self?.handle(frame: frame, endpoint: endpoint, reply: reply)
        }
    }

    private func handle(frame: LyraMeshPack.Frame, endpoint: NWEndpoint, reply: LyraMeshSocket.ReplyHandler) {
        if frame.packType == 5 {
            handlePayloadV2(frame: frame, endpoint: endpoint)
            return
        }
        guard let miFrame = MiConnectFrame(parsing: frame.payload) else {
            return
        }
        if let physConn = miFrame.physConnFrame {
            if case let .syncDeviceInfoRequest(requestData) = physConn.payload,
               let request = PhysConnSyncDeviceInfoRequest(parsing: requestData) {
                handleSyncRequest(frame: frame, physConn: physConn, request: request, endpoint: endpoint, reply: reply)
                return
            }
            if case let .keepAliveRequest(requestData) = physConn.payload {
                handleKeepAliveRequest(
                    frame: frame, physConn: physConn, request: requestData, endpoint: endpoint, reply: reply
                )
                return
            }
            if case let .disconnectRequest(requestData) = physConn.payload {
                handleDisconnectRequest(
                    frame: frame, physConn: physConn, request: requestData, endpoint: endpoint, reply: reply
                )
                return
            }
        }
        for logiConn in miFrame.logiConnFrames {
            if logiConn.flag {
                handleEncryptedLogiConn(frame: frame, logiConn: logiConn, endpoint: endpoint, reply: reply)
            } else {
                handleLogiConn(frame: frame, logiConn: logiConn, endpoint: endpoint, reply: reply)
            }
        }
    }

    private func handleEncryptedLogiConn(
        frame: LyraMeshPack.Frame,
        logiConn: LogiConnFrame,
        endpoint: NWEndpoint,
        reply: LyraMeshSocket.ReplyHandler
    ) {
        let inner = logiConn.inner
        guard !authSharedSecret.isEmpty, inner.count > 28 else {
            DiagnosticsLog.warn("xiaomi.mishare.mesh_logi_enc_nokey bytes=\(inner.count)")
            return
        }

        let nonce = inner.prefix(12)
        let ciphertext = inner.dropFirst(12).dropLast(16)
        let tag = inner.suffix(16)
        let infos: [(String, Data)] = [
            ("cs", authClientRandom + authServerRandom),
            ("sc", authServerRandom + authClientRandom)
        ]
        for (label, info) in infos {
            let key = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: SymmetricKey(data: authSharedSecret),
                salt: Self.hkdfSalt,
                info: info,
                outputByteCount: 32
            )
            do {
                let sealedBox = try AES.GCM.SealedBox(
                    nonce: AES.GCM.Nonce(data: nonce),
                    ciphertext: ciphertext,
                    tag: tag
                )
                let plaintext = try AES.GCM.open(sealedBox, using: key)
                channelKey = key
                DiagnosticsLog.info(
                    "xiaomi.mishare.mesh_logi_enc_decrypted from=\(endpoint.debugDescription) " +
                        "variant=\(label) hex=\(plaintext.map { String(format: "%02x", $0) }.joined())"
                )
                if let innerFrame = LogiConnInnerFrame(parsing: plaintext) {
                    if case let .request(requestData) = innerFrame.payload {
                        parseLogiConnRequest(requestData)
                        sendLogiConnResponse(
                            frame: frame, logiConn: logiConn, endpoint: endpoint, reply: reply
                        )
                    } else if case .responseAck = innerFrame.payload {
                        startChannelNegotiation(
                            frame: frame, logiConn: logiConn, endpoint: endpoint
                        )
                    }
                }
                return
            } catch {
                continue
            }
        }
        DiagnosticsLog.warn("xiaomi.mishare.mesh_logi_enc_decrypt_failed bytes=\(inner.count)")
    }

    private func parseLogiConnRequest(_ data: Data) {
        guard let fields = try? LyraProtoReader.readFields(from: data) else {
            return
        }
        var serviceName = ""
        var privateData = Data()
        for field in fields {
            switch (field.number, field.wireType) {
            case (2, 2):
                serviceName = field.lengthDelimitedValue.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            case (3, 2):
                privateData = field.lengthDelimitedValue ?? Data()
            default:
                continue
            }
        }
        var transKey = Data()
        var channelId: UInt32 = 0
        if let pdFields = try? LyraProtoReader.readFields(from: privateData) {
            for field in pdFields where field.wireType == 2 {
                if field.number == 3, let value = field.lengthDelimitedValue {
                    transKey = Self.parseColonHexKey(value) ?? value
                } else if field.number == 10, let value = field.lengthDelimitedValue,
                          let innerFields = try? LyraProtoReader.readFields(from: value)
                {
                    for innerField in innerFields where innerField.number == 1 && innerField.wireType == 0 {
                        channelId = UInt32(innerField.varintValue ?? 0)
                    }
                }
            }
        }
        if !transKey.isEmpty {
            phoneTransKey = transKey
        }
        if channelId != 0 {
            peerChannelId = channelId
        }
        DiagnosticsLog.info(
            "xiaomi.mishare.mesh_logi_request service=\(serviceName) " +
                "privateDataBytes=\(privateData.count) transKeyBytes=\(transKey.count) channelId=\(channelId)"
        )
    }

    private static func parseColonHexKey(_ data: Data) -> Data? {
        guard let string = String(data: data, encoding: .utf8), string.contains(":") else {
            return nil
        }
        let parts = string.split(separator: ":")
        guard parts.count == 32 else {
            return nil
        }
        var key = Data()
        for part in parts {
            guard let byte = UInt8(part, radix: 16) else {
                return nil
            }
            key.append(byte)
        }
        return key
    }

    private func handlePayloadV2(frame: LyraMeshPack.Frame, endpoint: NWEndpoint) {
        let body = frame.payload
        guard let channelKey, body.count > 30 else {
            return
        }
        let flag = body[body.index(body.startIndex, offsetBy: 1)]
        guard flag == 1 else {
            DiagnosticsLog.info(
                "xiaomi.mishare.channel_payload_plain from=\(endpoint.debugDescription) bytes=\(body.count)"
            )
            return
        }
        let nonce = body[body.index(body.startIndex, offsetBy: 2)..<body.index(body.startIndex, offsetBy: 14)]
        let ciphertext = body[body.index(body.startIndex, offsetBy: 14)..<body.index(body.endIndex, offsetBy: -16)]
        let tag = body[body.index(body.endIndex, offsetBy: -16)..<body.endIndex]
        guard let sealedBox = try? AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: Data(nonce)),
            ciphertext: Data(ciphertext),
            tag: Data(tag)
        ), let plaintext = try? AES.GCM.open(sealedBox, using: channelKey) else {
            DiagnosticsLog.warn("xiaomi.mishare.channel_payload_decrypt_failed bytes=\(body.count)")
            return
        }
        DiagnosticsLog.info(
            "xiaomi.mishare.channel_payload from=\(endpoint.debugDescription) bytes=\(plaintext.count) " +
                "hex=\(plaintext.prefix(96).map { String(format: "%02x", $0) }.joined())"
        )
        guard let (header, commandBody) = try? LyraChannelProtocol.decode(plaintext) else {
            return
        }
        if header.type == LyraChannelProtocol.CommandType.requestOfPeerPort.rawValue,
           let request = LyraChannelProtocol.PeerPortRequest(parsing: commandBody)
        {
            peerChannelId = request.channelId
            if request.transKey.count == 32 {
                phoneTransKey = request.transKey
            }
            DiagnosticsLog.info(
                "xiaomi.mishare.channel_port_request channelId=\(request.channelId) " +
                    "transKeyBytes=\(request.transKey.count)"
            )
        }
    }

    private func startChannelNegotiation(
        frame: LyraMeshPack.Frame,
        logiConn: LogiConnFrame,
        endpoint: NWEndpoint
    ) {
        guard !channelNegotiationStarted, channelKey != nil else {
            return
        }
        channelNegotiationStarted = true

        var serverKey = Data(count: 32)
        serverKey.withUnsafeMutableBytes { buffer in
            if let baseAddress = buffer.baseAddress {
                arc4random_buf(baseAddress, 32)
            }
        }
        channelServerKey = serverKey

        let endpointDescription = endpoint.debugDescription
        let logiConnId = logiConn.logiConnId
        let remoteNetId = logiConn.localNetId

        let socket = LyraChannelSocket()
        socket.onRawDatagram = { datagram, from in
            DiagnosticsLog.info(
                "xiaomi.mishare.channel_socket_rx from=\(from.debugDescription) bytes=\(datagram.count)"
            )
        }
        socket.onStateChanged = { [weak self] state in
            guard let self else { return }
            DiagnosticsLog.info("xiaomi.mishare.channel_socket_state state=\(String(describing: state))")
            guard case .ready = state, let port = socket.boundPort, port != 0, let channelKey = self.channelKey else {
                return
            }
            let response = LyraChannelProtocol.encodePeerPortResponse(
                peerChannelId: self.peerChannelId,
                serverChannelId: 5,
                port: UInt32(port),
                key: serverKey
            )
            do {
                try self.sendEncryptedChannelData(
                    response,
                    packType: 5,
                    logiConnId: logiConnId,
                    remoteNetId: remoteNetId,
                    endpointDescription: endpointDescription,
                    channelKey: channelKey
                )
                DiagnosticsLog.info(
                    "xiaomi.mishare.channel_port_response to=\(endpointDescription) port=\(port) " +
                        "peerChannelId=\(self.peerChannelId) bytes=\(response.count)"
                )
            } catch {
                DiagnosticsLog.error("xiaomi.mishare.channel_port_response_failed", error)
            }
        }
        socket.onPeerConnected = { [weak self] from in
            DiagnosticsLog.info("xiaomi.mishare.channel_socket_peer from=\(from.debugDescription)")
            self?.sendExpressHandshakeOverChannel()
        }
        socket.onMessage = { message, from in
            DiagnosticsLog.info(
                "xiaomi.mishare.channel_socket_message from=\(from.debugDescription) bytes=\(message.count) " +
                    "hex=\(message.prefix(128).map { String(format: "%02x", $0) }.joined())"
            )
        }
        do {
            let peerKey = phoneTransKey.isEmpty ? Data(count: 32) : phoneTransKey
            try socket.start(peerKey: peerKey, localKey: serverKey)
            channelSocket = socket
        } catch {
            DiagnosticsLog.error("xiaomi.mishare.channel_socket_start_failed", error)
        }
    }

    private func sendExpressHandshakeOverChannel() {
        guard !expressHandshakeDone, !channelServerKey.isEmpty else {
            return
        }
        expressHandshakeDone = true

        var key = Data(count: 16)
        key.withUnsafeMutableBytes { buffer in
            if let baseAddress = buffer.baseAddress {
                arc4random_buf(baseAddress, 16)
            }
        }

        do {
            let listener = try NWListener(using: .tcp, on: .any)
            listener.newConnectionHandler = { [weak self] connection in
                self?.acceptExpressConnection(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                DiagnosticsLog.info("xiaomi.mishare.express_listener_state state=\(String(describing: state))")
                guard case .ready = state, let port = listener.port?.rawValue, port != 0 else {
                    return
                }
                let tlv = LyraExpressTLV.handshakeEventFrame(dataPort: UInt32(port), key: key)
                do {
                    try self.channelSocket?.send(message: tlv)
                    DiagnosticsLog.info(
                        "xiaomi.mishare.express_handshake_sent dataPort=\(port) " +
                            "key=\(key.map { String(format: "%02x", $0) }.joined()) tlvBytes=\(tlv.count)"
                    )
                } catch {
                    DiagnosticsLog.error("xiaomi.mishare.express_handshake_failed", error)
                }
            }
            listener.start(queue: expressQueue)
            expressListener = listener
        } catch {
            DiagnosticsLog.error("xiaomi.mishare.express_handshake_failed", error)
        }
    }

    private func sendEncryptedChannelData(
        _ plaintext: Data,
        packType: UInt8,
        logiConnId: UInt32,
        remoteNetId: UInt32,
        endpointDescription: String,
        channelKey: SymmetricKey
    ) throws {
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(plaintext, using: channelKey, nonce: nonce)
        var body = Data()
        body.append(UInt8(remoteNetId & 0xFF))
        body.append(1)
        body.append(contentsOf: nonce.withUnsafeBytes { Data($0) })
        body.append(sealed.ciphertext)
        body.append(sealed.tag)

        let dataFrame = LyraMeshPack.Frame(packType: 5, payload: body)
        try socket.sendInbound(frame: dataFrame, toEndpointDescription: endpointDescription)
    }

    private func acceptExpressConnection(_ connection: NWConnection) {
        let endpoint = connection.endpoint
        DiagnosticsLog.info("xiaomi.mishare.express_conn from=\(endpoint.debugDescription)")
        connection.start(queue: expressQueue)
        receiveExpressData(connection)
    }

    private func receiveExpressData(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            if let content, !content.isEmpty {
                DiagnosticsLog.info(
                    "xiaomi.mishare.express_rx from=\(connection.endpoint.debugDescription) bytes=\(content.count) " +
                        "hex=\(content.prefix(256).map { String(format: "%02x", $0) }.joined())"
                )
            }
            if let error {
                DiagnosticsLog.error("xiaomi.mishare.express_rx_failed", error)
                return
            }
            if isComplete {
                DiagnosticsLog.info("xiaomi.mishare.express_conn_closed from=\(connection.endpoint.debugDescription)")
                return
            }
            self?.receiveExpressData(connection)
        }
    }

    private func sendLogiConnResponse(
        frame: LyraMeshPack.Frame,
        logiConn: LogiConnFrame,
        endpoint: NWEndpoint,
        reply: LyraMeshSocket.ReplyHandler
    ) {
        guard let channelKey else {
            return
        }
        let responseInner = LogiConnInnerFrame(frameType: 2, payload: .response(Data()))
        do {
            let nonce = AES.GCM.Nonce()
            let sealed = try AES.GCM.seal(responseInner.serialized(), using: channelKey, nonce: nonce)
            var encryptedInner = Data()
            encryptedInner.append(contentsOf: nonce.withUnsafeBytes { Data($0) })
            encryptedInner.append(sealed.ciphertext)
            encryptedInner.append(sealed.tag)

            let responseLogiConn = LogiConnFrame(
                logiConnId: logiConn.logiConnId,
                localNetId: 1,
                remoteNetId: logiConn.localNetId,
                flag: true,
                inner: encryptedInner
            )
            let miResponse = MiConnectFrame(version: 0, logiConnFrames: [responseLogiConn])
            let responseFrame = LyraMeshPack.Frame(packType: frame.packType, payload: miResponse.serialized())
            try reply(responseFrame)
            DiagnosticsLog.info(
                "xiaomi.mishare.mesh_logi_response to=\(endpoint.debugDescription) " +
                    "logiConnId=\(logiConn.logiConnId) encryptedBytes=\(encryptedInner.count)"
            )
        } catch {
            DiagnosticsLog.error("xiaomi.mishare.mesh_logi_response_failed", error)
        }
    }

    private func handleLogiConn(
        frame: LyraMeshPack.Frame,
        logiConn: LogiConnFrame,
        endpoint: NWEndpoint,
        reply: LyraMeshSocket.ReplyHandler
    ) {
        guard let inner = LogiConnInnerFrame(parsing: logiConn.inner) else {
            return
        }
        switch inner.payload {
        case let .syncInfo(syncInfoData):
            handleLogiSyncInfo(
                syncInfoData: syncInfoData, frame: frame, logiConn: logiConn,
                endpoint: endpoint, reply: reply
            )
        case let .upgrade(upgradeData):
            handleLogiUpgrade(
                upgradeData: upgradeData, frame: frame, logiConn: logiConn,
                endpoint: endpoint, reply: reply
            )
        default:
            DiagnosticsLog.info(
                "xiaomi.mishare.mesh_logi_unhandled from=\(endpoint.debugDescription) " +
                    "logiConnId=\(logiConn.logiConnId) frameType=\(inner.frameType) " +
                    "innerBytes=\(logiConn.inner.count)"
            )
        }
    }

    private func handleLogiSyncInfo(
        syncInfoData: Data,
        frame: LyraMeshPack.Frame,
        logiConn: LogiConnFrame,
        endpoint: NWEndpoint,
        reply: LyraMeshSocket.ReplyHandler
    ) {

        let fields = (try? LyraProtoReader.readFields(from: syncInfoData)) ?? []
        var sessionId: UInt64 = 0
        var trustLevel: UInt64 = 0
        var capability: UInt64?
        var uidFeature = Data()
        var signature = Data()
        for field in fields {
            switch (field.number, field.wireType) {
            case (1, 0): sessionId = field.varintValue ?? 0
            case (2, 0): trustLevel = field.varintValue ?? 0
            case (3, 0): capability = field.varintValue
            case (5, 2): uidFeature = field.lengthDelimitedValue ?? Data()
            case (6, 2): signature = field.lengthDelimitedValue ?? Data()
            default: continue
            }
        }

        DiagnosticsLog.info(
            "xiaomi.mishare.mesh_logi_sync_info from=\(endpoint.debugDescription) " +
                "logiConnId=\(logiConn.logiConnId) peerNetId=\(logiConn.localNetId) " +
                "session=\(sessionId) trust=\(trustLevel) uidFeatureBytes=\(uidFeature.count)"
        )

        expressHandshakeDone = false
        expressListener?.cancel()
        expressListener = nil
        channelNegotiationStarted = false
        channelSocket?.stop()
        channelSocket = nil
        channelServerKey = Data()
        phoneTransKey = Data()
        peerChannelId = 0

        var syncInfo = Data()
        LyraProtoWriter.appendVarintField(1, value: sessionId, to: &syncInfo)
        LyraProtoWriter.appendVarintField(2, value: trustLevel, to: &syncInfo)
        if let capability {
            LyraProtoWriter.appendVarintField(3, value: capability, to: &syncInfo)
        }
        if !uidFeature.isEmpty {
            LyraProtoWriter.appendLengthDelimitedField(5, value: uidFeature, to: &syncInfo)
        }
        if !signature.isEmpty {
            LyraProtoWriter.appendLengthDelimitedField(6, value: signature, to: &syncInfo)
        }

        let responseInner = LogiConnInnerFrame(frameType: 5, payload: .syncInfo(syncInfo))
        let responseLogiConn = LogiConnFrame(
            logiConnId: logiConn.logiConnId,
            localNetId: 1,
            remoteNetId: logiConn.localNetId,
            inner: responseInner.serialized()
        )
        let miResponse = MiConnectFrame(version: 0, logiConnFrames: [responseLogiConn])
        let responseFrame = LyraMeshPack.Frame(packType: frame.packType, payload: miResponse.serialized())

        do {
            try reply(responseFrame)
            let responsePayload = (try? LyraMeshPack.encode(responseFrame)) ?? Data()
            DiagnosticsLog.info(
                "xiaomi.mishare.mesh_logi_sync_info_response to=\(endpoint.debugDescription) " +
                    "logiConnId=\(logiConn.logiConnId) hex=\(responsePayload.map { String(format: "%02x", $0) }.joined())"
            )
        } catch {
            DiagnosticsLog.error("xiaomi.mishare.mesh_logi_sync_info_response_failed", error)
        }
    }

    private struct AuthClientHello {
        var handshakeId: UInt64
        var family: UInt64
        var messageClass: UInt64
        var clientRandom: Data
        var cipher1: UInt64
        var cipher2: UInt64
        var keyType: UInt64
        var publicKey: Data
    }

    private func handleLogiUpgrade(
        upgradeData: Data,
        frame: LyraMeshPack.Frame,
        logiConn: LogiConnFrame,
        endpoint: NWEndpoint,
        reply: LyraMeshSocket.ReplyHandler
    ) {
        guard let hello = Self.parseAuthClientHello(upgradeData) else {
            DiagnosticsLog.warn("xiaomi.mishare.mesh_logi_upgrade_parse_failed bytes=\(upgradeData.count)")
            return
        }

        let privateKey = P256.KeyAgreement.PrivateKey()
        keyAgreementKey = privateKey
        authClientRandom = hello.clientRandom
        var sharedSecretPrefix = ""
        do {
            let peerPublicKey = try P256.KeyAgreement.PublicKey(x963Representation: hello.publicKey)
            let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: peerPublicKey)
            let secretData = sharedSecret.withUnsafeBytes { Data($0) }
            authSharedSecret = secretData
            sharedSecretPrefix = secretData.prefix(4).map { String(format: "%02x", $0) }.joined()
        } catch {
            DiagnosticsLog.warn("xiaomi.mishare.mesh_logi_upgrade_ecdh_failed error=\(error.localizedDescription)")
        }

        DiagnosticsLog.info(
            "xiaomi.mishare.mesh_logi_upgrade from=\(endpoint.debugDescription) " +
                "logiConnId=\(logiConn.logiConnId) handshakeId=\(hello.handshakeId) " +
                "family=\(hello.family) class=\(hello.messageClass) " +
                "ciphers=\(hello.cipher1),\(hello.cipher2) secretPrefix=\(sharedSecretPrefix)"
        )

        var serverRandom = Data(count: 32)
        _ = serverRandom.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        authServerRandom = serverRandom

        var publicKeyMessage = Data()
        LyraProtoWriter.appendVarintField(1, value: hello.keyType, to: &publicKeyMessage)
        LyraProtoWriter.appendLengthDelimitedField(2, value: privateKey.publicKey.x963Representation, to: &publicKeyMessage)

        var cipherSuite = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &cipherSuite)
        LyraProtoWriter.appendLengthDelimitedField(2, value: serverRandom, to: &cipherSuite)
        LyraProtoWriter.appendVarintField(3, value: hello.cipher1, to: &cipherSuite)
        LyraProtoWriter.appendVarintField(4, value: hello.cipher2, to: &cipherSuite)
        LyraProtoWriter.appendLengthDelimitedField(5, value: publicKeyMessage, to: &cipherSuite)

        var serverNotify = Data()
        LyraProtoWriter.appendLengthDelimitedField(1, value: cipherSuite, to: &serverNotify)

        var pairFrame = Data()
        var handshakeFrame = Data()
        if hello.family == 5 {
            LyraProtoWriter.appendVarintField(1, value: 2, to: &pairFrame)
            LyraProtoWriter.appendLengthDelimitedField(3, value: serverNotify, to: &pairFrame)
            LyraProtoWriter.appendVarintField(1, value: hello.family, to: &handshakeFrame)
            LyraProtoWriter.appendVarintField(2, value: 6, to: &handshakeFrame)
            LyraProtoWriter.appendLengthDelimitedField(8, value: pairFrame, to: &handshakeFrame)
        } else {
            var supportedCapacity = Data()
            LyraProtoWriter.appendVarintField(1, value: 1, to: &supportedCapacity)
            var authExtParam = Data()
            LyraProtoWriter.appendVarintField(1, value: 1, to: &authExtParam)
            LyraProtoWriter.appendLengthDelimitedField(3, value: supportedCapacity, to: &serverNotify)
            LyraProtoWriter.appendLengthDelimitedField(4, value: authExtParam, to: &serverNotify)
            LyraProtoWriter.appendVarintField(1, value: 2, to: &pairFrame)
            LyraProtoWriter.appendLengthDelimitedField(3, value: serverNotify, to: &pairFrame)
            LyraProtoWriter.appendVarintField(1, value: hello.family, to: &handshakeFrame)
            LyraProtoWriter.appendVarintField(2, value: 4, to: &handshakeFrame)
            LyraProtoWriter.appendLengthDelimitedField(6, value: pairFrame, to: &handshakeFrame)
        }

        var authFrame = Data()
        LyraProtoWriter.appendVarintField(1, value: hello.handshakeId, to: &authFrame)
        LyraProtoWriter.appendLengthDelimitedField(2, value: handshakeFrame, to: &authFrame)

        let responseInner = LogiConnInnerFrame(frameType: 6, payload: .upgrade(authFrame))
        let responseLogiConn = LogiConnFrame(
            logiConnId: logiConn.logiConnId,
            localNetId: 1,
            remoteNetId: logiConn.localNetId,
            inner: responseInner.serialized()
        )
        let miResponse = MiConnectFrame(version: 0, logiConnFrames: [responseLogiConn])
        let responseFrame = LyraMeshPack.Frame(packType: frame.packType, payload: miResponse.serialized())

        do {
            try reply(responseFrame)
            let responsePayload = (try? LyraMeshPack.encode(responseFrame)) ?? Data()
            DiagnosticsLog.info(
                "xiaomi.mishare.mesh_logi_upgrade_response to=\(endpoint.debugDescription) " +
                    "logiConnId=\(logiConn.logiConnId) hex=\(responsePayload.map { String(format: "%02x", $0) }.joined())"
            )
        } catch {
            DiagnosticsLog.error("xiaomi.mishare.mesh_logi_upgrade_response_failed", error)
        }
    }

    private static func parseAuthClientHello(_ data: Data) -> AuthClientHello? {
        func lengthDelimited(_ fieldNumber: Int, in data: Data) -> Data? {
            guard let fields = try? LyraProtoReader.readFields(from: data) else { return nil }
            return fields.first { $0.number == fieldNumber && $0.wireType == 2 }?.lengthDelimitedValue
        }
        func varint(_ fieldNumber: Int, in data: Data) -> UInt64? {
            guard let fields = try? LyraProtoReader.readFields(from: data) else { return nil }
            return fields.first { $0.number == fieldNumber && $0.wireType == 0 }?.varintValue
        }

        guard let handshakeId = varint(1, in: data),
              let handshakeFrame = lengthDelimited(2, in: data),
              let family = varint(1, in: handshakeFrame),
              let messageClass = varint(2, in: handshakeFrame),
              let pairFrame = lengthDelimited(family == 5 ? 8 : 6, in: handshakeFrame),
              let clientNotify = lengthDelimited(2, in: pairFrame),
              let supportedCipherSuites = lengthDelimited(1, in: clientNotify),
              let clientRandom = lengthDelimited(2, in: supportedCipherSuites),
              let cipher1 = varint(3, in: supportedCipherSuites),
              let cipher2 = varint(4, in: supportedCipherSuites),
              let genericPublicKey = lengthDelimited(5, in: supportedCipherSuites),
              let keyType = varint(1, in: genericPublicKey),
              let publicKey = lengthDelimited(2, in: genericPublicKey),
              publicKey.count == 65, publicKey.first == 0x04
        else {
            return nil
        }
        return AuthClientHello(
            handshakeId: handshakeId,
            family: family,
            messageClass: messageClass,
            clientRandom: clientRandom,
            cipher1: cipher1,
            cipher2: cipher2,
            keyType: keyType,
            publicKey: publicKey
        )
    }

    private func handleKeepAliveRequest(
        frame: LyraMeshPack.Frame,
        physConn: PhysConnFrame,
        request: Data,
        endpoint: NWEndpoint,
        reply: LyraMeshSocket.ReplyHandler
    ) {
        let tick = UInt64(LyraMeshSocket.tick())
        var responsePayload = Data()
        LyraProtoWriter.appendVarintField(1, value: tick, to: &responsePayload)
        LyraProtoWriter.appendVarintField(2, value: 2, to: &responsePayload)
        LyraProtoWriter.appendVarintField(3, value: tick, to: &responsePayload)
        let responsePhysConn = PhysConnFrame(
            field2: 5,
            payload: .keepAliveResponse(responsePayload)
        )
        let miResponse = MiConnectFrame(version: 0, logiConnFrames: [], physConnFrame: responsePhysConn)
        let responseFrame = LyraMeshPack.Frame(packType: frame.packType, payload: miResponse.serialized())

        do {
            try reply(responseFrame)
            DiagnosticsLog.info(
                "xiaomi.mishare.mesh_keepalive_response to=\(endpoint.debugDescription) " +
                    "requestBytes=\(request.count)"
            )
        } catch {
            DiagnosticsLog.error("xiaomi.mishare.mesh_keepalive_response_failed", error)
        }
    }

    private func handleDisconnectRequest(
        frame: LyraMeshPack.Frame,
        physConn: PhysConnFrame,
        request: Data,
        endpoint: NWEndpoint,
        reply: LyraMeshSocket.ReplyHandler
    ) {
        var responsePayload = Data()
        LyraProtoWriter.appendVarintField(
            1, value: UInt64(Date().timeIntervalSince1970 * 1000), to: &responsePayload
        )
        let responsePhysConn = PhysConnFrame(
            field2: 7,
            payload: .disconnectResponse(responsePayload)
        )
        let miResponse = MiConnectFrame(version: 0, logiConnFrames: [], physConnFrame: responsePhysConn)
        let responseFrame = LyraMeshPack.Frame(packType: frame.packType, payload: miResponse.serialized())

        do {
            try reply(responseFrame)
            DiagnosticsLog.info(
                "xiaomi.mishare.mesh_disconnect_response to=\(endpoint.debugDescription) " +
                    "requestBytes=\(request.count)"
            )
        } catch {
            DiagnosticsLog.error("xiaomi.mishare.mesh_disconnect_response_failed", error)
        }
    }

    private func handleSyncRequest(
        frame: LyraMeshPack.Frame,
        physConn: PhysConnFrame,
        request: PhysConnSyncDeviceInfoRequest,
        endpoint: NWEndpoint,
        reply: LyraMeshSocket.ReplyHandler
    ) {

        DiagnosticsLog.info(
            "xiaomi.mishare.mesh_sync_request from=\(endpoint.debugDescription) " +
                "physConnId=\(physConn.field1) role=\(physConn.field2) " +
                "device=\(request.deviceId ?? "unknown") type=\(request.deviceType ?? 0) " +
                "connMedium=0x\(String(request.connMediumTypes ?? 0, radix: 16))"
        )

        guard deviceIdHexProvider() != nil else {
            return
        }
        let deviceIdHex = deviceIdHexProvider()!

        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let osVersionString = "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
        let deviceInfo = LyraDeviceInfo(
            deviceId: deviceIdHex,
            deviceType: 14,
            uidHash: "61F2",
            displayName: displayNameProvider(),
            osVersion: osVersionString,
            connMediumTypes: 0x40082,
            romVersion: "5.1.174.10.6031221"
        )
        var networkInfo = Data()
        LyraProtoWriter.appendVarintField(1, value: 256, to: &networkInfo)
        LyraProtoWriter.appendLengthDelimitedField(5, value: Data(), to: &networkInfo)

        let response = PhysConnSyncDeviceInfoResponse(
            timestampMs: UInt64(Date().timeIntervalSince1970 * 1000),
            deviceInfo: deviceInfo,
            networkInfo: networkInfo
        )
        let responsePhysConn = PhysConnFrame(
            field1: physConn.field1,
            field2: 2,
            payload: .syncDeviceInfoResponse(response.serialized())
        )
        let miResponse = MiConnectFrame(version: 0, logiConnFrames: [], physConnFrame: responsePhysConn)
        let responseFrame = LyraMeshPack.Frame(packType: frame.packType, payload: miResponse.serialized())

        do {
            try reply(responseFrame)
            let responsePayload = (try? LyraMeshPack.encode(responseFrame)) ?? Data()
            DiagnosticsLog.info(
                "xiaomi.mishare.mesh_sync_response to=\(endpoint.debugDescription) " +
                    "physConnId=\(physConn.field1) hex=\(responsePayload.map { String(format: "%02x", $0) }.joined())"
            )
        } catch {
            DiagnosticsLog.error("xiaomi.mishare.mesh_sync_response_failed", error)
        }
    }
}
