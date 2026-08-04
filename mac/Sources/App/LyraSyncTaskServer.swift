import CryptoKit
import EdgeLinkKit
import Foundation

// Server side of the phone's SyncManager reverse sync task (service 00150323).
// The task dials our mesh port in quick-conn mode: its phys sync request
// carries private_data (trailing field 4) with an embedded LogiConnFrame whose
// sync_info holds a quick-conn AuthHandshake client_notify. Without an answer
// embedded in the phys sync response private_data the phone parks in
// kAuthClient and the task dies with a kcp trans timeout — so DevRepo never
// learns our TrustedDeviceInfo and TeleService finds no relay service.
// Auth server logic mirrors the proven LyraRelayCallSession implementation.
final class LyraSyncTaskServer {
    static let syncServiceName = "00150323"

    private struct ConnState {
        var connId: UInt32
        var peerNetId: UInt32
        var handshakeId: UInt64
        var serverEphPriv: P256.KeyAgreement.PrivateKey
        var clientEphPub: Data
        var sharedZ: Data
        var clientRandom: Data
        var serverRandom: Data
        var sessionKey: SymmetricKey?
        var logiResponseSent = false
    }

    private static let maxConns = 8
    private var conns: [UInt32: ConnState] = [:]
    private var connOrder: [UInt32] = []

    var sessionKeys: [SymmetricKey] {
        connOrder.compactMap { conns[$0]?.sessionKey }
    }

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

    func handles(logiConn: LogiConnFrame) -> Bool {
        conns[logiConn.logiConnId] != nil
    }

    // Classic (non-quick-conn) entry: the phone dials the sync service with a
    // plaintext logi sync_info. Register the conn and answer with the official
    // server sync_info ({10000, 40, uidFeature} — no service/key_index/cred);
    // the phone then runs the 4-step AuthHandshake on the conn (step 1/3 in
    // handleLogiConn), followed by the encrypted REQUEST and payload exchange.
    func handleClassicSyncInfo(syncInfoData: Data, logiConn: LogiConnFrame) -> LogiConnFrame {
        let state = ConnState(
            connId: logiConn.logiConnId,
            peerNetId: logiConn.localNetId,
            handshakeId: 0,
            serverEphPriv: P256.KeyAgreement.PrivateKey(),
            clientEphPub: Data(),
            sharedZ: Data(),
            clientRandom: Data(),
            serverRandom: Data()
        )
        remember(state)
        let ticketStore = MiTrustTicketStore.current()
        var syncInfo = Data()
        LyraProtoWriter.appendVarintField(1, value: 10000, to: &syncInfo)
        LyraProtoWriter.appendVarintField(2, value: 40, to: &syncInfo)
        LyraProtoWriter.appendLengthDelimitedField(5, value: ticketStore.uidFeatureInfo(), to: &syncInfo)
        let inner = LogiConnInnerFrame(frameType: 5, payload: .syncInfo(syncInfo))
        DiagnosticsLog.info(
            "xiaomi.synctask.classic_sync_info connId=\(logiConn.logiConnId) " +
                "peerNetId=\(logiConn.localNetId)"
        )
        return LogiConnFrame(
            logiConnId: logiConn.logiConnId,
            localNetId: 1,
            remoteNetId: logiConn.localNetId,
            inner: inner.serialized()
        )
    }

    // Parses the phys sync request's trailing fields for quick-conn private_data
    // and, when it embeds a sync-service client_notify, returns the private_data
    // to embed in the phys sync response (our sync_info + server_notify) plus
    // the standalone logi frame to offer on the conn as well.
    func responsePrivateData(
        requestTrailingFields: [LyraProtoReader.Field]
    ) -> (privateData: Data, logiFrame: LogiConnFrame)? {
        guard let privateData = requestTrailingFields
            .first(where: { $0.number == 4 && $0.wireType == 2 })?
            .lengthDelimitedValue,
            let pdFields = try? LyraProtoReader.readFields(from: privateData)
        else {
            return nil
        }
        for field in pdFields where field.number == 2 && field.wireType == 2 {
            guard let wrapper = field.lengthDelimitedValue,
                  let logiConnData = Self.lengthDelimited(1, in: wrapper),
                  let logiConn = LogiConnFrame(parsing: logiConnData),
                  let inner = LogiConnInnerFrame(parsing: logiConn.inner),
                  case let .syncInfo(syncInfoData) = inner.payload
            else {
                continue
            }
            let service = Self.lengthDelimited(4, in: syncInfoData)
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            guard service == Self.syncServiceName else {
                if !service.isEmpty {
                    DiagnosticsLog.info("xiaomi.synctask.embedded_service_ignored service=\(service)")
                }
                continue
            }
            guard let quickConn = Self.lengthDelimited(8, in: syncInfoData),
                  let qcInner = LogiConnInnerFrame(parsing: quickConn),
                  case let .upgrade(upgradeData) = qcInner.payload,
                  let handshakeId = Self.varint(1, in: upgradeData),
                  let handshake = Self.lengthDelimited(2, in: upgradeData),
                  let authFrame = Self.lengthDelimited(7, in: handshake),
                  Self.varint(1, in: authFrame) == 1
            else {
                let quickConnHex = Self.lengthDelimited(8, in: syncInfoData)?
                    .map { String(format: "%02x", $0) }.joined() ?? ""
                DiagnosticsLog.info(
                    "xiaomi.synctask.quickconn_parse_failed connId=\(logiConn.logiConnId) " +
                        "quickConnBytes=\(Self.lengthDelimited(8, in: syncInfoData)?.count ?? 0) " +
                        "syncInfoHex=\(syncInfoData.map { String(format: "%02x", $0) }.joined()) " +
                        "quickConnHex=\(quickConnHex)"
                )
                continue
            }
            guard let built = makeServerNotify(
                authFrame: authFrame,
                handshakeId: handshakeId,
                connId: logiConn.logiConnId,
                peerNetId: logiConn.localNetId
            ) else {
                continue
            }
            remember(built.state)
            let responseData = buildResponsePrivateData(
                connId: logiConn.logiConnId,
                peerNetId: logiConn.localNetId,
                handshakeId: handshakeId,
                serverNotifyAuthFrame: built.authFrame
            )
            // Standalone logi-frame sync_info for the phone's fallback path:
            // when its auth-reuse check rejects the embedded quick-conn copy
            // ("service check error") it continues with a normal logi-conn
            // handshake against the official-shape (f8-less) sync_info.
            let logiFrame = buildResponseLogiFrame(
                connId: logiConn.logiConnId,
                peerNetId: logiConn.localNetId,
                handshakeId: handshakeId,
                serverNotifyAuthFrame: built.authFrame,
                withQuickConn: false
            )
            DiagnosticsLog.info(
                "xiaomi.synctask.quickconn_server_notify connId=\(logiConn.logiConnId) " +
                    "handshakeId=\(handshakeId) privateDataBytes=\(responseData.count)"
            )
            return (responseData, logiFrame)
        }
        return nil
    }

    // Handles frames on the quick-conn logi conn after the phys exchange:
    // plaintext client_finished (answer server_finished) and the encrypted
    // logi REQUEST (answer a minimal logi RESPONSE). Returns frames to send.
    func handleLogiConn(_ logiConn: LogiConnFrame) -> [LogiConnFrame] {
        guard let conn = conns[logiConn.logiConnId] else { return [] }
        if logiConn.flag {
            return handleEncrypted(logiConn, conn: conn)
        }
        guard let inner = LogiConnInnerFrame(parsing: logiConn.inner),
              case let .upgrade(upgradeData) = inner.payload,
              let handshakeId = Self.varint(1, in: upgradeData),
              let handshake = Self.lengthDelimited(2, in: upgradeData),
              let authFrame = Self.lengthDelimited(7, in: handshake),
              let step = Self.varint(1, in: authFrame)
        else {
            DiagnosticsLog.info(
                "xiaomi.synctask.conn_frame_ignored connId=\(logiConn.logiConnId) " +
                    "bytes=\(logiConn.inner.count)"
            )
            return []
        }
        switch step {
        case 1:
            // The phone's auth-reuse fallback sends a fresh client_notify on
            // the logi conn; run the full auth server round for it.
            guard let built = makeServerNotify(
                authFrame: authFrame,
                handshakeId: handshakeId,
                connId: logiConn.logiConnId,
                peerNetId: conn.peerNetId
            ) else {
                return []
            }
            remember(built.state)
            var freshState = built.state
            freshState.logiResponseSent = conn.logiResponseSent
            conns[logiConn.logiConnId] = freshState
            let frame = authHandshakeFrame(
                authFrame: built.authFrame, handshakeId: handshakeId, conn: freshState
            )
            DiagnosticsLog.info(
                "xiaomi.synctask.logi_server_notify connId=\(logiConn.logiConnId) " +
                    "handshakeId=\(handshakeId)"
            )
            return [frame]
        case 3:
            return handleAuthClientFinished(authFrame: authFrame, handshakeId: handshakeId, conn: conn)
        default:
            DiagnosticsLog.info(
                "xiaomi.synctask.conn_frame_ignored connId=\(logiConn.logiConnId) step=\(step)"
            )
            return []
        }
    }

    // MARK: - AuthHandshake server (mirrors LyraRelayCallSession)

    private func makeServerNotify(
        authFrame: Data,
        handshakeId: UInt64,
        connId: UInt32,
        peerNetId: UInt32
    ) -> (authFrame: Data, state: ConnState)? {
        guard let clientNotify = Self.lengthDelimited(2, in: authFrame),
              let cipherSuite = Self.lengthDelimited(1, in: clientNotify),
              let clientRandom = Self.lengthDelimited(2, in: cipherSuite),
              clientRandom.count == 32,
              let publicKeyMessage = Self.lengthDelimited(5, in: cipherSuite),
              let clientPub = Self.lengthDelimited(2, in: publicKeyMessage),
              clientPub.count == 65, clientPub.first == 0x04
        else {
            DiagnosticsLog.warn("xiaomi.synctask.auth_notify_parse_failed")
            return nil
        }
        let ticketStore = MiTrustTicketStore.current()
        guard let identityKey = ticketStore.identityPrivateKey else {
            DiagnosticsLog.warn("xiaomi.synctask.auth_no_identity")
            return nil
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
            DiagnosticsLog.error("xiaomi.synctask.auth_ecdh_failed", error)
            return nil
        }
        guard let signature = try? identityKey.signature(for: SHA256.hash(data: serverPub + clientPub)) else {
            DiagnosticsLog.warn("xiaomi.synctask.auth_sign_failed")
            return nil
        }
        let nonce = AES.GCM.Nonce()
        guard let sealed = try? AES.GCM.seal(
            signature.derRepresentation, using: SymmetricKey(data: secret), nonce: nonce
        ) else {
            DiagnosticsLog.warn("xiaomi.synctask.auth_enc_failed")
            return nil
        }
        var encSig = Data()
        encSig.append(contentsOf: nonce.withUnsafeBytes { Data($0) })
        encSig.append(sealed.ciphertext)
        encSig.append(sealed.tag)

        var outPublicKeyMessage = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &outPublicKeyMessage)
        LyraProtoWriter.appendLengthDelimitedField(2, value: serverPub, to: &outPublicKeyMessage)
        let offeredP3 = Self.varint(3, in: cipherSuite) ?? 0x40
        let offeredP4 = Self.varint(4, in: cipherSuite) ?? 2
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

        let state = ConnState(
            connId: connId,
            peerNetId: peerNetId,
            handshakeId: handshakeId,
            serverEphPriv: privateKey,
            clientEphPub: clientPub,
            sharedZ: secret,
            clientRandom: clientRandom,
            serverRandom: serverRandom
        )
        return (outAuthFrame, state)
    }

    private func handleAuthClientFinished(
        authFrame: Data,
        handshakeId: UInt64,
        conn: ConnState
    ) -> [LogiConnFrame] {
        guard let clientFinished = Self.lengthDelimited(4, in: authFrame),
              let encSigC = Self.lengthDelimited(1, in: clientFinished),
              !encSigC.isEmpty
        else {
            DiagnosticsLog.warn("xiaomi.synctask.auth_finished_parse_failed connId=\(conn.connId)")
            return []
        }
        let serverEphPub = conn.serverEphPriv.publicKey.x963Representation
        let ticketStore = MiTrustTicketStore.current()
        let zKey = SymmetricKey(data: conn.sharedZ)
        guard let sigC = ticketStore.decrypt(encSigC, with: zKey) else {
            DiagnosticsLog.warn("xiaomi.synctask.auth_sig_decrypt_failed connId=\(conn.connId)")
            return []
        }
        do {
            let peerIdentity = try P256.Signing.PublicKey(x963Representation: ticketStore.peerIdentityPubKey)
            let signature = try P256.Signing.ECDSASignature(derRepresentation: sigC)
            guard peerIdentity.isValidSignature(
                signature, for: SHA256.hash(data: conn.clientEphPub + serverEphPub)
            ) else {
                DiagnosticsLog.warn("xiaomi.synctask.auth_sig_invalid connId=\(conn.connId)")
                return []
            }
        } catch {
            DiagnosticsLog.error("xiaomi.synctask.auth_sig_verify_failed", error)
            return []
        }
        let newSessionKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: zKey,
            salt: Self.sessionSalt,
            info: conn.clientRandom + conn.serverRandom,
            outputByteCount: 32
        )
        let ticket = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: zKey,
            salt: Self.ticketSalt,
            info: conn.clientRandom + conn.serverRandom,
            outputByteCount: 32
        )
        MiTrustTicketStore.recordAuthSession(
            sessionKey: newSessionKey.withUnsafeBytes { Data($0) },
            ticket: ticket.withUnsafeBytes { Data($0) }
        )
        var updated = conn
        updated.sessionKey = newSessionKey
        conns[conn.connId] = updated

        var serverFinished = Data()
        do {
            let nonce = AES.GCM.Nonce()
            let sealed = try AES.GCM.seal(conn.sharedZ + serverEphPub, using: newSessionKey, nonce: nonce)
            var blob = Data()
            blob.append(contentsOf: nonce.withUnsafeBytes { Data($0) })
            blob.append(sealed.ciphertext)
            blob.append(sealed.tag)
            LyraProtoWriter.appendLengthDelimitedField(1, value: blob, to: &serverFinished)
        } catch {
            DiagnosticsLog.error("xiaomi.synctask.auth_finish_enc_failed", error)
            return []
        }
        var outAuthFrame = Data()
        LyraProtoWriter.appendVarintField(1, value: 4, to: &outAuthFrame)
        LyraProtoWriter.appendLengthDelimitedField(5, value: serverFinished, to: &outAuthFrame)
        let frame = authHandshakeFrame(
            authFrame: outAuthFrame, handshakeId: handshakeId, conn: updated
        )
        DiagnosticsLog.info("xiaomi.synctask.auth_completed connId=\(conn.connId)")
        return [frame]
    }

    // MARK: - Encrypted logi conn (post-handshake REQUEST/RESPONSE)

    private func handleEncrypted(_ logiConn: LogiConnFrame, conn: ConnState) -> [LogiConnFrame] {
        guard let sessionKey = conn.sessionKey else {
            DiagnosticsLog.warn("xiaomi.synctask.enc_nokey connId=\(logiConn.logiConnId)")
            return []
        }
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
            DiagnosticsLog.warn(
                "xiaomi.synctask.enc_decrypt_failed connId=\(logiConn.logiConnId) bytes=\(logiConn.inner.count)"
            )
            return []
        }
        guard case let .request(requestData) = decoded.payload else {
            DiagnosticsLog.info(
                "xiaomi.synctask.enc_frame connId=\(conn.connId) frameType=\(decoded.frameType)"
            )
            return []
        }
        let service = Self.lengthDelimited(2, in: requestData)
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        DiagnosticsLog.info(
            "xiaomi.synctask.logi_request connId=\(conn.connId) service=\(service) " +
                "requestBytes=\(requestData.count)"
        )
        guard !conn.logiResponseSent else { return [] }
        var updated = conn
        updated.logiResponseSent = true
        conns[conn.connId] = updated

        // Minimal official-shape LogiConnResponseFrame for the sync service
        // (the phone's own sync RESPONSE carries just f1=0 status and f3=1).
        var responseFrame = Data()
        LyraProtoWriter.appendVarintField(1, value: 0, to: &responseFrame)
        LyraProtoWriter.appendVarintField(3, value: 1, to: &responseFrame)
        let responseInner = LogiConnInnerFrame(frameType: 2, payload: .response(responseFrame))
        do {
            let nonce = AES.GCM.Nonce()
            let sealed = try AES.GCM.seal(responseInner.serialized(), using: sessionKey, nonce: nonce)
            var encryptedInner = Data()
            encryptedInner.append(contentsOf: nonce.withUnsafeBytes { Data($0) })
            encryptedInner.append(sealed.ciphertext)
            encryptedInner.append(sealed.tag)
            let frame = LogiConnFrame(
                logiConnId: conn.connId,
                localNetId: 1,
                remoteNetId: conn.peerNetId,
                flag: true,
                inner: encryptedInner
            )
            DiagnosticsLog.info("xiaomi.synctask.logi_response_tx connId=\(conn.connId)")
            return [frame]
        } catch {
            DiagnosticsLog.error("xiaomi.synctask.logi_response_enc_failed", error)
            return []
        }
    }

    // MARK: - Builders

    private func buildResponsePrivateData(
        connId: UInt32,
        peerNetId: UInt32,
        handshakeId: UInt64,
        serverNotifyAuthFrame: Data
    ) -> Data {
        let logiConn = buildResponseLogiFrame(
            connId: connId,
            peerNetId: peerNetId,
            handshakeId: handshakeId,
            serverNotifyAuthFrame: serverNotifyAuthFrame,
            withQuickConn: true
        )
        var wrapper = Data()
        LyraProtoWriter.appendLengthDelimitedField(1, value: logiConn.serialized(), to: &wrapper)
        var privateData = Data()
        LyraProtoWriter.appendLengthDelimitedField(2, value: wrapper, to: &privateData)
        return privateData
    }

    private func buildResponseLogiFrame(
        connId: UInt32,
        peerNetId: UInt32,
        handshakeId: UInt64,
        serverNotifyAuthFrame: Data,
        withQuickConn: Bool
    ) -> LogiConnFrame {
        var handshake = Data()
        LyraProtoWriter.appendVarintField(1, value: 4, to: &handshake)
        LyraProtoWriter.appendVarintField(2, value: 5, to: &handshake)
        LyraProtoWriter.appendLengthDelimitedField(7, value: serverNotifyAuthFrame, to: &handshake)
        var upgrade = Data()
        LyraProtoWriter.appendVarintField(1, value: handshakeId, to: &upgrade)
        LyraProtoWriter.appendLengthDelimitedField(2, value: handshake, to: &upgrade)
        let quickConn = LogiConnInnerFrame(frameType: 6, payload: .upgrade(upgrade))

        let ticketStore = MiTrustTicketStore.current()
        var syncInfo = Data()
        LyraProtoWriter.appendVarintField(1, value: 10000, to: &syncInfo)
        LyraProtoWriter.appendVarintField(2, value: 40, to: &syncInfo)
        LyraProtoWriter.appendVarintField(3, value: ticketStore.myKeyIndex, to: &syncInfo)
        LyraProtoWriter.appendLengthDelimitedField(
            4, value: Data(Self.syncServiceName.utf8), to: &syncInfo
        )
        LyraProtoWriter.appendLengthDelimitedField(5, value: ticketStore.uidFeatureInfo(), to: &syncInfo)
        // key_index + encrypted_cred let the phone's DeviceKeyManager resolve
        // our device key for the full-handshake fallback ("client not have
        // device key" otherwise), same as the relayCall server sync_info.
        if let ourEncCred = ticketStore.encryptLocalCred() {
            LyraProtoWriter.appendLengthDelimitedField(6, value: ourEncCred, to: &syncInfo)
        }
        if withQuickConn {
            LyraProtoWriter.appendLengthDelimitedField(8, value: quickConn.serialized(), to: &syncInfo)
        }

        let inner = LogiConnInnerFrame(frameType: 5, payload: .syncInfo(syncInfo))
        return LogiConnFrame(
            logiConnId: connId, localNetId: 1, remoteNetId: peerNetId, inner: inner.serialized()
        )
    }

    private func authHandshakeFrame(
        authFrame: Data,
        handshakeId: UInt64,
        conn: ConnState
    ) -> LogiConnFrame {
        var handshake = Data()
        LyraProtoWriter.appendVarintField(1, value: 4, to: &handshake)
        LyraProtoWriter.appendVarintField(2, value: 5, to: &handshake)
        LyraProtoWriter.appendLengthDelimitedField(7, value: authFrame, to: &handshake)
        var upgrade = Data()
        LyraProtoWriter.appendVarintField(1, value: handshakeId, to: &upgrade)
        LyraProtoWriter.appendLengthDelimitedField(2, value: handshake, to: &upgrade)
        let inner = LogiConnInnerFrame(frameType: 6, payload: .upgrade(upgrade))
        return LogiConnFrame(
            logiConnId: conn.connId,
            localNetId: 1,
            remoteNetId: conn.peerNetId,
            inner: inner.serialized()
        )
    }

    private func remember(_ state: ConnState) {
        if conns[state.connId] == nil {
            connOrder.append(state.connId)
        }
        conns[state.connId] = state
        while connOrder.count > Self.maxConns, let evicted = connOrder.first {
            connOrder.removeFirst()
            conns.removeValue(forKey: evicted)
        }
    }

    // MARK: - Proto helpers

    private static func lengthDelimited(_ fieldNumber: Int, in data: Data) -> Data? {
        guard let fields = try? LyraProtoReader.readFields(from: data) else { return nil }
        return fields.first { $0.number == fieldNumber && $0.wireType == 2 }?.lengthDelimitedValue
    }

    private static func varint(_ fieldNumber: Int, in data: Data) -> UInt64? {
        guard let fields = try? LyraProtoReader.readFields(from: data) else { return nil }
        return fields.first { $0.number == fieldNumber && $0.wireType == 0 }?.varintValue
    }
}
