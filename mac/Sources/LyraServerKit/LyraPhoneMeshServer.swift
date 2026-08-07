import CryptoKit
import EdgeLinkKit
import Foundation
import Network

// Inbound service dial handler (cast, mitrustservice, …) — the phone-side
// equivalent of the Mac's per-service logi conn servers. Also adopted by
// outbound roles (sync task, relayCall) for the conns they dial.
public protocol LyraServiceHandler: AnyObject {
    var serviceName: String { get }
    func handleServiceSyncInfo(
        syncInfoData: Data, logiConn: LogiConnFrame, server: LyraPhoneMeshServer
    )
    func handleServiceLogiConn(_ logiConn: LogiConnFrame, server: LyraPhoneMeshServer)
    // packType-5 payload that the announce session key could not decrypt.
    func handleServiceMeshCommand(payload: Data, server: LyraPhoneMeshServer) -> Bool
}

// The phone's mesh endpoint: accepts the Mac's announce dial (phys sync →
// cookie → sync_info → 4-step AuthHandshake → encrypted logi → packType-5
// payload exchange), routes inbound service dials to registered handlers, and
// provides the outbound primitives the phone's own roles (sync task,
// relayCall) dial with.
//
// Single-peer model, like the real pairing: one Mac at a time.
public final class LyraPhoneMeshServer {
    public static let announceServiceName = "00150323"

    public enum Event {
        case log(String)
        case physSynced
        case announceAuthenticated
        case announceReceived(LyraTrustedDevice)
        case payloadReceived(LyraTrustedDeviceParser.Payload)
        case serviceDialed(service: String, connId: UInt32)
        case disconnected
    }

    public var onEvent: (Event) -> Void = { _ in }

    public let identity: LyraPhoneIdentity
    public let oracle: LyraDevRepoOracle
    // TrustedDeviceInfo services the phone advertises in its own pushes.
    public var phoneServices: [LyraTrustedDeviceInfo.Service] = [
        LyraTrustedDeviceInfo.Service(name: "relayCall", package: "com.android.phone"),
    ]

    private let socket: LyraMeshDatagramPipe
    public var boundPort: UInt16? { socket.boundPort }

    // MARK: - Peer state (single active Mac)

    public struct Peer {
        public var host: String = ""
        public var port: UInt16 = 0
        public var endpointDescription: String = ""
        public var announceConnId: UInt32 = 0
        public var peerNetId: UInt32 = 1
        public var sessionKey: SymmetricKey?
        public var ticket: SymmetricKey?
        public var logiSynced = false
        public var pushSent = false
    }

    public private(set) var peer = Peer()

    private var authServer: LyraAuthHandshake.Server?
    private enum ConnRole {
        case announce
        case service(LyraServiceHandler)
    }

    private var connRoles: [UInt32: ConnRole] = [:]
    private var serviceHandlers: [String: LyraServiceHandler] = [:]
    // Outbound phys-sync dials (sync task role), keyed by target port. The
    // callback gets (raw response data, response private_data).
    private var physSyncClients: [UInt16: (Data, Data?) -> Void] = [:]
    // Plaintext packType-5 commands (peer-port responses etc.) are offered
    // to this handler before the inbound service handlers.
    public var plaintextCommandHandler: ((Data) -> Bool)?

    public init(
        identity: LyraPhoneIdentity,
        oracle: LyraDevRepoOracle,
        meshTransport: LyraMeshDatagramPipe? = nil
    ) {
        self.identity = identity
        self.oracle = oracle
        self.socket = meshTransport ?? LyraMeshSocket()
    }

    public func start(port: UInt16) throws {
        socket.onFrame = { [weak self] frame, endpoint, reply in
            self?.handle(frame: frame, endpoint: endpoint, reply: reply)
        }
        try socket.start(preferredPort: port)
    }

    public func stop() {
        socket.stop()
    }

    public func register(_ handler: LyraServiceHandler) {
        serviceHandlers[handler.serviceName] = handler
    }

    // Routes an outbound conn (dialed by a phone role) to its handler.
    public func adoptOutboundConn(connId: UInt32, handler: LyraServiceHandler) {
        connRoles[connId] = .service(handler)
    }

    public func forgetConn(connId: UInt32) {
        connRoles.removeValue(forKey: connId)
    }

    // MARK: - Outbound primitives for phone roles

    public func send(frame: LyraMeshPack.Frame, to host: String, port: UInt16) {
        do {
            try socket.send(frame: frame, to: host, port: port)
        } catch {
            emit(.log("mesh send failed: \(error)"))
        }
    }

    public func sendToPeer(frame: LyraMeshPack.Frame) {
        // Must ride the inbound connection (phone's listener port as the
        // source) — the announcer's connected UDP socket drops datagrams
        // from any other endpoint.
        guard !peer.endpointDescription.isEmpty else { return }
        socket.sendInboundAsync(frame: frame, toEndpointDescription: peer.endpointDescription)
    }

    public func sendLogi(
        connId: UInt32, inner: LogiConnInnerFrame, encryptWith key: SymmetricKey? = nil,
        toHost host: String? = nil, port: UInt16? = nil
    ) {
        let logiConn: LogiConnFrame
        if let key, let sealed = LyraAuthHandshake.gcmSeal(inner.serialized(), using: key) {
            logiConn = LogiConnFrame(
                logiConnId: connId, localNetId: identity.netId, remoteNetId: peer.peerNetId,
                flag: true, inner: sealed
            )
        } else {
            logiConn = LogiConnFrame(
                logiConnId: connId, localNetId: identity.netId, remoteNetId: peer.peerNetId,
                inner: inner.serialized()
            )
        }
        let miFrame = MiConnectFrame(version: 0, logiConnFrames: [logiConn])
        let frame = LyraMeshPack.Frame(packType: 2, payload: miFrame.serialized())
        if let host, let port {
            send(frame: frame, to: host, port: port)
        } else {
            sendToPeer(frame: frame)
        }
    }

    // packType-5 plaintext command (netId, 0x00, LyraChannelProtocol blob).
    public func sendPlaintextCommand(_ command: Data) {
        var payload = Data()
        payload.append(UInt8(identity.netId & 0xFF))
        payload.append(0)
        payload.append(command)
        sendToPeer(frame: LyraMeshPack.Frame(packType: 5, payload: payload))
    }

    // packType-5 encrypted payload (netId, 0x01, AES-GCM(sessionKey)).
    public func sendEncryptedPayload(_ plaintext: Data, using key: SymmetricKey? = nil) {
        guard let key = key ?? peer.sessionKey,
              let sealed = LyraAuthHandshake.gcmSeal(plaintext, using: key)
        else { return }
        var payload = Data()
        payload.append(UInt8(identity.netId & 0xFF))
        payload.append(1)
        payload.append(sealed)
        sendToPeer(frame: LyraMeshPack.Frame(packType: 5, payload: payload))
    }

    // The phone's own device-initiated type-1 sync push — its full
    // TrustedDeviceInfo with the group cred in tdi.f15 (the only carrier the
    // real phone's parse survives; sync.f3 is the oneof sibling that kills
    // the dev frame).
    public func sendSyncPush() {
        let payload = LyraTrustedDeviceInfo.syncPushPayload(
            deviceInfo: ownDeviceInfoFrame(), groupInfo: nil
        )
        sendEncryptedPayload(payload)
        peer.pushSent = true
        emit(.log("sync push sent"))
    }

    // Outbound phys sync dial (sync task role) with response callback.
    public func dialPhysSync(
        to host: String, port: UInt16, privateData: Data?,
        response: @escaping (Data, Data?) -> Void
    ) {
        physSyncClients[port] = response
        let deviceInfo = LyraDeviceInfo(
            deviceId: identity.deviceIdHex,
            deviceType: 1,
            uidHash: String(identity.uidHash.prefix(4)),
            displayName: identity.displayName,
            osVersion: "15",
            connMediumTypes: 0x40182,
            romVersion: identity.romVersion
        )
        var request = Data()
        LyraProtoWriter.appendVarintField(
            1, value: UInt64(Date().timeIntervalSince1970 * 1000), to: &request
        )
        LyraProtoWriter.appendLengthDelimitedField(2, value: deviceInfo.serialized(), to: &request)
        if let privateData {
            LyraProtoWriter.appendLengthDelimitedField(4, value: privateData, to: &request)
        }
        let physConn = PhysConnFrame(field2: 1, payload: .syncDeviceInfoRequest(request))
        let miFrame = MiConnectFrame(version: 0, logiConnFrames: [], physConnFrame: physConn)
        send(frame: LyraMeshPack.Frame(packType: 1, payload: miFrame.serialized()), to: host, port: port)
    }

    // MARK: - Frame dispatch

    private func handle(frame: LyraMeshPack.Frame, endpoint: NWEndpoint, reply: LyraMeshSocket.ReplyHandler) {
        if frame.packType == 5 {
            handleMeshCommand(frame.payload)
            return
        }
        guard let miFrame = MiConnectFrame(parsing: frame.payload) else { return }
        if let physConn = miFrame.physConnFrame {
            handlePhysConn(physConn, endpoint: endpoint, reply: reply)
        }
        for logiConn in miFrame.logiConnFrames {
            handleLogiConn(logiConn, endpoint: endpoint, reply: reply)
        }
    }

    private func rememberPeer(endpoint: NWEndpoint) {
        let description = endpoint.debugDescription
        guard let colon = description.lastIndex(of: ":") else { return }
        let port = UInt16(description[description.index(after: colon)...]) ?? 0
        let host = String(description[..<colon])
        if peer.endpointDescription != description {
            peer.host = host
            peer.port = port
            peer.endpointDescription = description
        }
    }

    // MARK: - Phys conn

    private func handlePhysConn(
        _ physConn: PhysConnFrame, endpoint: NWEndpoint, reply: LyraMeshSocket.ReplyHandler
    ) {
        switch physConn.payload {
        case let .syncDeviceInfoRequest(requestData):
            rememberPeer(endpoint: endpoint)
            let deviceInfo = LyraDeviceInfo(
                deviceId: identity.deviceIdHex,
                deviceType: 1,
                uidHash: String(identity.uidHash.prefix(4)),
                displayName: identity.displayName,
                osVersion: "15",
                connMediumTypes: 0x40182,
                romVersion: identity.romVersion
            )
            let response = PhysConnSyncDeviceInfoResponse(
                timestampMs: UInt64(Date().timeIntervalSince1970 * 1000),
                deviceInfo: deviceInfo
            )
            let responsePhys = PhysConnFrame(
                field1: physConn.field1, field2: 2,
                payload: .syncDeviceInfoResponse(response.serialized())
            )
            let miFrame = MiConnectFrame(version: 0, logiConnFrames: [], physConnFrame: responsePhys)
            try? reply(LyraMeshPack.Frame(packType: 1, payload: miFrame.serialized()))
            emit(.physSynced)
        case let .syncDeviceInfoResponse(responseData):
            // Answer to our outbound dial (sync task role) — do NOT touch
            // the announce peer state; the responder is a different endpoint.
            let description = endpoint.debugDescription
            guard let colon = description.lastIndex(of: ":"),
                  let sourcePort = UInt16(description[description.index(after: colon)...])
            else { return }
            let privateData = LyraAuthHandshake.lengthDelimited(4, in: responseData)
            let handler = physSyncClients[sourcePort]
            physSyncClients.removeValue(forKey: sourcePort)
            handler?(responseData, privateData)
        case let .keepAliveRequest(requestData):
            rememberPeer(endpoint: endpoint)
            let fields = (try? LyraProtoReader.readFields(from: requestData)) ?? []
            let phase = fields.first { $0.number == 2 }?.varintValue ?? 0
            let tick = UInt64(LyraMeshSocket.tick())
            var responseData = Data()
            LyraProtoWriter.appendVarintField(1, value: tick, to: &responseData)
            LyraProtoWriter.appendVarintField(2, value: phase + 1, to: &responseData)
            LyraProtoWriter.appendVarintField(3, value: tick, to: &responseData)
            let responsePhys = PhysConnFrame(field2: 5, payload: .keepAliveResponse(responseData))
            let miFrame = MiConnectFrame(version: 0, logiConnFrames: [], physConnFrame: responsePhys)
            try? reply(LyraMeshPack.Frame(packType: 1, payload: miFrame.serialized()))
        case .disconnectRequest:
            emit(.log("peer disconnect"))
            peer = Peer()
            connRoles.removeAll()
            authServer = nil
            emit(.disconnected)
        default:
            break
        }
    }

    // MARK: - Logi conns

    private func handleLogiConn(
        _ logiConn: LogiConnFrame, endpoint: NWEndpoint, reply: LyraMeshSocket.ReplyHandler
    ) {
        if let role = connRoles[logiConn.logiConnId] {
            switch role {
            case .announce:
                rememberPeer(endpoint: endpoint)
                handleAnnounceLogiConn(logiConn)
            case .service(let handler):
                handler.handleServiceLogiConn(logiConn, server: self)
            }
            return
        }
        // New conn: plaintext sync_info decides the role.
        guard !logiConn.flag,
              let inner = LogiConnInnerFrame(parsing: logiConn.inner),
              case let .syncInfo(syncInfoData) = inner.payload,
              let service = LyraAuthHandshake.lengthDelimited(4, in: syncInfoData)
                .flatMap({ String(data: $0, encoding: .utf8) })
        else {
            emit(.log("stray logi conn \(logiConn.logiConnId)"))
            return
        }
        rememberPeer(endpoint: endpoint)
        if service == Self.announceServiceName {
            connRoles[logiConn.logiConnId] = .announce
            peer.announceConnId = logiConn.logiConnId
            peer.peerNetId = logiConn.localNetId
            authServer = LyraAuthHandshake.Server(identity: identity)
            answerAnnounceSyncInfo(connId: logiConn.logiConnId)
            emit(.serviceDialed(service: service, connId: logiConn.logiConnId))
            return
        }
        if let handler = serviceHandlers[service] {
            connRoles[logiConn.logiConnId] = .service(handler)
            emit(.serviceDialed(service: service, connId: logiConn.logiConnId))
            handler.handleServiceSyncInfo(syncInfoData: syncInfoData, logiConn: logiConn, server: self)
            return
        }
        emit(.log("unknown service dial: \(service)"))
    }

    // MARK: - Announce service (phone side of the Mac's 00150323 dial)

    private func answerAnnounceSyncInfo(connId: UInt32) {
        var syncInfo = Data()
        LyraProtoWriter.appendVarintField(1, value: 10000, to: &syncInfo)
        LyraProtoWriter.appendVarintField(2, value: 16, to: &syncInfo)
        LyraProtoWriter.appendVarintField(3, value: 1, to: &syncInfo)
        LyraProtoWriter.appendLengthDelimitedField(5, value: identity.uidFeatureInfo(), to: &syncInfo)
        if let key = peer.sessionKey ?? peer.ticket,
           let encCred = identity.encryptedLocalCred(using: key)
        {
            LyraProtoWriter.appendLengthDelimitedField(6, value: encCred, to: &syncInfo)
        }
        let inner = LogiConnInnerFrame(frameType: 5, payload: .syncInfo(syncInfo))
        sendLogi(connId: connId, inner: inner)
    }

    private func handleAnnounceLogiConn(_ logiConn: LogiConnFrame) {
        if logiConn.flag {
            guard let key = peer.sessionKey,
                  let plaintext = LyraAuthHandshake.gcmOpen(logiConn.inner, using: key),
                  let inner = LogiConnInnerFrame(parsing: plaintext)
            else {
                emit(.log("announce enc frame decrypt failed"))
                return
            }
            if case .request = inner.payload {
                var responseData = Data()
                LyraProtoWriter.appendVarintField(1, value: 0, to: &responseData)
                LyraProtoWriter.appendVarintField(3, value: 1, to: &responseData)
                let response = LogiConnInnerFrame(frameType: 2, payload: .response(responseData))
                sendLogi(connId: logiConn.logiConnId, inner: response, encryptWith: key)
                peer.logiSynced = true
                emit(.log("announce logi synced"))
                // The real phone pushes its TrustedDeviceInfo as soon as the
                // announce conn is live.
                sendSyncPush()
            }
            return
        }
        guard let inner = LogiConnInnerFrame(parsing: logiConn.inner) else { return }
        switch inner.payload {
        case let .upgrade(upgradeData):
            handleAnnounceAuth(upgradeData: upgradeData, connId: logiConn.logiConnId)
        case .disconnect:
            peer = Peer()
            connRoles.removeAll()
            authServer = nil
            emit(.disconnected)
        default:
            break
        }
    }

    private func handleAnnounceAuth(upgradeData: Data, connId: UInt32) {
        guard let handshake = LyraAuthHandshake.lengthDelimited(2, in: upgradeData),
              let handshakeId = LyraAuthHandshake.varint(1, in: upgradeData),
              let authFrame = LyraAuthHandshake.authFrame(fromHandshake: handshake),
              let step = LyraAuthHandshake.varint(1, in: authFrame),
              let authServer
        else { return }
        let outAuthFrame: Data?
        switch step {
        case 1:
            outAuthFrame = authServer.handleClientNotify(authFrame: authFrame)
        case 3:
            // Verify the Mac's client_finished against its paired identity.
            var result: LyraAuthHandshake.Result?
            var frame: Data?
            for peerIdentity in oracle.trustedPeerIdentities {
                if let finished = authServer.handleClientFinished(
                    authFrame: authFrame, peerIdentityPubKey: peerIdentity
                ) {
                    frame = finished.serverFinished
                    result = finished.result
                    break
                }
            }
            if oracle.trustedPeerIdentities.isEmpty {
                // Unpaired phone: still complete the handshake (the real
                // phone does — trust is enforced later by the oracle gates).
                if let anyKey = try? P256.Signing.PrivateKey(),
                   let finished = authServer.handleClientFinished(
                       authFrame: authFrame,
                       peerIdentityPubKey: anyKey.publicKey.x963Representation
                   )
                {
                    frame = finished.serverFinished
                    result = finished.result
                }
            }
            guard let result else {
                emit(.log("announce auth client_finished rejected"))
                return
            }
            peer.sessionKey = result.sessionKey
            peer.ticket = result.ticket
            outAuthFrame = frame
            emit(.announceAuthenticated)
        default:
            outAuthFrame = nil
        }
        guard let outAuthFrame else { return }
        var handshakeOut = Data()
        LyraProtoWriter.appendVarintField(1, value: 4, to: &handshakeOut)
        LyraProtoWriter.appendVarintField(2, value: 5, to: &handshakeOut)
        LyraProtoWriter.appendLengthDelimitedField(7, value: outAuthFrame, to: &handshakeOut)
        var upgrade = Data()
        LyraProtoWriter.appendVarintField(1, value: handshakeId, to: &upgrade)
        LyraProtoWriter.appendLengthDelimitedField(2, value: handshakeOut, to: &upgrade)
        let inner = LogiConnInnerFrame(frameType: 6, payload: .upgrade(upgrade))
        sendLogi(connId: connId, inner: inner)
    }

    // MARK: - packType 5

    private func handleMeshCommand(_ payload: Data) {
        guard payload.count > 2 else { return }
        let flag = payload[payload.index(after: payload.startIndex)]
        if flag == 1, let key = peer.sessionKey,
           let plaintext = LyraAuthHandshake.gcmOpen(Data(payload.dropFirst(2)), using: key)
        {
            handlePeerPayload(plaintext)
            return
        }
        if flag == 0 {
            let command = Data(payload.dropFirst(2))
            if plaintextCommandHandler?(command) == true {
                return
            }
            let handled = serviceHandlers.values.contains {
                $0.handleServiceMeshCommand(payload: command, server: self)
            }
            if !handled {
                emit(.log("unhandled plaintext mesh command"))
            }
            return
        }
        let handled = serviceHandlers.values.contains {
            $0.handleServiceMeshCommand(payload: payload, server: self)
        }
        if !handled {
            emit(.log("undecryptable mesh command"))
        }
    }

    private func handlePeerPayload(_ plaintext: Data) {
        guard let parsed = LyraTrustedDeviceParser.parsePayload(plaintext) else {
            emit(.log("peer payload parse failed bytes=\(plaintext.count)"))
            return
        }
        emit(.payloadReceived(parsed))
        switch parsed.kind {
        case .announce:
            let record = oracle.handleAnnounce(device: parsed.device)
            emit(.announceReceived(parsed.device))
            emit(.log(
                "peer announce: trustedType=\(record.trustedType) online=\(record.online) " +
                    "reasons=\(record.rejectionReasons.joined(separator: "; "))"
            ))
        case .push:
            let record = oracle.handleSyncPush(
                device: parsed.device, groupInfo: parsed.groupInfo,
                connHadFullHandshake: peer.sessionKey != nil
            )
            emit(.announceReceived(parsed.device))
            emit(.log(
                "peer push: trustedType=\(record.trustedType) online=\(record.online) " +
                    "reasons=\(record.rejectionReasons.joined(separator: "; "))"
            ))
            // Answer with our own push (the phone's side of the exchange).
            sendSyncPush()
        case .reply:
            let record = oracle.handleSyncReply(device: parsed.device, groupInfo: parsed.groupInfo)
            emit(.announceReceived(parsed.device))
            emit(.log(
                "peer reply: trustedType=\(record.trustedType) online=\(record.online) " +
                    "reasons=\(record.rejectionReasons.joined(separator: "; "))"
            ))
        }
    }

    // MARK: - Own frames

    private func ownDeviceInfoFrame() -> Data {
        LyraTrustedDeviceInfo.syncReplyDeviceInfoFrame(
            deviceName: identity.displayName,
            deviceType: 1,
            fullDeviceIdHex: identity.fullDeviceIdHex,
            shortDeviceIdHex: identity.deviceIdHex,
            uidHash: identity.uidHashRaw.map { String(format: "%02X", $0) }.joined(),
            hwModel: identity.model,
            lyraVersion: identity.romVersion,
            services: phoneServices,
            meshPort: boundPort,
            ipAddress: nil,
            osVersion: "15",
            accountNumericId: identity.accountNumericId,
            syncUuid: UUID().uuidString.lowercased(),
            region: "cn",
            deviceKey: identity.deviceKeyData,
            credBlock: identity.accountCertCredBlock()
        )
    }

    private func emit(_ event: Event) {
        onEvent(event)
    }
}
