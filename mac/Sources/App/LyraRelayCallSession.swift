import CryptoKit
import EdgeLinkKit
import Foundation
import Network

// Server side of the TeleService relayCall dial (com.ios.phone:relayCall).
// The phone dials our device after discovering the relayCall service in our
// encrypted mesh announce; its sync_info carries an auth-reuse cred plus a
// quick-conn ConnRequestFrame, both AES-GCM'd with the AuthHandshake session
// key from the announce conn.
final class LyraRelayCallSession {
    static let serviceName = "com.ios.phone:relayCall"
    static let servicePackage = "com.ios.phone"

    private(set) static var activeRelaySession: LyraRelayCallSession?

    static func adopt(
        syncInfoData: Data,
        logiConn: LogiConnFrame,
        endpoint: NWEndpoint,
        sessionKey: SymmetricKey?,
        channelTransport: LyraChannelDatagramPipe? = nil,
        send: @escaping (LyraMeshPack.Frame, String) -> Void
    ) -> LyraRelayCallSession {
        if let existing = activeRelaySession, existing.connId != logiConn.logiConnId {
            existing.teardown()
            activeRelaySession = nil
        }
        let session = activeRelaySession
            ?? LyraRelayCallSession(send: send, channelTransport: channelTransport)
        activeRelaySession = session
        session.handleSyncInfo(syncInfoData: syncInfoData, logiConn: logiConn, sessionKey: sessionKey)
        return session
    }

    private let send: (LyraMeshPack.Frame, String) -> Void
    // Relay-transport harness: the channel runs over this pipe (cloud-relay
    // path) instead of a local UDP socket when set.
    private let channelTransport: LyraChannelDatagramPipe?
    private var connId: UInt32 = 0
    private var peerNetId: UInt32 = 0
    private var sessionKey: SymmetricKey?
    private var responseSent = false
    private var peerPortAwaitingAck = false
    private var peerPortResponseSent = false
    private var channelSocket: LyraChannelDatagramPipe?
    private var transKey = Data()
    private var peerChannelId: UInt64 = 0
    private var methodCounter: UInt64 = 0

    init(send: @escaping (LyraMeshPack.Frame, String) -> Void, channelTransport: LyraChannelDatagramPipe? = nil) {
        self.send = send
        self.channelTransport = channelTransport
    }

    func handles(logiConn: LogiConnFrame) -> Bool {
        connId != 0 && logiConn.logiConnId == connId
    }

    func teardown() {
        channelSocket?.stop()
        channelSocket = nil
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
        let peerKeyIndex = varint(3, in: syncInfoData) ?? 0
        let peerEncryptedCred = lengthDelimited(6, in: syncInfoData) ?? Data()
        let quickConn = lengthDelimited(8, in: syncInfoData) ?? Data()
        DiagnosticsLog.info(
            "xiaomi.relaycall.peer_sync_info connId=\(connId) keyIndex=\(peerKeyIndex) " +
                "encCredBytes=\(peerEncryptedCred.count) quickConnBytes=\(quickConn.count)"
        )
        if !peerEncryptedCred.isEmpty {
            if let sessionKey, let plaintext = ticketStore.decrypt(peerEncryptedCred, with: sessionKey) {
                DiagnosticsLog.info("xiaomi.relaycall.peer_cred_decrypted bytes=\(plaintext.count)")
            } else {
                DiagnosticsLog.warn("xiaomi.relaycall.peer_cred_decrypt_failed")
            }
        }

        let syncInfo = Self.serverSyncInfo(ticketStore: ticketStore, sessionKey: sessionKey)
        let inner = LogiConnInnerFrame(frameType: 5, payload: .syncInfo(syncInfo))
        let frame = LogiConnFrame(
            logiConnId: connId, localNetId: 1, remoteNetId: peerNetId, inner: inner.serialized()
        )
        let miFrame = MiConnectFrame(version: 0, logiConnFrames: [frame])
        send(LyraMeshPack.Frame(packType: 2, payload: miFrame.serialized()), "relaycall_sync_info")

        if !quickConn.isEmpty {
            handleQuickConn(quickConn, ticketStore: ticketStore)
        }
    }

    // Server-side sync_info for the relayCall dial ({10000, 16, key_index,
    // uidFeature, encrypted_cred}) — shared by the conn-level reply and the
    // phys sync response private_data (quick-conn dials).
    static func serverSyncInfo(ticketStore: MiTrustTicketStore, sessionKey: SymmetricKey?) -> Data {
        var syncInfo = Data()
        LyraProtoWriter.appendVarintField(1, value: 10000, to: &syncInfo)
        LyraProtoWriter.appendVarintField(2, value: 16, to: &syncInfo)
        LyraProtoWriter.appendVarintField(3, value: ticketStore.myKeyIndex, to: &syncInfo)
        LyraProtoWriter.appendLengthDelimitedField(5, value: ticketStore.uidFeatureInfo(), to: &syncInfo)
        let credKey = sessionKey ?? ticketStore.sessionKey ?? ticketStore.ticketKey
        if let credKey, let identityPrivateKey = ticketStore.identityPrivateKey {
            var nonce32 = Data(count: 32)
            nonce32.withUnsafeMutableBytes { buffer in
                if let base = buffer.baseAddress { arc4random_buf(base, 32) }
            }
            if let signature = try? identityPrivateKey.signature(for: SHA256.hash(data: nonce32)),
               let blob = sealCred(nonce: nonce32, derSignature: signature.derRepresentation, key: credKey)
            {
                LyraProtoWriter.appendLengthDelimitedField(6, value: blob, to: &syncInfo)
            }
        }
        return syncInfo
    }

    private static func sealCred(nonce: Data, derSignature: Data, key: SymmetricKey) -> Data? {
        var pubKeyCred = Data()
        LyraProtoWriter.appendLengthDelimitedField(1, value: nonce, to: &pubKeyCred)
        LyraProtoWriter.appendLengthDelimitedField(2, value: derSignature, to: &pubKeyCred)
        var credFeature = Data()
        LyraProtoWriter.appendVarintField(1, value: 2, to: &credFeature)
        LyraProtoWriter.appendLengthDelimitedField(3, value: pubKeyCred, to: &credFeature)
        var frame = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &frame)
        LyraProtoWriter.appendLengthDelimitedField(3, value: credFeature, to: &frame)
        let gcmNonce = AES.GCM.Nonce()
        guard let sealed = try? AES.GCM.seal(frame, using: key, nonce: gcmNonce) else { return nil }
        var blob = Data()
        blob.append(contentsOf: gcmNonce.withUnsafeBytes { Data($0) })
        blob.append(sealed.ciphertext)
        blob.append(sealed.tag)
        return blob
    }

    private func encryptLocalCred(ticketStore: MiTrustTicketStore) -> Data? {
        guard let identityPrivateKey = ticketStore.identityPrivateKey else { return nil }
        let key = sessionKey ?? ticketStore.sessionKey ?? ticketStore.ticketKey
        guard let key else { return nil }
        var nonce32 = Data(count: 32)
        nonce32.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress { arc4random_buf(base, 32) }
        }
        guard let signature = try? identityPrivateKey.signature(for: SHA256.hash(data: nonce32)) else {
            return nil
        }
        var pubKeyCred = Data()
        LyraProtoWriter.appendLengthDelimitedField(1, value: nonce32, to: &pubKeyCred)
        LyraProtoWriter.appendLengthDelimitedField(2, value: signature.derRepresentation, to: &pubKeyCred)
        var credFeature = Data()
        LyraProtoWriter.appendVarintField(1, value: 2, to: &credFeature)
        LyraProtoWriter.appendLengthDelimitedField(3, value: pubKeyCred, to: &credFeature)
        var frame = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &frame)
        LyraProtoWriter.appendLengthDelimitedField(3, value: credFeature, to: &frame)
        do {
            let nonce = AES.GCM.Nonce()
            let sealed = try AES.GCM.seal(frame, using: key, nonce: nonce)
            var blob = Data()
            blob.append(contentsOf: nonce.withUnsafeBytes { Data($0) })
            blob.append(sealed.ciphertext)
            blob.append(sealed.tag)
            return blob
        } catch {
            DiagnosticsLog.error("xiaomi.relaycall.cred_encrypt_failed", error)
            return nil
        }
    }

    private func handleQuickConn(_ quickConn: Data, ticketStore: MiTrustTicketStore) {
        guard let sessionKey, let plaintext = ticketStore.decrypt(quickConn, with: sessionKey) else {
            DiagnosticsLog.warn("xiaomi.relaycall.quickconn_decrypt_failed")
            return
        }
        let request = lengthDelimited(2, in: plaintext) ?? Data()
        let userInfo = lengthDelimited(3, in: request) ?? Data()
        let peerPortRequest = lengthDelimited(10, in: userInfo)
        DiagnosticsLog.info(
            "xiaomi.relaycall.quickconn_decrypted userInfoBytes=\(userInfo.count) " +
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
        let serverInfo = LyraMitrustResponse.serverUserInfo(
            package: Self.servicePackage,
            nodeIdColonHex: Self.serverFingerprint,
            medium: 136
        )
        let responseFrame = LyraMitrustResponse.logiConnResponse(userInfo: serverInfo)
        let inner = LogiConnInnerFrame(frameType: 2, payload: .response(responseFrame))
        sendEncrypted(inner: inner, label: "relaycall_logi_response")
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
            DiagnosticsLog.error("xiaomi.relaycall.encrypt_failed label=\(label)", error)
        }
    }

    func handleFrame(_ logiConn: LogiConnFrame) {
        if logiConn.flag {
            handleEncryptedFrame(logiConn)
            return
        }
        guard let inner = LogiConnInnerFrame(parsing: logiConn.inner) else {
            DiagnosticsLog.warn("xiaomi.relaycall.plain_parse_failed bytes=\(logiConn.inner.count)")
            return
        }
        switch inner.payload {
        case let .upgrade(upgradeData):
            handleAuthUpgrade(upgradeData)
        case let .disconnect(data):
            let code = varint(1, in: data) ?? 0
            DiagnosticsLog.warn("xiaomi.relaycall.disconnect code=\(code)")
            teardown()
            if Self.activeRelaySession === self {
                Self.activeRelaySession = nil
            }
        case let .request(requestData):
            handleLogiRequest(requestData)
        default:
            DiagnosticsLog.info(
                "xiaomi.relaycall.plain_frame frameType=\(inner.frameType) bytes=\(logiConn.inner.count)"
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
            DiagnosticsLog.warn("xiaomi.relaycall.decrypt_failed bytes=\(logiConn.inner.count)")
            return
        }
        if decoded.frameType == 3 {
            DiagnosticsLog.info("xiaomi.relaycall.response_ack_rx")
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
            DiagnosticsLog.info("xiaomi.relaycall.command type=\(header.type) frameType=\(decoded.frameType)")
            if header.type == LyraChannelProtocol.CommandType.requestOfPeerPort.rawValue {
                prepareChannel(peerPortRequest: commandBody)
                sendPeerPortResponseIfReady()
            }
            return
        }
        DiagnosticsLog.info(
            "xiaomi.relaycall.frame frameType=\(decoded.frameType) bytes=\(payloadData.count) " +
                "head=\(payloadData.prefix(32).map { String(format: "%02x", $0) }.joined())"
        )
    }

    private func handleLogiRequest(_ requestData: Data) {
        let userInfo = lengthDelimited(3, in: requestData) ?? Data()
        let peerPortRequest = lengthDelimited(10, in: userInfo)
        DiagnosticsLog.info(
            "xiaomi.relaycall.logi_request_rx userInfoBytes=\(userInfo.count) hasPeerPort=\(peerPortRequest != nil)"
        )
        // REQUESTs may be KCP retransmits of one whose answer was lost
        // or keyed pre-auth — always re-answer with the current session key.
        sendLogiResponse(force: true)
        if let peerPortRequest {
            peerPortAwaitingAck = true
            prepareChannel(peerPortRequest: peerPortRequest)
        }
    }

    // MARK: - AuthHandshake server (fallback when auth reuse fails)

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
    // Account-pair family salt pair (libmicontinuity.so AccountPairHandshake,
    // same as LyraSyncTaskServer / LyraMeshAnnouncer).
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
            DiagnosticsLog.warn(
                "xiaomi.relaycall.auth_parse_failed hex=\(upgradeData.prefix(48).map { String(format: "%02x", $0) }.joined())"
            )
            return
        }
        let accountFrame = lengthDelimited(6, in: handshake)
        let authFrame = lengthDelimited(7, in: handshake) ?? accountFrame
        handshakeIsAccountPair[handshakeId] = accountFrame != nil && lengthDelimited(7, in: handshake) == nil
        guard let authFrame, let step = varint(1, in: authFrame)
        else {
            DiagnosticsLog.warn(
                "xiaomi.relaycall.auth_parse_failed hex=\(upgradeData.prefix(48).map { String(format: "%02x", $0) }.joined())"
            )
            return
        }
        switch step {
        case 1:
            handleAuthClientNotify(authFrame: authFrame, handshakeId: handshakeId)
        case 3:
            handleAuthClientFinished(authFrame: authFrame, handshakeId: handshakeId)
        default:
            DiagnosticsLog.info("xiaomi.relaycall.auth_other step=\(step)")
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
            DiagnosticsLog.warn("xiaomi.relaycall.auth_notify_parse_failed")
            return
        }
        let ticketStore = MiTrustTicketStore.current()
        guard let identityKey = ticketStore.identityPrivateKey else {
            DiagnosticsLog.warn("xiaomi.relaycall.auth_no_identity")
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
            DiagnosticsLog.error("xiaomi.relaycall.auth_ecdh_failed", error)
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
        guard let signature = try? identityKey.signature(for: SHA256.hash(data: serverPub + clientPub)) else {
            DiagnosticsLog.warn("xiaomi.relaycall.auth_sign_failed")
            return
        }
        let nonce = AES.GCM.Nonce()
        guard let sealed = try? AES.GCM.seal(signature.derRepresentation, using: SymmetricKey(data: secret), nonce: nonce) else {
            DiagnosticsLog.warn("xiaomi.relaycall.auth_enc_failed")
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
        sendAuthHandshake(authFrame: outAuthFrame, handshakeId: handshakeId, label: "relaycall_auth_server_notify")
    }

    // Account-pair server_notify (mirrors LyraSyncTaskServer): encSig opens
    // under Z to {our enrolled cert, sig by cert key over serverEph‖clientEph}.
    private func sendAccountPairServerNotify(
        cipherSuite: Data, secret: Data, serverPub: Data, clientPub: Data,
        serverRandom: Data, handshakeId: UInt64
    ) {
        guard let (certDER, certPriv) = Self.enrolledCertMaterial(),
              let signature = try? certPriv.signature(for: SHA256.hash(data: serverPub + clientPub))
        else {
            DiagnosticsLog.warn("xiaomi.relaycall.acctpair_no_cert")
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
            sendAuthHandshake(authFrame: outAuthFrame, handshakeId: handshakeId, label: "relaycall_acctpair_server_notify")
        } catch {
            DiagnosticsLog.error("xiaomi.relaycall.acctpair_enc_failed", error)
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
              let encSigC = lengthDelimited(1, in: clientFinished),
              !encSigC.isEmpty,
              let serverEphPub = authServerEphPriv?.publicKey.x963Representation,
              !authSharedZ.isEmpty, !authClientEphPub.isEmpty
        else {
            DiagnosticsLog.warn("xiaomi.relaycall.auth_finished_parse_failed")
            return
        }
        let ticketStore = MiTrustTicketStore.current()
        let zKey = SymmetricKey(data: authSharedZ)
        if handshakeIsAccountPair[handshakeId] == true {
            handleAccountPairClientFinished(
                clientFinished: clientFinished, zKey: zKey, handshakeId: handshakeId
            )
            return
        }
        guard let sigC = ticketStore.decrypt(encSigC, with: zKey) else {
            DiagnosticsLog.warn("xiaomi.relaycall.auth_sig_decrypt_failed")
            return
        }
        let digest = SHA256.hash(data: authClientEphPub + serverEphPub)
        guard let signature = try? P256.Signing.ECDSASignature(derRepresentation: sigC) else {
            DiagnosticsLog.warn("xiaomi.relaycall.auth_sig_parse_failed")
            return
        }
        let verified = ticketStore.peerSigningPubKeys.contains { keyData in
            guard let key = try? P256.Signing.PublicKey(x963Representation: keyData) else { return false }
            return key.isValidSignature(signature, for: digest)
        }
        guard verified else {
            DiagnosticsLog.warn("xiaomi.relaycall.auth_sig_invalid")
            return
        }
        let newSessionKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: zKey,
            salt: Self.sessionSalt,
            info: authClientRandom + authServerRandom,
            outputByteCount: 32
        )
        let ticket = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: zKey,
            salt: Self.ticketSalt,
            info: authClientRandom + authServerRandom,
            outputByteCount: 32
        )
        let sessionKeyData = newSessionKey.withUnsafeBytes { Data($0) }
        MiTrustTicketStore.recordAuthSession(
            sessionKey: sessionKeyData,
            ticket: ticket.withUnsafeBytes { Data($0) }
        )
        sessionKey = newSessionKey

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
            DiagnosticsLog.error("xiaomi.relaycall.auth_finish_enc_failed", error)
            return
        }
        var outAuthFrame = Data()
        LyraProtoWriter.appendVarintField(1, value: 4, to: &outAuthFrame)
        LyraProtoWriter.appendLengthDelimitedField(5, value: serverFinished, to: &outAuthFrame)
        sendAuthHandshake(authFrame: outAuthFrame, handshakeId: handshakeId, label: "relaycall_auth_server_finished")
        DiagnosticsLog.info("xiaomi.relaycall.auth_completed")
    }

    // Account-pair client_finished: {f1:credBlob(AES-GCM(Z, {phone cert,
    // sig over clientEph‖serverEph})), f2:proof(AES-GCM(sessionKey, 24B))}.
    private func handleAccountPairClientFinished(
        clientFinished: Data, zKey: SymmetricKey, handshakeId: UInt64
    ) {
        let ticketStore = MiTrustTicketStore.current()
        guard let credBlob = lengthDelimited(1, in: clientFinished),
              let credMessage = ticketStore.decrypt(credBlob, with: zKey),
              let phoneCert = lengthDelimited(1, in: credMessage),
              let phoneSig = lengthDelimited(2, in: credMessage),
              let cert = SecCertificateCreateWithData(nil, phoneCert as CFData),
              let key = SecCertificateCopyKey(cert),
              let rep = SecKeyCopyExternalRepresentation(key, nil) as? Data,
              let phonePub = try? P256.Signing.PublicKey(x963Representation: rep),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: phoneSig),
              let serverEphPriv = authServerEphPriv
        else {
            DiagnosticsLog.warn("xiaomi.relaycall.acctpair_finished_parse_failed")
            return
        }
        let serverEphPub = serverEphPriv.publicKey.x963Representation
        guard phonePub.isValidSignature(
            signature, for: SHA256.hash(data: authClientEphPub + serverEphPub)
        ) else {
            DiagnosticsLog.warn("xiaomi.relaycall.acctpair_sig_invalid")
            return
        }
        MiTrustTicketStore.harvestPeerAccountPubKey(fromCertDER: phoneCert)
        let newSessionKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: zKey,
            salt: Self.accountPairSessionSalt,
            info: authClientRandom + authServerRandom,
            outputByteCount: 32
        )
        let ticket = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: zKey,
            salt: Self.accountPairTicketSalt,
            info: authClientRandom + authServerRandom,
            outputByteCount: 32
        )
        MiTrustTicketStore.recordAuthSession(
            sessionKey: newSessionKey.withUnsafeBytes { Data($0) },
            ticket: ticket.withUnsafeBytes { Data($0) }
        )
        sessionKey = newSessionKey
        if let proof = lengthDelimited(2, in: clientFinished) {
            let proofOk = ticketStore.decrypt(proof, with: newSessionKey) != nil
            DiagnosticsLog.info("xiaomi.relaycall.acctpair_proof ok=\(proofOk)")
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
            DiagnosticsLog.error("xiaomi.relaycall.acctpair_finish_enc_failed", error)
            return
        }
        var outAuthFrame = Data()
        LyraProtoWriter.appendVarintField(1, value: 4, to: &outAuthFrame)
        LyraProtoWriter.appendLengthDelimitedField(5, value: serverFinished, to: &outAuthFrame)
        sendAuthHandshake(authFrame: outAuthFrame, handshakeId: handshakeId, label: "relaycall_acctpair_server_finished")
        DiagnosticsLog.info("xiaomi.relaycall.acctpair_completed")
    }

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
            DiagnosticsLog.warn("xiaomi.relaycall.peer_port_bad_request")
            return
        }
        guard channelSocket == nil else { return }
        transKey = key
        peerChannelId = channelId
        let socket: LyraChannelDatagramPipe = channelTransport ?? LyraChannelSocket()
        socket.onMessage = { [weak self] message, _ in
            self?.handleChannelMessage(message)
        }
        socket.onPeerConnected = { from in
            DiagnosticsLog.info("xiaomi.relaycall.channel_peer from=\(from.debugDescription)")
        }
        socket.onNegotiated = { serverChannelId, mtu in
            DiagnosticsLog.info("xiaomi.relaycall.channel_negotiated serverChannelId=\(serverChannelId) mtu=\(mtu)")
        }
        do {
            try socket.start(socketKey: key, serverChannelId: 6)
            channelSocket = socket
        } catch {
            DiagnosticsLog.error("xiaomi.relaycall.channel_start_failed", error)
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
            serverChannelId: 6,
            port: port,
            serverKey: serverKey
        )
        let command = LyraChannelProtocol.encode(type: .responseOfPeerPort, body: responseBody)
        var payload = Data()
        payload.append(UInt8(peerNetId & 0xFF))
        payload.append(0)
        payload.append(command)
        send(LyraMeshPack.Frame(packType: 5, payload: payload), "relaycall_peer_port_response")
        DiagnosticsLog.info("xiaomi.relaycall.peer_port_tx port=\(port)")
    }

    private func handleChannelMessage(_ message: Data) {
        var payload = message
        if let (tag, child) = try? LyraExpressTLVParser.parseOneOf(message), tag == 1,
           let payloadNode = LyraExpressTLVParser.firstChild(0, in: LyraExpressTLVParser.children(of: child))
        {
            payload = payloadNode.payload
        }
        guard let text = String(data: payload, encoding: .utf8), text.hasPrefix("relay://") else {
            DiagnosticsLog.info(
                "xiaomi.relaycall.channel_rx bytes=\(message.count) " +
                    "head=\(message.prefix(48).map { String(format: "%02x", $0) }.joined())"
            )
            return
        }
        DiagnosticsLog.info("xiaomi.relaycall.uri_rx \(text)")
        handleRelayURI(text)
    }

    // URI protocol: relay://<method>:<methodId>/request?<paramJson> requests
    // from the phone; answers are relay://<method>:<methodId>/response?<json>
    // with {responseDeviceId, code(200/408/500), msg, address, callstate}.
    private func handleRelayURI(_ text: String) {
        guard let parsed = RelayURI(text) else {
            DiagnosticsLog.warn("xiaomi.relaycall.uri_parse_failed \(text.prefix(120))")
            return
        }
        switch (parsed.method, parsed.kind) {
        case ("ring", "request"):
            let number = parsed.jsonString("address") ?? ""
            let state = parsed.jsonString("callstate") ?? ""
            DiagnosticsLog.info("xiaomi.relaycall.ring number=\(number) state=\(state)")
            respond(
                to: parsed,
                fields: ["code": "200", "msg": "ok", "address": number, "callstate": state]
            )
        case ("call_state_idle", "request"), ("update_call_state", "request"):
            // Native mirror-call uplink: 4 = ACTIVE starts the phone's
            // PHONERELAY sink at our audio source; idle/disconnect stops it.
            // Call end also closes the dialer's channel so the phone's
            // relay-channel release lands while no call is in flight
            // (LyraRelayCallDialer.callEnded).
            if parsed.method == "call_state_idle" {
                LyraMirrorCallRelaySession.activeSession?.setCallActive(false)
                LyraRelayCallDialer.activeDialer?.callEnded()
            } else if let callState = parsed.jsonInt("callState") {
                if callState == 4 {
                    LyraMirrorCallRelaySession.activeSession?.setCallActive(true)
                } else if callState == 0 || callState == 6 || callState == 7 {
                    LyraMirrorCallRelaySession.activeSession?.setCallActive(false)
                    LyraRelayCallDialer.activeDialer?.callEnded()
                }
            }
            respond(to: parsed, fields: ["code": "200", "msg": "ok"])
        case ("update_call_info", "request"):
            // Caller name/number update mid-call; ack so the phone stops
            // retrying into a 10 s 408 (the info itself is only logged —
            // nothing surfaces it yet).
            DiagnosticsLog.info(
                "xiaomi.relaycall.call_info name=\(parsed.jsonString("contactName") ?? "") " +
                    "number=\(parsed.jsonString("address") ?? "")"
            )
            respond(to: parsed, fields: ["code": "200", "msg": "ok"])
        case ("wantRelay", "request"):
            respond(to: parsed, fields: ["code": "200", "msg": "ok"])
        default:
            DiagnosticsLog.info("xiaomi.relaycall.uri_unhandled \(text.prefix(160))")
        }
    }

    private func respond(to request: RelayURI, fields: [String: String]) {
        var jsonFields = ["\"responseDeviceId\":\"\(Self.responseDeviceId)\""]
        for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
            // Official shape: code/callstate are JSON numbers, the rest strings.
            if (key == "code" || key == "callstate"), Int(value) != nil {
                jsonFields.append("\"\(key)\":\(value)")
            } else {
                let escaped = value.replacingOccurrences(of: "\"", with: "\\\"")
                jsonFields.append("\"\(key)\":\"\(escaped)\"")
            }
        }
        let json = "{" + jsonFields.joined(separator: ",") + "}"
        let uri = "relay://\(request.method):\(request.methodId)/response?\(json)"
        sendChannelText(uri)
    }

    private static var responseDeviceId: String {
        UserDefaults.standard.string(forKey: "xiaomiTrustCloneDeviceId") ?? "721572C3"
    }

    private func sendChannelText(_ text: String) {
        guard let socket = channelSocket, !transKey.isEmpty else {
            DiagnosticsLog.warn("xiaomi.relaycall.tx_no_channel")
            return
        }
        // The channel string node carries the raw URI text — a proto field
        // wrapper leaks into the phone's payload ("brelay://…", scheme check
        // fails, every response falls to a 408 timeout phone-side).
        let frame = Data(text.utf8)
        do {
            try socket.sendVariant(
                channelFrame: LyraChannelSocket.wrapChannelFrame(frame),
                key: transKey,
                singleLayer: true
            )
            DiagnosticsLog.info("xiaomi.relaycall.uri_tx \(text)")
        } catch {
            DiagnosticsLog.error("xiaomi.relaycall.channel_tx_failed", error)
        }
    }

    private struct RelayURI {
        let method: String
        let methodId: String
        let kind: String
        let query: String

        init?(_ text: String) {
            guard text.hasPrefix("relay://") else { return nil }
            let rest = String(text.dropFirst("relay://".count))
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            let head = String(rest[..<slash])
            guard let colon = head.lastIndex(of: ":") else { return nil }
            method = String(head[..<colon])
            methodId = String(head[head.index(after: colon)...])
            let tail = String(rest[rest.index(after: slash)...])
            if let question = tail.firstIndex(of: "?") {
                kind = String(tail[..<question])
                query = String(tail[tail.index(after: question)...])
            } else {
                kind = tail
                query = ""
            }
        }

        func jsonString(_ key: String) -> String? {
            guard let range = query.range(of: "\"\(key)\":\"") else { return nil }
            let valueStart = query[range.upperBound...]
            guard let end = valueStart.firstIndex(of: "\"") else { return nil }
            return String(valueStart[..<end])
        }

        func jsonInt(_ key: String) -> Int? {
            guard let range = query.range(of: "\"\(key)\":") else { return nil }
            let valueStart = query[range.upperBound...]
            let digits = valueStart.prefix(while: { $0.isNumber || $0 == "-" })
            return Int(digits)
        }
    }
}
