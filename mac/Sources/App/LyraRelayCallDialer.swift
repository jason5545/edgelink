import CryptoKit
import EdgeLinkKit
import Foundation
import Network

// Mac-initiated native relay dial: dials the phone's relayPhoneCall service
// (com.android.phone:relayPhoneCall) like a pad would — full client
// AuthHandshake on a fresh conn, logi REQUEST carrying the peer-port request,
// channel socket negotiation, then relay://dial URI. The phone's
// handleRelayDialRequest places the cellular call with EXTRA_CALL_RELAYED.
final class LyraRelayCallDialer {
    private enum State: Equatable {
        case idle
        case cookie
        case syncAuth
        case authHandshake
        case connRequest
        case awaitingPeerPort
        case channelUp
        case done
        case failed(String)
    }

    static let serviceName = "com.android.phone:relayPhoneCall"
    static let servicePackage = "com.android.phone"
    private static let clientChannelId: UInt64 = 7
    private static let overallTimeout: TimeInterval = 20

    private let socket = LyraMeshSocket()
    private let queue = DispatchQueue(label: "edgelink.lyra.relaydialer")
    private var host: String?
    private var port: UInt16 = 0
    private var candidatePorts: [UInt16] = []
    private var state: State = .idle
    private var number = ""
    private var physConnId: UInt32 = 0
    private var logiConnId: UInt32 = 0
    private var peerNetId: UInt32 = 0
    private var ourCookie: UInt64 = 0
    private let handshakeId: UInt64 = 1
    private var authEphKey: P256.KeyAgreement.PrivateKey?
    private var authClientRandom = Data()
    private var authSharedZ = Data()
    private var authServerEphPub = Data()
    private var meshSessionKey: SymmetricKey?
    private var transKey = Data()
    private var channelSocket: LyraChannelSocket?
    private var methodId = "1"
    private var timeoutItem: DispatchWorkItem?

    private let deviceIdHexProvider: () -> String?
    private let displayNameProvider: () -> String

    private static let sessionSalt = Data([
        0x5e, 0xd5, 0xa3, 0xf8, 0x36, 0xf6, 0xb5, 0x4f,
        0x7b, 0x1e, 0xfa, 0xd0, 0x27, 0x14, 0xd5, 0x17,
        0x7b, 0x8a, 0x1f, 0x0f, 0x19, 0xe3, 0x69, 0xcc,
        0x0b, 0xe8, 0xd9, 0x8b, 0xa6, 0x29, 0x73, 0x17
    ])
    private static let ticketSalt = Data([
        0x0a, 0x5b, 0x87, 0x72, 0x08, 0xd4, 0xa1, 0xcf,
        0x76, 0xd3, 0x08, 0x09, 0x51, 0xdd, 0x1b, 0xb8,
        0x6b, 0x4e, 0x9e, 0xe2, 0x57, 0x92, 0x4b, 0xaf,
        0xdb, 0xa6, 0x2c, 0x5a, 0x67, 0x06, 0xe6, 0x18
    ])

    init(
        deviceIdHexProvider: @escaping () -> String?,
        displayNameProvider: @escaping () -> String
    ) {
        self.deviceIdHexProvider = deviceIdHexProvider
        self.displayNameProvider = displayNameProvider
    }

    static func currentDeviceIdHex() -> String {
        UserDefaults.standard.string(forKey: "xiaomiTrustCloneDeviceId") ?? "721572C3"
    }

    func dial(number: String, host: String, ports: [UInt16]) {
        queue.async { [weak self] in
            guard let self, !ports.isEmpty else { return }
            self.stopLocked()
            self.number = number
            self.host = host
            self.candidatePorts = Array(ports.prefix(8))
            self.state = .idle
            self.methodId = String(UInt32.random(in: 1...UInt32.max))
            self.socket.onFrame = { [weak self] frame, endpoint, reply in
                self?.handle(frame: frame, endpoint: endpoint, reply: reply)
            }
            DiagnosticsLog.info("xiaomi.relaydial.start number_len=\(number.count) to=\(host):\(self.candidatePorts)")
            self.sendPhysSyncRequest()
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, self.state != .done, self.state != .channelUp else { return }
                DiagnosticsLog.warn("xiaomi.relaydial.timeout state=\(self.state)")
                self.stopLocked()
            }
            timeoutItem = timeout
            queue.asyncAfter(deadline: .now() + Self.overallTimeout, execute: timeout)
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopLocked()
        }
    }

    private func stopLocked() {
        timeoutItem?.cancel()
        timeoutItem = nil
        channelSocket?.stop()
        channelSocket = nil
        socket.stop()
        state = .idle
        host = nil
        port = 0
        candidatePorts = []
        peerNetId = 0
        ourCookie = 0
        authEphKey = nil
        authClientRandom = Data()
        authSharedZ = Data()
        authServerEphPub = Data()
        meshSessionKey = nil
        transKey = Data()
    }

    // MARK: - phys / cookie / sync_info

    private func sendPhysSyncRequest() {
        guard let deviceIdHex = deviceIdHexProvider(), host != nil else {
            DiagnosticsLog.warn("xiaomi.relaydial.no_identity")
            return
        }
        physConnId = .random(in: 1...UInt32.max)
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let deviceInfo = LyraDeviceInfo(
            deviceId: deviceIdHex,
            deviceType: 14,
            uidHash: "61F2",
            displayName: displayNameProvider(),
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
            field1: physConnId,
            field2: 1,
            payload: .syncDeviceInfoRequest(request)
        )
        let miFrame = MiConnectFrame(version: 0, logiConnFrames: [], physConnFrame: physConn)
        for targetPort in port != 0 ? [port] : candidatePorts {
            send(frame: LyraMeshPack.Frame(packType: 1, payload: miFrame.serialized()), label: "phys_sync", toPort: targetPort)
        }
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
        logiConnId = .random(in: 1...UInt32.max)
        var syncInfo = Data()
        LyraProtoWriter.appendVarintField(1, value: 10000, to: &syncInfo)
        LyraProtoWriter.appendVarintField(2, value: 16, to: &syncInfo)
        LyraProtoWriter.appendLengthDelimitedField(4, value: Data(Self.serviceName.utf8), to: &syncInfo)
        LyraProtoWriter.appendLengthDelimitedField(
            5, value: MiTrustTicketStore.current().uidFeatureInfo(), to: &syncInfo
        )
        let inner = LogiConnInnerFrame(frameType: 5, payload: .syncInfo(syncInfo))
        let logiConn = LogiConnFrame(
            logiConnId: logiConnId,
            localNetId: 1,
            remoteNetId: peerNetId,
            inner: inner.serialized()
        )
        let miFrame = MiConnectFrame(version: 0, logiConnFrames: [logiConn])
        send(frame: LyraMeshPack.Frame(packType: 2, payload: miFrame.serialized()), label: "sync_auth_hello")
    }

    // MARK: - AuthHandshake client (mirrors LyraMeshAnnouncer)

    private func sendAuthClientNotify() {
        let ephemeral = P256.KeyAgreement.PrivateKey()
        var clientRandom = Data(count: 32)
        clientRandom.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress { arc4random_buf(base, 32) }
        }
        authEphKey = ephemeral
        authClientRandom = clientRandom

        var publicKeyMessage = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &publicKeyMessage)
        LyraProtoWriter.appendLengthDelimitedField(
            2, value: ephemeral.publicKey.x963Representation, to: &publicKeyMessage
        )
        var cipherSuite = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &cipherSuite)
        LyraProtoWriter.appendLengthDelimitedField(2, value: clientRandom, to: &cipherSuite)
        LyraProtoWriter.appendVarintField(3, value: 64, to: &cipherSuite)
        LyraProtoWriter.appendVarintField(4, value: 2, to: &cipherSuite)
        LyraProtoWriter.appendLengthDelimitedField(5, value: publicKeyMessage, to: &cipherSuite)
        var clientNotify = Data()
        LyraProtoWriter.appendLengthDelimitedField(1, value: cipherSuite, to: &clientNotify)
        LyraProtoWriter.appendVarintField(2, value: 4, to: &clientNotify)
        LyraProtoWriter.appendLengthDelimitedField(3, value: Data([0x08, 0x01]), to: &clientNotify)
        LyraProtoWriter.appendLengthDelimitedField(4, value: Data([0x08, 0x01]), to: &clientNotify)
        var authFrame = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &authFrame)
        LyraProtoWriter.appendLengthDelimitedField(2, value: clientNotify, to: &authFrame)
        sendAuthHandshake(authFrame: authFrame, label: "auth_client_notify")
        state = .authHandshake
    }

    private func sendAuthHandshake(authFrame: Data, label: String) {
        var handshake = Data()
        LyraProtoWriter.appendVarintField(1, value: 4, to: &handshake)
        LyraProtoWriter.appendVarintField(2, value: 5, to: &handshake)
        LyraProtoWriter.appendLengthDelimitedField(7, value: authFrame, to: &handshake)
        var upgrade = Data()
        LyraProtoWriter.appendVarintField(1, value: handshakeId, to: &upgrade)
        LyraProtoWriter.appendLengthDelimitedField(2, value: handshake, to: &upgrade)
        let inner = LogiConnInnerFrame(frameType: 6, payload: .upgrade(upgrade))
        let logiConn = LogiConnFrame(
            logiConnId: logiConnId,
            localNetId: 1,
            remoteNetId: peerNetId,
            inner: inner.serialized()
        )
        let miFrame = MiConnectFrame(version: 0, logiConnFrames: [logiConn])
        send(frame: LyraMeshPack.Frame(packType: 2, payload: miFrame.serialized()), label: label)
    }

    private func handleAuthUpgrade(_ upgradeData: Data) {
        guard let handshake = lengthDelimitedField(2, in: upgradeData),
              let authFrame = lengthDelimitedField(7, in: handshake)
                ?? lengthDelimitedField(6, in: handshake),
              let step = varintField(1, in: authFrame)
        else {
            DiagnosticsLog.warn(
                "xiaomi.relaydial.auth_parse_failed hex=\(upgradeData.prefix(64).map { String(format: "%02x", $0) }.joined())"
            )
            return
        }
        switch step {
        case 2:
            handleAuthServerNotify(authFrame: authFrame)
        case 4:
            handleAuthServerFinished(authFrame: authFrame)
        default:
            DiagnosticsLog.info("xiaomi.relaydial.auth_other step=\(step)")
        }
    }

    private func handleAuthServerNotify(authFrame: Data) {
        guard let serverNotify = lengthDelimitedField(3, in: authFrame),
              let selected = lengthDelimitedField(1, in: serverNotify),
              let serverRandom = lengthDelimitedField(2, in: selected),
              serverRandom.count == 32,
              let publicKeyMessage = lengthDelimitedField(5, in: selected),
              let serverPub = lengthDelimitedField(2, in: publicKeyMessage),
              serverPub.count == 65, serverPub.first == 0x04,
              let ephemeral = authEphKey
        else {
            DiagnosticsLog.warn("xiaomi.relaydial.auth_notify_parse_failed")
            return
        }
        let secret: Data
        do {
            let peerKey = try P256.KeyAgreement.PublicKey(x963Representation: serverPub)
            secret = try ephemeral.sharedSecretFromKeyAgreement(with: peerKey).withUnsafeBytes { Data($0) }
        } catch {
            DiagnosticsLog.error("xiaomi.relaydial.auth_ecdh_failed", error)
            return
        }
        authSharedZ = secret
        authServerEphPub = serverPub
        let clientPub = ephemeral.publicKey.x963Representation
        let sessionKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            salt: Self.sessionSalt,
            info: authClientRandom + serverRandom,
            outputByteCount: 32
        )
        let ticket = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            salt: Self.ticketSalt,
            info: authClientRandom + serverRandom,
            outputByteCount: 32
        )
        meshSessionKey = sessionKey
        MiTrustTicketStore.recordAuthSession(
            sessionKey: sessionKey.withUnsafeBytes { Data($0) },
            ticket: ticket.withUnsafeBytes { Data($0) }
        )
        let ticketStore = MiTrustTicketStore.current()
        guard let identityKey = ticketStore.identityPrivateKey,
              let signature = try? identityKey.signature(for: SHA256.hash(data: clientPub + serverPub))
        else {
            DiagnosticsLog.warn("xiaomi.relaydial.auth_no_identity")
            return
        }
        do {
            let nonce = AES.GCM.Nonce()
            let sealed = try AES.GCM.seal(
                signature.derRepresentation, using: SymmetricKey(data: secret), nonce: nonce
            )
            var blob = Data()
            blob.append(contentsOf: nonce.withUnsafeBytes { Data($0) })
            blob.append(sealed.ciphertext)
            blob.append(sealed.tag)
            var clientFinished = Data()
            LyraProtoWriter.appendLengthDelimitedField(1, value: blob, to: &clientFinished)
            var outAuthFrame = Data()
            LyraProtoWriter.appendVarintField(1, value: 3, to: &outAuthFrame)
            LyraProtoWriter.appendLengthDelimitedField(4, value: clientFinished, to: &outAuthFrame)
            sendAuthHandshake(authFrame: outAuthFrame, label: "auth_client_finished")
        } catch {
            DiagnosticsLog.error("xiaomi.relaydial.auth_finish_enc_failed", error)
        }
    }

    private func handleAuthServerFinished(authFrame: Data) {
        guard let serverFinished = lengthDelimitedField(5, in: authFrame),
              let blob = lengthDelimitedField(1, in: serverFinished),
              let sessionKey = meshSessionKey
        else {
            DiagnosticsLog.warn("xiaomi.relaydial.auth_finished_parse_failed")
            return
        }
        if let proof = MiTrustTicketStore.current().decrypt(blob, with: sessionKey) {
            DiagnosticsLog.info(
                "xiaomi.relaydial.auth_server_finished valid=\(proof == authSharedZ + authServerEphPub)"
            )
        }
        DiagnosticsLog.info("xiaomi.relaydial.auth_completed")
        sendLogiConnRequest()
    }

    // MARK: - logi REQUEST + peer-port + channel

    private func sendLogiConnRequest() {
        transKey = randomBytes(32)
        var peerPortRequest = Data()
        LyraProtoWriter.appendVarintField(1, value: Self.clientChannelId, to: &peerPortRequest)
        LyraProtoWriter.appendLengthDelimitedField(4, value: transKey, to: &peerPortRequest)
        LyraProtoWriter.appendLengthDelimitedField(5, value: randomBytes(32), to: &peerPortRequest)
        var userInfo = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &userInfo)
        LyraProtoWriter.appendLengthDelimitedField(2, value: Data(Self.servicePackage.utf8), to: &userInfo)
        LyraProtoWriter.appendLengthDelimitedField(
            3, value: Data(colonHex(randomBytes(32)).utf8), to: &userInfo
        )
        LyraProtoWriter.appendLengthDelimitedField(10, value: peerPortRequest, to: &userInfo)
        var request = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &request)
        LyraProtoWriter.appendLengthDelimitedField(2, value: Data(Self.serviceName.utf8), to: &request)
        LyraProtoWriter.appendLengthDelimitedField(3, value: userInfo, to: &request)
        let inner = LogiConnInnerFrame(frameType: 1, payload: .request(request))
        sendEncrypted(inner: inner, label: "logi_request")
        state = .connRequest
    }

    private func connectChannel(port peerPort: UInt16) {
        guard let host else { return }
        let socket = LyraChannelSocket()
        socket.onNegotiated = { [weak self] serverChannelId, mtu in
            guard let self else { return }
            self.state = .channelUp
            DiagnosticsLog.info(
                "xiaomi.relaydial.channel_up serverChannelId=\(serverChannelId) mtu=\(mtu)"
            )
            self.sendDialRequest()
        }
        socket.onMessage = { [weak self] message, _ in
            self?.handleChannelMessage(message)
        }
        socket.onPeerConnected = { from in
            DiagnosticsLog.info("xiaomi.relaydial.channel_peer from=\(from.debugDescription)")
        }
        do {
            try socket.connect(host: host, port: peerPort, socketKey: transKey)
            try socket.sendClientNegotiation(
                channelId: UInt32(Self.clientChannelId), version: 1, mtu: 0xFF00
            )
            channelSocket = socket
            DiagnosticsLog.info("xiaomi.relaydial.channel_connect port=\(peerPort)")
        } catch {
            DiagnosticsLog.error("xiaomi.relaydial.channel_connect_failed", error)
            state = .failed("channel connect failed")
        }
    }

    private func sendDialRequest() {
        let json =
            "{\"address\":\"\(number)\",\"requestDeviceId\":\"\(Self.currentDeviceIdHex())\",\"videoState\":0}"
        let uri = "relay://dial:\(methodId)/request?\(json)"
        sendChannelText(uri)
    }

    private func sendChannelText(_ text: String) {
        guard let socket = channelSocket, !transKey.isEmpty else {
            DiagnosticsLog.warn("xiaomi.relaydial.tx_no_channel")
            return
        }
        do {
            try socket.sendVariant(
                channelFrame: LyraChannelSocket.wrapChannelFrame(Data(text.utf8)),
                key: transKey,
                singleLayer: true
            )
            DiagnosticsLog.info("xiaomi.relaydial.uri_tx \(text)")
        } catch {
            DiagnosticsLog.error("xiaomi.relaydial.channel_tx_failed", error)
        }
    }

    private func handleChannelMessage(_ message: Data) {
        var payload = message
        if let (tag, child) = try? LyraExpressTLVParser.parseOneOf(message), tag == 1,
           let payloadNode = LyraExpressTLVParser.firstChild(0, in: LyraExpressTLVParser.children(of: child))
        {
            payload = payloadNode.payload
        }
        guard let text = String(data: payload, encoding: .utf8) else {
            DiagnosticsLog.info(
                "xiaomi.relaydial.channel_rx bytes=\(message.count) " +
                    "head=\(message.prefix(48).map { String(format: "%02x", $0) }.joined())"
            )
            return
        }
        DiagnosticsLog.info("xiaomi.relaydial.uri_rx \(text)")
        if text.hasPrefix("relay://dial:\(methodId)/response?") {
            if text.contains("\"code\":0") || text.contains("\"code\": 0") {
                DiagnosticsLog.info("xiaomi.relaydial.dial_accepted")
                state = .done
            } else {
                DiagnosticsLog.warn("xiaomi.relaydial.dial_rejected \(text)")
                state = .failed("dial rejected")
            }
        }
    }

    // MARK: - frame handling

    private func handle(frame: LyraMeshPack.Frame, endpoint: NWEndpoint, reply: LyraMeshSocket.ReplyHandler) {
        if port == 0, let endpointPort = Self.endpointPort(endpoint), candidatePorts.contains(endpointPort) {
            port = endpointPort
            candidatePorts = [endpointPort]
            DiagnosticsLog.info("xiaomi.relaydial.port_pinned port=\(endpointPort)")
        }
        if frame.packType == 5 {
            handlePayloadFrame(frame)
            return
        }
        guard let miFrame = MiConnectFrame(parsing: frame.payload) else {
            return
        }
        if let physConn = miFrame.physConnFrame {
            switch physConn.payload {
            case .syncDeviceInfoResponse:
                DiagnosticsLog.info("xiaomi.relaydial.phys_synced")
                state = .cookie
                sendCookie(phase: 1)
            case let .keepAliveResponse(responseData) where physConn.field2 == 5:
                if state == .cookie {
                    let fields = (try? LyraProtoReader.readFields(from: responseData)) ?? []
                    var phase: UInt64 = 0
                    for field in fields where field.number == 2 && field.wireType == 0 {
                        phase = field.varintValue ?? 0
                    }
                    if phase < 2 {
                        sendCookie(phase: phase + 1)
                    } else {
                        state = .syncAuth
                        sendSyncAuthHello()
                    }
                }
            case let .keepAliveRequest(requestData):
                let tick = UInt64(LyraMeshSocket.tick())
                var responsePayload = Data()
                LyraProtoWriter.appendVarintField(1, value: tick, to: &responsePayload)
                LyraProtoWriter.appendVarintField(2, value: 2, to: &responsePayload)
                LyraProtoWriter.appendVarintField(3, value: tick, to: &responsePayload)
                let responsePhysConn = PhysConnFrame(field2: 5, payload: .keepAliveResponse(responsePayload))
                let miResponse = MiConnectFrame(version: 0, logiConnFrames: [], physConnFrame: responsePhysConn)
                try? reply(LyraMeshPack.Frame(packType: frame.packType, payload: miResponse.serialized()))
                _ = requestData
            case .disconnectRequest, .disconnectResponse:
                DiagnosticsLog.warn("xiaomi.relaydial.disconnected state=\(state)")
                stopLocked()
            default:
                break
            }
        }
        for logiConn in miFrame.logiConnFrames where logiConn.logiConnId == logiConnId {
            var inner = LogiConnInnerFrame(parsing: logiConn.inner)
            if inner == nil, logiConn.flag {
                inner = decryptInner(logiConn)
            }
            guard let inner else { continue }
            switch inner.payload {
            case .syncInfo:
                peerNetId = logiConn.localNetId
                DiagnosticsLog.info(
                    "xiaomi.relaydial.logi_synced peerNetId=\(logiConn.localNetId) connId=\(logiConn.logiConnId)"
                )
                if state == .syncAuth {
                    sendAuthClientNotify()
                }
            case let .upgrade(upgradeData):
                handleAuthUpgrade(upgradeData)
            case let .response(responseData):
                DiagnosticsLog.info(
                    "xiaomi.relaydial.logi_response hex=\(responseData.map { String(format: "%02x", $0) }.joined())"
                )
                if state == .connRequest {
                    let ack = LogiConnInnerFrame(frameType: 3, payload: .responseAck(Data()))
                    sendEncrypted(inner: ack, label: "response_ack")
                    state = .awaitingPeerPort
                }
            case let .disconnect(data):
                let code = varintField(1, in: data) ?? 0
                DiagnosticsLog.warn("xiaomi.relaydial.logi_disconnect code=\(code) state=\(state)")
                stopLocked()
            default:
                DiagnosticsLog.info(
                    "xiaomi.relaydial.logi_other frameType=\(inner.frameType) bytes=\(logiConn.inner.count)"
                )
            }
        }
    }

    private func handlePayloadFrame(_ frame: LyraMeshPack.Frame) {
        let payload = frame.payload
        // Plaintext packType-5 command: [netId, 0] + LyraChannelProtocol command.
        if payload.count > 4, let (header, commandBody) = try? LyraChannelProtocol.decode(payload.dropFirst(2)) {
            DiagnosticsLog.info("xiaomi.relaydial.command_plain type=\(header.type)")
            handlePeerPortResponse(type: header.type, body: commandBody)
            return
        }
        // Encrypted variant: [netId, 0] + AES-GCM(sessionKey) command.
        if let sessionKey = meshSessionKey, payload.count > 30 {
            let nonce = payload.dropFirst(2).prefix(12)
            let ciphertext = payload.dropFirst(14).dropLast(16)
            let tag = payload.suffix(16)
            if let box = try? AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: Data(nonce)),
                ciphertext: Data(ciphertext),
                tag: Data(tag)
            ), let plaintext = try? AES.GCM.open(box, using: sessionKey),
               let (header, commandBody) = try? LyraChannelProtocol.decode(plaintext)
            {
                DiagnosticsLog.info("xiaomi.relaydial.command_enc type=\(header.type)")
                handlePeerPortResponse(type: header.type, body: commandBody)
                return
            }
        }
        DiagnosticsLog.info(
            "xiaomi.relaydial.payload_ignored bytes=\(payload.count) " +
                "head=\(payload.prefix(24).map { String(format: "%02x", $0) }.joined())"
        )
    }

    private func handlePeerPortResponse(type: UInt8, body: Data) {
        guard type == LyraChannelProtocol.CommandType.responseOfPeerPort.rawValue else { return }
        let fields = (try? LyraProtoReader.readFields(from: body)) ?? []
        var peerPort: UInt16 = 0
        for field in fields where field.number == 3 && field.wireType == 0 {
            peerPort = UInt16(field.varintValue ?? 0)
        }
        guard peerPort != 0, state == .awaitingPeerPort else { return }
        DiagnosticsLog.info("xiaomi.relaydial.peer_port_rx port=\(peerPort)")
        connectChannel(port: peerPort)
    }

    // MARK: - helpers

    private func sendEncrypted(inner: LogiConnInnerFrame, label: String) {
        guard let sessionKey = meshSessionKey else { return }
        do {
            let nonce = AES.GCM.Nonce()
            let sealed = try AES.GCM.seal(inner.serialized(), using: sessionKey, nonce: nonce)
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
            DiagnosticsLog.error("xiaomi.relaydial.encrypt_failed label=\(label)", error)
        }
    }

    private func decryptInner(_ logiConn: LogiConnFrame) -> LogiConnInnerFrame? {
        guard let sessionKey = meshSessionKey else { return nil }
        let inner = logiConn.inner
        guard inner.count > 28 else { return nil }
        guard let box = try? AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: Data(inner.prefix(12))),
            ciphertext: Data(inner.dropFirst(12).dropLast(16)),
            tag: Data(inner.suffix(16))
        ), let plaintext = try? AES.GCM.open(box, using: sessionKey) else {
            return nil
        }
        return LogiConnInnerFrame(parsing: plaintext)
    }

    private func send(frame: LyraMeshPack.Frame, label: String, toPort: UInt16? = nil) {
        let targetPort = toPort ?? port
        guard let host, targetPort != 0 else { return }
        do {
            try socket.send(frame: frame, to: host, port: targetPort)
            DiagnosticsLog.info("xiaomi.relaydial.tx label=\(label)")
        } catch {
            DiagnosticsLog.error("xiaomi.relaydial.tx_failed label=\(label)", error)
        }
    }

    private static func endpointPort(_ endpoint: NWEndpoint) -> UInt16? {
        let description = endpoint.debugDescription
        guard let colon = description.lastIndex(of: ":") else { return nil }
        return UInt16(description[description.index(after: colon)...])
    }

    private func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress { arc4random_buf(base, count) }
        }
        return data
    }

    private func colonHex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    private func lengthDelimitedField(_ fieldNumber: Int, in data: Data) -> Data? {
        guard let fields = try? LyraProtoReader.readFields(from: data) else { return nil }
        return fields.first { $0.number == fieldNumber && $0.wireType == 2 }?.lengthDelimitedValue
    }

    private func varintField(_ fieldNumber: Int, in data: Data) -> UInt64? {
        guard let fields = try? LyraProtoReader.readFields(from: data) else { return nil }
        return fields.first { $0.number == fieldNumber && $0.wireType == 0 }?.varintValue
    }
}
