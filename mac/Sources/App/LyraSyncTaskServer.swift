import CryptoKit
import EdgeLinkKit
import Foundation
import Security

// Server side of the phone's SyncManager reverse sync task (service 00150323).
// The task dials our mesh port in quick-conn mode: its phys sync request
// carries private_data (trailing field 4) with an embedded LogiConnFrame whose
// sync_info holds a quick-conn AuthHandshake client_notify. The official Mac
// (2026-08-05 pcap) leaves the phys sync response private_data-less and sends
// the f8-less server sync_info plus the matching-family server_notify as
// standalone logi frames on the quick conn; embedding an answer in the phys
// response instead makes the phone park in kAuthClient ("auth reuse failed:
// service check error") and the task dies with a logical conn timeout — so
// DevRepo never learns our TrustedDeviceInfo and TeleService finds no relay
// service. Auth server logic mirrors the proven LyraRelayCallSession
// implementation.
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

    // Builds our TrustedDeviceInfo sync payload (type-2 reply frame) for
    // answering the phone's payload push on a dialed conn.
    var syncPayloadProvider: (() -> Data)?

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
    // The account-pair family derives its session/ticket keys with its OWN
    // salt pair (libmicontinuity.so AccountPairHandshake::ParseServerNotifyMessage
    // / ParseClientFinishedMessage, 2026-08-06): HKDF256(Z, salt,
    // clientRandom‖serverRandom). Using the AUTH salts derives a key the phone
    // rejects — its client_finished proof won't open and it disconnects with
    // code 29001 right after server_finished.
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

    func handles(logiConn: LogiConnFrame) -> Bool {
        conns[logiConn.logiConnId] != nil
    }

    // Classic (non-quick-conn) entry: the phone dials the sync service with a
    // plaintext logi sync_info. Register the conn and answer with the official
    // server sync_info ({10000, 40, uidFeature} — no service/key_index/cred);
    // the phone then runs the 4-step AuthHandshake on the conn (step 1/3 in
    // handleLogiConn), followed by the encrypted REQUEST and payload exchange.
    func handleClassicSyncInfo(syncInfoData: Data, logiConn: LogiConnFrame) -> LogiConnFrame {
        var state = ConnState(
            connId: logiConn.logiConnId,
            peerNetId: logiConn.localNetId,
            handshakeId: 0,
            serverEphPriv: P256.KeyAgreement.PrivateKey(),
            clientEphPub: Data(),
            sharedZ: Data(),
            clientRandom: Data(),
            serverRandom: Data()
        )
        // Auth-reuse classic dial: the phone's sync_info carries key_index +
        // encrypted_cred and it will send the REQUEST encrypted with the
        // recorded session key — adopt it so handleEncrypted can proceed
        // without a fresh full handshake.
        let ticketStore = MiTrustTicketStore.current()
        if let encCred = Self.lengthDelimited(6, in: syncInfoData),
           let decrypted = ticketStore.decryptCredBlobWithKey(encCred) {
            state.sessionKey = decrypted.key
            DiagnosticsLog.info(
                "xiaomi.synctask.classic_reuse connId=\(logiConn.logiConnId) " +
                    "keyIndex=\(Self.varint(3, in: syncInfoData) ?? 0) credBytes=\(decrypted.plaintext.count)"
            )
        }
        remember(state)
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

    struct EmbeddedOpening {
        let service: String
        let syncInfo: Data
        let logiConn: LogiConnFrame
    }

    // Extracts the embedded logi opening (sync_info) from a phys sync
    // request's quick-conn private_data, regardless of target service, so the
    // responder can route non-sync-service dials (e.g. relayCall) elsewhere.
    func embeddedLogiOpening(
        requestTrailingFields: [LyraProtoReader.Field]
    ) -> EmbeddedOpening? {
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
            return EmbeddedOpening(service: service, syncInfo: syncInfoData, logiConn: logiConn)
        }
        return nil
    }

    // Parses the phys sync request's trailing fields for quick-conn private_data
    // and, when it embeds a sync-service client_notify, answers the way the
    // official Mac does (2026-08-05 pcap): the phys sync response carries NO
    // private_data, and the f8-less server sync_info plus the server_notify
    // answering the embedded client_notify go out as standalone logi frames on
    // the quick conn. (Embedding even an f8-less sync_info in the phys response
    // makes the phone hard-fail with "auth reuse failed: service check error"
    // and park in kAuthClient.) The auth-reuse variant keeps the embedded
    // private_data answer, which the phone accepts.
    func responsePrivateData(
        requestTrailingFields: [LyraProtoReader.Field]
    ) -> (privateData: Data?, logiFrames: [LogiConnFrame])? {
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
                  let authFrame = Self.authFrame(fromHandshake: handshake),
                  Self.varint(1, in: authFrame) == 1
            else {
                // Auth-reuse variant: after a full handshake the phone records
                // the session key in its DeviceKeyManager and the quick-conn
                // carries the ConnRequestFrame encrypted with that reuse key
                // instead of a plaintext client_notify.
                if let quickConn = Self.lengthDelimited(8, in: syncInfoData),
                   let reused = reuseKeyForQuickConn(quickConn, logiConn: logiConn) {
                    return reused
                }
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
            // Answer the embedded client_notify with a same-family
            // server_notify as a standalone logi frame (official Mac shape):
            // account-pair (wrapper {2,4}+f6) for family-2 dials, AUTH
            // (wrapper {4,5}+f7) for family-4 dials. The phys response stays
            // private_data-less; the f8-less server sync_info precedes it.
            let syncInfoFrame = buildResponseLogiFrame(
                connId: logiConn.logiConnId,
                peerNetId: logiConn.localNetId,
                handshakeId: 0,
                serverNotifyAuthFrame: nil,
                withQuickConn: false
            )
            if Self.varint(1, in: handshake) == 2 {
                guard let built = makeAccountPairServerNotify(
                    accountFrame: authFrame,
                    handshakeId: handshakeId,
                    connId: logiConn.logiConnId,
                    peerNetId: logiConn.localNetId
                ) else {
                    DiagnosticsLog.warn(
                        "xiaomi.synctask.acctpair_embedded_unanswered connId=\(logiConn.logiConnId)"
                    )
                    return (nil, [syncInfoFrame])
                }
                remember(built.state)
                let notifyFrame = accountPairHandshakeFrame(
                    accountFrame: built.accountFrame, handshakeId: handshakeId, conn: built.state
                )
                DiagnosticsLog.info(
                    "xiaomi.synctask.acctpair_embedded_server_notify connId=\(logiConn.logiConnId) " +
                        "handshakeId=\(handshakeId)"
                )
                return (nil, [syncInfoFrame, notifyFrame])
            }
            guard let built = makeServerNotify(
                authFrame: authFrame,
                handshakeId: handshakeId,
                connId: logiConn.logiConnId,
                peerNetId: logiConn.localNetId
            ) else {
                DiagnosticsLog.warn(
                    "xiaomi.synctask.auth_embedded_unanswered connId=\(logiConn.logiConnId)"
                )
                return (nil, [syncInfoFrame])
            }
            remember(built.state)
            let notifyFrame = authHandshakeFrame(
                authFrame: built.authFrame, handshakeId: handshakeId, conn: built.state
            )
            DiagnosticsLog.info(
                "xiaomi.synctask.auth_embedded_server_notify connId=\(logiConn.logiConnId) " +
                    "handshakeId=\(handshakeId)"
            )
            return (nil, [syncInfoFrame, notifyFrame])
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
              let authFrame = Self.authFrame(fromHandshake: handshake),
              let step = Self.varint(1, in: authFrame)
        else {
            DiagnosticsLog.info(
                "xiaomi.synctask.conn_frame_ignored connId=\(logiConn.logiConnId) " +
                    "bytes=\(logiConn.inner.count) " +
                    "hex=\(logiConn.inner.prefix(32).map { String(format: "%02x", $0) }.joined())"
            )
            return []
        }
        // ALERT frames (AuthHandshake msg=1) abort the handshake — log the
        // code/text so a phone-side rejection is visible in diagnostics.
        if Self.varint(2, in: handshake) == 1 {
            let code = Self.varint(1, in: authFrame) ?? 0
            let text = Self.lengthDelimited(2, in: authFrame)
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            DiagnosticsLog.warn(
                "xiaomi.synctask.handshake_alert connId=\(logiConn.logiConnId) code=\(code) text=\(text)"
            )
            return []
        }
        // Handshake family 2 = account-pair (handshake f6, cert-cred messages);
        // family 4 = AUTH (handshake f7, identity-sig messages). The phone picks
        // per dial ("add account pair handshake" vs "add account auth
        // handshake", live 2026-08-05).
        if Self.varint(1, in: handshake) == 2 {
            switch step {
            case 1:
                return handleAccountPairClientNotify(
                    accountFrame: authFrame, handshakeId: handshakeId, logiConn: logiConn, conn: conn
                )
            case 3:
                return handleAccountPairClientFinished(
                    accountFrame: authFrame, handshakeId: handshakeId, logiConn: logiConn, conn: conn
                )
            default:
                DiagnosticsLog.info(
                    "xiaomi.synctask.conn_frame_ignored connId=\(logiConn.logiConnId) step=\(step)"
                )
                return []
            }
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

    // Handles the auth-reuse quick-conn: f8 decrypts to a ConnRequestFrame
    // ({f1:1, f2:{f2:service, f4:trustLevel, f5:timeout, f6:connType, f7:1}})
    // with the recorded session key. Registers the conn with the reuse key and
    // answers with our server sync_info in the phys response private_data.
    private func reuseKeyForQuickConn(
        _ quickConn: Data, logiConn: LogiConnFrame
    ) -> (privateData: Data?, logiFrames: [LogiConnFrame])? {
        let ticketStore = MiTrustTicketStore.current()
        guard let decrypted = ticketStore.decryptCredBlobWithKey(quickConn) else {
            DiagnosticsLog.warn(
                "xiaomi.synctask.quickconn_reuse_decrypt_failed connId=\(logiConn.logiConnId)"
            )
            return nil
        }
        guard Self.varint(1, in: decrypted.plaintext) == 1,
              let requestFrame = Self.lengthDelimited(2, in: decrypted.plaintext),
              Self.lengthDelimited(2, in: requestFrame)
                .flatMap({ String(data: $0, encoding: .utf8) }) == Self.syncServiceName
        else {
            DiagnosticsLog.warn(
                "xiaomi.synctask.quickconn_reuse_shape connId=\(logiConn.logiConnId) " +
                    "plain=\(decrypted.plaintext.map { String(format: "%02x", $0) }.joined())"
            )
            return nil
        }
        var state = ConnState(
            connId: logiConn.logiConnId,
            peerNetId: logiConn.localNetId,
            handshakeId: 0,
            serverEphPriv: P256.KeyAgreement.PrivateKey(),
            clientEphPub: Data(),
            sharedZ: Data(),
            clientRandom: Data(),
            serverRandom: Data()
        )
        state.sessionKey = decrypted.key
        remember(state)
        let logiFrame = buildResponseLogiFrame(
            connId: logiConn.logiConnId,
            peerNetId: logiConn.localNetId,
            handshakeId: 0,
            serverNotifyAuthFrame: nil,
            withQuickConn: false
        )
        var wrapper = Data()
        LyraProtoWriter.appendLengthDelimitedField(1, value: logiFrame.serialized(), to: &wrapper)
        var privateData = Data()
        LyraProtoWriter.appendLengthDelimitedField(2, value: wrapper, to: &privateData)
        DiagnosticsLog.info(
            "xiaomi.synctask.quickconn_reuse connId=\(logiConn.logiConnId) " +
                "privateDataBytes=\(privateData.count)"
        )
        return (privateData, [logiFrame])
    }

    // MARK: - AuthHandshake server (mirrors LyraRelayCallSession)

    // Account-pair handshake (family 2, cert-cred). Wire shape reversed from
    // the official Mac (2026-08-05 pcap, phone sync task ↔ official Mac):
    //   server_notify  AccountPairFrame{f1:2, f3:{f1:selected, f2:encSig, f3:{f1:1}, f4:{f1:1}}}
    //     encSig = nonce‖AES-GCM(Z, AccountCredMessage{f1:certDER, f2:sigDER})‖tag
    //     sig    = ECDSA-SHA256(serverEph‖clientEph) under the enrolled Mijia cert key
    //   client_finished AccountPairFrame{f1:3, f4:{f1:credBlob, f2:proof}}
    //     credBlob = AES-GCM(Z, AccountCredMessage{phone cert, sig}) — sig over clientEph‖serverEph
    //     proof    = AES-GCM(sessionKey, 24B)
    //   server_finished AccountPairFrame{f1:4, f5:{f1:AES-GCM(sessionKey, Z‖serverEphPub)}}
    // Session key / ticket: same HKDF salts and info as the AUTH handshake.
    private func handleAccountPairClientNotify(
        accountFrame: Data,
        handshakeId: UInt64,
        logiConn: LogiConnFrame,
        conn: ConnState
    ) -> [LogiConnFrame] {
        guard let built = makeAccountPairServerNotify(
            accountFrame: accountFrame,
            handshakeId: handshakeId,
            connId: logiConn.logiConnId,
            peerNetId: conn.peerNetId
        ) else {
            return []
        }
        var state = built.state
        state.logiResponseSent = conn.logiResponseSent
        conns[logiConn.logiConnId] = state
        let frame = accountPairHandshakeFrame(
            accountFrame: built.accountFrame, handshakeId: handshakeId, conn: state
        )
        DiagnosticsLog.info(
            "xiaomi.synctask.acctpair_server_notify connId=\(logiConn.logiConnId) " +
                "handshakeId=\(handshakeId)"
        )
        return [frame]
    }

    // Builds the account-pair server_notify for a parsed client_notify and the
    // ConnState the eventual client_finished will consume. Shared by the
    // on-conn path and the embedded quick-conn answer.
    private func makeAccountPairServerNotify(
        accountFrame: Data,
        handshakeId: UInt64,
        connId: UInt32,
        peerNetId: UInt32
    ) -> (accountFrame: Data, state: ConnState)? {
        guard let clientNotify = Self.lengthDelimited(2, in: accountFrame),
              let cipherSuite = Self.lengthDelimited(1, in: clientNotify),
              let clientRandom = Self.lengthDelimited(2, in: cipherSuite),
              clientRandom.count == 32,
              let publicKeyMessage = Self.lengthDelimited(5, in: cipherSuite),
              let clientPub = Self.lengthDelimited(2, in: publicKeyMessage),
              clientPub.count == 65, clientPub.first == 0x04
        else {
            DiagnosticsLog.warn(
                "xiaomi.synctask.acctpair_notify_parse_failed " +
                    "authFrame=\(accountFrame.prefix(48).map { String(format: "%02x", $0) }.joined())"
            )
            return nil
        }
        guard let (certDER, certPriv) = Self.enrolledCertMaterial() else {
            DiagnosticsLog.warn("xiaomi.synctask.acctpair_no_cert")
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
            DiagnosticsLog.error("xiaomi.synctask.acctpair_ecdh_failed", error)
            return nil
        }
        guard let signature = try? certPriv.signature(for: SHA256.hash(data: serverPub + clientPub)) else {
            DiagnosticsLog.warn("xiaomi.synctask.acctpair_sign_failed")
            return nil
        }
        var credMessage = Data()
        LyraProtoWriter.appendLengthDelimitedField(1, value: certDER, to: &credMessage)
        LyraProtoWriter.appendLengthDelimitedField(2, value: signature.derRepresentation, to: &credMessage)
        let zKey = SymmetricKey(data: secret)
        let encSig: Data
        do {
            let nonce = AES.GCM.Nonce()
            let sealed = try AES.GCM.seal(credMessage, using: zKey, nonce: nonce)
            var blob = Data()
            blob.append(contentsOf: nonce.withUnsafeBytes { Data($0) })
            blob.append(sealed.ciphertext)
            blob.append(sealed.tag)
            encSig = blob
        } catch {
            DiagnosticsLog.error("xiaomi.synctask.acctpair_enc_failed", error)
            return nil
        }

        var outPublicKeyMessage = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &outPublicKeyMessage)
        LyraProtoWriter.appendLengthDelimitedField(2, value: serverPub, to: &outPublicKeyMessage)
        let offeredP3 = Self.varint(3, in: cipherSuite) ?? 0x10
        let offeredP4 = Self.varint(4, in: cipherSuite) ?? 0x08
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
        var outAccountFrame = Data()
        LyraProtoWriter.appendVarintField(1, value: 2, to: &outAccountFrame)
        LyraProtoWriter.appendLengthDelimitedField(3, value: serverNotify, to: &outAccountFrame)

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
        return (outAccountFrame, state)
    }

    private func handleAccountPairClientFinished(
        accountFrame: Data,
        handshakeId: UInt64,
        logiConn: LogiConnFrame,
        conn: ConnState
    ) -> [LogiConnFrame] {
        guard let clientFinished = Self.lengthDelimited(4, in: accountFrame),
              let credBlob = Self.lengthDelimited(1, in: clientFinished)
        else {
            DiagnosticsLog.warn("xiaomi.synctask.acctpair_finished_parse_failed connId=\(conn.connId)")
            return []
        }
        let zKey = SymmetricKey(data: conn.sharedZ)
        guard let credMessage = MiTrustTicketStore.current().decrypt(credBlob, with: zKey),
              let phoneCert = Self.lengthDelimited(1, in: credMessage),
              let phoneSig = Self.lengthDelimited(2, in: credMessage),
              let phonePubData = Self.certPubKey(der: phoneCert),
              let phonePub = try? P256.Signing.PublicKey(x963Representation: phonePubData),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: phoneSig)
        else {
            DiagnosticsLog.warn("xiaomi.synctask.acctpair_cred_decrypt_failed connId=\(conn.connId)")
            return []
        }
        let serverEphPub = conn.serverEphPriv.publicKey.x963Representation
        let digest = SHA256.hash(data: conn.clientEphPub + serverEphPub)
        guard phonePub.isValidSignature(signature, for: digest) else {
            DiagnosticsLog.warn("xiaomi.synctask.acctpair_sig_invalid connId=\(conn.connId)")
            return []
        }
        MiTrustTicketStore.harvestPeerAccountPubKey(fromCertDER: phoneCert)
        let newSessionKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: zKey,
            salt: Self.accountPairSessionSalt,
            info: conn.clientRandom + conn.serverRandom,
            outputByteCount: 32
        )
        let ticket = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: zKey,
            salt: Self.accountPairTicketSalt,
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
        if let proof = Self.lengthDelimited(2, in: clientFinished) {
            let proofOk = MiTrustTicketStore.current().decrypt(proof, with: newSessionKey) != nil
            DiagnosticsLog.info(
                "xiaomi.synctask.acctpair_proof connId=\(conn.connId) ok=\(proofOk)"
            )
        }

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
            DiagnosticsLog.error("xiaomi.synctask.acctpair_finish_enc_failed", error)
            return []
        }
        var outAccountFrame = Data()
        LyraProtoWriter.appendVarintField(1, value: 4, to: &outAccountFrame)
        LyraProtoWriter.appendLengthDelimitedField(5, value: serverFinished, to: &outAccountFrame)
        let frame = accountPairHandshakeFrame(
            accountFrame: outAccountFrame, handshakeId: handshakeId, conn: updated
        )
        DiagnosticsLog.info("xiaomi.synctask.acctpair_completed connId=\(conn.connId)")
        return [frame]
    }

    private func accountPairHandshakeFrame(
        accountFrame: Data,
        handshakeId: UInt64,
        conn: ConnState
    ) -> LogiConnFrame {
        var handshake = Data()
        LyraProtoWriter.appendVarintField(1, value: 2, to: &handshake)
        LyraProtoWriter.appendVarintField(2, value: 4, to: &handshake)
        LyraProtoWriter.appendLengthDelimitedField(6, value: accountFrame, to: &handshake)
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

    private static func certPubKey(der: Data) -> Data? {
        guard let cert = SecCertificateCreateWithData(nil, der as CFData),
              let key = SecCertificateCopyKey(cert),
              let rep = SecKeyCopyExternalRepresentation(key, nil) as? Data,
              rep.count == 65, rep.first == 0x04
        else { return nil }
        return rep
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
            DiagnosticsLog.warn(
                "xiaomi.synctask.auth_notify_parse_failed " +
                    "authFrame=\(authFrame.prefix(48).map { String(format: "%02x", $0) }.joined())"
            )
            return nil
        }
        DiagnosticsLog.info(
            "xiaomi.synctask.auth_notify_parsed clientPub=\(clientPub.prefix(9).map { String(format: "%02x", $0) }.joined()) " +
                "clientRandom=\(clientRandom.prefix(6).map { String(format: "%02x", $0) }.joined())"
        )
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
        // The phone signs client_finished with its account identity key (from
        // its Mijia cert) on auth_type 4 dials, not the pairing identity key —
        // accept any known peer signing key.
        let digest = SHA256.hash(data: conn.clientEphPub + serverEphPub)
        guard let signature = try? P256.Signing.ECDSASignature(derRepresentation: sigC) else {
            DiagnosticsLog.warn("xiaomi.synctask.auth_sig_parse_failed connId=\(conn.connId)")
            return []
        }
        let verified = ticketStore.peerSigningPubKeys.contains { keyData in
            guard let key = try? P256.Signing.PublicKey(x963Representation: keyData) else { return false }
            return key.isValidSignature(signature, for: digest)
        }
        guard verified else {
            DiagnosticsLog.warn(
                "xiaomi.synctask.auth_sig_invalid connId=\(conn.connId) " +
                    "clientEphPub=\(conn.clientEphPub.map { String(format: "%02x", $0) }.joined()) " +
                    "serverEphPub=\(serverEphPub.map { String(format: "%02x", $0) }.joined()) " +
                    "sig=\(sigC.map { String(format: "%02x", $0) }.joined())"
            )
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
        if case let .data(payloadData) = decoded.payload {
            return handleSyncPayloadPush(payloadData, logiConn: logiConn, conn: conn, sessionKey: sessionKey)
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

    // The phone's payload push on the dialed conn (PAYLOAD_V2 sync frame) —
    // answer with our TrustedDeviceInfo payload so its sync task completes.
    private func handleSyncPayloadPush(
        _ payloadData: Data, logiConn: LogiConnFrame, conn: ConnState, sessionKey: SymmetricKey
    ) -> [LogiConnFrame] {
        DiagnosticsLog.info(
            "xiaomi.synctask.payload_push connId=\(conn.connId) bytes=\(payloadData.count) " +
                "head=\(payloadData.prefix(24).map { String(format: "%02x", $0) }.joined())"
        )
        MiTrustTicketStore.harvestPeerAccountPubKey(fromSyncPayload: payloadData)
        guard let reply = syncPayloadProvider?() else { return [] }
        let replyInner = LogiConnInnerFrame(frameType: 7, payload: .data(reply))
        do {
            let nonce = AES.GCM.Nonce()
            let sealed = try AES.GCM.seal(replyInner.serialized(), using: sessionKey, nonce: nonce)
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
            DiagnosticsLog.info("xiaomi.synctask.payload_reply_tx connId=\(conn.connId)")
            return [frame]
        } catch {
            DiagnosticsLog.error("xiaomi.synctask.payload_reply_enc_failed", error)
            return []
        }
    }

    // MARK: - Builders

    private func buildResponseLogiFrame(
        connId: UInt32,
        peerNetId: UInt32,
        handshakeId: UInt64,
        serverNotifyAuthFrame: Data?,
        withQuickConn: Bool
    ) -> LogiConnFrame {
        let ticketStore = MiTrustTicketStore.current()
        var syncInfo = Data()
        LyraProtoWriter.appendVarintField(1, value: 10000, to: &syncInfo)
        LyraProtoWriter.appendVarintField(2, value: 40, to: &syncInfo)
        // Official server shape: no key_index / encrypted_cred. Advertising a
        // key_index makes the phone attempt auth reuse against its (possibly
        // empty) DeviceKeyManager — "key is null" terminally drops quick-conn
        // dials instead of falling back to the full handshake we serve below.
        LyraProtoWriter.appendLengthDelimitedField(
            4, value: Data(Self.syncServiceName.utf8), to: &syncInfo
        )
        LyraProtoWriter.appendLengthDelimitedField(5, value: ticketStore.uidFeatureInfo(), to: &syncInfo)
        if withQuickConn, let serverNotifyAuthFrame {
            // Sync-task dials run the ACCOUNT-pair handshake family: wrapper
            // {f1:2, f2:4} with the auth frame in f6 (live 2026-08-05 — the
            // AUTH-family wrapper {4,5}+f7 we use for relayCall gets "bad
            // server notify message" here).
            var handshake = Data()
            LyraProtoWriter.appendVarintField(1, value: 2, to: &handshake)
            LyraProtoWriter.appendVarintField(2, value: 4, to: &handshake)
            LyraProtoWriter.appendLengthDelimitedField(6, value: serverNotifyAuthFrame, to: &handshake)
            var upgrade = Data()
            LyraProtoWriter.appendVarintField(1, value: handshakeId, to: &upgrade)
            LyraProtoWriter.appendLengthDelimitedField(2, value: handshake, to: &upgrade)
            let quickConn = LogiConnInnerFrame(frameType: 6, payload: .upgrade(upgrade))
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
        // On-conn fallback handshake rides the AUTH family wrapper {4,5}+f7
        // (same as relayCall; live 2026-08-05 — the account-family {2,4}+f6
        // only applies to the EMBEDDED quick-conn server_notify).
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

    // The phone wraps client auth frames in handshake f7 on some dials
    // (relayCall) and f6 on others (sync-task quick-conn, live 2026-08-05).
    static func authFrame(fromHandshake handshake: Data) -> Data? {
        lengthDelimited(7, in: handshake) ?? lengthDelimited(6, in: handshake)
    }

    private static func lengthDelimited(_ fieldNumber: Int, in data: Data) -> Data? {
        guard let fields = try? LyraProtoReader.readFields(from: data) else { return nil }
        return fields.first { $0.number == fieldNumber && $0.wireType == 2 }?.lengthDelimitedValue
    }

    private static func varint(_ fieldNumber: Int, in data: Data) -> UInt64? {
        guard let fields = try? LyraProtoReader.readFields(from: data) else { return nil }
        return fields.first { $0.number == fieldNumber && $0.wireType == 0 }?.varintValue
    }
}
