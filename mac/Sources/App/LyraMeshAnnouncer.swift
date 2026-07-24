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
        case logiSynced
    }

    private let socket = LyraMeshSocket()
    private var host: String?
    private var port: UInt16 = 0
    private var state: State = .idle
    private var physConnId: UInt32 = 0
    private var logiConnId: UInt32 = 0
    private var peerNetId: UInt32 = 0
    private var ourCookie: UInt64 = 0
    private var syncAuthPrivateKey: Curve25519.KeyAgreement.PrivateKey?
    private var syncAuthOurConnId = Data()
    private var syncKeyCandidates: [SymmetricKey] = []
    private var announceTimer: DispatchSourceTimer?
    private var lastActivity = Date.distantPast
    private static let staleTimeout: TimeInterval = 20
    private let queue = DispatchQueue(label: "edgelink.lyra.announcer")
    private let deviceIdHexProvider: () -> String?
    private let displayNameProvider: () -> String

    init(
        deviceIdHexProvider: @escaping () -> String?,
        displayNameProvider: @escaping () -> String
    ) {
        self.deviceIdHexProvider = deviceIdHexProvider
        self.displayNameProvider = displayNameProvider
    }

    func start(host: String, port: UInt16) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.host == host, self.port == port, self.state == .logiSynced,
               Date().timeIntervalSince(self.lastActivity) < Self.staleTimeout {
                return
            }
            if self.host == host, self.port == port, self.state != .idle {
                DiagnosticsLog.info(
                    "xiaomi.mishare.announcer_resync state=\(self.state) " +
                        "idleSeconds=\(Int(Date().timeIntervalSince(self.lastActivity)))"
                )
            }
            self.stopLocked()
            self.host = host
            self.port = port
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
        peerNetId = 0
        ourCookie = 0
        syncAuthPrivateKey = nil
        syncAuthOurConnId = Data()
        syncKeyCandidates = []
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
            deviceType: 14,
            uidHash: "61F2",
            displayName: displayNameProvider(),
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
            field1: physConnId,
            field2: 1,
            payload: .syncDeviceInfoRequest(request)
        )
        let miFrame = MiConnectFrame(version: 0, logiConnFrames: [], physConnFrame: physConn)
        send(frame: LyraMeshPack.Frame(packType: 1, payload: miFrame.serialized()), label: "phys_sync")
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
        let logiConn = LogiConnFrame(
            logiConnId: logiConnId,
            localNetId: 1,
            remoteNetId: peerNetId,
            inner: inner.serialized()
        )
        let miFrame = MiConnectFrame(version: 0, logiConnFrames: [logiConn])
        send(frame: LyraMeshPack.Frame(packType: 2, payload: miFrame.serialized()), label: "sync_auth_hello")
    }

    private func deriveSyncKeys(peerConnId: Data, peerPubKey: Data) {
        guard let privateKey = syncAuthPrivateKey, peerPubKey.count == 32,
              let peerKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPubKey),
              let sharedSecret = try? privateKey.sharedSecretFromKeyAgreement(with: peerKey)
        else {
            DiagnosticsLog.warn(
                "xiaomi.mishare.announcer_sync_key_failed peerConnId=\(peerConnId.count) peerPubKey=\(peerPubKey.count)"
            )
            return
        }
        let secret = sharedSecret.withUnsafeBytes { Data($0) }
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

    private func sendAnnounce() {
        guard let deviceIdHex = deviceIdHexProvider(), !syncKeyCandidates.isEmpty else {
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
        for (index, key) in syncKeyCandidates.enumerated() {
            do {
                let nonce = AES.GCM.Nonce()
                let sealed = try AES.GCM.seal(inner, using: key, nonce: nonce)
                var payload = Data()
                payload.append(UInt8((peerNetId == 0 ? 1 : peerNetId) & 0xFF))
                payload.append(1)
                payload.append(contentsOf: nonce.withUnsafeBytes { Data($0) })
                payload.append(sealed.ciphertext)
                payload.append(sealed.tag)
                send(frame: LyraMeshPack.Frame(packType: 5, payload: payload), label: "announce_c\(index)")
            } catch {
                DiagnosticsLog.error("xiaomi.mishare.announcer_announce_failed", error)
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

    private func send(frame: LyraMeshPack.Frame, label: String) {
        guard let host, port != 0 else { return }
        do {
            try socket.send(frame: frame, to: host, port: port)
            DiagnosticsLog.info("xiaomi.mishare.announcer_tx label=\(label) to=\(host):\(port)")
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

    private func handle(frame: LyraMeshPack.Frame, endpoint: NWEndpoint, reply: LyraMeshSocket.ReplyHandler) {
        lastActivity = Date()
        if frame.packType == 5 {
            DiagnosticsLog.info(
                "xiaomi.mishare.announcer_payload bytes=\(frame.payload.count) " +
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
            guard let inner = LogiConnInnerFrame(parsing: logiConn.inner) else {
                DiagnosticsLog.warn(
                    "xiaomi.mishare.announcer_logi_parse_failed bytes=\(logiConn.inner.count) " +
                        "hex=\(logiConn.inner.prefix(48).map { String(format: "%02x", $0) }.joined())"
                )
                continue
            }
            if case let .syncInfo(syncInfoData) = inner.payload {
                peerNetId = logiConn.localNetId
                let fields = (try? LyraProtoReader.readFields(from: syncInfoData)) ?? []
                var peerCred = Data()
                for field in fields {
                    if field.number == 5, field.wireType == 2 {
                        peerCred = field.lengthDelimitedValue ?? Data()
                    }
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
                DiagnosticsLog.info(
                    "xiaomi.mishare.announcer_logi_synced peerNetId=\(logiConn.localNetId) " +
                        "logiConnId=\(logiConn.logiConnId) credBytes=\(peerCred.count)"
                )
                deriveSyncKeys(peerConnId: peerConnId, peerPubKey: peerPubKey)
                if !syncKeyCandidates.isEmpty {
                    state = .logiSynced
                    sendAnnounce()
                }
            } else {
                DiagnosticsLog.info(
                    "xiaomi.mishare.announcer_logi_other frameType=\(inner.frameType) " +
                        "bytes=\(logiConn.inner.count) " +
                        "hex=\(logiConn.inner.prefix(48).map { String(format: "%02x", $0) }.joined())"
                )
            }
        }
    }
}
