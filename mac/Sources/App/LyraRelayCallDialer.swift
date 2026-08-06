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
    private var authIsAccountPair = false

    private let deviceIdHexProvider: () -> String?
    private let displayNameProvider: () -> String

    // One-shot outcome for the runtime's bridge-dial fallback: true once the
    // DIAL URI is on the channel (the phone placeCalls on receipt), false on
    // timeout/failure before that.
    var onDialOutcome: ((Bool) -> Void)?

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
    // same as LyraMeshAnnouncer / LyraSyncTaskServer).
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
            self.outcomeReported = false
            self.redialStage = 0
            self.dialAcked = false
            Self.activeDialer = self
            self.number = number
            self.host = host
            self.candidatePorts = Array(ports.prefix(8))
            self.state = .idle
            // Phone parses methodId as a Java int — stay within Int32 or the
            // dial response comes back as relay://dial:-1/response.
            self.methodId = String(UInt32.random(in: 1...UInt32(Int32.max)))
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

    private var outcomeReported = false

    private(set) static var activeDialer: LyraRelayCallDialer?

    // TeleService's handleRelayDialRequest calls setDeviceInRelay immediately
    // after placeCall, before the relayed Connection exists, so
    // mConnectRelayAudio is never armed and DistAudio never connects. A second
    // dial while the first call is still DIALING gets its duplicate placeCall
    // dropped by Telecom (observed 2026-08-06, bridge double-dial race) but
    // re-runs setDeviceInRelay with the connection present, arming the
    // ACTIVE-state connectDistAudioDevice.
    func redialForRelayedAudio() {
        queue.async { [weak self] in
            self?.redialForRelayedAudioLocked()
        }
    }

    private func reportOutcome(_ sent: Bool) {
        guard !outcomeReported else { return }
        outcomeReported = true
        let handler = onDialOutcome
        DispatchQueue.main.async { handler?(sent) }
    }

    private func stopLocked() {
        if state != .done, state != .channelUp, state != .idle {
            reportOutcome(false)
        }
        if Self.activeDialer === self {
            Self.activeDialer = nil
        }
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
        // With an enrolled Mijia cert the phone's DevRepo cred for us is
        // cert-based and it rejects AUTH-family client_finished (ALERT 301
        // "bad public key" observed live 2026-08-06); the official client
        // dials account-pair in that state, so do the same.
        authIsAccountPair = Self.enrolledCertMaterial() != nil

        var publicKeyMessage = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &publicKeyMessage)
        LyraProtoWriter.appendLengthDelimitedField(
            2, value: ephemeral.publicKey.x963Representation, to: &publicKeyMessage
        )
        var cipherSuite = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &cipherSuite)
        LyraProtoWriter.appendLengthDelimitedField(2, value: clientRandom, to: &cipherSuite)
        LyraProtoWriter.appendVarintField(3, value: authIsAccountPair ? 16 : 64, to: &cipherSuite)
        LyraProtoWriter.appendVarintField(4, value: authIsAccountPair ? 8 : 2, to: &cipherSuite)
        LyraProtoWriter.appendLengthDelimitedField(5, value: publicKeyMessage, to: &cipherSuite)
        var clientNotify = Data()
        LyraProtoWriter.appendLengthDelimitedField(1, value: cipherSuite, to: &clientNotify)
        if authIsAccountPair {
            LyraProtoWriter.appendLengthDelimitedField(2, value: Data([0x08, 0x01]), to: &clientNotify)
            LyraProtoWriter.appendLengthDelimitedField(3, value: Data([0x08, 0x01]), to: &clientNotify)
        } else {
            LyraProtoWriter.appendVarintField(2, value: 4, to: &clientNotify)
            LyraProtoWriter.appendLengthDelimitedField(3, value: Data([0x08, 0x01]), to: &clientNotify)
            LyraProtoWriter.appendLengthDelimitedField(4, value: Data([0x08, 0x01]), to: &clientNotify)
        }
        var authFrame = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &authFrame)
        LyraProtoWriter.appendLengthDelimitedField(2, value: clientNotify, to: &authFrame)
        sendAuthHandshake(authFrame: authFrame, label: "auth_client_notify")
        state = .authHandshake
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

    private func sendAuthHandshake(authFrame: Data, label: String) {
        var handshake = Data()
        if authIsAccountPair {
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
        guard let handshake = lengthDelimitedField(2, in: upgradeData) else {
            DiagnosticsLog.warn(
                "xiaomi.relaydial.auth_parse_failed hex=\(upgradeData.prefix(64).map { String(format: "%02x", $0) }.joined())"
            )
            return
        }
        // ALERT (observed live 2026-08-06): handshake{f1:7, f2:{f1:4, f2:1,
        // f3:{f1:code, f2:text}}}, e.g. code 301 "bad public key".
        if varintField(1, in: handshake) == 7,
           let alertOuter = lengthDelimitedField(2, in: handshake),
           let alertInner = lengthDelimitedField(3, in: alertOuter)
        {
            let code = varintField(1, in: alertInner) ?? 0
            let text = lengthDelimitedField(2, in: alertInner)
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            DiagnosticsLog.warn("xiaomi.relaydial.auth_alert code=\(code) text=\(text)")
            return
        }
        guard let authFrame = lengthDelimitedField(7, in: handshake)
                ?? lengthDelimitedField(6, in: handshake),
              let step = varintField(1, in: authFrame)
        else {
            DiagnosticsLog.warn(
                "xiaomi.relaydial.auth_parse_failed hex=\(upgradeData.prefix(64).map { String(format: "%02x", $0) }.joined())"
            )
            return
        }
        if varintField(2, in: handshake) == 1 {
            let text = lengthDelimitedField(2, in: authFrame)
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            DiagnosticsLog.warn("xiaomi.relaydial.auth_alert code=\(step) text=\(text)")
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
        if authIsAccountPair {
            handleAccountPairServerNotify(
                authFrame: authFrame, secret: secret,
                serverRandom: serverRandom, serverPub: serverPub, clientPub: clientPub
            )
            return
        }
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

    // Account-pair family server_notify — mirrors LyraMeshAnnouncer: encSig
    // opens under Z to {phone cert, sig}; our client_finished carries OUR
    // enrolled cert + sig over clientEph‖serverEph plus the proof, keyed by
    // the account-pair HKDF salt pair.
    private func handleAccountPairServerNotify(
        authFrame: Data, secret: Data, serverRandom: Data, serverPub: Data, clientPub: Data
    ) {
        guard let serverNotify = lengthDelimitedField(3, in: authFrame),
              let encSig = lengthDelimitedField(2, in: serverNotify)
        else {
            DiagnosticsLog.warn("xiaomi.relaydial.acctpair_notify_parse_failed")
            return
        }
        let ticketStore = MiTrustTicketStore.current()
        let zKey = SymmetricKey(data: secret)
        if let credMessage = ticketStore.decrypt(encSig, with: zKey),
           let phoneCert = lengthDelimitedField(1, in: credMessage),
           let sigDer = lengthDelimitedField(2, in: credMessage),
           let signature = try? P256.Signing.ECDSASignature(derRepresentation: sigDer)
        {
            MiTrustTicketStore.harvestPeerAccountPubKey(fromCertDER: phoneCert)
            var valid = false
            if let cert = SecCertificateCreateWithData(nil, phoneCert as CFData),
               let key = SecCertificateCopyKey(cert),
               let rep = SecKeyCopyExternalRepresentation(key, nil) as? Data,
               let pub = try? P256.Signing.PublicKey(x963Representation: rep)
            {
                valid = pub.isValidSignature(signature, for: SHA256.hash(data: serverPub + clientPub))
            }
            DiagnosticsLog.info("xiaomi.relaydial.acctpair_server_sig valid=\(valid)")
        } else {
            DiagnosticsLog.warn("xiaomi.relaydial.acctpair_encsig_decrypt_failed")
        }
        let sessionKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: zKey,
            salt: Self.accountPairSessionSalt,
            info: authClientRandom + serverRandom,
            outputByteCount: 32
        )
        let ticket = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: zKey,
            salt: Self.accountPairTicketSalt,
            info: authClientRandom + serverRandom,
            outputByteCount: 32
        )
        meshSessionKey = sessionKey
        MiTrustTicketStore.recordAuthSession(
            sessionKey: sessionKey.withUnsafeBytes { Data($0) },
            ticket: ticket.withUnsafeBytes { Data($0) }
        )
        guard let (certDER, certPriv) = Self.enrolledCertMaterial(),
              let signature = try? certPriv.signature(for: SHA256.hash(data: clientPub + serverPub))
        else {
            DiagnosticsLog.warn("xiaomi.relaydial.acctpair_no_cert")
            return
        }
        do {
            var credMessage = Data()
            LyraProtoWriter.appendLengthDelimitedField(1, value: certDER, to: &credMessage)
            LyraProtoWriter.appendLengthDelimitedField(2, value: signature.derRepresentation, to: &credMessage)
            let credNonce = AES.GCM.Nonce()
            let credSealed = try AES.GCM.seal(credMessage, using: zKey, nonce: credNonce)
            var credBlob = Data()
            credBlob.append(contentsOf: credNonce.withUnsafeBytes { Data($0) })
            credBlob.append(credSealed.ciphertext)
            credBlob.append(credSealed.tag)

            let proofNonce = AES.GCM.Nonce()
            let proofSealed = try AES.GCM.seal(Data(count: 24), using: sessionKey, nonce: proofNonce)
            var proof = Data()
            proof.append(contentsOf: proofNonce.withUnsafeBytes { Data($0) })
            proof.append(proofSealed.ciphertext)
            proof.append(proofSealed.tag)

            var clientFinished = Data()
            LyraProtoWriter.appendLengthDelimitedField(1, value: credBlob, to: &clientFinished)
            LyraProtoWriter.appendLengthDelimitedField(2, value: proof, to: &clientFinished)
            var outAuthFrame = Data()
            LyraProtoWriter.appendVarintField(1, value: 3, to: &outAuthFrame)
            LyraProtoWriter.appendLengthDelimitedField(4, value: clientFinished, to: &outAuthFrame)
            sendAuthHandshake(authFrame: outAuthFrame, label: "auth_client_finished")
        } catch {
            DiagnosticsLog.error("xiaomi.relaydial.acctpair_finish_enc_failed", error)
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

    private func connectChannel(port peerPort: UInt16, serverChannelId: UInt32) {
        guard let host else { return }
        let socket = LyraChannelSocket()
        socket.suppressNegotiationReply = true
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
            channelSocket = socket
            DiagnosticsLog.info("xiaomi.relaydial.channel_connect port=\(peerPort)")
        } catch {
            DiagnosticsLog.error("xiaomi.relaydial.channel_connect_failed", error)
            state = .failed("channel connect failed")
            return
        }
        // The phone's server channel comes up asynchronously after confirm;
        // the cast flow waits then retries the negotiation — mirror that.
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.sendChannelNegotiation(serverChannelId: serverChannelId, attempt: 0)
        }
    }

    private func sendChannelNegotiation(serverChannelId: UInt32, attempt: Int) {
        guard state == .awaitingPeerPort, attempt < 3, let socket = channelSocket else { return }
        do {
            try socket.sendClientNegotiation(channelId: serverChannelId, version: 1, mtu: 0xFF00)
            DiagnosticsLog.info(
                "xiaomi.relaydial.channel_negotiation_tx channelId=\(serverChannelId) attempt=\(attempt)"
            )
        } catch {
            DiagnosticsLog.error("xiaomi.relaydial.channel_negotiation_failed", error)
        }
        queue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.sendChannelNegotiation(serverChannelId: serverChannelId, attempt: attempt + 1)
        }
    }

    private func sendDialRequest(deviceIdOverride: String? = nil) {
        let deviceId = deviceIdOverride ?? Self.currentDeviceIdHex()
        let json =
            "{\"address\":\"\(number)\",\"requestDeviceId\":\"\(deviceId)\",\"videoState\":0}"
        let uri = "relay://dial:\(methodId)/request?\(json)"
        sendChannelText(uri)
        reportOutcome(true)
        // The back-channel update_call_state(DIALING) is not guaranteed to
        // arrive (channel negotiation can lag), so also schedule the
        // audio-arming redials after the dial — cellular calls stay DIALING
        // for several seconds, and Telecom drops the duplicate placeCall
        // while re-running setDeviceInRelay with the connection present.
        queue.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.redialForRelayedAudio()
        }
        queue.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            self?.redialForRelayedAudio()
        }
    }

    private var dialAcked = false
    private var redialStage = 0

    // TeleService's handleRelayDialRequest calls setDeviceInRelay right after
    // placeCall, before the relayed Connection exists, so mConnectRelayAudio
    // is never armed and DistAudio never connects. Re-dialing while DIALING
    // makes Telecom drop the duplicate placeCall but re-run setDeviceInRelay
    // with the connection present — but only when the device id CHANGES (the
    // whole body sits inside an old!=new guard). So redial #2 uses a
    // lowercased id to arm mConnectRelayAudio, and redial #3 restores the
    // exact id so the ACTIVE-state connectDistAudioDevice lookup matches our
    // published DistAudio device.
    private func redialForRelayedAudioLocked() {
        guard state == .done || state == .channelUp, dialAcked, channelSocket != nil else { return }
        switch redialStage {
        case 0:
            redialStage = 1
            methodId = String(UInt32.random(in: 1...UInt32(Int32.max)))
            DiagnosticsLog.info("xiaomi.relaydial.redial_for_audio stage=lowercase")
            sendDialRequest(deviceIdOverride: Self.currentDeviceIdHex().lowercased())
        case 1:
            redialStage = 2
            methodId = String(UInt32.random(in: 1...UInt32(Int32.max)))
            DiagnosticsLog.info("xiaomi.relaydial.redial_for_audio stage=restore")
            sendDialRequest()
        default:
            return
        }
    }

    // Suppress the scheduled audio redials (call ended / channel lost).
    func cancelRedial() {
        queue.async { [weak self] in
            self?.redialStage = 99
        }
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
        if text == "ok" {
            // Transport-level ack on the dial channel; the real dial response
            // (code 200) arrives on the back-channel.
            dialAcked = true
            if state == .channelUp { state = .done }
            return
        }
        if text.hasPrefix("relay://dial:\(methodId)/response?") {
            if text.contains("\"code\":0") || text.contains("\"code\": 0")
                || text.contains("\"code\":200") || text.contains("\"code\": 200")
            {
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
        if frame.packType == 4 {
            handleLogiPayloadFrame(frame)
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
        for logiConn in miFrame.logiConnFrames {
            // The phone may reuse this phys conn to dial our relayCall service
            // (createRelayChannel after a DIAL request) — adopt those logi
            // conns into the shared relay session, same as the announcer.
            if logiConn.logiConnId != logiConnId {
                if let inner = LogiConnInnerFrame(parsing: logiConn.inner),
                   case let .syncInfo(syncInfoData) = inner.payload,
                   lengthDelimitedField(4, in: syncInfoData)
                       .flatMap({ String(data: $0, encoding: .utf8) }) == LyraDistAudioRpcSession.serviceName
                {
                    DiagnosticsLog.info(
                        "xiaomi.relaydial.distrpc_sync_info connId=\(logiConn.logiConnId) " +
                            "peerNetId=\(logiConn.localNetId)"
                    )
                    LyraDistAudioRpcSession.adopt(
                        syncInfoData: syncInfoData,
                        logiConn: logiConn,
                        endpoint: endpoint,
                        sessionKey: meshSessionKey,
                        deviceIdHex: deviceIdHexProvider() ?? "",
                        deviceName: displayNameProvider()
                    ) { [weak self] frame, label in
                        self?.send(frame: frame, label: label)
                    }
                } else if let session = LyraDistAudioRpcSession.activeSession, session.handles(logiConn: logiConn) {
                    session.handleFrame(logiConn)
                } else if let inner = LogiConnInnerFrame(parsing: logiConn.inner),
                   case let .syncInfo(syncInfoData) = inner.payload,
                   lengthDelimitedField(4, in: syncInfoData)
                       .flatMap({ String(data: $0, encoding: .utf8) }) == LyraDistHardwareSession.serviceName
                {
                    DiagnosticsLog.info(
                        "xiaomi.relaydial.disthw_sync_info connId=\(logiConn.logiConnId) " +
                            "peerNetId=\(logiConn.localNetId)"
                    )
                    LyraDistHardwareSession.adopt(
                        syncInfoData: syncInfoData,
                        logiConn: logiConn,
                        endpoint: endpoint,
                        sessionKey: meshSessionKey,
                        deviceIdHex: deviceIdHexProvider() ?? "",
                        deviceName: displayNameProvider()
                    ) { [weak self] frame, label in
                        self?.send(frame: frame, label: label)
                    }
                } else if let session = LyraDistHardwareSession.activeSession, session.handles(logiConn: logiConn) {
                    session.handleFrame(logiConn)
                } else if let inner = LogiConnInnerFrame(parsing: logiConn.inner),
                   case let .syncInfo(syncInfoData) = inner.payload,
                   lengthDelimitedField(4, in: syncInfoData)
                       .flatMap({ String(data: $0, encoding: .utf8) }) == LyraRelayCallSession.serviceName
                {
                    DiagnosticsLog.info(
                        "xiaomi.relaydial.relaycall_sync_info connId=\(logiConn.logiConnId) " +
                            "peerNetId=\(logiConn.localNetId)"
                    )
                    LyraRelayCallSession.adopt(
                        syncInfoData: syncInfoData,
                        logiConn: logiConn,
                        endpoint: endpoint,
                        sessionKey: meshSessionKey
                    ) { [weak self] frame, label in
                        self?.send(frame: frame, label: label)
                    }
                } else if let session = LyraRelayCallSession.activeRelaySession {
                    session.handleFrame(logiConn)
                } else {
                    DiagnosticsLog.info(
                        "xiaomi.relaydial.stray_conn connId=\(logiConn.logiConnId) " +
                            "bytes=\(logiConn.inner.count)"
                    )
                }
                continue
            }
            var inner = LogiConnInnerFrame(parsing: logiConn.inner)
            if inner == nil, logiConn.flag {
                inner = decryptInner(logiConn)
            }
            // responseOfPeerPort may arrive as a raw ChannelProtocol command in
            // the logi frame inner (plaintext or session-key encrypted), not
            // wrapped in a LogiConnInnerFrame — same as the cast flow.
            if inner == nil {
                if let (header, body) = try? LyraChannelProtocol.decode(logiConn.inner) {
                    DiagnosticsLog.info("xiaomi.relaydial.command_logi_plain type=\(header.type)")
                    handlePeerPortResponse(type: header.type, body: body)
                } else if logiConn.flag, let plain = decryptInnerRaw(logiConn),
                          let (header, body) = try? LyraChannelProtocol.decode(plain)
                {
                    DiagnosticsLog.info("xiaomi.relaydial.command_logi_enc type=\(header.type)")
                    handlePeerPortResponse(type: header.type, body: body)
                } else {
                    DiagnosticsLog.info(
                        "xiaomi.relaydial.logi_unparsed bytes=\(logiConn.inner.count) " +
                            "head=\(logiConn.inner.prefix(32).map { String(format: "%02x", $0) }.joined())"
                    )
                }
                continue
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

    // packType-4 "logi payload": either a MiConnectFrame whose logi inner is
    // a raw ChannelProtocol command (cast flow), or [netId][flag] + AES-GCM
    // blob keyed by the session or channel trans key. Observed live
    // 2026-08-06: the phone's responseOfPeerPort arrived this way.
    private func handleLogiPayloadFrame(_ frame: LyraMeshPack.Frame) {
        let body = frame.payload
        if let miFrame = MiConnectFrame(parsing: body) {
            for logiConn in miFrame.logiConnFrames {
                if let (header, commandBody) = try? LyraChannelProtocol.decode(logiConn.inner) {
                    DiagnosticsLog.info("xiaomi.relaydial.command_p4_logi type=\(header.type)")
                    handlePeerPortResponse(type: header.type, body: commandBody)
                    return
                }
            }
        }
        var keys: [SymmetricKey] = []
        if let meshSessionKey { keys.append(meshSessionKey) }
        if !transKey.isEmpty { keys.append(SymmetricKey(data: transKey)) }
        for headerBytes in 1...2 where body.count > headerBytes + 28 {
            let nonce = body[body.index(body.startIndex, offsetBy: headerBytes)..<body.index(body.startIndex, offsetBy: headerBytes + 12)]
            let ciphertext = body[body.index(body.startIndex, offsetBy: headerBytes + 12)..<body.index(body.endIndex, offsetBy: -16)]
            let tag = body[body.index(body.endIndex, offsetBy: -16)..<body.endIndex]
            guard let box = try? AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: Data(nonce)),
                ciphertext: Data(ciphertext),
                tag: Data(tag)
            ) else { continue }
            for key in keys {
                guard let plaintext = try? AES.GCM.open(box, using: key),
                      let (header, commandBody) = try? LyraChannelProtocol.decode(plaintext)
                else { continue }
                DiagnosticsLog.info(
                    "xiaomi.relaydial.command_p4_enc type=\(header.type) headerBytes=\(headerBytes)"
                )
                handlePeerPortResponse(type: header.type, body: commandBody)
                return
            }
        }
        DiagnosticsLog.info(
            "xiaomi.relaydial.p4_unparsed bytes=\(body.count) " +
                "head=\(body.prefix(32).map { String(format: "%02x", $0) }.joined())"
        )
    }

    private func handlePeerPortResponse(type: UInt8, body: Data) {
        guard type == LyraChannelProtocol.CommandType.responseOfPeerPort.rawValue else { return }
        let fields = (try? LyraProtoReader.readFields(from: body)) ?? []
        var peerPort: UInt16 = 0
        var serverChannelId: UInt64 = 0
        for field in fields {
            switch (field.number, field.wireType) {
            case (2, 0): serverChannelId = field.varintValue ?? 0
            case (3, 0): peerPort = UInt16(field.varintValue ?? 0)
            default: continue
            }
        }
        guard peerPort != 0, state == .awaitingPeerPort else { return }
        DiagnosticsLog.info(
            "xiaomi.relaydial.peer_port_rx port=\(peerPort) serverChannelId=\(serverChannelId)"
        )
        connectChannel(port: peerPort, serverChannelId: UInt32(serverChannelId))
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
        guard let plaintext = decryptInnerRaw(logiConn) else { return nil }
        return LogiConnInnerFrame(parsing: plaintext)
    }

    private func decryptInnerRaw(_ logiConn: LogiConnFrame) -> Data? {
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
        return plaintext
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
