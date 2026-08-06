import CryptoKit
import EdgeLinkKit
import Foundation
import Network

// Server side of the audiomonitor DistAudio JSON-RPC service
// (com.miui.audiomonitor:DistAudioService). After the phone connects a
// DistAudio device (TeleService DistAudioDeviceProvider.connectDistAudioDevice),
// it dials this service and calls distAudio.openSpeaker / openMicrophone
// (JSON-RPC 2.0 over the lyra channel). We answer with real endpoints and
// capture the MiPlayCast/RTSP bytes both ways to ground-truth the transport.
final class LyraDistAudioRpcSession {
    static let serviceName = "com.miui.audiomonitor:DistAudioService"
    static let servicePackage = "com.miui.audiomonitor"

    private(set) static var activeSession: LyraDistAudioRpcSession?

    static func adopt(
        syncInfoData: Data,
        logiConn: LogiConnFrame,
        endpoint: NWEndpoint,
        sessionKey: SymmetricKey?,
        deviceIdHex: String,
        deviceName: String,
        send: @escaping (LyraMeshPack.Frame, String) -> Void
    ) -> LyraDistAudioRpcSession {
        if let existing = activeSession, existing.connId != logiConn.logiConnId {
            existing.teardown()
            activeSession = nil
        }
        let session = activeSession ?? LyraDistAudioRpcSession(send: send)
        session.deviceIdHex = deviceIdHex
        session.deviceName = deviceName
        activeSession = session
        session.handleSyncInfo(syncInfoData: syncInfoData, logiConn: logiConn, sessionKey: sessionKey)
        return session
    }

    private let send: (LyraMeshPack.Frame, String) -> Void
    private var connId: UInt32 = 0
    private var peerNetId: UInt32 = 0
    private var sessionKey: SymmetricKey?
    private var deviceIdHex = ""
    private var deviceName = ""
    private var responseSent = false
    private var peerPortAwaitingAck = false
    private var peerPortResponseSent = false
    private var channelSocket: LyraChannelSocket?
    private var transKey = Data()
    private var peerChannelId: UInt64 = 0

    init(send: @escaping (LyraMeshPack.Frame, String) -> Void) {
        self.send = send
    }

    func handles(logiConn: LogiConnFrame) -> Bool {
        connId != 0 && logiConn.logiConnId == connId
    }

    func teardown() {
        channelSocket?.stop()
        channelSocket = nil
        stopAudioTransport()
    }

    private func lengthDelimited(_ fieldNumber: Int, in data: Data) -> Data? {
        guard let fields = try? LyraProtoReader.readFields(from: data) else { return nil }
        return fields.first { $0.number == fieldNumber && $0.wireType == 2 }?.lengthDelimitedValue
    }

    private func varint(_ fieldNumber: Int, in data: Data) -> UInt64? {
        guard let fields = try? LyraProtoReader.readFields(from: data) else { return nil }
        return fields.first { $0.number == fieldNumber && $0.wireType == 0 }?.varintValue
    }

    private func handleSyncInfo(syncInfoData: Data, logiConn: LogiConnFrame, sessionKey: SymmetricKey?) {
        connId = logiConn.logiConnId
        peerNetId = logiConn.localNetId
        self.sessionKey = sessionKey
        let ticketStore = MiTrustTicketStore.current()
        let quickConn = lengthDelimited(8, in: syncInfoData) ?? Data()
        DiagnosticsLog.info(
            "xiaomi.distrpc.peer_sync_info connId=\(connId) quickConnBytes=\(quickConn.count)"
        )

        let syncInfo = LyraRelayCallSession.serverSyncInfo(ticketStore: ticketStore, sessionKey: sessionKey)
        let inner = LogiConnInnerFrame(frameType: 5, payload: .syncInfo(syncInfo))
        let frame = LogiConnFrame(
            logiConnId: connId, localNetId: 1, remoteNetId: peerNetId, inner: inner.serialized()
        )
        let miFrame = MiConnectFrame(version: 0, logiConnFrames: [frame])
        send(LyraMeshPack.Frame(packType: 2, payload: miFrame.serialized()), "distrpc_sync_info")

        if !quickConn.isEmpty {
            handleQuickConn(quickConn)
        }
    }

    private func handleQuickConn(_ quickConn: Data) {
        guard let sessionKey,
              let plaintext = MiTrustTicketStore.current().decrypt(quickConn, with: sessionKey)
        else {
            DiagnosticsLog.warn("xiaomi.distrpc.quickconn_decrypt_failed")
            return
        }
        let request = lengthDelimited(2, in: plaintext) ?? Data()
        let userInfo = lengthDelimited(3, in: request) ?? Data()
        let peerPortRequest = lengthDelimited(10, in: userInfo)
        DiagnosticsLog.info(
            "xiaomi.distrpc.quickconn_decrypted userInfoBytes=\(userInfo.count) " +
                "hasPeerPort=\(peerPortRequest != nil)"
        )
        sendLogiResponse()
        if let peerPortRequest {
            peerPortAwaitingAck = true
            prepareChannel(peerPortRequest: peerPortRequest)
        }
    }

    private func sendLogiResponse(force: Bool = false) {
        if !force {
            guard !responseSent else { return }
        }
        responseSent = true
        // The RPC dial (ServerChannelOptionsV2) carries a V2-confirm userData
        // payload in userInfo field 4 — {"serviceVersion":"","userData":"DistAudio"}
        // (wire capture 2026-08-06). The phone's client waits for our confirm
        // to echo it ("logical conn remote confirm timeout" otherwise).
        let base = LyraMitrustResponse.serverUserInfo(
            package: Self.servicePackage,
            nodeIdColonHex: Self.serverFingerprint,
            medium: 136
        )
        var userInfo = Data()
        let fields = (try? LyraProtoReader.readFields(from: base)) ?? []
        var inserted = false
        for field in fields {
            if !inserted, field.number > 4 {
                LyraProtoWriter.appendLengthDelimitedField(
                    4,
                    value: Data("{\"serviceVersion\":\"\",\"userData\":\"DistAudio\"}".utf8),
                    to: &userInfo
                )
                inserted = true
            }
            switch field.wireType {
            case 0:
                LyraProtoWriter.appendVarintField(field.number, value: field.varintValue ?? 0, to: &userInfo)
            case 2:
                LyraProtoWriter.appendLengthDelimitedField(
                    field.number, value: field.lengthDelimitedValue ?? Data(), to: &userInfo
                )
            default:
                continue
            }
        }
        let responseFrame = LyraMitrustResponse.logiConnResponse(userInfo: userInfo)
        let inner = LogiConnInnerFrame(frameType: 2, payload: .response(responseFrame))
        sendEncrypted(inner: inner, label: "distrpc_logi_response")
    }

    private static var serverFingerprint: String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: "xiaomiTrustLocalNodeIdHex"), existing.count == 95 {
            return existing
        }
        var random = Data(count: 32)
        random.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress { arc4random_buf(base, 32) }
        }
        let generated = random.map { String(format: "%02X", $0) }.joined(separator: ":")
        defaults.set(generated, forKey: "xiaomiTrustLocalNodeIdHex")
        return generated
    }

    private func sendEncrypted(inner: LogiConnInnerFrame, label: String) {
        guard let sessionKey else { return }
        do {
            let nonce = AES.GCM.Nonce()
            let sealed = try AES.GCM.seal(inner.serialized(), using: sessionKey, nonce: nonce)
            var encryptedInner = Data()
            encryptedInner.append(contentsOf: nonce.withUnsafeBytes { Data($0) })
            encryptedInner.append(sealed.ciphertext)
            encryptedInner.append(sealed.tag)
            let frame = LogiConnFrame(
                logiConnId: connId,
                localNetId: 1,
                remoteNetId: peerNetId,
                flag: true,
                inner: encryptedInner
            )
            let miFrame = MiConnectFrame(version: 0, logiConnFrames: [frame])
            send(LyraMeshPack.Frame(packType: 2, payload: miFrame.serialized()), label)
        } catch {
            DiagnosticsLog.error("xiaomi.distrpc.encrypt_failed label=\(label)", error)
        }
    }

    func handleFrame(_ logiConn: LogiConnFrame) {
        if logiConn.flag {
            handleEncryptedFrame(logiConn)
            return
        }
        guard let inner = LogiConnInnerFrame(parsing: logiConn.inner) else {
            DiagnosticsLog.warn("xiaomi.distrpc.plain_parse_failed bytes=\(logiConn.inner.count)")
            return
        }
        switch inner.payload {
        case let .upgrade(upgradeData):
            handleAuthUpgrade(upgradeData)
        case let .disconnect(data):
            let code = varint(1, in: data) ?? 0
            DiagnosticsLog.warn("xiaomi.distrpc.disconnect code=\(code)")
            teardown()
            if Self.activeSession === self {
                Self.activeSession = nil
            }
        case let .request(requestData):
            handleLogiRequest(requestData)
        default:
            DiagnosticsLog.info(
                "xiaomi.distrpc.plain_frame frameType=\(inner.frameType) bytes=\(logiConn.inner.count)"
            )
        }
    }

    private func handleEncryptedFrame(_ logiConn: LogiConnFrame) {
        guard let sessionKey else { return }
        let inner = logiConn.inner
        guard inner.count > 28,
              let box = try? AES.GCM.SealedBox(
                  nonce: AES.GCM.Nonce(data: Data(inner.prefix(12))),
                  ciphertext: Data(inner.dropFirst(12).dropLast(16)),
                  tag: Data(inner.suffix(16))
              ),
              let plaintext = try? AES.GCM.open(box, using: sessionKey),
              let decoded = LogiConnInnerFrame(parsing: plaintext)
        else {
            DiagnosticsLog.warn("xiaomi.distrpc.decrypt_failed bytes=\(logiConn.inner.count)")
            return
        }
        if decoded.frameType == 3 {
            DiagnosticsLog.info("xiaomi.distrpc.response_ack_rx")
            peerPortAwaitingAck = false
            sendPeerPortResponseIfReady()
            return
        }
        if case let .request(requestData) = decoded.payload {
            handleLogiRequest(requestData)
            return
        }
        let payloadData = decoded.payload?.data ?? Data()
        if let (header, commandBody) = try? LyraChannelProtocol.decode(payloadData) {
            if header.type == LyraChannelProtocol.CommandType.requestOfPeerPort.rawValue {
                prepareChannel(peerPortRequest: commandBody)
                sendPeerPortResponseIfReady()
            }
            return
        }
        DiagnosticsLog.info(
            "xiaomi.distrpc.frame frameType=\(decoded.frameType) bytes=\(payloadData.count) " +
                "head=\(payloadData.prefix(32).map { String(format: "%02x", $0) }.joined())"
        )
    }

    private func handleLogiRequest(_ requestData: Data) {
        let userInfo = lengthDelimited(3, in: requestData) ?? Data()
        let peerPortRequest = lengthDelimited(10, in: userInfo)
        DiagnosticsLog.info(
            "xiaomi.distrpc.logi_request_rx userInfoBytes=\(userInfo.count) hasPeerPort=\(peerPortRequest != nil) " +
                "userInfoHex=\(userInfo.map { String(format: "%02x", $0) }.joined())"
        )
        // REQUESTs may be KCP retransmits of one whose answer was lost
        // or keyed pre-auth — always re-answer with the current session key.
        sendLogiResponse(force: true)
        if let peerPortRequest {
            peerPortAwaitingAck = true
            prepareChannel(peerPortRequest: peerPortRequest)
        }
    }

    // MARK: - AuthHandshake server (account-pair family + AUTH fallback reply)

    private var authServerEphPriv: P256.KeyAgreement.PrivateKey?
    private var authClientEphPub = Data()
    private var authSharedZ = Data()
    private var authClientRandom = Data()
    private var authServerRandom = Data()

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
    private static let accountPairSessionSalt = Data([
        0x32, 0x9b, 0xfc, 0x53, 0x39, 0x36, 0x55, 0xd7,
        0x5a, 0xb0, 0x83, 0x98, 0xca, 0x91, 0x91, 0xef,
        0xfa, 0xa3, 0x37, 0xf2, 0xe0, 0xbe, 0xb5, 0x73,
        0xb1, 0xf9, 0xa3, 0xd0, 0x15, 0x57, 0x64, 0x80
    ])
    private static let accountPairTicketSalt = Data([
        0x7a, 0x83, 0xe2, 0xdc, 0x8e, 0x9a, 0x93, 0x37,
        0xc7, 0x8e, 0xc1, 0x35, 0xfc, 0x39, 0x9d, 0xc3,
        0x70, 0x56, 0x96, 0xe3, 0x94, 0x9e, 0x49, 0x77,
        0xdd, 0xb2, 0xd1, 0x67, 0xfe, 0xb0, 0x08, 0x11
    ])
    private var handshakeIsAccountPair: [UInt64: Bool] = [:]

    private func handleAuthUpgrade(_ upgradeData: Data) {
        guard let handshake = lengthDelimited(2, in: upgradeData),
              let handshakeId = varint(1, in: upgradeData)
        else {
            DiagnosticsLog.warn("xiaomi.distrpc.auth_parse_failed")
            return
        }
        let accountFrame = lengthDelimited(6, in: handshake)
        let authFrame = lengthDelimited(7, in: handshake) ?? accountFrame
        handshakeIsAccountPair[handshakeId] = accountFrame != nil && lengthDelimited(7, in: handshake) == nil
        guard let authFrame, let step = varint(1, in: authFrame)
        else {
            DiagnosticsLog.warn("xiaomi.distrpc.auth_parse_failed")
            return
        }
        switch step {
        case 1:
            handleAuthClientNotify(authFrame: authFrame, handshakeId: handshakeId)
        case 3:
            handleAuthClientFinished(authFrame: authFrame, handshakeId: handshakeId)
        default:
            DiagnosticsLog.info("xiaomi.distrpc.auth_other step=\(step)")
        }
    }

    private func sendAuthHandshake(authFrame: Data, handshakeId: UInt64, label: String) {
        var handshake = Data()
        if handshakeIsAccountPair[handshakeId] == true {
            LyraProtoWriter.appendVarintField(1, value: 2, to: &handshake)
            LyraProtoWriter.appendVarintField(2, value: 4, to: &handshake)
            LyraProtoWriter.appendLengthDelimitedField(6, value: authFrame, to: &handshake)
        } else {
            LyraProtoWriter.appendVarintField(1, value: 4, to: &handshake)
            LyraProtoWriter.appendVarintField(2, value: 5, to: &handshake)
            LyraProtoWriter.appendLengthDelimitedField(7, value: authFrame, to: &handshake)
        }
        var upgrade = Data()
        LyraProtoWriter.appendVarintField(1, value: handshakeId, to: &upgrade)
        LyraProtoWriter.appendLengthDelimitedField(2, value: handshake, to: &upgrade)
        let inner = LogiConnInnerFrame(frameType: 6, payload: .upgrade(upgrade))
        let frame = LogiConnFrame(
            logiConnId: connId, localNetId: 1, remoteNetId: peerNetId, inner: inner.serialized()
        )
        let miFrame = MiConnectFrame(version: 0, logiConnFrames: [frame])
        send(LyraMeshPack.Frame(packType: 2, payload: miFrame.serialized()), label)
    }

    private func handleAuthClientNotify(authFrame: Data, handshakeId: UInt64) {
        guard let clientNotify = lengthDelimited(2, in: authFrame),
              let cipherSuite = lengthDelimited(1, in: clientNotify),
              let clientRandom = lengthDelimited(2, in: cipherSuite),
              clientRandom.count == 32,
              let publicKeyMessage = lengthDelimited(5, in: cipherSuite),
              let clientPub = lengthDelimited(2, in: publicKeyMessage),
              clientPub.count == 65, clientPub.first == 0x04
        else {
            DiagnosticsLog.warn("xiaomi.distrpc.auth_notify_parse_failed")
            return
        }
        let privateKey = P256.KeyAgreement.PrivateKey()
        var serverRandom = Data(count: 32)
        serverRandom.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress { arc4random_buf(base, 32) }
        }
        let serverPub = privateKey.publicKey.x963Representation
        let secret: Data
        do {
            let peerKey = try P256.KeyAgreement.PublicKey(x963Representation: clientPub)
            secret = try privateKey.sharedSecretFromKeyAgreement(with: peerKey).withUnsafeBytes { Data($0) }
        } catch {
            DiagnosticsLog.error("xiaomi.distrpc.auth_ecdh_failed", error)
            return
        }
        authServerEphPriv = privateKey
        authClientEphPub = clientPub
        authSharedZ = secret
        authClientRandom = clientRandom
        authServerRandom = serverRandom
        if handshakeIsAccountPair[handshakeId] == true {
            sendAccountPairServerNotify(
                cipherSuite: cipherSuite, secret: secret,
                serverPub: serverPub, clientPub: clientPub,
                serverRandom: serverRandom, handshakeId: handshakeId
            )
            return
        }
        let ticketStore = MiTrustTicketStore.current()
        guard let identityKey = ticketStore.identityPrivateKey,
              let signature = try? identityKey.signature(for: SHA256.hash(data: serverPub + clientPub))
        else {
            DiagnosticsLog.warn("xiaomi.distrpc.auth_no_identity")
            return
        }
        let nonce = AES.GCM.Nonce()
        guard let sealed = try? AES.GCM.seal(signature.derRepresentation, using: SymmetricKey(data: secret), nonce: nonce) else {
            DiagnosticsLog.warn("xiaomi.distrpc.auth_enc_failed")
            return
        }
        var encSig = Data()
        encSig.append(contentsOf: nonce.withUnsafeBytes { Data($0) })
        encSig.append(sealed.ciphertext)
        encSig.append(sealed.tag)

        var outPublicKeyMessage = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &outPublicKeyMessage)
        LyraProtoWriter.appendLengthDelimitedField(2, value: serverPub, to: &outPublicKeyMessage)
        let offeredP3 = varint(3, in: cipherSuite) ?? 0x40
        let offeredP4 = varint(4, in: cipherSuite) ?? 2
        var selected = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &selected)
        LyraProtoWriter.appendLengthDelimitedField(2, value: serverRandom, to: &selected)
        LyraProtoWriter.appendVarintField(3, value: offeredP3, to: &selected)
        LyraProtoWriter.appendVarintField(4, value: offeredP4, to: &selected)
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
        sendAuthHandshake(authFrame: outAuthFrame, handshakeId: handshakeId, label: "distrpc_auth_server_notify")
    }

    private func sendAccountPairServerNotify(
        cipherSuite: Data, secret: Data, serverPub: Data, clientPub: Data,
        serverRandom: Data, handshakeId: UInt64
    ) {
        guard let (certDER, certPriv) = Self.enrolledCertMaterial(),
              let signature = try? certPriv.signature(for: SHA256.hash(data: serverPub + clientPub))
        else {
            DiagnosticsLog.warn("xiaomi.distrpc.acctpair_no_cert")
            return
        }
        var credMessage = Data()
        LyraProtoWriter.appendLengthDelimitedField(1, value: certDER, to: &credMessage)
        LyraProtoWriter.appendLengthDelimitedField(2, value: signature.derRepresentation, to: &credMessage)
        let zKey = SymmetricKey(data: secret)
        do {
            let nonce = AES.GCM.Nonce()
            let sealed = try AES.GCM.seal(credMessage, using: zKey, nonce: nonce)
            var encSig = Data()
            encSig.append(contentsOf: nonce.withUnsafeBytes { Data($0) })
            encSig.append(sealed.ciphertext)
            encSig.append(sealed.tag)

            var outPublicKeyMessage = Data()
            LyraProtoWriter.appendVarintField(1, value: 1, to: &outPublicKeyMessage)
            LyraProtoWriter.appendLengthDelimitedField(2, value: serverPub, to: &outPublicKeyMessage)
            let offeredP3 = varint(3, in: cipherSuite) ?? 0x10
            let offeredP4 = varint(4, in: cipherSuite) ?? 0x08
            var selected = Data()
            LyraProtoWriter.appendVarintField(1, value: 1, to: &selected)
            LyraProtoWriter.appendLengthDelimitedField(2, value: serverRandom, to: &selected)
            LyraProtoWriter.appendVarintField(3, value: offeredP3, to: &selected)
            LyraProtoWriter.appendVarintField(4, value: offeredP4, to: &selected)
            LyraProtoWriter.appendLengthDelimitedField(5, value: outPublicKeyMessage, to: &selected)
            var tiny = Data()
            LyraProtoWriter.appendVarintField(1, value: 1, to: &tiny)
            var serverNotify = Data()
            LyraProtoWriter.appendLengthDelimitedField(1, value: selected, to: &serverNotify)
            LyraProtoWriter.appendLengthDelimitedField(2, value: encSig, to: &serverNotify)
            LyraProtoWriter.appendLengthDelimitedField(3, value: tiny, to: &serverNotify)
            LyraProtoWriter.appendLengthDelimitedField(4, value: tiny, to: &serverNotify)
            var outAuthFrame = Data()
            LyraProtoWriter.appendVarintField(1, value: 2, to: &outAuthFrame)
            LyraProtoWriter.appendLengthDelimitedField(3, value: serverNotify, to: &outAuthFrame)
            sendAuthHandshake(authFrame: outAuthFrame, handshakeId: handshakeId, label: "distrpc_acctpair_server_notify")
        } catch {
            DiagnosticsLog.error("xiaomi.distrpc.acctpair_enc_failed", error)
        }
    }

    private static func enrolledCertMaterial() -> (certDER: Data, priv: P256.Signing.PrivateKey)? {
        let lookup = MiTrustTicketStore.enrolledCertOverride ?? {
            guard let did = MijiaCertEnrollment.currentDid(
                shortDeviceIdHex: MijiaCertEnrollment.currentShortDeviceIdHex
            ) else { return nil }
            return MijiaEnrolledCertStore.usableCert(forDid: did)
        }
        guard let enrolled = lookup(),
              let certDER = enrolled.certDER,
              let privRaw = enrolled.privateKeyRaw,
              let priv = try? P256.Signing.PrivateKey(rawRepresentation: privRaw)
        else { return nil }
        return (certDER, priv)
    }

    private func handleAuthClientFinished(authFrame: Data, handshakeId: UInt64) {
        guard let clientFinished = lengthDelimited(4, in: authFrame),
              let serverEphPub = authServerEphPriv?.publicKey.x963Representation,
              !authSharedZ.isEmpty, !authClientEphPub.isEmpty
        else {
            DiagnosticsLog.warn("xiaomi.distrpc.auth_finished_parse_failed")
            return
        }
        let ticketStore = MiTrustTicketStore.current()
        let zKey = SymmetricKey(data: authSharedZ)
        if handshakeIsAccountPair[handshakeId] == true {
            guard let credBlob = lengthDelimited(1, in: clientFinished),
                  let credMessage = ticketStore.decrypt(credBlob, with: zKey),
                  let phoneCert = lengthDelimited(1, in: credMessage),
                  let phoneSig = lengthDelimited(2, in: credMessage),
                  let cert = SecCertificateCreateWithData(nil, phoneCert as CFData),
                  let key = SecCertificateCopyKey(cert),
                  let rep = SecKeyCopyExternalRepresentation(key, nil) as? Data,
                  let phonePub = try? P256.Signing.PublicKey(x963Representation: rep),
                  let signature = try? P256.Signing.ECDSASignature(derRepresentation: phoneSig)
            else {
                DiagnosticsLog.warn("xiaomi.distrpc.acctpair_finished_parse_failed")
                return
            }
            guard phonePub.isValidSignature(
                signature, for: SHA256.hash(data: authClientEphPub + serverEphPub)
            ) else {
                DiagnosticsLog.warn("xiaomi.distrpc.acctpair_sig_invalid")
                return
            }
            MiTrustTicketStore.harvestPeerAccountPubKey(fromCertDER: phoneCert)
            completeHandshake(
                zKey: zKey, sessionSalt: Self.accountPairSessionSalt, ticketSalt: Self.accountPairTicketSalt,
                serverEphPub: serverEphPub, handshakeId: handshakeId,
                label: "distrpc_acctpair_server_finished",
                proof: lengthDelimited(2, in: clientFinished)
            )
            return
        }
        guard let encSigC = lengthDelimited(1, in: clientFinished),
              !encSigC.isEmpty,
              let sigC = ticketStore.decrypt(encSigC, with: zKey),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: sigC)
        else {
            DiagnosticsLog.warn("xiaomi.distrpc.auth_sig_decrypt_failed")
            return
        }
        let digest = SHA256.hash(data: authClientEphPub + serverEphPub)
        let verified = ticketStore.peerSigningPubKeys.contains { keyData in
            guard let key = try? P256.Signing.PublicKey(x963Representation: keyData) else { return false }
            return key.isValidSignature(signature, for: digest)
        }
        guard verified else {
            DiagnosticsLog.warn("xiaomi.distrpc.auth_sig_invalid")
            return
        }
        completeHandshake(
            zKey: zKey, sessionSalt: Self.sessionSalt, ticketSalt: Self.ticketSalt,
            serverEphPub: serverEphPub, handshakeId: handshakeId,
            label: "distrpc_auth_server_finished", proof: nil
        )
    }

    private func completeHandshake(
        zKey: SymmetricKey, sessionSalt: Data, ticketSalt: Data,
        serverEphPub: Data, handshakeId: UInt64, label: String, proof: Data?
    ) {
        let newSessionKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: zKey,
            salt: sessionSalt,
            info: authClientRandom + authServerRandom,
            outputByteCount: 32
        )
        let ticket = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: zKey,
            salt: ticketSalt,
            info: authClientRandom + authServerRandom,
            outputByteCount: 32
        )
        MiTrustTicketStore.recordAuthSession(
            sessionKey: newSessionKey.withUnsafeBytes { Data($0) },
            ticket: ticket.withUnsafeBytes { Data($0) }
        )
        sessionKey = newSessionKey
        if let proof {
            let proofOk = MiTrustTicketStore.current().decrypt(proof, with: newSessionKey) != nil
            DiagnosticsLog.info("xiaomi.distrpc.acctpair_proof ok=\(proofOk)")
        }
        var serverFinished = Data()
        do {
            let nonce = AES.GCM.Nonce()
            let sealed = try AES.GCM.seal(authSharedZ + serverEphPub, using: newSessionKey, nonce: nonce)
            var blob = Data()
            blob.append(contentsOf: nonce.withUnsafeBytes { Data($0) })
            blob.append(sealed.ciphertext)
            blob.append(sealed.tag)
            LyraProtoWriter.appendLengthDelimitedField(1, value: blob, to: &serverFinished)
        } catch {
            DiagnosticsLog.error("xiaomi.distrpc.finish_enc_failed", error)
            return
        }
        var outAuthFrame = Data()
        LyraProtoWriter.appendVarintField(1, value: 4, to: &outAuthFrame)
        LyraProtoWriter.appendLengthDelimitedField(5, value: serverFinished, to: &outAuthFrame)
        sendAuthHandshake(authFrame: outAuthFrame, handshakeId: handshakeId, label: label)
        DiagnosticsLog.info("xiaomi.distrpc.handshake_completed")
    }

    // MARK: - Channel

    private func prepareChannel(peerPortRequest: Data) {
        var channelId: UInt64 = 0
        var key = Data()
        let fields = (try? LyraProtoReader.readFields(from: peerPortRequest)) ?? []
        for field in fields {
            switch (field.number, field.wireType) {
            case (1, 0): channelId = field.varintValue ?? 0
            case (4, 2): key = field.lengthDelimitedValue ?? Data()
            default: continue
            }
        }
        guard !key.isEmpty else {
            DiagnosticsLog.warn("xiaomi.distrpc.peer_port_bad_request")
            return
        }
        guard channelSocket == nil else { return }
        transKey = key
        peerChannelId = channelId
        let socket = LyraChannelSocket()
        socket.onMessage = { [weak self] message, _ in
            self?.handleChannelMessage(message)
        }
        socket.onPeerConnected = { [weak self] from in
            DiagnosticsLog.info("xiaomi.distrpc.channel_peer from=\(from.debugDescription)")
            // The RPC (openMicrophone) can arrive immediately after the channel
            // is up — have the uplink port ready before then.
            self?.startUplinkServer()
        }
        socket.onNegotiated = { serverChannelId, mtu in
            DiagnosticsLog.info("xiaomi.distrpc.channel_negotiated serverChannelId=\(serverChannelId) mtu=\(mtu)")
        }
        do {
            try socket.start(socketKey: key, serverChannelId: 10)
            channelSocket = socket
        } catch {
            DiagnosticsLog.error("xiaomi.distrpc.channel_start_failed", error)
        }
    }

    private func sendPeerPortResponseIfReady() {
        guard !peerPortAwaitingAck, !peerPortResponseSent,
              let port = channelSocket?.boundPort
        else { return }
        peerPortResponseSent = true
        var serverKey = Data(count: 32)
        serverKey.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress { arc4random_buf(base, 32) }
        }
        let responseBody = LyraMitrustResponse.peerPortResponseBody(
            clientChannelId: peerChannelId,
            serverChannelId: 10,
            port: port,
            serverKey: serverKey
        )
        let command = LyraChannelProtocol.encode(type: .responseOfPeerPort, body: responseBody)
        var payload = Data()
        payload.append(UInt8(peerNetId & 0xFF))
        payload.append(0)
        payload.append(command)
        send(LyraMeshPack.Frame(packType: 5, payload: payload), "distrpc_peer_port_response")
        DiagnosticsLog.info("xiaomi.distrpc.peer_port_tx port=\(port)")
    }

    // MARK: - JSON-RPC over the channel

    private func handleChannelMessage(_ message: Data) {
        var payload = message
        if let (tag, child) = try? LyraExpressTLVParser.parseOneOf(message), tag == 1,
           let payloadNode = LyraExpressTLVParser.firstChild(0, in: LyraExpressTLVParser.children(of: child))
        {
            payload = payloadNode.payload
        }
        guard let text = String(data: payload, encoding: .utf8),
              let request = JsonRpcRequest(text)
        else {
            DiagnosticsLog.info(
                "xiaomi.distrpc.channel_rx bytes=\(message.count) " +
                    "head=\(message.prefix(96).map { String(format: "%02x", $0) }.joined())"
            )
            return
        }
        DiagnosticsLog.info("xiaomi.distrpc.rpc_rx method=\(request.method) id=\(request.id ?? -1) \(text.prefix(200))")
        handleRpc(request)
    }

    private func handleRpc(_ request: JsonRpcRequest) {
        switch request.method {
        case "openSpeaker":
            // params.params carries the phone's MiCastServer endpoint + key.
            let ip = request.nestedString("params", "ip")
            let port = request.nestedInt("params", "port")
            let key = request.nestedString("params", "encryptKey")
            DiagnosticsLog.info(
                "xiaomi.distrpc.open_speaker ip=\(ip ?? "?") port=\(port ?? 0) keyB64=\(key?.count ?? 0)"
            )
            if let ip, let port, port > 0, let key {
                startDownlinkClient(host: ip, port: UInt16(port), keyBase64: key)
            }
            respond(result: "true", to: request)
        case "openMicrophone":
            startUplinkServer()
            let port = wfdServer?.port ?? 0
            let ip = Self.primaryIPv4Address() ?? "0.0.0.0"
            let result =
                "{\"bitDepth\":16,\"channels\":1,\"dynamicChange\":false," +
                "\"encryptKey\":\"\(Self.uplinkKey.base64EncodedString())\",\"ip\":\"\(ip)\",\"port\":\(port),\"sampleRate\":16000}"
            DiagnosticsLog.info("xiaomi.distrpc.open_mic_reply ip=\(ip) port=\(port)")
            respond(result: result, to: request)
        case "startMicrophoneStream", "startSpeakerStream",
             "stopMicrophoneStream", "stopSpeakerStream",
             "closeMicrophone", "closeSpeaker":
            DiagnosticsLog.info("xiaomi.distrpc.stream_ctl \(request.method)")
            respond(result: "true", to: request)
        default:
            DiagnosticsLog.info("xiaomi.distrpc.rpc_unhandled \(request.method)")
            respond(result: "true", to: request)
        }
    }

    private func respond(result: String, to request: JsonRpcRequest) {
        guard let id = request.id else { return }
        let text = "{\"jsonrpc\":\"2.0\",\"id\":\(id),\"result\":\(result)}"
        guard let socket = channelSocket, !transKey.isEmpty else {
            DiagnosticsLog.warn("xiaomi.distrpc.tx_no_channel")
            return
        }
        do {
            try socket.sendVariant(
                channelFrame: LyraChannelSocket.wrapChannelFrame(Data(text.utf8)),
                key: transKey,
                singleLayer: true
            )
            DiagnosticsLog.info("xiaomi.distrpc.rpc_tx \(text.prefix(160))")
        } catch {
            DiagnosticsLog.error("xiaomi.distrpc.channel_tx_failed", error)
        }
    }

    private struct JsonRpcRequest {
        let method: String
        let id: Int?
        let raw: String

        init?(_ text: String) {
            guard text.contains("\"jsonrpc\""),
                  let methodRange = text.range(of: "\"method\":\"")
            else { return nil }
            raw = text
            let methodTail = text[methodRange.upperBound...]
            guard let methodEnd = methodTail.firstIndex(of: "\"") else { return nil }
            let full = String(methodTail[..<methodEnd])
            guard let dot = full.lastIndex(of: ".") else { return nil }
            method = String(full[full.index(after: dot)...])
            if let idRange = text.range(of: "\"id\":") {
                let idTail = text[idRange.upperBound...]
                let digits = idTail.prefix(while: { $0.isNumber || $0 == "-" })
                id = Int(digits)
            } else {
                id = nil
            }
        }

        func nestedString(_ object: String, _ key: String) -> String? {
            guard let objectRange = raw.range(of: "\"\(object)\":{") else { return nil }
            let tail = raw[objectRange.upperBound...]
            guard let keyRange = tail.range(of: "\"\(key)\":\"") else { return nil }
            let valueTail = tail[keyRange.upperBound...]
            guard let end = valueTail.firstIndex(of: "\"") else { return nil }
            return String(valueTail[..<end])
        }

        func nestedInt(_ object: String, _ key: String) -> Int? {
            guard let objectRange = raw.range(of: "\"\(object)\":{") else { return nil }
            let tail = raw[objectRange.upperBound...]
            guard let keyRange = tail.range(of: "\"\(key)\":") else { return nil }
            let valueTail = tail[keyRange.upperBound...]
            let digits = valueTail.prefix(while: { $0.isNumber || $0 == "-" })
            return Int(digits)
        }
    }

    // MARK: - Audio transport (MiPlayCast/WFD RTSP + AES-ECB PCM)

    // Random per-process 128-bit key for our uplink; the phone decrypts with
    // the base64 we return from openMicrophone.
    private static let uplinkKey: Data = {
        var key = Data(count: 16)
        key.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress { arc4random_buf(base, 16) }
        }
        return key
    }()

    private var wfdServer: LyraDistAudioWFDServer?
    private var wfdClient: LyraDistAudioWFDClient?

    private func startUplinkServer() {
        guard wfdServer == nil else { return }
        let server = LyraDistAudioWFDServer(mediaKeyBase64: Self.uplinkKey.base64EncodedString())
        do {
            try server.start()
            wfdServer = server
            DiagnosticsLog.info("xiaomi.distrpc.uplink_listen port=\(server.port ?? 0)")
        } catch {
            DiagnosticsLog.error("xiaomi.distrpc.uplink_listen_failed", error)
        }
    }

    private func startDownlinkClient(host: String, port: UInt16, keyBase64: String) {
        wfdClient?.stop()
        let client = LyraDistAudioWFDClient(host: host, port: port, mediaKeyBase64: keyBase64)
        _ = client.prepareClientMediaPort()
        wfdClient = client
        client.start()
    }

    private func stopAudioTransport() {
        wfdClient?.stop()
        wfdClient = nil
        wfdServer?.stop()
        wfdServer = nil
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
}
