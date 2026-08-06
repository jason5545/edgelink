import CryptoKit
import EdgeLinkKit
import Foundation

// The phone's reverse sync task (service 00150323): dials the Mac's
// quick-conn server through a phys sync whose private_data embeds the logi
// opening (sync_info + AuthHandshake client_notify), completes the 4-step
// handshake as the client, then pushes the phone's TrustedDeviceInfo payload
// and consumes the Mac's reply. An auth-reuse variant skips the handshake
// when a session key is already recorded for the peer.
public final class LyraSyncTaskRole: LyraServiceHandler {
    public let serviceName = LyraPhoneMeshServer.announceServiceName

    public enum State: Sendable, Equatable {
        case idle
        case dialing
        case handshaking
        case established
        case failed(String)
    }

    public var onEvent: (String) -> Void = { _ in }
    public private(set) var state: State = .idle
    // The Mac's TrustedDeviceInfo as learned from its payload reply.
    public private(set) var peerDevice: LyraTrustedDevice?

    private let identity: LyraPhoneIdentity
    private let oracle: LyraDevRepoOracle
    private var connId: UInt32 = 0
    private var handshakeId: UInt64 = 1
    private var client: LyraAuthHandshake.Client?
    private var sessionKey: SymmetricKey?
    private var responderHost = "127.0.0.1"
    private var responderPort: UInt16 = 0
    private var payloadPushed = false
    // Auth-reuse key recorded from a previous handshake with this peer.
    public var reuseKey: SymmetricKey?

    public init(identity: LyraPhoneIdentity, oracle: LyraDevRepoOracle) {
        self.identity = identity
        self.oracle = oracle
    }

    // Dials the Mac responder's quick-conn sync server.
    public func dial(server: LyraPhoneMeshServer, host: String, port: UInt16) {
        state = .dialing
        responderHost = host
        responderPort = port
        connId = UInt32.random(in: 1...UInt32.max)
        handshakeId = UInt64.random(in: 1...UInt64(UInt32.max))
        payloadPushed = false
        server.adoptOutboundConn(connId: connId, handler: self)

        var syncInfo = Data()
        LyraProtoWriter.appendVarintField(1, value: 10000, to: &syncInfo)
        LyraProtoWriter.appendVarintField(2, value: 16, to: &syncInfo)
        LyraProtoWriter.appendLengthDelimitedField(4, value: Data(serviceName.utf8), to: &syncInfo)
        LyraProtoWriter.appendLengthDelimitedField(5, value: identity.uidFeatureInfo(), to: &syncInfo)

        if let reuseKey {
            // Auth-reuse: f6 = our cred encrypted with the reuse key, f8 =
            // the ConnRequestFrame encrypted with the same key (no
            // handshake). Mirrors the phone's DeviceKeyManager-resolved dial.
            if let encCred = identity.encryptedLocalCred(using: reuseKey) {
                LyraProtoWriter.appendVarintField(3, value: 1, to: &syncInfo)
                LyraProtoWriter.appendLengthDelimitedField(6, value: encCred, to: &syncInfo)
            }
            let connRequest = buildConnRequestFrame()
            if let sealed = LyraAuthHandshake.gcmSeal(connRequest, using: reuseKey) {
                LyraProtoWriter.appendLengthDelimitedField(8, value: sealed, to: &syncInfo)
            }
            sessionKey = reuseKey
            state = .established
            onEvent("sync task auth-reuse dial")
        } else {
            let authClient = LyraAuthHandshake.Client(identity: identity)
            client = authClient
            let clientNotify = authClient.makeClientNotify()
            var handshake = Data()
            LyraProtoWriter.appendVarintField(1, value: 4, to: &handshake)
            LyraProtoWriter.appendVarintField(2, value: 5, to: &handshake)
            // Live 2026-08-05: the real phone wraps the sync-task client_notify
            // auth frame in handshake f6 (relayCall dials use f7).
            LyraProtoWriter.appendLengthDelimitedField(6, value: clientNotify, to: &handshake)
            var upgrade = Data()
            LyraProtoWriter.appendVarintField(1, value: handshakeId, to: &upgrade)
            LyraProtoWriter.appendLengthDelimitedField(2, value: handshake, to: &upgrade)
            let quickConn = LogiConnInnerFrame(frameType: 6, payload: .upgrade(upgrade))
            LyraProtoWriter.appendLengthDelimitedField(8, value: quickConn.serialized(), to: &syncInfo)
            state = .handshaking
            onEvent("sync task full-handshake dial")
        }

        let inner = LogiConnInnerFrame(frameType: 5, payload: .syncInfo(syncInfo))
        let logiConn = LogiConnFrame(
            logiConnId: connId, localNetId: identity.netId, remoteNetId: 1,
            inner: inner.serialized()
        )
        var wrapper = Data()
        LyraProtoWriter.appendLengthDelimitedField(1, value: logiConn.serialized(), to: &wrapper)
        var privateData = Data()
        LyraProtoWriter.appendLengthDelimitedField(2, value: wrapper, to: &privateData)
        LyraProtoWriter.appendVarintField(5, value: 128, to: &privateData)
        server.dialPhysSync(to: host, port: port, privateData: privateData) { [weak self] _, responsePrivateData in
            self?.handlePhysSyncResponse(privateData: responsePrivateData, server: server)
        }
    }

    // Classic dial (the phone's "reuse classic conn" mode): a plaintext logi
    // sync_info on the mesh conn itself — no phys private_data embedding.
    // The server answers with its own sync_info, then the 4-step handshake
    // runs on the conn.
    public func dialClassic(server: LyraPhoneMeshServer, host: String, port: UInt16) {
        state = .dialing
        responderHost = host
        responderPort = port
        connId = UInt32.random(in: 1...UInt32.max)
        handshakeId = UInt64.random(in: 1...UInt64(UInt32.max))
        payloadPushed = false
        server.adoptOutboundConn(connId: connId, handler: self)

        var syncInfo = Data()
        LyraProtoWriter.appendVarintField(1, value: 10000, to: &syncInfo)
        LyraProtoWriter.appendVarintField(2, value: 16, to: &syncInfo)
        LyraProtoWriter.appendLengthDelimitedField(4, value: Data(serviceName.utf8), to: &syncInfo)
        LyraProtoWriter.appendLengthDelimitedField(5, value: identity.uidFeatureInfo(), to: &syncInfo)
        let inner = LogiConnInnerFrame(frameType: 5, payload: .syncInfo(syncInfo))
        server.sendLogi(connId: connId, inner: inner, toHost: host, port: port)
        state = .handshaking
        onEvent("sync task classic dial")
    }

    private func buildConnRequestFrame() -> Data {
        var request = Data()
        LyraProtoWriter.appendLengthDelimitedField(2, value: Data(serviceName.utf8), to: &request)
        LyraProtoWriter.appendVarintField(4, value: 16, to: &request)
        LyraProtoWriter.appendVarintField(5, value: 10000, to: &request)
        LyraProtoWriter.appendVarintField(7, value: 1, to: &request)
        var frame = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &frame)
        LyraProtoWriter.appendLengthDelimitedField(2, value: request, to: &frame)
        return frame
    }

    private func handlePhysSyncResponse(privateData: Data?, server: LyraPhoneMeshServer) {
        guard let privateData,
              let wrapper = LyraAuthHandshake.lengthDelimited(2, in: privateData),
              let logiConnData = LyraAuthHandshake.lengthDelimited(1, in: wrapper),
              let logiConn = LogiConnFrame(parsing: logiConnData),
              let inner = LogiConnInnerFrame(parsing: logiConn.inner),
              case let .syncInfo(syncInfoData) = inner.payload
        else {
            // Auth-reuse dials get their server sync_info here too; a missing
            // private_data means the Mac answers on the conn instead (official
            // Mac shape, 2026-08-05 pcap: no embedded answer, standalone
            // sync_info + server_notify) — wait for the on-conn server_notify
            // and consume it with the embedded handshake's client.
            if state == .established {
                pushPayload(server: server)
                return
            }
            onEvent("sync task awaiting on-conn server_notify")
            return
        }
        if state == .established {
            // Auth-reuse path: server sync_info acknowledges the dial.
            pushPayload(server: server)
            return
        }
        guard let quickConn = LyraAuthHandshake.lengthDelimited(8, in: syncInfoData),
              let qcInner = LogiConnInnerFrame(parsing: quickConn),
              case let .upgrade(upgradeData) = qcInner.payload,
              let handshake = LyraAuthHandshake.lengthDelimited(2, in: upgradeData),
              let authFrame = LyraAuthHandshake.authFrame(fromHandshake: handshake),
              let client,
              let clientFinished = client.handleServerNotify(authFrame: authFrame)
        else {
            // f8-less server sync_info: the real phone's "continue normal conn
            // from quick conn" fallback — run the full handshake on the conn.
            if state == .handshaking {
                let authClient = LyraAuthHandshake.Client(identity: identity)
                client = authClient
                sendAuthFrame(authClient.makeClientNotify(), server: server)
            } else {
                state = .failed("server sync_info missing quick-conn server_notify")
                onEvent("sync task failed: bad server sync_info")
            }
            return
        }
        sendAuthFrame(clientFinished, server: server)
    }

    private func sendAuthFrame(_ authFrame: Data, server: LyraPhoneMeshServer) {
        var handshake = Data()
        LyraProtoWriter.appendVarintField(1, value: 4, to: &handshake)
        LyraProtoWriter.appendVarintField(2, value: 5, to: &handshake)
        LyraProtoWriter.appendLengthDelimitedField(7, value: authFrame, to: &handshake)
        var upgrade = Data()
        LyraProtoWriter.appendVarintField(1, value: handshakeId, to: &upgrade)
        LyraProtoWriter.appendLengthDelimitedField(2, value: handshake, to: &upgrade)
        let inner = LogiConnInnerFrame(frameType: 6, payload: .upgrade(upgrade))
        server.sendLogi(connId: connId, inner: inner, toHost: responderHost, port: responderPort)
    }

    // MARK: - LyraServiceHandler (outbound conn frames)

    public func handleServiceSyncInfo(
        syncInfoData: Data, logiConn: LogiConnFrame, server: LyraPhoneMeshServer
    ) {
        // Classic dial: the server's sync_info answer kicks off the
        // full-handshake client_notify on the conn. A quick-conn dial already
        // has its embedded handshake in flight (client != nil) — the on-conn
        // sync_info is just the server's opening there, not a kickoff.
        guard state == .handshaking, client == nil else { return }
        let authClient = LyraAuthHandshake.Client(identity: identity)
        client = authClient
        let clientNotify = authClient.makeClientNotify()
        sendAuthFrame(clientNotify, server: server)
    }

    public func handleServiceLogiConn(_ logiConn: LogiConnFrame, server: LyraPhoneMeshServer) {
        if logiConn.flag {
            guard let key = sessionKey,
                  let plaintext = LyraAuthHandshake.gcmOpen(logiConn.inner, using: key),
                  let inner = LogiConnInnerFrame(parsing: plaintext)
            else { return }
            switch inner.payload {
            case let .data(payloadData):
                // The Mac's payload reply: its TrustedDeviceInfo → DevRepo
                // (reply path runs the same tdi.f15 cred checks).
                if let parsed = LyraTrustedDeviceParser.parsePayload(payloadData) {
                    peerDevice = parsed.device
                    _ = oracle.handleSyncReply(device: parsed.device, groupInfo: parsed.groupInfo)
                    onEvent("sync task peer payload: \(parsed.device.deviceName)")
                }
            case .response:
                onEvent("sync task logi response")
                pushPayload(server: server)
            default:
                break
            }
            return
        }
        guard let inner = LogiConnInnerFrame(parsing: logiConn.inner) else { return }
        // Classic dial: the server's sync_info answer arrives on the conn.
        if case let .syncInfo(syncInfoData) = inner.payload {
            handleServiceSyncInfo(syncInfoData: syncInfoData, logiConn: logiConn, server: server)
            return
        }
        guard case let .upgrade(upgradeData) = inner.payload,
              let handshake = LyraAuthHandshake.lengthDelimited(2, in: upgradeData),
              let authFrame = LyraAuthHandshake.authFrame(fromHandshake: handshake),
              let step = LyraAuthHandshake.varint(1, in: authFrame)
        else { return }
        if step == 2, let client, let clientFinished = client.handleServerNotify(authFrame: authFrame) {
            // Classic dial: server_notify arrives on the conn.
            sendAuthFrame(clientFinished, server: server)
            return
        }
        guard step == 4,
              let client, let result = client.handleServerFinished(authFrame: authFrame)
        else { return }
        sessionKey = result.sessionKey
        reuseKey = result.sessionKey
        state = .established
        onEvent("sync task established")
        // Post-handshake: encrypted logi REQUEST, then the payload push (the
        // Mac answers the REQUEST first; push rides after the response).
        var request = Data()
        LyraProtoWriter.appendLengthDelimitedField(2, value: Data(serviceName.utf8), to: &request)
        LyraProtoWriter.appendVarintField(4, value: 16, to: &request)
        LyraProtoWriter.appendVarintField(5, value: 10000, to: &request)
        let requestInner = LogiConnInnerFrame(frameType: 1, payload: .request(request))
        server.sendLogi(
            connId: connId, inner: requestInner, encryptWith: result.sessionKey,
            toHost: responderHost, port: responderPort
        )
    }

    private func pushPayload(server: LyraPhoneMeshServer) {
        guard !payloadPushed, let key = sessionKey else { return }
        payloadPushed = true
        let deviceInfo = LyraTrustedDeviceInfo.syncReplyDeviceInfoFrame(
            deviceName: identity.displayName,
            deviceType: 1,
            fullDeviceIdHex: identity.fullDeviceIdHex,
            shortDeviceIdHex: identity.deviceIdHex,
            uidHash: identity.uidHash,
            hwModel: identity.model,
            lyraVersion: identity.romVersion,
            services: [LyraTrustedDeviceInfo.Service(name: "relayCall", package: "com.android.phone")],
            meshPort: server.boundPort,
            ipAddress: nil,
            osVersion: "15",
            accountNumericId: identity.accountNumericId,
            syncUuid: UUID().uuidString.lowercased(),
            region: "cn",
            deviceKey: identity.deviceKeyData,
            credBlock: identity.accountCertCredBlock()
        )
        let payload = LyraTrustedDeviceInfo.syncPushPayload(deviceInfo: deviceInfo, groupInfo: nil)
        let inner = LogiConnInnerFrame(frameType: 7, payload: .data(payload))
        server.sendLogi(
            connId: connId, inner: inner, encryptWith: key,
            toHost: responderHost, port: responderPort
        )
        onEvent("sync task payload pushed")
    }

    public func handleServiceMeshCommand(payload: Data, server: LyraPhoneMeshServer) -> Bool {
        false
    }
}
