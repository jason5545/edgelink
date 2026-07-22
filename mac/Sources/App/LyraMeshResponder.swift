import CryptoKit
import EdgeLinkKit
import Foundation
import Network

final class LyraMeshResponder {
    static let officialMacUidFeature = Data([
        0x0A, 0x08, 0x26, 0xFB, 0x1C, 0x8E, 0xAC, 0x7C, 0xFC, 0x1F, 0x12, 0x20,
        0x57, 0x65, 0xD7, 0xBF, 0xBD, 0xC3, 0xCA, 0x3C, 0x8B, 0x99, 0xF2, 0xA5,
        0x96, 0x08, 0xD3, 0x95, 0x8E, 0x2B, 0xC3, 0xEC, 0x1F, 0x64, 0x81, 0xEB,
        0x11, 0xB6, 0x56, 0x13, 0x08, 0x27, 0x21, 0xBF
    ])
    static let officialMacSyncAuthCredential = Data([
        0x18, 0x60, 0x81, 0x5E, 0xFC, 0xCB, 0x61, 0x00, 0xC2, 0x28, 0x52, 0x05,
        0x26, 0x11, 0xE8, 0x1C, 0x68, 0x85, 0x53, 0x34, 0x49, 0xCC, 0x2D, 0x9D,
        0x60, 0x8E, 0xE8, 0x1A, 0xA4, 0xCD, 0x42, 0xF0, 0x4D, 0xD5, 0xAA, 0x07,
        0x2B, 0xA8, 0xB0, 0x67, 0x7A, 0xDA, 0x37, 0xF9, 0x3F, 0xC7, 0xAD, 0xDA,
        0x6B, 0x5D, 0x9F, 0xB9, 0x18, 0xDF, 0x65, 0x10, 0xEB, 0xF6, 0xD3, 0xF8,
        0xDC, 0xE9, 0x03, 0x12, 0xD6, 0xAE, 0xC1, 0xE5, 0xE8, 0xBD, 0xF5, 0x29,
        0x66, 0x58, 0x61, 0x6E, 0x6E, 0xCB, 0xFF, 0xCF, 0x11, 0x37, 0xD0, 0xC3,
        0x32, 0xD9, 0x34, 0x9A, 0xED, 0x05, 0x3C, 0x67, 0x61, 0x1B, 0x15, 0x2F,
        0xFA, 0x8F, 0x17, 0x29, 0x18, 0x52, 0x9E, 0x68, 0xA0, 0xD9, 0x3
    ])
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
    private var phoneTransRandom = Data()
    private var phoneColonHexKey = Data()
    private var peerChannelId: UInt32 = 0
    private var channelNegotiationStarted = false
    private var lastEndpointDescription: String?
    private var announceTimer: DispatchSourceTimer?
    private let announceQueue = DispatchQueue(label: "edgelink.lyra.announce")
    private var syncAuthPrivateKey: Curve25519.KeyAgreement.PrivateKey?
    private var syncAuthPeerConnId = Data()
    private var syncAuthOurConnId = Data()
    private var syncSessionKey: SymmetricKey?
    private var syncKeyCandidates: [SymmetricKey] = []
    private var syncAuthSharedSecret = Data()
    private var syncAnnounceEndpoint: String?
    private var syncCookieByEndpoint: [String: UInt64] = [:]
    private var expressDataKey = Data()
    private var eventBytesBuffer = Data()
    private var streamReceives: [UInt32: StreamReceive] = [:]
    private var expressBuffers: [ObjectIdentifier: Data] = [:]

    private struct StreamReceive {
        var streamId: UInt32
        var contentLength: Int64
        var filename: String
        var fileURL: URL
        var fileHandle: FileHandle?
        var received: Int64
    }

    static let hkdfSalt = Data([
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
        startAnnounceTimer()
    }

    private func startAnnounceTimer() {
        announceTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: announceQueue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self, let endpoint = self.lastEndpointDescription else { return }
            self.sendAnnounce(endpointDescription: endpoint)
        }
        announceTimer = timer
        timer.resume()
    }

    private func handle(frame: LyraMeshPack.Frame, endpoint: NWEndpoint, reply: LyraMeshSocket.ReplyHandler) {
        lastEndpointDescription = endpoint.debugDescription
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
                if physConn.field2 == 4 || physConn.field2 == 5 {
                    handleSyncCookie(
                        frame: frame, physConn: physConn, cookieData: requestData,
                        wrapperField: 6, endpoint: endpoint, reply: reply
                    )
                } else {
                    handleKeepAliveRequest(
                        frame: frame, physConn: physConn, request: requestData, endpoint: endpoint, reply: reply
                    )
                }
                return
            }
            if case let .keepAliveResponse(responseData) = physConn.payload,
               physConn.field2 == 4 || physConn.field2 == 5 {
                handleSyncCookie(
                    frame: frame, physConn: physConn, cookieData: responseData,
                    wrapperField: 7, endpoint: endpoint, reply: reply
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
                    if let colonKey = Self.parseColonHexKey(value) {
                        phoneColonHexKey = colonKey
                    }
                } else if field.number == 10, let value = field.lengthDelimitedValue,
                          let innerFields = try? LyraProtoReader.readFields(from: value)
                {
                    for innerField in innerFields {
                        switch (innerField.number, innerField.wireType) {
                        case (1, 0):
                            channelId = UInt32(innerField.varintValue ?? 0)
                        case (4, 2):
                            if let key = innerField.lengthDelimitedValue, key.count == 32 {
                                transKey = key
                            }
                        case (5, 2):
                            if let random = innerField.lengthDelimitedValue, random.count == 32 {
                                phoneTransRandom = random
                            }
                        default:
                            continue
                        }
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
                "privateDataBytes=\(privateData.count) transKeyBytes=\(transKey.count) channelId=\(channelId) " +
                "privateDataHex=\(privateData.map { String(format: "%02x", $0) }.joined())"
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
        guard body.count > 30 else {
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
        ) else {
            return
        }
        var keys: [(String, SymmetricKey)] = []
        if let syncSessionKey {
            keys.append(("sync", syncSessionKey))
        }
        for (index, candidate) in syncKeyCandidates.enumerated() {
            keys.append(("syncCand\(index)", candidate))
        }
        if let channelKey {
            keys.append(("channel", channelKey))
        }
        for (label, key) in keys {
            guard let plaintext = try? AES.GCM.open(sealedBox, using: key) else {
                continue
            }
            if label != "channel" {
                syncSessionKey = key
                syncKeyCandidates = []
                DiagnosticsLog.info(
                    "xiaomi.mishare.sync_announce_decrypted from=\(endpoint.debugDescription) " +
                        "label=\(label) bytes=\(plaintext.count) " +
                        "hex=\(plaintext.prefix(400).map { String(format: "%02x", $0) }.joined())"
                )
                sendEncryptedSyncAnnounce(endpointDescription: endpoint.debugDescription, key: key)
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
            return
        }
        if channelKey != nil || !syncKeyCandidates.isEmpty || syncSessionKey != nil {
            DiagnosticsLog.warn("xiaomi.mishare.channel_payload_decrypt_failed bytes=\(body.count)")
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
        sendAnnounce(endpointDescription: endpoint.debugDescription)

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
        socket.debugHandler = { message in
            DiagnosticsLog.info("xiaomi.mishare.\(message)")
        }
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
        socket.onPeerConnected = { from in
            DiagnosticsLog.info("xiaomi.mishare.channel_socket_peer from=\(from.debugDescription)")
        }
        socket.onNegotiated = { [weak self] peerChannelId, mtu in
            DiagnosticsLog.info("xiaomi.mishare.channel_negotiated peerChannelId=\(peerChannelId) mtu=\(mtu)")
            self?.sendExpressHandshakeOverChannel()
        }
        socket.onDecryptFailure = { reason in
            DiagnosticsLog.warn("xiaomi.mishare.channel_decrypt_failed \(reason)")
        }
        socket.onOfficialPacket = { plaintext, frameLength in
            DiagnosticsLog.info(
                "xiaomi.mishare.official_packet_decrypted frameBytes=\(frameLength) plainBytes=\(plaintext.count) " +
                    "hex=\(plaintext.prefix(64).map { String(format: "%02x", $0) }.joined())"
            )
            let dumpURL = URL(fileURLWithPath: "/tmp/lyra-rx-\(frameLength)-\(Int(Date().timeIntervalSince1970 * 1000)).bin")
            try? FileManager.default.createDirectory(
                at: dumpURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? plaintext.write(to: dumpURL)
        }
        socket.onMessage = { [weak self] message, from in
            self?.handleChannelMessage(message, from: from)
        }
        do {
            let key = phoneTransKey.isEmpty ? Data(count: 32) : phoneTransKey
            socket.candidateKeys = [phoneTransRandom, phoneColonHexKey].filter { $0.count == 32 }
            try socket.start(socketKey: key, serverChannelId: 5)
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
        expressDataKey = key

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
                let channelFrame = LyraChannelSocket.wrapChannelFrame(tlv)
                expressQueue.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    guard let self else { return }
                    do {
                        try self.channelSocket?.sendVariant(
                            channelFrame: channelFrame, key: self.phoneTransKey, singleLayer: true
                        )
                        DiagnosticsLog.info(
                            "xiaomi.mishare.express_handshake_sent dataPort=\(port) " +
                                "key=\(key.map { String(format: "%02x", $0) }.joined()) tlvBytes=\(tlv.count)"
                        )
                    } catch {
                        DiagnosticsLog.error("xiaomi.mishare.express_handshake_failed", error)
                    }
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

    private func sendAnnounce(endpointDescription: String) {
        if let syncSessionKey, let syncAnnounceEndpoint {
            sendEncryptedSyncAnnounce(endpointDescription: syncAnnounceEndpoint, key: syncSessionKey)
            return
        }
        guard let deviceIdHex = deviceIdHexProvider() else {
            return
        }
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let deviceInfo = LyraTrustedDeviceInfo.deviceInfoFrame(
            deviceName: displayNameProvider(),
            deviceType: 14,
            deviceId: deviceIdHex,
            uidHash: "61F2",
            hwModel: Self.hardwareModel(),
            lyraVersion: "5.1.208.10.fullCnRelease.0512164",
            services: [
                LyraTrustedDeviceInfo.Service(name: "miLyraShare", package: "com.edgelink.mac"),
                LyraTrustedDeviceInfo.Service(name: "miShareBasic", package: "com.edgelink.mac"),
                LyraTrustedDeviceInfo.Service(name: "miLyraShareTransfer", package: "com.edgelink.mac")
            ],
            ipAddress: Self.primaryIPv4Address(),
            osVersion: "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
        )
        let payload = LyraTrustedDeviceInfo.plaintextAnnounce(deviceInfo: deviceInfo)
        let frame = LyraMeshPack.Frame(packType: 5, payload: payload)
        socket.sendInboundAsync(frame: frame, toEndpointDescription: endpointDescription)
        DiagnosticsLog.info(
            "xiaomi.mishare.announce_sent to=\(endpointDescription) bytes=\(payload.count)"
        )
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

    private func handleChannelMessage(_ message: Data, from endpoint: NWEndpoint) {
        DiagnosticsLog.info(
            "xiaomi.mishare.channel_message_rx bytes=\(message.count) " +
                "hex=\(message.prefix(24).map { String(format: "%02x", $0) }.joined())"
        )
        guard let (frameTag, frameChild) = try? LyraExpressTLVParser.parseOneOf(message), frameTag == 1 else {
            DiagnosticsLog.warn("xiaomi.mishare.channel_frame_parse_failed bytes=\(message.count)")
            return
        }
        let frameChildren = LyraExpressTLVParser.children(of: frameChild)
        guard let payloadNode = LyraExpressTLVParser.firstChild(0, in: frameChildren) else {
            return
        }
        let eventFrame = payloadNode.payload
        guard let (eventTag, eventChild) = try? LyraExpressTLVParser.parseOneOf(eventFrame) else {
            DiagnosticsLog.warn("xiaomi.mishare.express_event_parse_failed bytes=\(eventFrame.count)")
            return
        }
        let children = LyraExpressTLVParser.children(of: eventChild)
        switch eventTag {
        case 1:
            DiagnosticsLog.info("xiaomi.mishare.express_event_handshake_rx bytes=\(eventFrame.count)")
        case 2:
            let chunk = LyraExpressTLVParser.firstChild(1, in: children)?.payload ?? Data()
            eventBytesBuffer.append(chunk)
            if let complete = Self.completedFileMessage(eventBytesBuffer) {
                eventBytesBuffer = Data()
                handleCompletedFileMessage(complete)
            }
        case 3:
            handleStreamSendBegin(children)
        default:
            DiagnosticsLog.info("xiaomi.mishare.express_event tag=\(eventTag) bytes=\(eventFrame.count)")
        }
    }

    private func sendEventFrame(oneOfTag: UInt16, child: Data) {
        let frame = LyraExpressTLV.oneOfNode(tag: 0xFFFF, selectedTag: oneOfTag, child: child)
        do {
            try channelSocket?.send(message: frame)
        } catch {
            DiagnosticsLog.error("xiaomi.mishare.express_event_send_failed", error)
        }
    }

    static func completedFileMessage(_ buffer: Data) -> Data? {
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

    private func handleCompletedFileMessage(_ data: Data) {
        guard let outerFields = try? LyraProtoReader.readFields(from: data),
              let envelope = outerFields.first(where: { $0.number == 2 && $0.wireType == 2 })?.lengthDelimitedValue,
              let fields = try? LyraProtoReader.readFields(from: envelope) else {
            return
        }
        let messageTag = outerFields.first(where: { $0.number == 1 && $0.wireType == 0 })?.varintValue ?? 1
        if messageTag == 7 {
            handleFileSendComplete(fields)
            return
        }
        guard messageTag == 1 else {
            DiagnosticsLog.info("xiaomi.mishare.file_message_ignored tag=\(messageTag)")
            return
        }
        var requestId: UInt64 = 1
        var senderName = ""
        var taskId = ""
        var fileBytes = Data()
        var filename = ""
        for field in fields {
            switch (field.number, field.wireType) {
            case (1, 0):
                requestId = field.varintValue ?? 1
            case (2, 2):
                senderName = field.lengthDelimitedValue.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            case (3, 2):
                taskId = field.lengthDelimitedValue.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            case (4, 2):
                fileBytes = field.lengthDelimitedValue ?? Data()
            case (5, 2):
                if let infoFields = try? LyraProtoReader.readFields(from: field.lengthDelimitedValue ?? Data()),
                   let nameField = infoFields.first(where: { $0.number == 1 && $0.wireType == 2 }),
                   let name = nameField.lengthDelimitedValue.flatMap { String(data: $0, encoding: .utf8) }
                {
                    filename = name
                }
            default:
                continue
            }
        }
        guard !fileBytes.isEmpty else {
            DiagnosticsLog.warn("xiaomi.mishare.file_receive_empty sender=\(senderName)")
            return
        }
        var responseBody = Data()
        LyraProtoWriter.appendVarintField(1, value: requestId, to: &responseBody)
        LyraProtoWriter.appendLengthDelimitedField(2, value: Data(taskId.utf8), to: &responseBody)
        LyraProtoWriter.appendVarintField(3, value: 0, to: &responseBody)
        var protocolFrame = Data()
        LyraProtoWriter.appendVarintField(1, value: 2, to: &protocolFrame)
        LyraProtoWriter.appendLengthDelimitedField(2, value: responseBody, to: &protocolFrame)
        let responseFrame = LyraExpressTLV.oneOfNode(
            tag: 0xFFFF,
            selectedTag: 1,
            child: LyraExpressTLV.containerNode(tag: 1, children: [
                LyraExpressTLV.stringNode(tag: 0, value: LyraExpressTLV.oneOfNode(
                    tag: 0xFFFF,
                    selectedTag: 2,
                    child: LyraExpressTLV.containerNode(tag: 2, children: [
                        LyraExpressTLV.int32Node(tag: 0, value: 0),
                        LyraExpressTLV.stringNode(tag: 1, value: protocolFrame)
                    ])
                ))
            ])
        )
        do {
            try channelSocket?.sendVariant(channelFrame: responseFrame, key: phoneTransKey, singleLayer: true)
            DiagnosticsLog.info(
                "xiaomi.mishare.file_send_response_sent requestId=\(requestId) taskId=\(taskId)"
            )
        } catch {
            DiagnosticsLog.error("xiaomi.mishare.file_send_response_failed", error)
        }
        if filename.isEmpty {
            filename = taskId.isEmpty ? "mishare-\(Int(Date().timeIntervalSince1970))" : taskId
        }
        let sanitized = filename.replacingOccurrences(of: "/", with: "_")
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/EdgeLink-MiShare", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(sanitized)
            try fileBytes.write(to: url, options: .atomic)
            DiagnosticsLog.info(
                "xiaomi.mishare.file_received sender=\(senderName) name=\(sanitized) bytes=\(fileBytes.count) path=\(url.path)"
            )
        } catch {
            DiagnosticsLog.error("xiaomi.mishare.file_receive_write_failed", error)
        }
    }

    private func handleFileSendComplete(_ fields: [LyraProtoReader.Field]) {
        let requestId = fields.first(where: { $0.number == 1 && $0.wireType == 0 })?.varintValue ?? 0
        DiagnosticsLog.info("xiaomi.mishare.file_send_complete_rx requestId=\(requestId)")
        var responseBody = Data()
        LyraProtoWriter.appendVarintField(1, value: requestId, to: &responseBody)
        var protocolFrame = Data()
        LyraProtoWriter.appendVarintField(1, value: 8, to: &protocolFrame)
        LyraProtoWriter.appendLengthDelimitedField(2, value: responseBody, to: &protocolFrame)
        let responseFrame = LyraExpressTLV.oneOfNode(
            tag: 0xFFFF,
            selectedTag: 1,
            child: LyraExpressTLV.containerNode(tag: 1, children: [
                LyraExpressTLV.stringNode(tag: 0, value: LyraExpressTLV.oneOfNode(
                    tag: 0xFFFF,
                    selectedTag: 2,
                    child: LyraExpressTLV.containerNode(tag: 2, children: [
                        LyraExpressTLV.int32Node(tag: 0, value: 0),
                        LyraExpressTLV.stringNode(tag: 1, value: protocolFrame)
                    ])
                ))
            ])
        )
        do {
            try channelSocket?.sendVariant(channelFrame: responseFrame, key: phoneTransKey, singleLayer: true)
            DiagnosticsLog.info("xiaomi.mishare.file_send_complete_response_sent requestId=\(requestId)")
        } catch {
            DiagnosticsLog.error("xiaomi.mishare.file_send_complete_response_failed", error)
        }
    }

    private func handleStreamSendBegin(_ children: [LyraExpressTLVNode]) {
        let streamId = LyraExpressTLVParser.firstChild(1, in: children)?.int32Value ?? 0
        let contentLength = Int64(bitPattern: LyraExpressTLVParser.firstChild(2, in: children)?.int64Value ?? 0)
        let filename = LyraExpressTLVParser.firstChild(4, in: children)
            .flatMap { String(data: $0.payload, encoding: .utf8) }
            ?? LyraExpressTLVParser.firstChild(3, in: children)
                .flatMap { String(data: $0.payload, encoding: .utf8) }
            ?? "stream-\(streamId)"
        DiagnosticsLog.info(
            "xiaomi.mishare.stream_send_begin streamId=\(streamId) length=\(contentLength) name=\(filename)"
        )

        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent("EdgeLink-MiShare", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeName = filename.components(separatedBy: "/").last ?? "stream-\(streamId)"
        let fileURL = directory.appendingPathComponent(safeName)
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        let handle = try? FileHandle(forWritingTo: fileURL)
        streamReceives[streamId] = StreamReceive(
            streamId: streamId,
            contentLength: contentLength,
            filename: safeName,
            fileURL: fileURL,
            fileHandle: handle,
            received: 0
        )

        sendStreamEvent(oneOfTag: 4, child: LyraExpressTLV.containerNode(tag: 4, children: [
            LyraExpressTLV.int32Node(tag: 0, value: 2),
            LyraExpressTLV.int32Node(tag: 1, value: streamId),
            LyraExpressTLV.int32Node(tag: 2, value: 1)
        ]))
        DiagnosticsLog.info("xiaomi.mishare.stream_rcv_begin_sent streamId=\(streamId)")
    }

    private func sendStreamEvent(oneOfTag: UInt16, child: Data, protocolFrame: Data? = nil) {
        let inner = LyraExpressTLV.oneOfNode(
            tag: 0xFFFF,
            selectedTag: oneOfTag,
            child: child
        )
        let frame = LyraExpressTLV.oneOfNode(
            tag: 0xFFFF,
            selectedTag: 1,
            child: LyraExpressTLV.containerNode(tag: 1, children: [
                LyraExpressTLV.stringNode(tag: 0, value: inner)
            ])
        )
        do {
            try channelSocket?.sendVariant(channelFrame: frame, key: phoneTransKey, singleLayer: true)
        } catch {
            DiagnosticsLog.error("xiaomi.mishare.express_event_send_failed", error)
        }
    }

    private func handleStreamlet(_ children: [LyraExpressTLVNode], data: Data) {
        let streamId = LyraExpressTLVParser.firstChild(1, in: children)?.int32Value ?? 0
        let streamOffset = Int64(LyraExpressTLVParser.firstChild(2, in: children)?.int64Value ?? 0)
        let streamletSize = Int32(bitPattern: LyraExpressTLVParser.firstChild(3, in: children)?.int32Value ?? 0)

        guard var receive = streamReceives[streamId] else {
            DiagnosticsLog.warn("xiaomi.mishare.streamlet_unknown_stream streamId=\(streamId)")
            return
        }
        if streamletSize > 0 {
            if let handle = receive.fileHandle {
                do {
                    try handle.seek(toOffset: UInt64(streamOffset))
                    try handle.write(contentsOf: data)
                } catch {
                    DiagnosticsLog.error("xiaomi.mishare.stream_write_failed", error)
                }
            }
            receive.received += Int64(data.count)
            streamReceives[streamId] = receive
            return
        }
        if streamletSize == 0 {
            receive.fileHandle?.closeFile()
            DiagnosticsLog.info(
                "xiaomi.mishare.stream_complete streamId=\(streamId) name=\(receive.filename) " +
                    "bytes=\(receive.received) path=\(receive.fileURL.path)"
            )
            streamReceives.removeValue(forKey: streamId)
            sendStreamEvent(oneOfTag: 5, child: LyraExpressTLV.containerNode(tag: 5, children: [
                LyraExpressTLV.int32Node(tag: 0, value: 0),
                LyraExpressTLV.int32Node(tag: 1, value: streamId),
                LyraExpressTLV.int32Node(tag: 2, value: 1)
            ]))
            return
        }
        receive.fileHandle?.closeFile()
        streamReceives.removeValue(forKey: streamId)
        DiagnosticsLog.warn("xiaomi.mishare.stream_failed streamId=\(streamId) code=\(streamletSize)")
        sendStreamEvent(oneOfTag: 5, child: LyraExpressTLV.containerNode(tag: 5, children: [
            LyraExpressTLV.int32Node(tag: 0, value: 1),
            LyraExpressTLV.int32Node(tag: 1, value: streamId),
            LyraExpressTLV.int32Node(tag: 2, value: 1)
        ]))
    }

    private func acceptExpressConnection(_ connection: NWConnection) {
        let endpoint = connection.endpoint
        DiagnosticsLog.info("xiaomi.mishare.express_conn from=\(endpoint.debugDescription)")
        connection.start(queue: expressQueue)
        expressBuffers[ObjectIdentifier(connection)] = Data()
        receiveExpressData(connection)
    }

    private func receiveExpressData(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            let id = ObjectIdentifier(connection)
            if let content, !content.isEmpty {
                var buffer = self.expressBuffers[id] ?? Data()
                buffer.append(content)
                self.drainExpressFrames(&buffer, connection: connection)
                self.expressBuffers[id] = buffer
            }
            if error != nil || isComplete {
                self.expressBuffers.removeValue(forKey: id)
                DiagnosticsLog.info("xiaomi.mishare.express_conn_closed from=\(connection.endpoint.debugDescription)")
                return
            }
            self.receiveExpressData(connection)
        }
    }

    private func drainExpressFrames(_ buffer: inout Data, connection: NWConnection) {
        while true {
            guard buffer.count >= 10 else { return }
            let header = Array(buffer.prefix(10))
            guard header[0] == 0, header[1] == 0, header[2] == 0, header[3] == 0, header[4] == 0, header[5] == 0 else {
                DiagnosticsLog.warn("xiaomi.mishare.express_bad_header hex=\(header.map { String(format: "%02x", $0) }.joined())")
                buffer = Data()
                return
            }
            let payloadLength = (Int(header[6]) << 24) | (Int(header[7]) << 16) | (Int(header[8]) << 8) | Int(header[9])
            guard buffer.count >= 10 + payloadLength else { return }
            let frame = buffer.prefix(10 + payloadLength)
            let payload = Data(frame.suffix(payloadLength))
            buffer.removeFirst(10 + payloadLength)
            decryptExpressFrame(payload, connection: connection)
        }
    }

    private func decryptExpressFrame(_ payload: Data, connection: NWConnection) {
        guard payload.count > 28, !expressDataKey.isEmpty else {
            return
        }
        let key = SymmetricKey(data: expressDataKey)
        let nonce = payload.prefix(12)
        let tag = payload[payload.index(payload.startIndex, offsetBy: 12)..<payload.index(payload.startIndex, offsetBy: 28)]
        let ciphertext = payload[payload.index(payload.startIndex, offsetBy: 28)...]
        guard let sealedBox = try? AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: Data(nonce)),
            ciphertext: Data(ciphertext),
            tag: Data(tag)
        ), let plaintext = try? AES.GCM.open(sealedBox, using: key) else {
            DiagnosticsLog.warn("xiaomi.mishare.express_decrypt_failed bytes=\(payload.count)")
            return
        }
        guard plaintext.count >= 2 else { return }
        let trailerOffset = plaintext.count - 2
        let tlvLength = (Int(plaintext[trailerOffset]) << 8) | Int(plaintext[trailerOffset + 1])
        guard tlvLength <= trailerOffset else { return }
        let tlv = Data(plaintext[(trailerOffset - tlvLength)..<trailerOffset])
        let chunkData = Data(plaintext[..<(trailerOffset - tlvLength)])
        guard let (tag100, child) = try? LyraExpressTLVParser.parseOneOf(tlv), tag100 == 0x100 else {
            DiagnosticsLog.warn("xiaomi.mishare.express_tlv_unexpected bytes=\(tlv.count)")
            return
        }
        handleStreamlet(LyraExpressTLVParser.children(of: child), data: chunkData)
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
        case let .disconnect(payload) where inner.frameType == 4:
            handleSyncAuthContinuation(
                payload: payload, frame: frame, logiConn: logiConn,
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
        var serviceName = ""
        var uidFeature = Data()
        var signature = Data()
        for field in fields {
            switch (field.number, field.wireType) {
            case (1, 0): sessionId = field.varintValue ?? 0
            case (2, 0): trustLevel = field.varintValue ?? 0
            case (3, 0): capability = field.varintValue
            case (4, 2):
                serviceName = field.lengthDelimitedValue.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            case (5, 2): uidFeature = field.lengthDelimitedValue ?? Data()
            case (6, 2): signature = field.lengthDelimitedValue ?? Data()
            default: continue
            }
        }

        DiagnosticsLog.info(
            "xiaomi.mishare.mesh_logi_sync_info from=\(endpoint.debugDescription) " +
                "logiConnId=\(logiConn.logiConnId) peerNetId=\(logiConn.localNetId) " +
                "session=\(sessionId) trust=\(trustLevel) service=\(serviceName) uidFeatureBytes=\(uidFeature.count)"
        )

        if !serviceName.isEmpty {
            resetChannelState()
            handleSyncAuthRequest(
                syncInfoData: syncInfoData, serviceName: serviceName,
                frame: frame, logiConn: logiConn, endpoint: endpoint, reply: reply
            )
            return
        }

        expressHandshakeDone = false
        expressListener?.cancel()
        expressListener = nil
        channelNegotiationStarted = false
        channelSocket?.stop()
        channelSocket = nil
        channelServerKey = Data()
        phoneTransKey = Data()
        peerChannelId = 0
        expressDataKey = Data()
        eventBytesBuffer = Data()
        for (_, receive) in streamReceives {
            receive.fileHandle?.closeFile()
        }
        streamReceives.removeAll()
        expressBuffers.removeAll()

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

    private func handleSyncCookie(
        frame: LyraMeshPack.Frame,
        physConn: PhysConnFrame,
        cookieData: Data,
        wrapperField: Int,
        endpoint: NWEndpoint,
        reply: LyraMeshSocket.ReplyHandler
    ) {
        let fields = (try? LyraProtoReader.readFields(from: cookieData)) ?? []
        var cookie: UInt64 = 0
        var phase: UInt64 = 0
        var echo: UInt64 = 0
        for field in fields {
            switch (field.number, field.wireType) {
            case (1, 0): cookie = field.varintValue ?? 0
            case (2, 0): phase = field.varintValue ?? 0
            case (3, 0): echo = field.varintValue ?? 0
            default: continue
            }
        }
        let ourCookie = UInt64.random(in: 1...UInt64(UInt32.max))
        let endpointKey = endpoint.debugDescription
        let lastCookie = syncCookieByEndpoint[endpointKey] ?? 0
        if wrapperField == 7, phase >= 2, echo == lastCookie, lastCookie != 0 {
            DiagnosticsLog.info(
                "xiaomi.mishare.mesh_sync_cookie_complete from=\(endpointKey) " +
                    "cookie=\(cookie) phase=\(phase) echo=\(echo)"
            )
            return
        }
        let replyPhase: UInt64
        if wrapperField == 7, phase < 2 {
            replyPhase = phase + 1
        } else {
            replyPhase = phase
        }
        var inner = Data()
        LyraProtoWriter.appendVarintField(1, value: ourCookie, to: &inner)
        LyraProtoWriter.appendVarintField(2, value: replyPhase, to: &inner)
        LyraProtoWriter.appendVarintField(3, value: cookie, to: &inner)
        let responseNetId: UInt32 = physConn.field2 == 4 ? 5 : 4
        let responsePayload: PhysConnPayload = wrapperField == 6
            ? .keepAliveResponse(inner)
            : .keepAliveRequest(inner)
        let responsePhysConn = PhysConnFrame(field2: responseNetId, payload: responsePayload)
        syncCookieByEndpoint[endpointKey] = ourCookie
        let miResponse = MiConnectFrame(version: 0, logiConnFrames: [], physConnFrame: responsePhysConn)
        let responseFrame = LyraMeshPack.Frame(packType: frame.packType, payload: miResponse.serialized())
        do {
            try reply(responseFrame)
            DiagnosticsLog.info(
                "xiaomi.mishare.mesh_sync_cookie from=\(endpoint.debugDescription) " +
                    "netId=\(physConn.field2) wrapper=\(wrapperField) cookie=\(cookie) phase=\(phase) echo=\(echo) " +
                    "ourCookie=\(ourCookie) replyPhase=\(replyPhase)"
            )
        } catch {
            DiagnosticsLog.error("xiaomi.mishare.mesh_sync_cookie_failed", error)
        }
    }

    private func resetChannelState() {
        expressHandshakeDone = false
        expressListener?.cancel()
        expressListener = nil
        channelNegotiationStarted = false
        channelSocket?.stop()
        channelSocket = nil
        channelServerKey = Data()
        phoneTransKey = Data()
        peerChannelId = 0
        expressDataKey = Data()
        eventBytesBuffer = Data()
        for (_, receive) in streamReceives {
            receive.fileHandle?.closeFile()
        }
        streamReceives.removeAll()
        expressBuffers.removeAll()
    }

    private func handleSyncAuthRequest(
        syncInfoData: Data,
        serviceName: String,
        frame: LyraMeshPack.Frame,
        logiConn: LogiConnFrame,
        endpoint: NWEndpoint,
        reply: LyraMeshSocket.ReplyHandler
    ) {
        let fields = (try? LyraProtoReader.readFields(from: syncInfoData)) ?? []
        var peerCred = Data()
        for field in fields where field.number == 5 && field.wireType == 2 {
            peerCred = field.lengthDelimitedValue ?? Data()
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
        syncAuthPrivateKey = privateKey
        syncAuthPeerConnId = peerConnId
        var ourConnId = Data()
        for _ in 0..<8 {
            ourConnId.append(UInt8.random(in: 0...255))
        }
        syncAuthOurConnId = ourConnId
        syncSessionKey = nil
        syncKeyCandidates = deriveSyncKeyCandidates(peerPubKey: peerPubKey)
        syncAnnounceEndpoint = endpoint.debugDescription

        var cred = Data()
        LyraProtoWriter.appendLengthDelimitedField(1, value: ourConnId, to: &cred)
        LyraProtoWriter.appendLengthDelimitedField(
            2, value: privateKey.publicKey.rawRepresentation, to: &cred
        )
        var syncInfo = Data()
        LyraProtoWriter.appendVarintField(1, value: 10000, to: &syncInfo)
        LyraProtoWriter.appendVarintField(2, value: 48, to: &syncInfo)
        LyraProtoWriter.appendVarintField(3, value: 7, to: &syncInfo)
        LyraProtoWriter.appendLengthDelimitedField(5, value: cred, to: &syncInfo)
        LyraProtoWriter.appendLengthDelimitedField(
            6, value: Self.officialMacSyncInfoSignature, to: &syncInfo
        )
        let responseInner = LogiConnInnerFrame(frameType: 5, payload: .syncInfo(syncInfo))
        let responseLogiConn = LogiConnFrame(
            logiConnId: logiConn.logiConnId,
            localNetId: logiConn.localNetId,
            remoteNetId: logiConn.remoteNetId,
            inner: responseInner.serialized()
        )
        let miResponse = MiConnectFrame(version: 0, logiConnFrames: [responseLogiConn])
        let responseFrame = LyraMeshPack.Frame(packType: frame.packType, payload: miResponse.serialized())
        do {
            try reply(responseFrame)
            DiagnosticsLog.info(
                "xiaomi.mishare.mesh_sync_auth_response to=\(endpoint.debugDescription) " +
                    "service=\(serviceName) counter=\(logiConn.localNetId) " +
                    "peerPubBytes=\(peerPubKey.count) keyCandidates=\(syncKeyCandidates.count)"
            )
        } catch {
            DiagnosticsLog.error("xiaomi.mishare.mesh_sync_auth_response_failed", error)
        }
    }

    private func deriveSyncKeyCandidates(peerPubKey: Data) -> [SymmetricKey] {
        guard let privateKey = syncAuthPrivateKey, peerPubKey.count == 32,
              let peerKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPubKey),
              let sharedSecret = try? privateKey.sharedSecretFromKeyAgreement(with: peerKey)
        else {
            return []
        }
        let secret = sharedSecret.withUnsafeBytes { Data($0) }
        syncAuthSharedSecret = secret
        let ours = syncAuthOurConnId
        let theirs = syncAuthPeerConnId
        let ourPub = privateKey.publicKey.rawRepresentation
        let infos: [Data] = [
            theirs + ours,
            ours + theirs,
            peerPubKey + ourPub,
            ourPub + peerPubKey,
            Data(),
        ]
        var keys: [SymmetricKey] = []
        for info in infos {
            keys.append(
                HKDF<SHA256>.deriveKey(
                    inputKeyMaterial: SymmetricKey(data: secret),
                    salt: Self.hkdfSalt,
                    info: info,
                    outputByteCount: 32
                )
            )
        }
        return keys
    }

    private func handleSyncAuthContinuation(
        payload: Data,
        frame: LyraMeshPack.Frame,
        logiConn: LogiConnFrame,
        endpoint: NWEndpoint,
        reply: LyraMeshSocket.ReplyHandler
    ) {
        if payload.count > 64 {
            let blob = Self.officialMacSyncAuthCredential
            let responseInner = LogiConnInnerFrame(frameType: 4, payload: .disconnect(blob))
            let responseLogiConn = LogiConnFrame(
                logiConnId: logiConn.logiConnId,
                localNetId: logiConn.localNetId,
                remoteNetId: logiConn.remoteNetId,
                inner: responseInner.serialized()
            )
            let miResponse = MiConnectFrame(version: 0, logiConnFrames: [responseLogiConn])
            let responseFrame = LyraMeshPack.Frame(packType: frame.packType, payload: miResponse.serialized())
            do {
                try reply(responseFrame)
                DiagnosticsLog.info(
                    "xiaomi.mishare.mesh_sync_auth_cred_response to=\(endpoint.debugDescription) " +
                        "credBytes=\(payload.count)"
                )
            } catch {
                DiagnosticsLog.error("xiaomi.mishare.mesh_sync_auth_cred_failed", error)
            }
        } else if payload.count == 32 {
            DiagnosticsLog.info(
                "xiaomi.mishare.mesh_sync_auth_confirm from=\(endpoint.debugDescription) " +
                    "hex=\(payload.map { String(format: "%02x", $0) }.joined())"
            )
        } else {
            DiagnosticsLog.info(
                "xiaomi.mishare.mesh_sync_auth_status from=\(endpoint.debugDescription) " +
                    "hex=\(payload.map { String(format: "%02x", $0) }.joined())"
            )
        }
    }

    private func sendEncryptedSyncAnnounce(endpointDescription: String, key: SymmetricKey) {
        guard let deviceIdHex = deviceIdHexProvider() else {
            return
        }
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let deviceInfo = LyraTrustedDeviceInfo.deviceInfoFrame(
            deviceName: displayNameProvider(),
            deviceType: 14,
            deviceId: deviceIdHex,
            uidHash: "61F2",
            hwModel: Self.hardwareModel(),
            lyraVersion: "5.1.208.10.fullCnRelease.0512164",
            services: [
                LyraTrustedDeviceInfo.Service(name: "miLyraShare", package: "com.edgelink.mac"),
                LyraTrustedDeviceInfo.Service(name: "miShareBasic", package: "com.edgelink.mac"),
                LyraTrustedDeviceInfo.Service(name: "miLyraShareTransfer", package: "com.edgelink.mac")
            ],
            ipAddress: Self.primaryIPv4Address(),
            osVersion: "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
        )
        let inner = LyraTrustedDeviceInfo.plaintextAnnounce(deviceInfo: deviceInfo)
        do {
            let nonce = AES.GCM.Nonce()
            let sealed = try AES.GCM.seal(inner, using: key, nonce: nonce)
            var payload = Data()
            payload.append(1)
            payload.append(1)
            payload.append(contentsOf: nonce.withUnsafeBytes { Data($0) })
            payload.append(sealed.ciphertext)
            payload.append(sealed.tag)
            let frame = LyraMeshPack.Frame(packType: 5, payload: payload)
            socket.sendInboundAsync(frame: frame, toEndpointDescription: endpointDescription)
            DiagnosticsLog.info(
                "xiaomi.mishare.sync_announce_sent to=\(endpointDescription) bytes=\(payload.count)"
            )
        } catch {
            DiagnosticsLog.error("xiaomi.mishare.sync_announce_failed", error)
        }
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
            sendAnnounce(endpointDescription: endpoint.debugDescription)
        } catch {
            DiagnosticsLog.error("xiaomi.mishare.mesh_sync_response_failed", error)
        }
    }
}
