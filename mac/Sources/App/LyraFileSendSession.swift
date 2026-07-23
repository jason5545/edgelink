import CryptoKit
import EdgeLinkKit
import Foundation
import Network

final class LyraFileSendSession {
    struct OutgoingFile {
        let url: URL
        let id: String
        let name: String
        let size: Int64
        let mimeType: String
        let createTime: Int64
        let modifyTime: Int64
    }

    enum Stage: Equatable {
        case physSync
        case cookie
        case logiSyncOld
        case syncAuth
        case syncAuthCred
        case upgrade
        case logiConnRequest
        case channelWait
        case channelNegotiate
        case expressHandshakeWait
        case fileRequestWait
        case streamBeginWait
        case streaming
        case streamEndWait
        case completeWait
        case done
        case failed(String)
    }

    var onStatus: ((String) -> Void)?

    private let host: String
    private let port: UInt16
    private let deviceIdHex: String
    private let displayName: String
    private let files: [OutgoingFile]
    private let queue = DispatchQueue(label: "edgelink.lyra.send", qos: .userInitiated)

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
    private var syncAuthSharedSecret = Data()
    private var syncKeyCandidates: [SymmetricKey] = []

    private var keyAgreementKey: P256.KeyAgreement.PrivateKey?
    private var authClientRandom = Data()
    private var authServerRandom = Data()
    private var authSharedSecret = Data()
    private var channelKeyCS: SymmetricKey?
    private var channelKeySC: SymmetricKey?
    private var upgradeHandshakeId: UInt64 = 0

    private var channelId: UInt32 = 0
    private var serverChannelId: UInt32 = 0
    private var serverKey = Data()
    private var transKey = Data()
    private var transRandom = Data()
    private var colonHexKey = Data()

    private var channelSocket: LyraChannelSocket?
    private var channelReady = false

    private var expressDataKey = Data()
    private var expressDataPort: UInt32 = 0
    private var expressConnCount = 8
    private var expressConnections: [NWConnection] = []
    private var expressNextConn = 0

    private let requestId: UInt64
    private let jobId = UUID().uuidString
    private var eventBytesBuffer = Data()
    private var currentFileIndex = 0
    private var currentStreamId: UInt32 = 0
    private var nextStreamId: UInt32 = 1
    private var currentOffset: Int64 = 0
    private var currentFileHandle: FileHandle?

    private static let chunkSize = 64 * 1024

    init(host: String, port: UInt16, deviceIdHex: String, displayName: String, files: [OutgoingFile]) {
        self.host = host
        self.port = port
        self.deviceIdHex = deviceIdHex
        self.displayName = displayName
        self.files = files
        self.requestId = UInt64.random(in: 1...1_000_000_000)
    }

    static func makeFiles(from urls: [URL]) -> [OutgoingFile] {
        urls.map { url in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey])
            return OutgoingFile(
                url: url,
                id: UUID().uuidString,
                name: url.lastPathComponent,
                size: Int64(values?.fileSize ?? 0),
                mimeType: Self.mimeType(for: url),
                createTime: Int64(values?.creationDate?.timeIntervalSince1970 ?? 0),
                modifyTime: Int64(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)
            )
        }
    }

    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "heic": return "image/heic"
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "pdf": return "application/pdf"
        case "txt": return "text/plain"
        case "zip": return "application/zip"
        default: return "application/octet-stream"
        }
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.socket.onFrame = { [weak self] frame, endpoint, reply in
                self?.handle(frame: frame, endpoint: endpoint, reply: reply)
            }
            self.socket.onRawDatagram = { datagram, endpoint in
                DiagnosticsLog.info(
                    "xiaomi.mishare.send_mesh_rx from=\(endpoint.debugDescription) bytes=\(datagram.count) " +
                        "hex=\(datagram.prefix(32).map { String(format: "%02x", $0) }.joined())"
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
            if self.stage != .done, Date().timeIntervalSince(self.lastProgress) > 30 {
                self.fail(String(localized: "逾時（stage=\(self.stage)）"))
            }
        }
        watchdog = timer
        timer.resume()
    }

    private func progress(_ newStage: Stage, _ message: String) {
        lastProgress = Date()
        stage = newStage
        DiagnosticsLog.info("xiaomi.mishare.send_stage stage=\(newStage) \(message)")
        onStatus?(message)
    }

    private func fail(_ message: String) {
        DiagnosticsLog.warn("xiaomi.mishare.send_failed stage=\(stage) reason=\(message)")
        stage = .failed(message)
        onStatus?(String(localized: "傳送失敗：\(message)"))
        finishLocked()
    }

    private func finishLocked() {
        cancelled = true
        watchdog?.cancel()
        watchdog = nil
        currentFileHandle?.closeFile()
        currentFileHandle = nil
        for connection in expressConnections {
            connection.cancel()
        }
        expressConnections.removeAll()
        channelSocket?.stop()
        channelSocket = nil
        socket.stop()
    }

    private func send(frame: LyraMeshPack.Frame, label: String) {
        do {
            try socket.send(frame: frame, to: host, port: port)
            DiagnosticsLog.info("xiaomi.mishare.send_tx label=\(label) to=\(host):\(port)")
        } catch {
            DiagnosticsLog.error("xiaomi.mishare.send_tx_failed label=\(label)", error)
        }
    }

    private func sendPhysSyncRequest(attempt: Int = 0) {
        if attempt == 0 {
            progress(.physSync, String(localized: "連接手機…"))
        }
        guard attempt < 5, stage == .physSync, !cancelled else { return }
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

    private func sendLogiSyncInfoOld() {
        progress(.logiSyncOld, String(localized: "同步裝置資訊…"))
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
        LyraProtoWriter.appendVarintField(1, value: 10000, to: &syncInfo)
        LyraProtoWriter.appendVarintField(2, value: 40, to: &syncInfo)
        LyraProtoWriter.appendLengthDelimitedField(5, value: cred, to: &syncInfo)
        let inner = LogiConnInnerFrame(frameType: 5, payload: .syncInfo(syncInfo))
        let logiConn = LogiConnFrame(logiConnId: logiConnId, localNetId: 1, inner: inner.serialized())
        let miFrame = MiConnectFrame(version: 0, logiConnFrames: [logiConn])
        send(frame: LyraMeshPack.Frame(packType: 2, payload: miFrame.serialized()), label: "logi_sync_old")
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
        LyraProtoWriter.appendLengthDelimitedField(
            4, value: Data("com.miui.mishare.connectivity:miLyraShareTransfer".utf8), to: &syncInfo
        )
        LyraProtoWriter.appendLengthDelimitedField(5, value: cred, to: &syncInfo)
        LyraProtoWriter.appendLengthDelimitedField(
            6, value: LyraMeshResponder.officialMacSyncInfoSignature, to: &syncInfo
        )
        let inner = LogiConnInnerFrame(frameType: 5, payload: .syncInfo(syncInfo))
        let logiConn = LogiConnFrame(logiConnId: logiConnId, localNetId: 1, remoteNetId: peerNetId, inner: inner.serialized())
        let miFrame = MiConnectFrame(version: 0, logiConnFrames: [logiConn])
        send(frame: LyraMeshPack.Frame(packType: 2, payload: miFrame.serialized()), label: "sync_auth_hello")
    }

    private func deriveSyncKeys(peerConnId: Data, peerPubKey: Data) {
        guard let privateKey = syncAuthPrivateKey, peerPubKey.count == 32,
              let peerKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPubKey),
              let sharedSecret = try? privateKey.sharedSecretFromKeyAgreement(with: peerKey)
        else {
            return
        }
        let secret = sharedSecret.withUnsafeBytes { Data($0) }
        syncAuthSharedSecret = secret
        let ours = syncAuthOurConnId
        let theirs = peerConnId
        let ourPub = privateKey.publicKey.rawRepresentation
        let infos: [Data] = [
            theirs + ours,
            ours + theirs,
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

    private func sendSyncAuthCred() {
        progress(.syncAuthCred, String(localized: "同步憑證…"))
        let inner = LogiConnInnerFrame(
            frameType: 4,
            payload: .disconnect(LyraMeshResponder.officialMacSyncAuthCredential)
        )
        let logiConn = LogiConnFrame(logiConnId: logiConnId, localNetId: 1, remoteNetId: peerNetId, inner: inner.serialized())
        let miFrame = MiConnectFrame(version: 0, logiConnFrames: [logiConn])
        send(frame: LyraMeshPack.Frame(packType: 2, payload: miFrame.serialized()), label: "sync_auth_cred")
    }

    private func sendSyncAuthConfirm() {
        let confirm = syncAuthSharedSecret.isEmpty ? Data(count: 32) : syncAuthSharedSecret
        let inner = LogiConnInnerFrame(frameType: 4, payload: .disconnect(confirm))
        let logiConn = LogiConnFrame(logiConnId: logiConnId, localNetId: 1, remoteNetId: peerNetId, inner: inner.serialized())
        let miFrame = MiConnectFrame(version: 0, logiConnFrames: [logiConn])
        send(frame: LyraMeshPack.Frame(packType: 2, payload: miFrame.serialized()), label: "sync_auth_confirm")
    }

    private func sendUpgrade(family: UInt64) {
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

        let cipher1: UInt64 = family == 5 ? 32 : 16
        let cipher2: UInt64 = family == 5 ? 2 : 8
        let messageClass: UInt64 = family == 5 ? 6 : 4

        var publicKeyMessage = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &publicKeyMessage)
        LyraProtoWriter.appendLengthDelimitedField(2, value: privateKey.publicKey.x963Representation, to: &publicKeyMessage)

        var cipherSuite = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &cipherSuite)
        LyraProtoWriter.appendLengthDelimitedField(2, value: clientRandom, to: &cipherSuite)
        LyraProtoWriter.appendVarintField(3, value: cipher1, to: &cipherSuite)
        LyraProtoWriter.appendVarintField(4, value: cipher2, to: &cipherSuite)
        LyraProtoWriter.appendLengthDelimitedField(5, value: publicKeyMessage, to: &cipherSuite)

        var clientNotify = Data()
        LyraProtoWriter.appendLengthDelimitedField(1, value: cipherSuite, to: &clientNotify)

        var pairFrame = Data()
        LyraProtoWriter.appendLengthDelimitedField(2, value: clientNotify, to: &pairFrame)

        var handshakeFrame = Data()
        LyraProtoWriter.appendVarintField(1, value: family, to: &handshakeFrame)
        LyraProtoWriter.appendVarintField(2, value: messageClass, to: &handshakeFrame)
        LyraProtoWriter.appendLengthDelimitedField(family == 5 ? 8 : 6, value: pairFrame, to: &handshakeFrame)

        var authFrame = Data()
        LyraProtoWriter.appendVarintField(1, value: upgradeHandshakeId, to: &authFrame)
        LyraProtoWriter.appendLengthDelimitedField(2, value: handshakeFrame, to: &authFrame)

        let inner = LogiConnInnerFrame(frameType: 6, payload: .upgrade(authFrame))
        let logiConn = LogiConnFrame(logiConnId: logiConnId, localNetId: 1, remoteNetId: peerNetId, inner: inner.serialized())
        let miFrame = MiConnectFrame(version: 0, logiConnFrames: [logiConn])
        send(frame: LyraMeshPack.Frame(packType: 2, payload: miFrame.serialized()), label: "upgrade_f\(family)")
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
            DiagnosticsLog.warn("xiaomi.mishare.send_upgrade_parse_failed bytes=\(data.count)")
            return
        }
        authServerRandom = hello.serverRandom
        do {
            let peerPublicKey = try P256.KeyAgreement.PublicKey(x963Representation: hello.publicKey)
            let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: peerPublicKey)
            let secret = sharedSecret.withUnsafeBytes { Data($0) }
            authSharedSecret = secret
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
            sendLogiConnRequest()
        } catch {
            fail(String(localized: "ECDH 失敗"))
        }
    }

    private func sendLogiConnRequest() {
        progress(.logiConnRequest, String(localized: "建立傳輸通道…"))
        channelId = UInt32.random(in: 100...60000)
        transKey = Self.randomBytes(32)
        transRandom = Self.randomBytes(32)
        colonHexKey = Self.randomBytes(32)
        let colonHex = colonHexKey.map { String(format: "%02x", $0) }.joined(separator: ":")

        var peerPortRequest = Data()
        LyraProtoWriter.appendVarintField(1, value: UInt64(channelId), to: &peerPortRequest)
        LyraProtoWriter.appendLengthDelimitedField(4, value: transKey, to: &peerPortRequest)
        LyraProtoWriter.appendLengthDelimitedField(5, value: transRandom, to: &peerPortRequest)

        var privateData = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &privateData)
        LyraProtoWriter.appendLengthDelimitedField(
            2, value: Data("com.miui.mishare.connectivity".utf8), to: &privateData
        )
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
        LyraProtoWriter.appendLengthDelimitedField(
            2, value: Data("com.miui.mishare.connectivity:miLyraShareTransfer".utf8), to: &request
        )
        LyraProtoWriter.appendLengthDelimitedField(3, value: privateData, to: &request)

        let requestInner = LogiConnInnerFrame(frameType: 1, payload: .request(request))
        sendEncryptedLogiConn(inner: requestInner, label: "logi_request")
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
            handlePhysConn(physConn, frame: frame, reply: reply)
        }
        for logiConn in miFrame.logiConnFrames {
            handleLogiConn(logiConn, frame: frame, reply: reply)
        }
    }

    private func handlePhysConn(
        _ physConn: PhysConnFrame,
        frame: LyraMeshPack.Frame,
        reply: LyraMeshSocket.ReplyHandler
    ) {
        switch physConn.payload {
        case .syncDeviceInfoResponse:
            if stage == .physSync {
                progress(.cookie, String(localized: "cookie 交握…"))
                sendCookie(phase: 1)
            }
        case let .keepAliveResponse(responseData) where physConn.field2 == 5:
            guard stage == .cookie else { return }
            let fields = (try? LyraProtoReader.readFields(from: responseData)) ?? []
            var phase: UInt64 = 0
            var echo: UInt64 = 0
            for field in fields {
                if field.number == 2, field.wireType == 0 { phase = field.varintValue ?? 0 }
                if field.number == 3, field.wireType == 0 { echo = field.varintValue ?? 0 }
            }
            DiagnosticsLog.info("xiaomi.mishare.send_cookie_rx phase=\(phase) echo=\(echo)")
            if phase < 2 {
                sendCookie(phase: phase + 1)
            } else {
                sendSyncAuthHello()
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
            guard let inner = decryptLogiConnInner(logiConn) else {
                DiagnosticsLog.warn("xiaomi.mishare.send_logi_enc_decrypt_failed bytes=\(logiConn.inner.count)")
                return
            }
            if case .response = inner.payload {
                DiagnosticsLog.info("xiaomi.mishare.send_logi_response_rx")
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
                    "xiaomi.mishare.send_logi_enc_other frameType=\(inner.frameType) bytes=\(logiConn.inner.count)"
                )
            }
            return
        }
        guard let inner = LogiConnInnerFrame(parsing: logiConn.inner) else {
            return
        }
        switch inner.payload {
        case let .syncInfo(syncInfoData):
            handleSyncInfoResponse(syncInfoData, logiConn: logiConn)
        case let .disconnect(payload) where inner.frameType == 4:
            handleSyncAuthContinuation(payload)
        case let .upgrade(upgradeData):
            handleUpgradeResponse(upgradeData)
        default:
            DiagnosticsLog.info(
                "xiaomi.mishare.send_logi_other frameType=\(inner.frameType) bytes=\(logiConn.inner.count)"
            )
        }
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
        peerNetId = logiConn.localNetId
        DiagnosticsLog.info(
            "xiaomi.mishare.send_sync_info_rx peerNetId=\(peerNetId) service=\(serviceName) credBytes=\(peerCred.count)"
        )
        switch stage {
        case .logiSyncOld:
            sendSyncAuthHello()
        case .syncAuth:
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
            sendUpgrade(family: 5)
        default:
            break
        }
    }

    private func handleSyncAuthContinuation(_ payload: Data) {
        DiagnosticsLog.info(
            "xiaomi.mishare.send_sync_auth_rx stage=\(stage) bytes=\(payload.count) " +
                "hex=\(payload.prefix(64).map { String(format: "%02x", $0) }.joined())"
        )
        switch stage {
        case .syncAuthCred:
            if payload.count > 64 {
                sendSyncAuthConfirm()
                sendUpgrade(family: 6)
            }
        case .upgrade:
            break
        default:
            break
        }
    }

    private func handleLogiPayload(frame: LyraMeshPack.Frame) {
        let body = frame.payload
        DiagnosticsLog.info(
            "xiaomi.mishare.send_logi_payload_raw bytes=\(body.count) " +
                "hex=\(body.map { String(format: "%02x", $0) }.joined())"
        )
        if let miFrame = MiConnectFrame(parsing: body) {
            for logiConn in miFrame.logiConnFrames {
                if let (header, commandBody) = try? LyraChannelProtocol.decode(logiConn.inner),
                   header.type == LyraChannelProtocol.CommandType.responseOfPeerPort.rawValue
                {
                    handlePeerPortResponse(commandBody)
                    return
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
            var keys: [(String, SymmetricKey)] = []
            if let channelKeySC { keys.append(("channelSC", channelKeySC)) }
            if let channelKeyCS { keys.append(("channelCS", channelKeyCS)) }
            for (index, candidate) in syncKeyCandidates.enumerated() {
                keys.append(("syncCand\(index)", candidate))
            }
            for (label, key) in keys {
                guard let plaintext = try? AES.GCM.open(sealedBox, using: key) else {
                    continue
                }
                DiagnosticsLog.info(
                    "xiaomi.mishare.send_logi_payload_decrypted headerBytes=\(headerBytes) label=\(label) " +
                        "bytes=\(plaintext.count) hex=\(plaintext.prefix(48).map { String(format: "%02x", $0) }.joined())"
                )
                if let (header, commandBody) = try? LyraChannelProtocol.decode(plaintext),
                   header.type == LyraChannelProtocol.CommandType.responseOfPeerPort.rawValue
                {
                    handlePeerPortResponse(commandBody)
                    return
                }
            }
        }
    }

    private func handlePayloadV2(frame: LyraMeshPack.Frame) {
        let body = frame.payload
        DiagnosticsLog.info(
            "xiaomi.mishare.send_payload_rx bytes=\(body.count) " +
                "hex=\(body.prefix(40).map { String(format: "%02x", $0) }.joined())"
        )
        guard body.count > 30 else { return }
        let flag = body[body.index(body.startIndex, offsetBy: 1)]
        guard flag == 1 else {
            DiagnosticsLog.info("xiaomi.mishare.send_payload_plain bytes=\(body.count)")
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
        if let channelKeySC { keys.append(("channelSC", channelKeySC)) }
        if let channelKeyCS { keys.append(("channelCS", channelKeyCS)) }
        for (index, candidate) in syncKeyCandidates.enumerated() {
            keys.append(("syncCand\(index)", candidate))
        }
        for (label, key) in keys {
            guard let plaintext = try? AES.GCM.open(sealedBox, using: key) else {
                continue
            }
            DiagnosticsLog.info(
                "xiaomi.mishare.send_payload_decrypted label=\(label) bytes=\(plaintext.count) " +
                    "hex=\(plaintext.prefix(96).map { String(format: "%02x", $0) }.joined())"
            )
            guard let (header, commandBody) = try? LyraChannelProtocol.decode(plaintext),
                  header.type == LyraChannelProtocol.CommandType.responseOfPeerPort.rawValue
            else {
                return
            }
            handlePeerPortResponse(commandBody)
            return
        }
        DiagnosticsLog.warn("xiaomi.mishare.send_payload_decrypt_failed bytes=\(body.count)")
    }

    private func sendEncryptedAnnounces() {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let deviceInfo = LyraTrustedDeviceInfo.deviceInfoFrame(
            deviceName: displayName,
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
                DiagnosticsLog.error("xiaomi.mishare.send_announce_failed", error)
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
            DiagnosticsLog.error("xiaomi.mishare.send_peer_port_request_failed", error)
        }
    }

    private func handlePeerPortResponse(_ body: Data) {
        guard stage == .channelWait || stage == .logiConnRequest else {
            return
        }
        let fields = (try? LyraProtoReader.readFields(from: body)) ?? []
        var port: UInt64 = 0
        var serverChannelId: UInt64 = 0
        var serverKey = Data()
        for field in fields {
            switch (field.number, field.wireType) {
            case (2, 0): serverChannelId = field.varintValue ?? 0
            case (3, 0): port = field.varintValue ?? 0
            case (7, 2): serverKey = field.lengthDelimitedValue ?? Data()
            default: continue
            }
        }
        guard port != 0, let nwPort = UInt16(exactly: port) else {
            DiagnosticsLog.warn("xiaomi.mishare.send_peer_port_invalid")
            return
        }
        self.serverChannelId = UInt32(serverChannelId)
        if serverKey.count == 32 {
            self.serverKey = serverKey
        }
        progress(.channelNegotiate, String(localized: "通道協商…"))
        DiagnosticsLog.info(
            "xiaomi.mishare.send_peer_port port=\(port) serverChannelId=\(serverChannelId) keyBytes=\(serverKey.count)"
        )
        let socket = LyraChannelSocket()
        socket.suppressNegotiationReply = true
        socket.debugHandler = { message in
            DiagnosticsLog.info("xiaomi.mishare.send_channel.\(message)")
        }
        socket.onDecryptFailure = { reason in
            DiagnosticsLog.warn("xiaomi.mishare.send_channel_decrypt_failed \(reason)")
        }
        socket.onNegotiated = { [weak self] serverChannelId, mtu in
            DiagnosticsLog.info("xiaomi.mishare.send_channel_negotiated serverChannelId=\(serverChannelId) mtu=\(mtu)")
            self?.channelReady = true
            self?.progress(.expressHandshakeWait, String(localized: "等待手機 express handshake…"))
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
            DiagnosticsLog.info(
                "xiaomi.mishare.send_channel_negotiation_sent channelId=\(serverChannelId) attempt=\(attempt)"
            )
        } catch {
            DiagnosticsLog.error("xiaomi.mishare.send_channel_negotiation_failed", error)
        }
        queue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.sendChannelNegotiation(attempt: attempt + 1)
        }
    }

    private func handleChannelMessage(_ message: Data) {
        lastProgress = Date()
        guard let (frameTag, frameChild) = try? LyraExpressTLVParser.parseOneOf(message), frameTag == 1,
              let payloadNode = LyraExpressTLVParser.firstChild(0, in: LyraExpressTLVParser.children(of: frameChild)),
              let (eventTag, eventChild) = try? LyraExpressTLVParser.parseOneOf(payloadNode.payload)
        else {
            DiagnosticsLog.warn("xiaomi.mishare.send_channel_parse_failed bytes=\(message.count)")
            return
        }
        let children = LyraExpressTLVParser.children(of: eventChild)
        switch eventTag {
        case 1:
            handleExpressHandshake(children)
        case 2:
            let chunk = LyraExpressTLVParser.firstChild(1, in: children)?.payload ?? Data()
            eventBytesBuffer.append(chunk)
            if let complete = LyraMeshResponder.completedFileMessage(eventBytesBuffer) {
                eventBytesBuffer = Data()
                handleFileProtocolMessage(complete)
            }
        case 4:
            handleRcvBegin(children)
        case 5:
            handleRcvEnd(children)
        default:
            DiagnosticsLog.info("xiaomi.mishare.send_express_event tag=\(eventTag) bytes=\(message.count)")
        }
    }

    private func handleExpressHandshake(_ children: [LyraExpressTLVNode]) {
        guard stage == .expressHandshakeWait else {
            DiagnosticsLog.info("xiaomi.mishare.send_handshake_rx_ignored stage=\(stage)")
            return
        }
        let dataPort = LyraExpressTLVParser.firstChild(3, in: children)?.int32Value ?? 0
        let key = LyraExpressTLVParser.firstChild(4, in: children)?.payload ?? Data()
        let connCount = LyraExpressTLVParser.firstChild(5, in: children)?.payload.first ?? 8
        guard dataPort != 0, key.count == 16, let port = UInt16(exactly: dataPort) else {
            DiagnosticsLog.warn(
                "xiaomi.mishare.send_handshake_invalid port=\(dataPort) keyBytes=\(key.count)"
            )
            return
        }
        expressDataPort = dataPort
        expressDataKey = key
        expressConnCount = max(1, Int(connCount))
        DiagnosticsLog.info(
            "xiaomi.mishare.send_handshake_rx port=\(dataPort) conns=\(expressConnCount) " +
                "key=\(key.map { String(format: "%02x", $0) }.joined())"
        )
        openExpressConnections(port: port)
        sendFileSendRequest()
    }

    private func openExpressConnections(port: UInt16) {
        for index in 0..<expressConnCount {
            let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            connection.stateUpdateHandler = { state in
                DiagnosticsLog.info("xiaomi.mishare.send_express_conn_\(index) state=\(String(describing: state))")
            }
            connection.start(queue: queue)
            expressConnections.append(connection)
        }
    }

    private func sendEventFrame(_ inner: Data) {
        do {
            try channelSocket?.sendVariant(
                channelFrame: LyraChannelSocket.wrapChannelFrame(inner),
                key: transKey, singleLayer: true
            )
        } catch {
            DiagnosticsLog.error("xiaomi.mishare.send_event_failed", error)
        }
    }

    private func sendFileProtocolMessage(tag: UInt64, body: Data) {
        var protocolFrame = Data()
        LyraProtoWriter.appendVarintField(1, value: tag, to: &protocolFrame)
        LyraProtoWriter.appendLengthDelimitedField(2, value: body, to: &protocolFrame)
        let event = LyraExpressTLV.oneOfNode(
            tag: 0xFFFF,
            selectedTag: 2,
            child: LyraExpressTLV.containerNode(tag: 2, children: [
                LyraExpressTLV.int32Node(tag: 0, value: 0),
                LyraExpressTLV.stringNode(tag: 1, value: protocolFrame)
            ])
        )
        sendEventFrame(event)
    }

    private func sendFileSendRequest() {
        progress(.fileRequestWait, String(localized: "等待手機接受…"))
        var request = Data()
        LyraProtoWriter.appendVarintField(1, value: requestId, to: &request)
        LyraProtoWriter.appendLengthDelimitedField(2, value: Data(displayName.utf8), to: &request)
        LyraProtoWriter.appendLengthDelimitedField(3, value: Data(jobId.utf8), to: &request)
        for file in files {
            var info = Data()
            LyraProtoWriter.appendLengthDelimitedField(1, value: Data(file.name.utf8), to: &info)
            LyraProtoWriter.appendVarintField(2, value: UInt64(bitPattern: file.size), to: &info)
            LyraProtoWriter.appendLengthDelimitedField(3, value: Data(file.id.utf8), to: &info)
            LyraProtoWriter.appendLengthDelimitedField(5, value: Data(file.mimeType.utf8), to: &info)
            LyraProtoWriter.appendVarintField(6, value: UInt64(bitPattern: file.createTime), to: &info)
            LyraProtoWriter.appendVarintField(7, value: UInt64(bitPattern: file.modifyTime), to: &info)
            LyraProtoWriter.appendLengthDelimitedField(5, value: info, to: &request)
        }
        LyraProtoWriter.appendVarintField(14, value: 1, to: &request)
        sendFileProtocolMessage(tag: 1, body: request)
        DiagnosticsLog.info(
            "xiaomi.mishare.send_file_request requestId=\(requestId) files=\(files.count) bytes=\(request.count)"
        )
    }

    private func handleFileProtocolMessage(_ data: Data) {
        guard let outerFields = try? LyraProtoReader.readFields(from: data),
              let envelope = outerFields.first(where: { $0.number == 2 && $0.wireType == 2 })?.lengthDelimitedValue,
              let fields = try? LyraProtoReader.readFields(from: envelope)
        else {
            return
        }
        let messageTag = outerFields.first(where: { $0.number == 1 && $0.wireType == 0 })?.varintValue ?? 0
        DiagnosticsLog.info("xiaomi.mishare.send_file_message tag=\(messageTag) stage=\(stage)")
        switch messageTag {
        case 2:
            let rejectReason = fields.first(where: { $0.number == 3 && $0.wireType == 0 })?.varintValue ?? 0
            guard stage == .fileRequestWait else { return }
            if rejectReason != 0 {
                fail(String(localized: "手機拒絕接收（reason=\(rejectReason)）"))
                return
            }
            startNextFile()
        case 8:
            progress(.done, String(localized: "傳送完成"))
            onStatus?(String(localized: "已傳送 \(files.count) 個檔案"))
            finishLocked()
        default:
            break
        }
    }

    private func startNextFile() {
        guard currentFileIndex < files.count else {
            var complete = Data()
            LyraProtoWriter.appendVarintField(1, value: requestId, to: &complete)
            LyraProtoWriter.appendLengthDelimitedField(2, value: Data(jobId.utf8), to: &complete)
            progress(.completeWait, String(localized: "完成確認…"))
            sendFileProtocolMessage(tag: 7, body: complete)
            return
        }
        let file = files[currentFileIndex]
        currentStreamId = nextStreamId
        nextStreamId += 1
        currentOffset = 0
        currentFileHandle = try? FileHandle(forReadingFrom: file.url)
        guard currentFileHandle != nil else {
            fail(String(localized: "無法讀取 \(file.name)"))
            return
        }
        progress(.streamBeginWait, String(localized: "傳送 \(file.name)…"))
        let begin = LyraExpressTLV.oneOfNode(
            tag: 0xFFFF,
            selectedTag: 3,
            child: LyraExpressTLV.containerNode(tag: 3, children: [
                LyraExpressTLV.int32Node(tag: 0, value: 0),
                LyraExpressTLV.int32Node(tag: 1, value: currentStreamId),
                LyraExpressTLV.int64Node(tag: 2, value: UInt64(bitPattern: Int64(-1))),
                LyraExpressTLV.stringNode(tag: 3, value: Data()),
                LyraExpressTLV.stringNode(tag: 4, value: Data(file.name.utf8)),
                LyraExpressTLV.stringNode(tag: 5, value: Data(file.id.utf8))
            ])
        )
        sendEventFrame(begin)
        DiagnosticsLog.info(
            "xiaomi.mishare.send_stream_begin streamId=\(currentStreamId) name=\(file.name) size=\(file.size)"
        )
    }

    private func handleRcvBegin(_ children: [LyraExpressTLVNode]) {
        let streamId = LyraExpressTLVParser.firstChild(1, in: children)?.int32Value ?? 0
        DiagnosticsLog.info("xiaomi.mishare.send_rcv_begin streamId=\(streamId) stage=\(stage)")
        guard stage == .streamBeginWait, streamId == currentStreamId else {
            return
        }
        progress(.streaming, String(localized: "傳輸中…"))
        sendNextChunk()
    }

    private func sendNextChunk() {
        guard !cancelled, stage == .streaming || stage == .streamBeginWait else { return }
        let file = files[currentFileIndex]
        let chunk: Data
        if currentOffset < file.size, let handle = currentFileHandle {
            do {
                try handle.seek(toOffset: UInt64(currentOffset))
                chunk = try handle.read(upToCount: Self.chunkSize) ?? Data()
            } catch {
                fail(String(localized: "讀檔失敗"))
                return
            }
        } else {
            chunk = Data()
        }
        let isEOF = currentOffset >= file.size || chunk.isEmpty
        let streamlet = LyraExpressTLV.oneOfNode(
            tag: 0xFFFF,
            selectedTag: 0x100,
            child: LyraExpressTLV.containerNode(tag: 0x100, children: [
                LyraExpressTLV.stringNode(tag: 0, value: Data()),
                LyraExpressTLV.int32Node(tag: 1, value: currentStreamId),
                LyraExpressTLV.int64Node(tag: 2, value: UInt64(bitPattern: currentOffset)),
                LyraExpressTLV.int32Node(tag: 3, value: isEOF ? 0 : UInt32(chunk.count))
            ])
        )
        var plaintext = Data()
        if !isEOF {
            plaintext.append(chunk)
        }
        plaintext.append(streamlet)
        plaintext.append(UInt8((streamlet.count >> 8) & 0xFF))
        plaintext.append(UInt8(streamlet.count & 0xFF))

        let key = SymmetricKey(data: expressDataKey)
        do {
            let nonce = AES.GCM.Nonce()
            let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
            var payload = Data()
            payload.append(contentsOf: nonce.withUnsafeBytes { Data($0) })
            payload.append(sealed.tag)
            payload.append(sealed.ciphertext)
            var frame = Data(capacity: 10 + payload.count)
            frame.append(contentsOf: [0, 0, 0, 0, 0, 0])
            let length = UInt32(payload.count)
            frame.append(UInt8((length >> 24) & 0xFF))
            frame.append(UInt8((length >> 16) & 0xFF))
            frame.append(UInt8((length >> 8) & 0xFF))
            frame.append(UInt8(length & 0xFF))
            frame.append(payload)

            let connection = expressConnections[expressNextConn % max(expressConnections.count, 1)]
            expressNextConn += 1
            let sentOffset = currentOffset
            connection.send(content: frame, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if let error {
                    self.fail(String(localized: "資料傳輸失敗：\(error.localizedDescription)"))
                    return
                }
                if isEOF {
                    self.progress(.streamEndWait, String(localized: "等待手機確認 \(self.files[self.currentFileIndex].name)…"))
                    DiagnosticsLog.info(
                        "xiaomi.mishare.send_stream_eof streamId=\(self.currentStreamId) bytes=\(sentOffset)"
                    )
                    return
                }
                self.currentOffset += Int64(chunk.count)
                self.sendNextChunk()
            })
        } catch {
            fail(String(localized: "加密失敗"))
        }
    }

    private func handleRcvEnd(_ children: [LyraExpressTLVNode]) {
        let result = LyraExpressTLVParser.firstChild(0, in: children)?.int32Value ?? 0
        let streamId = LyraExpressTLVParser.firstChild(1, in: children)?.int32Value ?? 0
        DiagnosticsLog.info(
            "xiaomi.mishare.send_rcv_end streamId=\(streamId) result=\(result) stage=\(stage)"
        )
        guard stage == .streamEndWait, streamId == currentStreamId else {
            return
        }
        currentFileHandle?.closeFile()
        currentFileHandle = nil
        guard result == 0 else {
            fail(String(localized: "手機接收失敗（result=\(result)）"))
            return
        }
        currentFileIndex += 1
        startNextFile()
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
}
