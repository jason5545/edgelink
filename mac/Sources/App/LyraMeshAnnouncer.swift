import CryptoKit
import EdgeLinkKit
import Foundation
import Network

final class LyraMeshAnnouncer {
    private enum State {
        case idle
        case physSynced
        case cookie
        case syncAuth
        case authHandshake
        case connRequest
        case logiSynced
    }

    private let socket = LyraMeshSocket()
    private var host: String?
    private var port: UInt16 = 0
    private var candidatePorts: [UInt16] = []
    private var state: State = .idle
    private var physConnId: UInt32 = 0
    private var logiConnId: UInt32 = 0
    private var peerNetId: UInt32 = 0
    private var ourCookie: UInt64 = 0
    private var handshakeId: UInt64 = 0
    private var authEphKey: P256.KeyAgreement.PrivateKey?
    private var authClientRandom = Data()
    private var authSharedZ = Data()
    private var authServerEphPub = Data()
    private var meshSessionKey: SymmetricKey?
    private var announceTimer: DispatchSourceTimer?
    private var lastActivity = Date.distantPast
    private static let staleTimeout: TimeInterval = 20
    private let queue = DispatchQueue(label: "edgelink.lyra.announcer")
    private let deviceIdHexProvider: () -> String?
    private let displayNameProvider: () -> String

    private static let announceServiceName = "00150323"
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

    private static var announcedDeviceType: UInt32 {
        let override = UserDefaults.standard.integer(forKey: "xiaomiDeviceTypeOverride")
        return override > 0 ? UInt32(override) : 14
    }

    private static var announcedServices: [LyraTrustedDeviceInfo.Service] {
        var services = [
            LyraTrustedDeviceInfo.Service(name: "miLyraShare", package: "com.edgelink.mac"),
            LyraTrustedDeviceInfo.Service(name: "miShareBasic", package: "com.edgelink.mac"),
            LyraTrustedDeviceInfo.Service(name: "miLyraShareTransfer", package: "com.edgelink.mac")
        ]
        // Opt-in while call-relay is groundwork (see LyraMeshResponder).
        let relayCallEnabled = UserDefaults.standard.object(forKey: "xiaomiRelayCallAdvertise") as? Bool ?? false
        if relayCallEnabled {
            services.append(
                LyraTrustedDeviceInfo.Service(
                    name: "relayCall",
                    package: "com.ios.phone",
                    data: Data([0x03, 0x01, 0x01, 0x01])
                )
            )
        }
        return services
    }

    init(
        deviceIdHexProvider: @escaping () -> String?,
        displayNameProvider: @escaping () -> String
    ) {
        self.deviceIdHexProvider = deviceIdHexProvider
        self.displayNameProvider = displayNameProvider
    }

    func start(host: String, port: UInt16) {
        start(host: host, ports: [port])
    }

    func start(host: String, ports: [UInt16]) {
        queue.async { [weak self] in
            guard let self, !ports.isEmpty else { return }
            let ports = Array(ports.prefix(8))
            if self.host == host, self.candidatePorts == ports, self.state == .logiSynced,
               Date().timeIntervalSince(self.lastActivity) < Self.staleTimeout {
                return
            }
            if self.host == host, self.state != .idle {
                DiagnosticsLog.info(
                    "xiaomi.mishare.announcer_resync state=\(self.state) " +
                        "idleSeconds=\(Int(Date().timeIntervalSince(self.lastActivity)))"
                )
            }
            self.stopLocked()
            self.host = host
            self.candidatePorts = ports
            self.state = .idle
            self.socket.onFrame = { [weak self] frame, endpoint, reply in
                self?.handle(frame: frame, endpoint: endpoint, reply: reply)
            }
            self.socket.onRawDatagram = { datagram, endpoint in
                DiagnosticsLog.info(
                    "xiaomi.mishare.announcer_rx from=\(endpoint.debugDescription) bytes=\(datagram.count)"
                )
            }
            self.sendPhysSyncRequest()
            self.startAnnounceTimerLocked()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopLocked()
        }
    }

    private func stopLocked() {
        announceTimer?.cancel()
        announceTimer = nil
        socket.stop()
        state = .idle
        host = nil
        port = 0
        candidatePorts = []
        peerNetId = 0
        ourCookie = 0
        handshakeId = 0
        authEphKey = nil
        authClientRandom = Data()
        authSharedZ = Data()
        authServerEphPub = Data()
        meshSessionKey = nil
        lastActivity = .distantPast
    }

    private func sendPhysSyncRequest() {
        guard let deviceIdHex = deviceIdHexProvider(), host != nil else {
            DiagnosticsLog.warn(
                "xiaomi.mishare.announcer_sync_skipped identity=\(deviceIdHexProvider() != nil) host=\(host ?? "nil")"
            )
            return
        }
        physConnId = .random(in: 1...UInt32.max)
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let deviceInfo = LyraDeviceInfo(
            deviceId: deviceIdHex,
            deviceType: Self.announcedDeviceType,
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

    // Official mesh-announce sync_info (idm-boot ground truth): no key_index,
    // no encrypted_cred — the phone answers and parks the conn in kAuthWait
    // expecting the 4-step AuthHandshake below.
    private func sendSyncAuthHello() {
        logiConnId = .random(in: 1...UInt32.max)
        var syncInfo = Data()
        LyraProtoWriter.appendVarintField(1, value: 10000, to: &syncInfo)
        LyraProtoWriter.appendVarintField(2, value: 16, to: &syncInfo)
        LyraProtoWriter.appendLengthDelimitedField(
            4, value: Data(Self.announceServiceName.utf8), to: &syncInfo
        )
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

    private func sendAuthClientNotify() {
        let ephemeral = P256.KeyAgreement.PrivateKey()
        var clientRandom = Data(count: 32)
        clientRandom.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress { arc4random_buf(base, 32) }
        }
        authEphKey = ephemeral
        authClientRandom = clientRandom
        handshakeId = 1

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
              let authFrame = lengthDelimitedField(7, in: handshake),
              let step = varintField(1, in: authFrame)
        else {
            DiagnosticsLog.warn(
                "xiaomi.mishare.announcer_auth_parse_failed hex=\(upgradeData.prefix(64).map { String(format: "%02x", $0) }.joined())"
            )
            return
        }
        switch step {
        case 2:
            handleAuthServerNotify(authFrame: authFrame)
        case 4:
            handleAuthServerFinished(authFrame: authFrame)
        default:
            DiagnosticsLog.info("xiaomi.mishare.announcer_auth_other step=\(step)")
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
              let encSig = lengthDelimitedField(2, in: serverNotify),
              let ephemeral = authEphKey
        else {
            DiagnosticsLog.warn("xiaomi.mishare.announcer_auth_notify_parse_failed")
            return
        }
        let secret: Data
        do {
            let peerKey = try P256.KeyAgreement.PublicKey(x963Representation: serverPub)
            secret = try ephemeral.sharedSecretFromKeyAgreement(with: peerKey).withUnsafeBytes { Data($0) }
        } catch {
            DiagnosticsLog.error("xiaomi.mishare.announcer_auth_ecdh_failed", error)
            return
        }
        authSharedZ = secret
        authServerEphPub = serverPub
        let clientPub = ephemeral.publicKey.x963Representation
        let ticketStore = MiTrustTicketStore.current()
        if let sigDer = ticketStore.decrypt(encSig, with: SymmetricKey(data: secret)),
           !ticketStore.peerIdentityPubKey.isEmpty,
           let phoneIdentity = try? P256.Signing.PublicKey(x963Representation: ticketStore.peerIdentityPubKey),
           let signature = try? P256.Signing.ECDSASignature(derRepresentation: sigDer)
        {
            let valid = phoneIdentity.isValidSignature(signature, for: SHA256.hash(data: serverPub + clientPub))
            DiagnosticsLog.info("xiaomi.mishare.announcer_auth_server_sig valid=\(valid)")
        } else {
            DiagnosticsLog.warn("xiaomi.mishare.announcer_auth_server_sig_unchecked")
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
        let sessionKeyData = sessionKey.withUnsafeBytes { Data($0) }
        MiTrustTicketStore.recordAuthSession(
            sessionKey: sessionKeyData,
            ticket: ticket.withUnsafeBytes { Data($0) }
        )
        DiagnosticsLog.info(
            "xiaomi.mishare.announcer_session_key hex=\(sessionKeyData.map { String(format: "%02x", $0) }.joined())"
        )
        guard let identityKey = ticketStore.identityPrivateKey,
              let signature = try? identityKey.signature(for: SHA256.hash(data: clientPub + serverPub))
        else {
            DiagnosticsLog.warn("xiaomi.mishare.announcer_auth_no_identity")
            return
        }
        do {
            let nonce = AES.GCM.Nonce()
            let sealed = try AES.GCM.seal(signature.derRepresentation, using: SymmetricKey(data: secret), nonce: nonce)
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
            DiagnosticsLog.error("xiaomi.mishare.announcer_auth_finish_enc_failed", error)
        }
    }

    private func handleAuthServerFinished(authFrame: Data) {
        guard let serverFinished = lengthDelimitedField(5, in: authFrame),
              let blob = lengthDelimitedField(1, in: serverFinished),
              let sessionKey = meshSessionKey
        else {
            DiagnosticsLog.warn("xiaomi.mishare.announcer_auth_finished_parse_failed")
            return
        }
        let ticketStore = MiTrustTicketStore.current()
        if let proof = ticketStore.decrypt(blob, with: sessionKey) {
            let expected = authSharedZ + authServerEphPub
            DiagnosticsLog.info(
                "xiaomi.mishare.announcer_auth_server_finished valid=\(proof == expected) bytes=\(proof.count)"
            )
        } else {
            DiagnosticsLog.warn("xiaomi.mishare.announcer_auth_server_finished_decrypt_failed")
        }
        DiagnosticsLog.info("xiaomi.mishare.announcer_auth_completed")
        sendLogiConnRequest()
    }

    // Post-handshake the official client registers the conn with an encrypted
    // LOGI_CONN_REQUEST; the phone's RESPONSE is what makes DeviceManager
    // record our link address (the 15011 wall).
    private func sendLogiConnRequest() {
        var request = Data()
        LyraProtoWriter.appendLengthDelimitedField(
            2, value: Data(Self.announceServiceName.utf8), to: &request
        )
        LyraProtoWriter.appendVarintField(4, value: 16, to: &request)
        LyraProtoWriter.appendVarintField(5, value: 10000, to: &request)
        LyraProtoWriter.appendVarintField(6, value: 128, to: &request)
        LyraProtoWriter.appendVarintField(7, value: 1, to: &request)
        let inner = LogiConnInnerFrame(frameType: 1, payload: .request(request))
        sendEncrypted(inner: inner, label: "logi_request")
        state = .connRequest
    }

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
            DiagnosticsLog.error("xiaomi.mishare.announcer_encrypt_failed label=\(label)", error)
        }
    }

    private func decryptInner(_ logiConn: LogiConnFrame) -> LogiConnInnerFrame? {
        guard let sessionKey = meshSessionKey else { return nil }
        let inner = logiConn.inner
        guard inner.count > 28 else { return nil }
        let nonce = inner.prefix(12)
        let ciphertext = inner.dropFirst(12).dropLast(16)
        let tag = inner.suffix(16)
        guard let box = try? AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: Data(nonce)),
            ciphertext: Data(ciphertext),
            tag: Data(tag)
        ), let plaintext = try? AES.GCM.open(box, using: sessionKey) else {
            return nil
        }
        return LogiConnInnerFrame(parsing: plaintext)
    }

    // The phone's SyncManager reverse sync task rides the live announce conn:
    // it pushes its TrustedDeviceInfo payload (PAYLOAD_V2, session key) and
    // expects ours back — that exchange is what lands our device (with the
    // relayCall service) in the phone's DevRepo trusted store.
    private var lastSyncPayloadReplyAt = Date.distantPast

    private func replyToSyncPayload(plaintext: Data) {
        DiagnosticsLog.info(
            "xiaomi.mishare.announcer_sync_payload decrypted=\(plaintext.count) " +
                "head=\(plaintext.map { String(format: "%02x", $0) }.joined())"
        )
        guard Date().timeIntervalSince(lastSyncPayloadReplyAt) > 5 else { return }
        lastSyncPayloadReplyAt = Date()
        sendSyncReply()
        sendSyncPush()
    }

    // Full TrustedDeviceInfo in the type-0x00 sync frame (see LyraSyncReply) —
    // the plain announce frame is rejected by the sync path's FrameParse.
    private func sendSyncReply() {
        guard let deviceIdHex = deviceIdHexProvider(), let sessionKey = meshSessionKey else {
            return
        }
        let plaintext = LyraSyncReply.payload(
            deviceIdHex: deviceIdHex, displayName: displayNameProvider()
        )
        do {
            let nonce = AES.GCM.Nonce()
            let sealed = try AES.GCM.seal(plaintext, using: sessionKey, nonce: nonce)
            var payload = Data()
            payload.append(UInt8((peerNetId == 0 ? 1 : peerNetId) & 0xFF))
            payload.append(1)
            payload.append(contentsOf: nonce.withUnsafeBytes { Data($0) })
            payload.append(sealed.ciphertext)
            payload.append(sealed.tag)
            send(frame: LyraMeshPack.Frame(packType: 5, payload: payload), label: "sync_reply")
        } catch {
            DiagnosticsLog.error("xiaomi.mishare.announcer_sync_reply_failed", error)
        }
    }

    // Device-initiated type-1 sync push — the shape that routes through the
    // phone's HandleSyncDevMsg cred checks (the type-2 reply never does), so
    // the conn's trusted type can leave 0 and AddOnlineDevice accepts us.
    // Sent proactively after the announce (the phone's sync pushes back off
    // after failures, so waiting for them stalls the push forever).
    private var lastSyncPushAt = Date.distantPast

    private func maybeSendSyncPush() {
        guard Date().timeIntervalSince(lastSyncPushAt) > 60 else { return }
        lastSyncPushAt = Date()
        sendSyncPush()
    }

    private func sendSyncPush() {
        guard let deviceIdHex = deviceIdHexProvider(), let sessionKey = meshSessionKey else {
            return
        }
        let plaintext = LyraSyncReply.pushPayload(
            deviceIdHex: deviceIdHex, displayName: displayNameProvider()
        )
        DiagnosticsLog.info("xiaomi.mishare.announcer_sync_push_build bytes=\(plaintext.count)")
        do {
            let nonce = AES.GCM.Nonce()
            let sealed = try AES.GCM.seal(plaintext, using: sessionKey, nonce: nonce)
            var payload = Data()
            payload.append(UInt8((peerNetId == 0 ? 1 : peerNetId) & 0xFF))
            payload.append(1)
            payload.append(contentsOf: nonce.withUnsafeBytes { Data($0) })
            payload.append(sealed.ciphertext)
            payload.append(sealed.tag)
            send(frame: LyraMeshPack.Frame(packType: 5, payload: payload), label: "sync_push")
        } catch {
            DiagnosticsLog.error("xiaomi.mishare.announcer_sync_push_failed", error)
        }
    }

    private func sendAnnounce() {
        guard !UserDefaults.standard.bool(forKey: "xiaomiMeshAnnounceDisabled") else {
            return
        }
        guard let deviceIdHex = deviceIdHexProvider(), let sessionKey = meshSessionKey else {
            return
        }
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let deviceInfo = LyraTrustedDeviceInfo.deviceInfoFrame(
            deviceName: displayNameProvider(),
            deviceType: Self.announcedDeviceType,
            deviceId: deviceIdHex,
            uidHash: "61F250B63BE702E35785999767C221163AF7238995757F598034B753E3AF0733",
            hwModel: Self.hardwareModel(),
            lyraVersion: "5.1.208.10.fullCnRelease.0512164",
            services: Self.announcedServices,
            ipAddress: Self.primaryIPv4Address(),
            osVersion: "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)",
            region: UserDefaults.standard.string(forKey: "xiaomiMeshRegion") ?? "cn",
            deviceKey: MiTrustTicketStore.current().deviceKeyData
        )
        let inner = LyraTrustedDeviceInfo.plaintextAnnounce(deviceInfo: deviceInfo)
        do {
            let nonce = AES.GCM.Nonce()
            let sealed = try AES.GCM.seal(inner, using: sessionKey, nonce: nonce)
            var payload = Data()
            payload.append(UInt8((peerNetId == 0 ? 1 : peerNetId) & 0xFF))
            payload.append(1)
            payload.append(contentsOf: nonce.withUnsafeBytes { Data($0) })
            payload.append(sealed.ciphertext)
            payload.append(sealed.tag)
            send(frame: LyraMeshPack.Frame(packType: 5, payload: payload), label: "announce")
            maybeSendSyncPush()
        } catch {
            DiagnosticsLog.error("xiaomi.mishare.announcer_announce_failed", error)
        }
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
                if getnameinfo(
                    interface.pointee.ifa_addr,
                    socklen_t(interface.pointee.ifa_addr.pointee.sa_len),
                    &host,
                    socklen_t(host.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                ) == 0 {
                    address = String(cString: host)
                }
            }
            current = interface.pointee.ifa_next
        }
        return address
    }

    private static func endpointPort(_ endpoint: NWEndpoint) -> UInt16? {
        let description = endpoint.debugDescription
        guard let colon = description.lastIndex(of: ":") else { return nil }
        return UInt16(description[description.index(after: colon)...])
    }

    private func send(frame: LyraMeshPack.Frame, label: String, toPort: UInt16? = nil) {
        let targetPort = toPort ?? port
        guard let host, targetPort != 0 else { return }
        do {
            try socket.send(frame: frame, to: host, port: targetPort)
            DiagnosticsLog.info("xiaomi.mishare.announcer_tx label=\(label) to=\(host):\(targetPort)")
        } catch {
            DiagnosticsLog.error("xiaomi.mishare.announcer_tx_failed", error)
        }
    }

    private func startAnnounceTimerLocked() {
        announceTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 7, repeating: 7)
        timer.setEventHandler { [weak self] in
            guard let self, self.state == .logiSynced else { return }
            self.sendAnnounce()
        }
        announceTimer = timer
        timer.resume()
    }

    private func lengthDelimitedField(_ fieldNumber: Int, in data: Data) -> Data? {
        guard let fields = try? LyraProtoReader.readFields(from: data) else { return nil }
        return fields.first { $0.number == fieldNumber && $0.wireType == 2 }?.lengthDelimitedValue
    }

    private func varintField(_ fieldNumber: Int, in data: Data) -> UInt64? {
        guard let fields = try? LyraProtoReader.readFields(from: data) else { return nil }
        return fields.first { $0.number == fieldNumber && $0.wireType == 0 }?.varintValue
    }

    private func handle(frame: LyraMeshPack.Frame, endpoint: NWEndpoint, reply: LyraMeshSocket.ReplyHandler) {
        lastActivity = Date()
        if port == 0, let endpointPort = Self.endpointPort(endpoint), candidatePorts.contains(endpointPort) {
            port = endpointPort
            candidatePorts = [endpointPort]
            DiagnosticsLog.info("xiaomi.mishare.announcer_port_pinned port=\(endpointPort)")
        }
        if frame.packType == 5 {
            var detail = ""
            if let sessionKey = meshSessionKey, frame.payload.count > 30 {
                let body = frame.payload
                let nonce = body.dropFirst(2).prefix(12)
                let ciphertext = body.dropFirst(14).dropLast(16)
                let tag = body.suffix(16)
                if let box = try? AES.GCM.SealedBox(
                    nonce: AES.GCM.Nonce(data: Data(nonce)),
                    ciphertext: Data(ciphertext),
                    tag: Data(tag)
                ), let plaintext = try? AES.GCM.open(box, using: sessionKey) {
                    detail = " decryptedBytes=\(plaintext.count)"
                    replyToSyncPayload(plaintext: plaintext)
                }
            }
            DiagnosticsLog.info(
                "xiaomi.mishare.announcer_payload bytes=\(frame.payload.count)\(detail) " +
                    "hex=\(frame.payload.prefix(48).map { String(format: "%02x", $0) }.joined())"
            )
            return
        }
        guard let miFrame = MiConnectFrame(parsing: frame.payload) else {
            DiagnosticsLog.warn(
                "xiaomi.mishare.announcer_frame_parse_failed packType=\(frame.packType) " +
                    "bytes=\(frame.payload.count) " +
                    "hex=\(frame.payload.prefix(48).map { String(format: "%02x", $0) }.joined())"
            )
            return
        }
        if let physConn = miFrame.physConnFrame {
            switch physConn.payload {
            case .syncDeviceInfoResponse:
                DiagnosticsLog.info("xiaomi.mishare.announcer_phys_synced")
                state = .physSynced
                state = .cookie
                sendCookie(phase: 1)
            case let .keepAliveResponse(responseData) where physConn.field2 == 5:
                if state == .cookie {
                    let fields = (try? LyraProtoReader.readFields(from: responseData)) ?? []
                    var phase: UInt64 = 0
                    var echo: UInt64 = 0
                    for field in fields {
                        if field.number == 2, field.wireType == 0 { phase = field.varintValue ?? 0 }
                        if field.number == 3, field.wireType == 0 { echo = field.varintValue ?? 0 }
                    }
                    DiagnosticsLog.info("xiaomi.mishare.announcer_cookie_rx phase=\(phase) echo=\(echo)")
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
                DiagnosticsLog.warn("xiaomi.mishare.announcer_disconnected state=\(state)")
                stopLocked()
            default:
                DiagnosticsLog.info(
                    "xiaomi.mishare.announcer_phys_other field2=\(physConn.field2) " +
                        "payload=\(String(describing: physConn.payload))"
                )
            }
        }
        for logiConn in miFrame.logiConnFrames {
            if logiConn.logiConnId != logiConnId {
                if let inner = LogiConnInnerFrame(parsing: logiConn.inner),
                   case let .syncInfo(syncInfoData) = inner.payload,
                   lengthDelimitedField(4, in: syncInfoData)
                       .flatMap({ String(data: $0, encoding: .utf8) }) == LyraRelayCallSession.serviceName
                {
                    DiagnosticsLog.info(
                        "xiaomi.mishare.announcer_relaycall_sync_info connId=\(logiConn.logiConnId) " +
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
                        "xiaomi.mishare.announcer_stray_conn connId=\(logiConn.logiConnId) " +
                            "bytes=\(logiConn.inner.count)"
                    )
                }
                continue
            }
            var inner = LogiConnInnerFrame(parsing: logiConn.inner)
            if inner == nil, logiConn.flag {
                inner = decryptInner(logiConn)
            }
            guard let inner else {
                DiagnosticsLog.warn(
                    "xiaomi.mishare.announcer_logi_parse_failed bytes=\(logiConn.inner.count) " +
                        "flag=\(logiConn.flag) " +
                        "hex=\(logiConn.inner.prefix(48).map { String(format: "%02x", $0) }.joined())"
                )
                continue
            }
            switch inner.payload {
            case let .syncInfo(syncInfoData):
                peerNetId = logiConn.localNetId
                DiagnosticsLog.info(
                    "xiaomi.mishare.announcer_logi_synced peerNetId=\(logiConn.localNetId) " +
                        "logiConnId=\(logiConn.logiConnId)"
                )
                if state == .syncAuth {
                    sendAuthClientNotify()
                }
                _ = syncInfoData
            case let .upgrade(upgradeData):
                handleAuthUpgrade(upgradeData)
            case let .response(responseData):
                DiagnosticsLog.info(
                    "xiaomi.mishare.announcer_logi_response hex=\(responseData.map { String(format: "%02x", $0) }.joined())"
                )
                if state == .connRequest {
                    state = .logiSynced
                    sendAnnounce()
                }
            case let .disconnect(data):
                let code = varintField(1, in: data) ?? 0
                DiagnosticsLog.warn("xiaomi.mishare.announcer_logi_disconnect code=\(code) state=\(state)")
                stopLocked()
            default:
                DiagnosticsLog.info(
                    "xiaomi.mishare.announcer_logi_other frameType=\(inner.frameType) " +
                        "bytes=\(logiConn.inner.count)"
                )
            }
        }
    }
}
