import CryptoKit
import EdgeLinkKit
import Foundation
import Network

final class LyraCastTrustSession {
    enum Stage: Equatable {
        case physSync
        case cookie
        case syncAuth
        case upgrade
        case logiConnRequest
        case channelWait
        case channelNegotiate
        case ready
        case failed(String)
    }

    let trustManager: MacTrustManager

    var onStatus: ((String) -> Void)?

    private let queue = DispatchQueue(label: "edgelink.lyra.cast", qos: .userInitiated)
    private var endpoints: [(host: String, port: UInt16)]
    private var endpointIndex = 0
    private var host: String
    private var port: UInt16
    private let deviceIdHex: String
    private let displayName: String

    private let socket = LyraMeshSocket()
    private var stage: Stage = .physSync
    private var lastProgress = Date()
    private var watchdog: DispatchSourceTimer?
    private var cancelled = false

    private var peerNetId: UInt32 = 0
    private var logiConnId: UInt32 = 0
    private var ourCookie: UInt64 = 0

    private var syncAuthPrivateKey: Curve25519.KeyAgreement.PrivateKey?
    private var syncAuthOurConnId = Data()
    private var syncKeyCandidates: [SymmetricKey] = []

    private var keyAgreementKey: P256.KeyAgreement.PrivateKey?
    private var authClientRandom = Data()
    private var authServerRandom = Data()
    private var channelKeyCS: SymmetricKey?
    private var channelKeySC: SymmetricKey?
    private var upgradeHandshakeId: UInt64 = 0

    private var channelId: UInt32 = 0
    private var serverChannelId: UInt32 = 0
    private var transKey = Data()
    private var transRandom = Data()

    private var channelSocket: LyraChannelSocket?
    private var channelReady = false

    private var srvConnId: UInt32 = 0
    private var srvPeerNetId: UInt32 = 0
    private var srvSignKey: Curve25519.KeyAgreement.PrivateKey?
    private var srvOurConnId = Data()
    private var srvKeyCandidates: [SymmetricKey] = []
    private var srvKeyAgreementKey: P256.KeyAgreement.PrivateKey?
    private var srvClientRandom = Data()
    private var srvServerRandom = Data()
    private var srvKeyCS: SymmetricKey?
    private var srvKeySC: SymmetricKey?
    private var srvChannelSocket: LyraChannelSocket?
    private var srvChannelId: UInt32 = 0

    private static let serviceName = "com.xiaomi.mirror:cast"
    private static let servicePackage = "com.xiaomi.mirror"

    init(endpoints: [(host: String, port: UInt16)], deviceIdHex: String, displayName: String, trustManager: MacTrustManager) {
        self.endpoints = endpoints
        self.host = endpoints.first?.host ?? ""
        self.port = endpoints.first?.port ?? 0
        self.deviceIdHex = deviceIdHex
        self.displayName = displayName
        self.trustManager = trustManager
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.socket.onFrame = { [weak self] frame, endpoint, reply in
                self?.handle(frame: frame, endpoint: endpoint, reply: reply)
            }
            self.socket.onRawDatagram = { content, endpoint in
                DiagnosticsLog.info(
                    "xiaomi.cast.trust_raw_rx bytes=\(content.count) from=\(endpoint.debugDescription) " +
                        "head=\(content.prefix(16).map { String(format: "%02x", $0) }.joined())"
                )
            }
            do {
                try self.socket.start()
            } catch {
                self.fail(String(localized: "mesh socket 啟動失敗"))
                return
            }
            self.startWatchdog()
            self.sendPhysSyncRequest()
        }
    }

    func cancel() {
        queue.async { [weak self] in
            self?.finishLocked()
        }
    }

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self, !self.cancelled else { return }
            if self.stage != .ready, Date().timeIntervalSince(self.lastProgress) > 30 {
                self.fail(String(localized: "逾時（stage=\(self.stage)）"))
            }
        }
        watchdog = timer
        timer.resume()
    }

    private func progress(_ newStage: Stage, _ message: String) {
        lastProgress = Date()
        stage = newStage
        DiagnosticsLog.info("xiaomi.cast.trust_stage stage=\(newStage) \(message)")
        onStatus?(message)
    }

    private func fail(_ message: String) {
        DiagnosticsLog.warn("xiaomi.cast.trust_failed stage=\(stage) reason=\(message)")
        stage = .failed(message)
        onStatus?(String(localized: "連線失敗：\(message)"))
        finishLocked()
    }

    private func finishLocked() {
        cancelled = true
        watchdog?.cancel()
        watchdog = nil
        channelSocket?.stop()
        channelSocket = nil
        socket.stop()
        DispatchQueue.main.async { [weak self] in
            self?.trustManager.stop()
        }
    }

    private func teardownPhysAfterAuth() {
        guard !cancelled else { return }
        DiagnosticsLog.info("xiaomi.cast.trust_teardown_after_auth")
        cancelled = true
        watchdog?.cancel()
        watchdog = nil
        channelSocket?.stop()
        channelSocket = nil
        srvChannelSocket?.stop()
        srvChannelSocket = nil
        socket.stop()
    }

    private func send(frame: LyraMeshPack.Frame, label: String) {
        do {
            try socket.send(frame: frame, to: host, port: port)
            DiagnosticsLog.info("xiaomi.cast.trust_tx label=\(label) to=\(self.host):\(self.port)")
        } catch {
            DiagnosticsLog.error("xiaomi.cast.trust_tx_failed label=\(label)", error)
        }
    }

    private func sendPhysSyncRequest(attempt: Int = 0) {
        if attempt == 0 {
            progress(.physSync, String(localized: "連接手機…"))
        }
        guard attempt < 8, stage == .physSync, !cancelled, !endpoints.isEmpty else { return }
        let target = endpoints[attempt % endpoints.count]
        endpointIndex = attempt % endpoints.count
        host = target.host
        port = target.port
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let deviceInfo = LyraDeviceInfo(
            deviceId: deviceIdHex,
            deviceType: 14,
            uidHash: "61F2",
            displayName: displayName,
            osVersion: "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)",
            connMediumTypes: 0x40082,
            romVersion: "5.1.208.10.fullCnRelease.0512164"
        )
        var request = Data()
        LyraProtoWriter.appendVarintField(
            1, value: UInt64(Date().timeIntervalSince1970 * 1000), to: &request
        )
        LyraProtoWriter.appendLengthDelimitedField(2, value: deviceInfo.serialized(), to: &request)
        let physConn = PhysConnFrame(
            field1: .random(in: 1...UInt32.max),
            field2: 1,
            payload: .syncDeviceInfoRequest(request)
        )
        let miFrame = MiConnectFrame(version: 0, logiConnFrames: [], physConnFrame: physConn)
        send(frame: LyraMeshPack.Frame(packType: 1, payload: miFrame.serialized()), label: "phys_sync")
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.sendPhysSyncRequest(attempt: attempt + 1)
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
        progress(.syncAuth, String(localized: "同步認證…"))
        logiConnId = .random(in: 1...UInt32.max)
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        syncAuthPrivateKey = privateKey
        var connId = Data()
        for _ in 0..<8 {
            connId.append(UInt8.random(in: 0...255))
        }
        syncAuthOurConnId = connId
        var cred = Data()
        LyraProtoWriter.appendLengthDelimitedField(1, value: connId, to: &cred)
        LyraProtoWriter.appendLengthDelimitedField(2, value: privateKey.publicKey.rawRepresentation, to: &cred)
        var syncInfo = Data()
        LyraProtoWriter.appendVarintField(1, value: 15000, to: &syncInfo)
        LyraProtoWriter.appendVarintField(2, value: 48, to: &syncInfo)
        LyraProtoWriter.appendVarintField(3, value: 1, to: &syncInfo)
        LyraProtoWriter.appendLengthDelimitedField(4, value: Data(Self.serviceName.utf8), to: &syncInfo)
        LyraProtoWriter.appendLengthDelimitedField(5, value: cred, to: &syncInfo)
        LyraProtoWriter.appendLengthDelimitedField(
            6, value: LyraMeshResponder.officialMacSyncInfoSignature, to: &syncInfo
        )
        let inner = LogiConnInnerFrame(frameType: 5, payload: .syncInfo(syncInfo))
        let logiConn = LogiConnFrame(logiConnId: logiConnId, localNetId: 1, remoteNetId: peerNetId, inner: inner.serialized())
        let miFrame = MiConnectFrame(version: 0, logiConnFrames: [logiConn])
        send(frame: LyraMeshPack.Frame(packType: 2, payload: miFrame.serialized()), label: "sync_auth_hello")
    }

    private func sendUpgrade() {
        progress(.upgrade, String(localized: "建立加密通道…"))
        let privateKey = P256.KeyAgreement.PrivateKey()
        keyAgreementKey = privateKey
        var clientRandom = Data(count: 32)
        clientRandom.withUnsafeMutableBytes { buffer in
            if let baseAddress = buffer.baseAddress {
                arc4random_buf(baseAddress, 32)
            }
        }
        authClientRandom = clientRandom
        upgradeHandshakeId = UInt64.random(in: 1...UInt64(UInt32.max))

        var publicKeyMessage = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &publicKeyMessage)
        LyraProtoWriter.appendLengthDelimitedField(2, value: privateKey.publicKey.x963Representation, to: &publicKeyMessage)

        var cipherSuite = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &cipherSuite)
        LyraProtoWriter.appendLengthDelimitedField(2, value: clientRandom, to: &cipherSuite)
        LyraProtoWriter.appendVarintField(3, value: 32, to: &cipherSuite)
        LyraProtoWriter.appendVarintField(4, value: 2, to: &cipherSuite)
        LyraProtoWriter.appendLengthDelimitedField(5, value: publicKeyMessage, to: &cipherSuite)

        var clientNotify = Data()
        LyraProtoWriter.appendLengthDelimitedField(1, value: cipherSuite, to: &clientNotify)

        var pairFrame = Data()
        LyraProtoWriter.appendLengthDelimitedField(2, value: clientNotify, to: &pairFrame)

        var handshakeFrame = Data()
        LyraProtoWriter.appendVarintField(1, value: 5, to: &handshakeFrame)
        LyraProtoWriter.appendVarintField(2, value: 6, to: &handshakeFrame)
        LyraProtoWriter.appendLengthDelimitedField(8, value: pairFrame, to: &handshakeFrame)

        var authFrame = Data()
        LyraProtoWriter.appendVarintField(1, value: upgradeHandshakeId, to: &authFrame)
        LyraProtoWriter.appendLengthDelimitedField(2, value: handshakeFrame, to: &authFrame)

        let inner = LogiConnInnerFrame(frameType: 6, payload: .upgrade(authFrame))
        let logiConn = LogiConnFrame(logiConnId: logiConnId, localNetId: 1, remoteNetId: peerNetId, inner: inner.serialized())
        let miFrame = MiConnectFrame(version: 0, logiConnFrames: [logiConn])
        send(frame: LyraMeshPack.Frame(packType: 2, payload: miFrame.serialized()), label: "upgrade_f5")
    }

    private struct AuthServerHello {
        var serverRandom: Data
        var publicKey: Data
    }

    private func parseAuthServerHello(_ data: Data) -> AuthServerHello? {
        func lengthDelimited(_ fieldNumber: Int, in data: Data) -> Data? {
            guard let fields = try? LyraProtoReader.readFields(from: data) else { return nil }
            return fields.first { $0.number == fieldNumber && $0.wireType == 2 }?.lengthDelimitedValue
        }
        func varint(_ fieldNumber: Int, in data: Data) -> UInt64? {
            guard let fields = try? LyraProtoReader.readFields(from: data) else { return nil }
            return fields.first { $0.number == fieldNumber && $0.wireType == 0 }?.varintValue
        }
        guard let handshakeFrame = lengthDelimited(2, in: data),
              let family = varint(1, in: handshakeFrame),
              let pairFrame = lengthDelimited(family == 5 ? 8 : 6, in: handshakeFrame),
              let serverNotify = lengthDelimited(3, in: pairFrame),
              let cipherSuite = lengthDelimited(1, in: serverNotify),
              let serverRandom = lengthDelimited(2, in: cipherSuite),
              let genericPublicKey = lengthDelimited(5, in: cipherSuite),
              let publicKey = lengthDelimited(2, in: genericPublicKey),
              publicKey.count == 65, publicKey.first == 0x04
        else {
            return nil
        }
        return AuthServerHello(serverRandom: serverRandom, publicKey: publicKey)
    }

    private func handleUpgradeResponse(_ data: Data) {
        guard let hello = parseAuthServerHello(data), let privateKey = keyAgreementKey else {
            DiagnosticsLog.warn("xiaomi.cast.trust_upgrade_parse_failed bytes=\(data.count)")
            return
        }
        authServerRandom = hello.serverRandom
        do {
            let peerPublicKey = try P256.KeyAgreement.PublicKey(x963Representation: hello.publicKey)
            let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: peerPublicKey)
            let secret = sharedSecret.withUnsafeBytes { Data($0) }
            channelKeyCS = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: SymmetricKey(data: secret),
                salt: LyraMeshResponder.hkdfSalt,
                info: authClientRandom + authServerRandom,
                outputByteCount: 32
            )
            channelKeySC = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: SymmetricKey(data: secret),
                salt: LyraMeshResponder.hkdfSalt,
                info: authServerRandom + authClientRandom,
                outputByteCount: 32
            )
            sendEncryptedAnnounces()
            queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, !self.cancelled else { return }
                self.sendLogiConnRequest()
            }
        } catch {
            fail(String(localized: "ECDH 失敗"))
        }
    }

    private func sendLogiConnRequest() {
        progress(.logiConnRequest, String(localized: "建立傳輸通道…"))
        channelId = UInt32.random(in: 100...60000)
        transKey = Self.randomBytes(32)
        transRandom = Self.randomBytes(32)
        let colonHex = Self.randomBytes(32).map { String(format: "%02x", $0) }.joined(separator: ":")

        var peerPortRequest = Data()
        LyraProtoWriter.appendVarintField(1, value: UInt64(channelId), to: &peerPortRequest)
        LyraProtoWriter.appendLengthDelimitedField(4, value: transKey, to: &peerPortRequest)
        LyraProtoWriter.appendLengthDelimitedField(5, value: transRandom, to: &peerPortRequest)

        var privateData = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &privateData)
        LyraProtoWriter.appendLengthDelimitedField(2, value: Data(Self.servicePackage.utf8), to: &privateData)
        LyraProtoWriter.appendLengthDelimitedField(3, value: Data(colonHex.utf8), to: &privateData)
        LyraProtoWriter.appendLengthDelimitedField(
            4, value: Data("AQH//wAAAB4AAQEAAAEAAAAUAAUAAAAAAAxBUUFBQUFBQUFBQT0=".utf8), to: &privateData
        )
        LyraProtoWriter.appendLengthDelimitedField(
            5,
            value: Data([
                0x01, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x15,
                0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0xFF, 0x00,
                0x00, 0x06, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x01
            ]),
            to: &privateData
        )
        LyraProtoWriter.appendVarintField(6, value: 1, to: &privateData)
        LyraProtoWriter.appendLengthDelimitedField(10, value: peerPortRequest, to: &privateData)

        var request = Data()
        LyraProtoWriter.appendLengthDelimitedField(2, value: Data(Self.serviceName.utf8), to: &request)
        LyraProtoWriter.appendLengthDelimitedField(3, value: privateData, to: &request)

        let requestInner = LogiConnInnerFrame(frameType: 1, payload: .request(request))
        sendEncryptedLogiConn(inner: requestInner, label: "logi_request")
    }

    private static let mitrustServiceName = "com.xiaomi.trustservice:mitrustservice"

    private func isMitrustSyncInfo(_ data: Data) -> Bool {
        guard let fields = try? LyraProtoReader.readFields(from: data) else { return false }
        return fields.contains {
            $0.number == 4 && $0.lengthDelimitedValue.flatMap { String(data: $0, encoding: .utf8) } == Self.mitrustServiceName
        }
    }

    private func handleMitrustSyncInfo(_ data: Data, logiConn: LogiConnFrame) {
        srvConnId = logiConn.logiConnId
        srvPeerNetId = logiConn.localNetId
        let fields = (try? LyraProtoReader.readFields(from: data)) ?? []
        var peerCred = Data()
        for field in fields where field.number == 5 {
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
        srvSignKey = privateKey
        var connId = Data()
        for _ in 0..<8 {
            connId.append(UInt8.random(in: 0...255))
        }
        srvOurConnId = connId
        if peerPubKey.count == 32,
           let peerKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPubKey),
           let sharedSecret = try? privateKey.sharedSecretFromKeyAgreement(with: peerKey)
        {
            let secret = sharedSecret.withUnsafeBytes { Data($0) }
            let ourPub = privateKey.publicKey.rawRepresentation
            let infos: [Data] = [
                peerConnId + connId,
                connId + peerConnId,
                peerPubKey + ourPub,
                ourPub + peerPubKey,
                Data()
            ]
            srvKeyCandidates = infos.map {
                HKDF<SHA256>.deriveKey(
                    inputKeyMaterial: SymmetricKey(data: secret),
                    salt: LyraMeshResponder.hkdfSalt,
                    info: $0,
                    outputByteCount: 32
                )
            }
        }
        var cred = Data()
        LyraProtoWriter.appendLengthDelimitedField(1, value: connId, to: &cred)
        LyraProtoWriter.appendLengthDelimitedField(2, value: privateKey.publicKey.rawRepresentation, to: &cred)
        var syncInfo = Data()
        LyraProtoWriter.appendVarintField(1, value: 15000, to: &syncInfo)
        LyraProtoWriter.appendVarintField(2, value: 48, to: &syncInfo)
        LyraProtoWriter.appendVarintField(3, value: 1, to: &syncInfo)
        LyraProtoWriter.appendLengthDelimitedField(4, value: Data(Self.mitrustServiceName.utf8), to: &syncInfo)
        LyraProtoWriter.appendLengthDelimitedField(5, value: cred, to: &syncInfo)
        LyraProtoWriter.appendLengthDelimitedField(
            6, value: LyraMeshResponder.officialMacSyncInfoSignature, to: &syncInfo
        )
        let inner = LogiConnInnerFrame(frameType: 5, payload: .syncInfo(syncInfo))
        let frame = LogiConnFrame(logiConnId: srvConnId, localNetId: 1, remoteNetId: srvPeerNetId, inner: inner.serialized())
        let miFrame = MiConnectFrame(version: 0, logiConnFrames: [frame])
        send(frame: LyraMeshPack.Frame(packType: 2, payload: miFrame.serialized()), label: "mitrust_sync_info")
        DiagnosticsLog.info("xiaomi.cast.mitrust_sync_info_rx connId=\(self.srvConnId) peerNetId=\(self.srvPeerNetId)")
    }

    private func handleMitrustUpgrade(_ data: Data) {
        func lengthDelimited(_ fieldNumber: Int, in data: Data) -> Data? {
            guard let fields = try? LyraProtoReader.readFields(from: data) else { return nil }
            return fields.first { $0.number == fieldNumber && $0.wireType == 2 }?.lengthDelimitedValue
        }
        func varint(_ fieldNumber: Int, in data: Data) -> UInt64? {
            guard let fields = try? LyraProtoReader.readFields(from: data) else { return nil }
            return fields.first { $0.number == fieldNumber && $0.wireType == 0 }?.varintValue
        }
        guard let handshakeFrame = lengthDelimited(2, in: data),
              let family = varint(1, in: handshakeFrame),
              let pairFrame = lengthDelimited(family == 5 ? 8 : 6, in: handshakeFrame),
              let clientNotify = lengthDelimited(2, in: pairFrame),
              let cipherSuite = lengthDelimited(1, in: clientNotify),
              let clientRandom = lengthDelimited(2, in: cipherSuite),
              let publicKeyMessage = lengthDelimited(5, in: cipherSuite),
              let publicKey = lengthDelimited(2, in: publicKeyMessage),
              publicKey.count == 65, publicKey.first == 0x04,
              let handshakeId = varint(1, in: data)
        else {
            DiagnosticsLog.warn("xiaomi.cast.mitrust_upgrade_parse_failed bytes=\(data.count)")
            return
        }
        let privateKey = P256.KeyAgreement.PrivateKey()
        srvKeyAgreementKey = privateKey
        srvClientRandom = clientRandom
        let serverRandom = Self.randomBytes(32)
        srvServerRandom = serverRandom
        do {
            let peerPublicKey = try P256.KeyAgreement.PublicKey(x963Representation: publicKey)
            let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: peerPublicKey)
            let secret = sharedSecret.withUnsafeBytes { Data($0) }
            srvKeyCS = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: SymmetricKey(data: secret),
                salt: LyraMeshResponder.hkdfSalt,
                info: clientRandom + serverRandom,
                outputByteCount: 32
            )
            srvKeySC = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: SymmetricKey(data: secret),
                salt: LyraMeshResponder.hkdfSalt,
                info: serverRandom + clientRandom,
                outputByteCount: 32
            )
        } catch {
            DiagnosticsLog.error("xiaomi.cast.mitrust_upgrade_ecdh_failed", error)
            return
        }

        var outPublicKeyMessage = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &outPublicKeyMessage)
        LyraProtoWriter.appendLengthDelimitedField(2, value: privateKey.publicKey.x963Representation, to: &outPublicKeyMessage)

        var outCipherSuite = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &outCipherSuite)
        LyraProtoWriter.appendLengthDelimitedField(2, value: serverRandom, to: &outCipherSuite)
        LyraProtoWriter.appendVarintField(3, value: 32, to: &outCipherSuite)
        LyraProtoWriter.appendVarintField(4, value: 2, to: &outCipherSuite)
        LyraProtoWriter.appendLengthDelimitedField(5, value: outPublicKeyMessage, to: &outCipherSuite)

        var serverNotify = Data()
        LyraProtoWriter.appendLengthDelimitedField(1, value: outCipherSuite, to: &serverNotify)

        var outPairFrame = Data()
        LyraProtoWriter.appendLengthDelimitedField(3, value: serverNotify, to: &outPairFrame)

        var handshake = Data()
        LyraProtoWriter.appendVarintField(1, value: family, to: &handshake)
        LyraProtoWriter.appendVarintField(2, value: 6, to: &handshake)
        LyraProtoWriter.appendLengthDelimitedField(family == 5 ? 8 : 6, value: outPairFrame, to: &handshake)

        var authFrame = Data()
        LyraProtoWriter.appendVarintField(1, value: handshakeId, to: &authFrame)
        LyraProtoWriter.appendLengthDelimitedField(2, value: handshake, to: &authFrame)

        let inner = LogiConnInnerFrame(frameType: 6, payload: .upgrade(authFrame))
        let frame = LogiConnFrame(logiConnId: srvConnId, localNetId: 1, remoteNetId: srvPeerNetId, inner: inner.serialized())
        let miFrame = MiConnectFrame(version: 0, logiConnFrames: [frame])
        send(frame: LyraMeshPack.Frame(packType: 2, payload: miFrame.serialized()), label: "mitrust_upgrade")
        DiagnosticsLog.info("xiaomi.cast.mitrust_upgrade_tx")
    }

    private func mitrustDecrypt(_ logiConn: LogiConnFrame, key: SymmetricKey) -> LogiConnInnerFrame? {
        let inner = logiConn.inner
        guard inner.count > 28 else { return nil }
        let nonce = inner.prefix(12)
        let ciphertext = inner.dropFirst(12).dropLast(16)
        let tag = inner.suffix(16)
        guard let sealedBox = try? AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: Data(nonce)),
            ciphertext: Data(ciphertext),
            tag: Data(tag)
        ), let plaintext = try? AES.GCM.open(sealedBox, using: key) else {
            return nil
        }
        return LogiConnInnerFrame(parsing: plaintext)
    }

    private func mitrustSendEncrypted(inner: LogiConnInnerFrame, label: String) {
        guard let srvKeySC else { return }
        do {
            let nonce = AES.GCM.Nonce()
            let sealed = try AES.GCM.seal(inner.serialized(), using: srvKeySC, nonce: nonce)
            var encryptedInner = Data()
            encryptedInner.append(contentsOf: nonce.withUnsafeBytes { Data($0) })
            encryptedInner.append(sealed.ciphertext)
            encryptedInner.append(sealed.tag)
            let frame = LogiConnFrame(
                logiConnId: srvConnId,
                localNetId: 1,
                remoteNetId: srvPeerNetId,
                flag: true,
                inner: encryptedInner
            )
            let miFrame = MiConnectFrame(version: 0, logiConnFrames: [frame])
            send(frame: LyraMeshPack.Frame(packType: 2, payload: miFrame.serialized()), label: label)
        } catch {
            DiagnosticsLog.error("xiaomi.cast.mitrust_encrypt_failed label=\(label)", error)
        }
    }

    private func handleMitrustEncrypted(_ logiConn: LogiConnFrame) {
        for key in [srvKeyCS, srvKeySC].compactMap({ $0 }) + srvKeyCandidates {
            guard let inner = mitrustDecrypt(logiConn, key: key) else {
                continue
            }
            if case .request = inner.payload {
                DiagnosticsLog.info("xiaomi.cast.mitrust_logi_request_rx")
                let response = LogiConnInnerFrame(frameType: 2, payload: .response(Data()))
                mitrustSendEncrypted(inner: response, label: "mitrust_logi_response")
            } else {
                DiagnosticsLog.info("xiaomi.cast.mitrust_logi_other frameType=\(inner.frameType)")
            }
            return
        }
        DiagnosticsLog.warn("xiaomi.cast.mitrust_decrypt_failed bytes=\(logiConn.inner.count)")
    }

    private func handleMitrustPeerPortRequest(_ body: Data) {
        let fields = (try? LyraProtoReader.readFields(from: body)) ?? []
        var channelId: UInt64 = 0
        var transKey = Data()
        for field in fields {
            switch (field.number, field.wireType) {
            case (1, 0): channelId = field.varintValue ?? 0
            case (4, 2): transKey = field.lengthDelimitedValue ?? Data()
            default: continue
            }
        }
        guard !transKey.isEmpty else {
            DiagnosticsLog.warn("xiaomi.cast.mitrust_peer_port_bad_request")
            return
        }
        let socket = LyraChannelSocket()
        socket.onMessage = { message, _ in
            DiagnosticsLog.info(
                "xiaomi.cast.mitrust_channel_rx bytes=\(message.count) " +
                    "hex=\(message.prefix(48).map { String(format: "%02x", $0) }.joined())"
            )
        }
        socket.onNegotiated = { serverChannelId, mtu in
            DiagnosticsLog.info("xiaomi.cast.mitrust_channel_negotiated serverChannelId=\(serverChannelId) mtu=\(mtu)")
        }
        do {
            try socket.start(socketKey: transKey)
            srvChannelSocket = socket
            srvChannelId = UInt32(channelId)
        } catch {
            DiagnosticsLog.error("xiaomi.cast.mitrust_channel_start_failed", error)
            return
        }
        guard let port = socket.boundPort ?? {
            let semaphore = DispatchSemaphore(value: 0)
            var bound: UInt16?
            socket.onStateChanged = { state in
                if case .ready = state {
                    bound = socket.boundPort
                    semaphore.signal()
                }
            }
            _ = semaphore.wait(timeout: .now() + 1)
            return bound
        }() else {
            DiagnosticsLog.warn("xiaomi.cast.mitrust_channel_no_port")
            return
        }
        var responseBody = Data()
        LyraProtoWriter.appendVarintField(2, value: UInt64(srvChannelId), to: &responseBody)
        LyraProtoWriter.appendVarintField(3, value: UInt64(port), to: &responseBody)
        let command = LyraChannelProtocol.encode(type: .responseOfPeerPort, body: responseBody)
        guard let srvKeySC else { return }
        do {
            let nonce = AES.GCM.Nonce()
            let sealed = try AES.GCM.seal(command, using: srvKeySC, nonce: nonce)
            var payload = Data()
            payload.append(UInt8(srvPeerNetId & 0xFF))
            payload.append(1)
            payload.append(contentsOf: nonce.withUnsafeBytes { Data($0) })
            payload.append(sealed.ciphertext)
            payload.append(sealed.tag)
            send(frame: LyraMeshPack.Frame(packType: 5, payload: payload), label: "mitrust_peer_port_response")
            DiagnosticsLog.info("xiaomi.cast.mitrust_peer_port_tx port=\(port) channelId=\(self.srvChannelId)")
        } catch {
            DiagnosticsLog.error("xiaomi.cast.mitrust_peer_port_failed", error)
        }
    }

    private static func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { buffer in
            if let baseAddress = buffer.baseAddress {
                arc4random_buf(baseAddress, count)
            }
        }
        return data
    }

    private func sendEncryptedLogiConn(inner: LogiConnInnerFrame, label: String) {
        guard let channelKeyCS else {
            fail(String(localized: "缺少通道金鑰"))
            return
        }
        do {
            let nonce = AES.GCM.Nonce()
            let sealed = try AES.GCM.seal(inner.serialized(), using: channelKeyCS, nonce: nonce)
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
            fail(String(localized: "通道加密失敗"))
        }
    }

    private func decryptLogiConnInner(_ logiConn: LogiConnFrame) -> LogiConnInnerFrame? {
        let inner = logiConn.inner
        guard inner.count > 28 else { return nil }
        let nonce = inner.prefix(12)
        let ciphertext = inner.dropFirst(12).dropLast(16)
        let tag = inner.suffix(16)
        for key in [channelKeySC, channelKeyCS].compactMap({ $0 }) {
            guard let sealedBox = try? AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: Data(nonce)),
                ciphertext: Data(ciphertext),
                tag: Data(tag)
            ), let plaintext = try? AES.GCM.open(sealedBox, using: key) else {
                continue
            }
            return LogiConnInnerFrame(parsing: plaintext)
        }
        return nil
    }

    private func handle(frame: LyraMeshPack.Frame, endpoint: NWEndpoint, reply: LyraMeshSocket.ReplyHandler) {
        lastProgress = Date()
        DiagnosticsLog.info("xiaomi.cast.trust_frame_rx packType=\(frame.packType) bytes=\(frame.payload.count)")
        if frame.packType == 5 {
            handlePayloadV2(frame: frame)
            return
        }
        if frame.packType == 4 {
            handleLogiPayload(frame: frame)
            return
        }
        guard let miFrame = MiConnectFrame(parsing: frame.payload) else {
            return
        }
        if let physConn = miFrame.physConnFrame {
            handlePhysConn(physConn, frame: frame, endpoint: endpoint, reply: reply)
        }
        for logiConn in miFrame.logiConnFrames {
            handleLogiConn(logiConn, frame: frame, reply: reply)
        }
    }

    private func handlePhysConn(
        _ physConn: PhysConnFrame,
        frame: LyraMeshPack.Frame,
        endpoint: NWEndpoint,
        reply: LyraMeshSocket.ReplyHandler
    ) {
        switch physConn.payload {
        case .syncDeviceInfoResponse:
            if stage == .physSync {
                if let separator = endpoint.debugDescription.lastIndex(of: ":") {
                    let replyHost = String(endpoint.debugDescription[endpoint.debugDescription.startIndex..<separator])
                    if let replyPort = UInt16(endpoint.debugDescription[endpoint.debugDescription.index(after: separator)...]),
                       !replyHost.isEmpty
                    {
                        host = replyHost
                        port = replyPort
                        endpoints = [(replyHost, replyPort)]
                        LyraMeshResponder.recordPhoneEndpoint("\(replyHost):\(replyPort)")
                        DiagnosticsLog.info("xiaomi.cast.trust_endpoint_locked host=\(replyHost) port=\(replyPort)")
                    }
                }
                progress(.cookie, String(localized: "cookie 交握…"))
                sendCookie(phase: 1)
            }
        case let .keepAliveResponse(responseData) where physConn.field2 == 5:
            guard stage == .cookie else { return }
            let fields = (try? LyraProtoReader.readFields(from: responseData)) ?? []
            var phase: UInt64 = 0
            for field in fields where field.number == 2 && field.wireType == 0 {
                phase = field.varintValue ?? 0
            }
            if phase < 2 {
                sendCookie(phase: phase + 1)
            } else {
                sendSyncAuthHello()
            }
        case .keepAliveRequest:
            let tick = UInt64(LyraMeshSocket.tick())
            var responsePayload = Data()
            LyraProtoWriter.appendVarintField(1, value: tick, to: &responsePayload)
            LyraProtoWriter.appendVarintField(2, value: 2, to: &responsePayload)
            LyraProtoWriter.appendVarintField(3, value: tick, to: &responsePayload)
            let responsePhysConn = PhysConnFrame(field2: 5, payload: .keepAliveResponse(responsePayload))
            let miResponse = MiConnectFrame(version: 0, logiConnFrames: [], physConnFrame: responsePhysConn)
            try? reply(LyraMeshPack.Frame(packType: frame.packType, payload: miResponse.serialized()))
        default:
            break
        }
    }

    private func handleLogiConn(
        _ logiConn: LogiConnFrame,
        frame: LyraMeshPack.Frame,
        reply: LyraMeshSocket.ReplyHandler
    ) {
        if logiConn.flag {
            if srvConnId != 0, logiConn.logiConnId == srvConnId {
                handleMitrustEncrypted(logiConn)
                return
            }
            guard let inner = decryptLogiConnInner(logiConn) else {
                DiagnosticsLog.warn("xiaomi.cast.trust_logi_enc_decrypt_failed bytes=\(logiConn.inner.count)")
                return
            }
            if case .response = inner.payload {
                DiagnosticsLog.info("xiaomi.cast.trust_logi_response_rx")
                let ack = LogiConnInnerFrame(frameType: 3, payload: .responseAck(Data()))
                sendEncryptedLogiConn(inner: ack, label: "logi_response_ack")
                sendEncryptedAnnounces()
                queue.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    guard let self, !self.cancelled else { return }
                    self.sendPeerPortRequest()
                    self.progress(.channelWait, String(localized: "等待手機通道端口…"))
                }
            } else {
                DiagnosticsLog.info(
                    "xiaomi.cast.trust_logi_enc_other frameType=\(inner.frameType) bytes=\(logiConn.inner.count)"
                )
            }
            return
        }
        guard let inner = LogiConnInnerFrame(parsing: logiConn.inner) else {
            return
        }
        switch inner.payload {
        case let .syncInfo(syncInfoData):
            if isMitrustSyncInfo(syncInfoData) {
                handleMitrustSyncInfo(syncInfoData, logiConn: logiConn)
            } else {
                handleSyncInfoResponse(syncInfoData, logiConn: logiConn)
            }
        case let .upgrade(upgradeData):
            if srvConnId != 0, logiConn.logiConnId == srvConnId {
                handleMitrustUpgrade(upgradeData)
            } else {
                handleUpgradeResponse(upgradeData)
            }
        case let .disconnect(payload):
            DiagnosticsLog.info(
                "xiaomi.cast.trust_logi_disconnect bytes=\(payload.count) " +
                    "hex=\(payload.prefix(32).map { String(format: "%02x", $0) }.joined())"
            )
        default:
            DiagnosticsLog.info(
                "xiaomi.cast.trust_logi_other frameType=\(inner.frameType) bytes=\(logiConn.inner.count)"
            )
        }
    }

    private func sendEncryptedAnnounces() {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let deviceInfo = LyraTrustedDeviceInfo.deviceInfoFrame(
            deviceName: displayName,
            deviceType: 4,
            deviceId: deviceIdHex,
            uidHash: "61F2",
            hwModel: Self.hardwareModel(),
            lyraVersion: "5.1.208.10.fullCnRelease.0512164",
            services: [
                LyraTrustedDeviceInfo.Service(name: "miLyraShare", package: "com.edgelink.mac"),
                LyraTrustedDeviceInfo.Service(name: "miShareBasic", package: "com.edgelink.mac"),
                LyraTrustedDeviceInfo.Service(name: "miLyraShareTransfer", package: "com.edgelink.mac"),
                LyraTrustedDeviceInfo.Service(name: "cast", package: Self.servicePackage)
            ],
            ipAddress: Self.primaryIPv4Address(),
            osVersion: "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
        )
        let inner = LyraTrustedDeviceInfo.plaintextAnnounce(deviceInfo: deviceInfo)
        for (index, key) in syncKeyCandidates.enumerated() {
            do {
                let nonce = AES.GCM.Nonce()
                let sealed = try AES.GCM.seal(inner, using: key, nonce: nonce)
                var payload = Data()
                payload.append(UInt8(peerNetId & 0xFF))
                payload.append(1)
                payload.append(contentsOf: nonce.withUnsafeBytes { Data($0) })
                payload.append(sealed.ciphertext)
                payload.append(sealed.tag)
                send(frame: LyraMeshPack.Frame(packType: 5, payload: payload), label: "announce_c\(index)")
            } catch {
                DiagnosticsLog.error("xiaomi.cast.trust_announce_failed", error)
            }
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

    private func handleSyncInfoResponse(_ data: Data, logiConn: LogiConnFrame) {
        let fields = (try? LyraProtoReader.readFields(from: data)) ?? []
        var serviceName = ""
        var peerCred = Data()
        for field in fields {
            switch (field.number, field.wireType) {
            case (4, 2):
                serviceName = field.lengthDelimitedValue.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            case (5, 2):
                peerCred = field.lengthDelimitedValue ?? Data()
            default:
                continue
            }
        }
        guard stage == .syncAuth else {
            DiagnosticsLog.info(
                "xiaomi.cast.trust_sync_info_ignored stage=\(self.stage) service=\(serviceName)"
            )
            return
        }
        peerNetId = logiConn.localNetId
        DiagnosticsLog.info(
            "xiaomi.cast.trust_sync_info_rx peerNetId=\(peerNetId) service=\(serviceName) credBytes=\(peerCred.count)"
        )
        var peerConnId = Data()
        var peerPubKey = Data()
        for field in (try? LyraProtoReader.readFields(from: peerCred)) ?? [] {
            switch (field.number, field.wireType) {
            case (1, 2): peerConnId = field.lengthDelimitedValue ?? Data()
            case (2, 2): peerPubKey = field.lengthDelimitedValue ?? Data()
            default: continue
            }
        }
        deriveSyncKeys(peerConnId: peerConnId, peerPubKey: peerPubKey)
        sendUpgrade()
    }

    private func deriveSyncKeys(peerConnId: Data, peerPubKey: Data) {
        guard let privateKey = syncAuthPrivateKey, peerPubKey.count == 32,
              let peerKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPubKey),
              let sharedSecret = try? privateKey.sharedSecretFromKeyAgreement(with: peerKey)
        else {
            return
        }
        let secret = sharedSecret.withUnsafeBytes { Data($0) }
        let ours = syncAuthOurConnId
        let their = peerConnId
        let ourPub = privateKey.publicKey.rawRepresentation
        let infos: [Data] = [
            their + ours,
            ours + their,
            peerPubKey + ourPub,
            ourPub + peerPubKey,
            Data()
        ]
        syncKeyCandidates = infos.map {
            HKDF<SHA256>.deriveKey(
                inputKeyMaterial: SymmetricKey(data: secret),
                salt: LyraMeshResponder.hkdfSalt,
                info: $0,
                outputByteCount: 32
            )
        }
    }

    private func handleLogiPayload(frame: LyraMeshPack.Frame) {
        let body = frame.payload
        if let miFrame = MiConnectFrame(parsing: body) {
            for logiConn in miFrame.logiConnFrames {
                if let (header, commandBody) = try? LyraChannelProtocol.decode(logiConn.inner) {
                    if header.type == LyraChannelProtocol.CommandType.responseOfPeerPort.rawValue {
                        handlePeerPortResponse(commandBody)
                        return
                    }
                    if header.type == LyraChannelProtocol.CommandType.requestOfPeerPort.rawValue {
                        handleMitrustPeerPortRequest(commandBody)
                        return
                    }
                }
            }
        }
        for headerBytes in 1...2 where body.count > headerBytes + 28 {
            let nonce = body[body.index(body.startIndex, offsetBy: headerBytes)..<body.index(body.startIndex, offsetBy: headerBytes + 12)]
            let ciphertext = body[body.index(body.startIndex, offsetBy: headerBytes + 12)..<body.index(body.endIndex, offsetBy: -16)]
            let tag = body[body.index(body.endIndex, offsetBy: -16)..<body.endIndex]
            guard let sealedBox = try? AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: Data(nonce)),
                ciphertext: Data(ciphertext),
                tag: Data(tag)
            ) else {
                continue
            }
            var keys: [SymmetricKey] = [channelKeySC, channelKeyCS].compactMap { $0 }
            keys.append(contentsOf: syncKeyCandidates)
            keys.append(contentsOf: [srvKeyCS, srvKeySC].compactMap { $0 })
            keys.append(contentsOf: srvKeyCandidates)
            for key in keys {
                guard let plaintext = try? AES.GCM.open(sealedBox, using: key) else {
                    continue
                }
                if let (header, commandBody) = try? LyraChannelProtocol.decode(plaintext) {
                    if header.type == LyraChannelProtocol.CommandType.responseOfPeerPort.rawValue {
                        handlePeerPortResponse(commandBody)
                        return
                    }
                    if header.type == LyraChannelProtocol.CommandType.requestOfPeerPort.rawValue {
                        handleMitrustPeerPortRequest(commandBody)
                        return
                    }
                }
            }
        }
    }

    private func handlePayloadV2(frame: LyraMeshPack.Frame) {
        let body = frame.payload
        guard body.count > 30 else {
            DiagnosticsLog.warn("xiaomi.cast.trust_payload_v2_short bytes=\(body.count)")
            return
        }
        let flag = body[body.index(body.startIndex, offsetBy: 1)]
        guard flag == 1 else {
            DiagnosticsLog.warn("xiaomi.cast.trust_payload_v2_flag flag=\(flag) bytes=\(body.count)")
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
            DiagnosticsLog.warn("xiaomi.cast.trust_payload_v2_sealed_box_invalid bytes=\(body.count)")
            return
        }
        var keys: [SymmetricKey] = [channelKeySC, channelKeyCS].compactMap { $0 }
        keys.append(contentsOf: syncKeyCandidates)
        keys.append(contentsOf: [srvKeyCS, srvKeySC].compactMap { $0 })
        keys.append(contentsOf: srvKeyCandidates)
        for key in keys {
            guard let plaintext = try? AES.GCM.open(sealedBox, using: key) else {
                continue
            }
            guard let (header, commandBody) = try? LyraChannelProtocol.decode(plaintext) else {
                DiagnosticsLog.warn("xiaomi.cast.trust_payload_v2_decode_failed bytes=\(plaintext.count)")
                return
            }
            if header.type == LyraChannelProtocol.CommandType.responseOfPeerPort.rawValue {
                handlePeerPortResponse(commandBody)
            } else if header.type == LyraChannelProtocol.CommandType.requestOfPeerPort.rawValue {
                handleMitrustPeerPortRequest(commandBody)
            } else {
                DiagnosticsLog.info("xiaomi.cast.trust_payload_v2_unknown_type type=\(header.type)")
            }
            return
        }
        DiagnosticsLog.warn("xiaomi.cast.trust_payload_v2_decrypt_failed bytes=\(body.count) keys=\(keys.count)")
    }

    private func sendPeerPortRequest() {
        guard let channelKeyCS else { return }
        var body = Data()
        LyraProtoWriter.appendVarintField(1, value: UInt64(channelId), to: &body)
        LyraProtoWriter.appendLengthDelimitedField(4, value: transKey, to: &body)
        LyraProtoWriter.appendLengthDelimitedField(5, value: transRandom, to: &body)
        let command = LyraChannelProtocol.encode(type: .requestOfPeerPort, body: body)
        do {
            let nonce = AES.GCM.Nonce()
            let sealed = try AES.GCM.seal(command, using: channelKeyCS, nonce: nonce)
            var payload = Data()
            payload.append(UInt8(peerNetId & 0xFF))
            payload.append(1)
            payload.append(contentsOf: nonce.withUnsafeBytes { Data($0) })
            payload.append(sealed.ciphertext)
            payload.append(sealed.tag)
            send(frame: LyraMeshPack.Frame(packType: 5, payload: payload), label: "peer_port_request")
        } catch {
            DiagnosticsLog.error("xiaomi.cast.trust_peer_port_request_failed", error)
        }
    }

    private func handlePeerPortResponse(_ body: Data) {
        guard stage == .channelWait || stage == .logiConnRequest else {
            return
        }
        let fields = (try? LyraProtoReader.readFields(from: body)) ?? []
        var port: UInt64 = 0
        var serverChannelId: UInt64 = 0
        for field in fields {
            switch (field.number, field.wireType) {
            case (2, 0): serverChannelId = field.varintValue ?? 0
            case (3, 0): port = field.varintValue ?? 0
            default: continue
            }
        }
        guard port != 0, let nwPort = UInt16(exactly: port) else {
            DiagnosticsLog.warn("xiaomi.cast.trust_peer_port_invalid")
            return
        }
        self.serverChannelId = UInt32(serverChannelId)
        progress(.channelNegotiate, String(localized: "通道協商…"))
        DiagnosticsLog.info("xiaomi.cast.trust_peer_port port=\(port) serverChannelId=\(serverChannelId)")
        let socket = LyraChannelSocket()
        socket.suppressNegotiationReply = true
        socket.debugHandler = { message in
            DiagnosticsLog.info("xiaomi.cast.trust_channel.\(message)")
        }
        socket.onDecryptFailure = { reason in
            DiagnosticsLog.warn("xiaomi.cast.trust_channel_decrypt_failed \(reason)")
        }
        socket.onNegotiated = { [weak self] serverChannelId, mtu in
            guard let self else { return }
            DiagnosticsLog.info("xiaomi.cast.trust_channel_negotiated serverChannelId=\(serverChannelId) mtu=\(mtu)")
            self.channelReady = true
            self.progress(.ready, String(localized: "通道已建立"))
            DispatchQueue.main.async {
                self.trustManager.sendFrame = { [weak self] frame in
                    self?.sendChannelMessage(frame)
                }
                self.trustManager.onAuthActionSent = { [weak self] in
                    self?.queue.asyncAfter(deadline: .now() + 10.0) { [weak self] in
                        self?.teardownPhysAfterAuth()
                    }
                }
                self.trustManager.onAuthEventHandled = { [weak self] in
                    self?.queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        self?.teardownPhysAfterAuth()
                    }
                }
                self.trustManager.start()
            }
        }
        socket.onMessage = { [weak self] message, _ in
            self?.handleChannelMessage(message)
        }
        do {
            try socket.connect(host: host, port: nwPort, socketKey: transKey)
            channelSocket = socket
        } catch {
            fail(String(localized: "通道連接失敗"))
            return
        }
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.sendChannelNegotiation(attempt: 0)
        }
    }

    private func sendChannelNegotiation(attempt: Int) {
        guard !cancelled, !channelReady, attempt < 3, let socket = channelSocket else { return }
        do {
            try socket.sendClientNegotiation(channelId: serverChannelId, version: 1, mtu: 0xFF00)
        } catch {
            DiagnosticsLog.error("xiaomi.cast.trust_channel_negotiation_failed", error)
        }
        queue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.sendChannelNegotiation(attempt: attempt + 1)
        }
    }

    private func sendChannelMessage(_ message: Data) {
        do {
            try channelSocket?.sendVariant(
                channelFrame: LyraChannelSocket.wrapChannelFrame(message),
                key: transKey,
                singleLayer: true
            )
        } catch {
            DiagnosticsLog.error("xiaomi.cast.trust_channel_send_failed", error)
        }
    }

    private func handleChannelMessage(_ message: Data) {
        lastProgress = Date()
        var frame = message
        if let (tag, child) = try? LyraExpressTLVParser.parseOneOf(message), tag == 1,
           let payloadNode = LyraExpressTLVParser.firstChild(0, in: LyraExpressTLVParser.children(of: child))
        {
            frame = payloadNode.payload
        }
        guard let (type, _) = try? DuoScreenProtocolV1.decodeFrame(frame) else {
            DiagnosticsLog.warn(
                "xiaomi.cast.trust_channel_rx_bad bytes=\(message.count) " +
                    "hex=\(message.prefix(24).map { String(format: "%02x", $0) }.joined())"
            )
            return
        }
        DiagnosticsLog.info("xiaomi.cast.trust_channel_rx type=\(type) bytes=\(frame.count)")
        DispatchQueue.main.async { [weak self] in
            self?.trustManager.handleFrame(frame)
        }
    }
}
