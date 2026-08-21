import CryptoKit
import EdgeLinkKit
import Foundation

// The phone's MiShare sender (gallery share-sheet "send to this Mac"): dials
// the Mac's miLyraShareTransfer service on a classic logi conn — sync_info
// (Curve25519 sync-auth cred), P256 upgrade, encrypted conn request,
// responseAck, then packType-5 requestOfPeerPort — and expects the Mac's
// responseOfPeerPort back on the same conn.
//
// The dial rides whatever phys conn the phone's score-based reuse picks:
// its own mesh conn, or the Mac's ANNOUNCER conn (live 2026-08-21: the
// announcer conn won, the Mac dropped the sync_info as announcer_stray_conn,
// and the phone's 15s kcp timeout surfaced as 「連線失敗」).
// `dial(server:toHost:port:)` targets the Mac's published mesh port directly;
// `dial(server:)` rides the established announce peer conn.
public final class LyraMiShareSenderRole: LyraServiceHandler {
    public static let defaultServiceName = "com.xiaomi.hyperConnect:miLyraShareTransfer"

    public let serviceName: String

    public enum State: Sendable, Equatable {
        case idle
        case dialing
        case upgrading
        case requesting
        case channelNegotiating
        case channelReady
        case failed(String)
    }

    public var onEvent: (String) -> Void = { _ in }
    public private(set) var state: State = .idle
    // The Mac's channel listener port, from its responseOfPeerPort.
    public private(set) var receivedChannelPort: UInt32?

    private let identity: LyraPhoneIdentity
    private var connId: UInt32 = 0
    private var channelId: UInt32 = 0
    private var transKey = Data()
    private var transRandom = Data()
    private var p256Key: P256.KeyAgreement.PrivateKey?
    private var clientRandom = Data()
    private var channelKey: SymmetricKey?
    private var dialHost: String?
    private var dialPort: UInt16?

    public init(
        identity: LyraPhoneIdentity,
        serviceName: String = LyraMiShareSenderRole.defaultServiceName
    ) {
        self.identity = identity
        self.serviceName = serviceName
    }

    public func dial(server: LyraPhoneMeshServer, toHost host: String? = nil, port: UInt16? = nil) {
        state = .dialing
        receivedChannelPort = nil
        channelKey = nil
        p256Key = nil
        dialHost = host
        dialPort = port
        connId = UInt32.random(in: 1...UInt32.max)
        channelId = UInt32.random(in: 1...UInt32.max)
        transKey = Self.randomBytes(32)
        transRandom = Self.randomBytes(32)
        server.adoptOutboundConn(connId: connId, handler: self)

        var cred = Data()
        LyraProtoWriter.appendLengthDelimitedField(1, value: Self.randomBytes(8), to: &cred)
        let syncAuthKey = Curve25519.KeyAgreement.PrivateKey()
        LyraProtoWriter.appendLengthDelimitedField(
            2, value: syncAuthKey.publicKey.rawRepresentation, to: &cred
        )
        var syncInfo = Data()
        LyraProtoWriter.appendVarintField(1, value: 10000, to: &syncInfo)
        LyraProtoWriter.appendVarintField(2, value: 48, to: &syncInfo)
        LyraProtoWriter.appendVarintField(3, value: 7, to: &syncInfo)
        LyraProtoWriter.appendLengthDelimitedField(4, value: Data(serviceName.utf8), to: &syncInfo)
        LyraProtoWriter.appendLengthDelimitedField(5, value: cred, to: &syncInfo)
        send(inner: LogiConnInnerFrame(frameType: 5, payload: .syncInfo(syncInfo)), server: server)
        onEvent("mishare sender dialed")
    }

    // MARK: - LyraServiceHandler

    public func handleServiceSyncInfo(
        syncInfoData: Data, logiConn: LogiConnFrame, server: LyraPhoneMeshServer
    ) {
        // Outbound role: the Mac's sync_info REPLY arrives via
        // handleServiceLogiConn on the adopted outbound conn.
    }

    public func handleServiceLogiConn(_ logiConn: LogiConnFrame, server: LyraPhoneMeshServer) {
        if logiConn.flag {
            guard let key = channelKey,
                  let plaintext = LyraAuthHandshake.gcmOpen(logiConn.inner, using: key),
                  let inner = LogiConnInnerFrame(parsing: plaintext)
            else { return }
            switch inner.payload {
            case .response:
                // The Mac acked the conn request; the responseAck kicks off
                // its channel listener, then we ask for its port.
                send(
                    inner: LogiConnInnerFrame(frameType: 3, payload: .responseAck(Data())),
                    server: server, encryptWith: key
                )
                sendRequestOfPeerPort(server: server, key: key)
                state = .channelNegotiating
                onEvent("mishare sender responseAck + requestOfPeerPort sent")
            case let .disconnect(data):
                state = .failed("disconnect \(data.map { String(format: "%02x", $0) }.joined())")
                onEvent("mishare sender disconnect")
            default:
                break
            }
            return
        }
        guard let inner = LogiConnInnerFrame(parsing: logiConn.inner) else { return }
        switch inner.payload {
        case .syncInfo:
            // The Mac's sync-auth response (its Curve25519 cred); the receive
            // flow goes straight for the P256 channel-key upgrade.
            sendUpgrade(server: server)
        case let .upgrade(upgradeData):
            handleUpgradeReply(upgradeData: upgradeData, server: server)
        default:
            break
        }
    }

    // packType-5 commands the announce session key could not decrypt — the
    // Mac's responseOfPeerPort is encrypted with the channel key.
    public func handleServiceMeshCommand(payload: Data, server: LyraPhoneMeshServer) -> Bool {
        guard let key = channelKey, payload.count > 2,
              payload[payload.index(after: payload.startIndex)] == 1,
              let plaintext = LyraAuthHandshake.gcmOpen(Data(payload.dropFirst(2)), using: key),
              let (header, body) = try? LyraChannelProtocol.decode(plaintext),
              header.type == LyraChannelProtocol.CommandType.responseOfPeerPort.rawValue,
              let port = LyraAuthHandshake.varint(3, in: body)
        else { return false }
        receivedChannelPort = UInt32(port)
        state = .channelReady
        onEvent("mishare sender channel port=\(port)")
        return true
    }

    // MARK: - Flow steps

    private func sendUpgrade(server: LyraPhoneMeshServer) {
        let privateKey = P256.KeyAgreement.PrivateKey()
        p256Key = privateKey
        clientRandom = Self.randomBytes(32)

        var publicKeyMessage = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &publicKeyMessage)
        LyraProtoWriter.appendLengthDelimitedField(
            2, value: privateKey.publicKey.x963Representation, to: &publicKeyMessage
        )
        var cipherSuites = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &cipherSuites)
        LyraProtoWriter.appendLengthDelimitedField(2, value: clientRandom, to: &cipherSuites)
        LyraProtoWriter.appendVarintField(3, value: 1, to: &cipherSuites)
        LyraProtoWriter.appendVarintField(4, value: 1, to: &cipherSuites)
        LyraProtoWriter.appendLengthDelimitedField(5, value: publicKeyMessage, to: &cipherSuites)
        var clientNotify = Data()
        LyraProtoWriter.appendLengthDelimitedField(1, value: cipherSuites, to: &clientNotify)
        var pairFrame = Data()
        LyraProtoWriter.appendLengthDelimitedField(2, value: clientNotify, to: &pairFrame)
        var handshakeFrame = Data()
        LyraProtoWriter.appendVarintField(1, value: 2, to: &handshakeFrame)
        LyraProtoWriter.appendVarintField(2, value: 4, to: &handshakeFrame)
        // family != 5 → the pair frame rides handshake field 6 (the shape the
        // Mac's parseAuthClientHello expects).
        LyraProtoWriter.appendLengthDelimitedField(6, value: pairFrame, to: &handshakeFrame)
        var authFrame = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &authFrame)
        LyraProtoWriter.appendLengthDelimitedField(2, value: handshakeFrame, to: &authFrame)
        send(inner: LogiConnInnerFrame(frameType: 6, payload: .upgrade(authFrame)), server: server)
        state = .upgrading
        onEvent("mishare sender upgrade sent")
    }

    private func handleUpgradeReply(upgradeData: Data, server: LyraPhoneMeshServer) {
        guard let handshakeFrame = LyraAuthHandshake.lengthDelimited(2, in: upgradeData),
              let family = LyraAuthHandshake.varint(1, in: handshakeFrame),
              let pairFrame = LyraAuthHandshake.lengthDelimited(family == 5 ? 8 : 6, in: handshakeFrame),
              let serverNotify = LyraAuthHandshake.lengthDelimited(3, in: pairFrame),
              let cipherSuite = LyraAuthHandshake.lengthDelimited(1, in: serverNotify),
              let serverRandom = LyraAuthHandshake.lengthDelimited(2, in: cipherSuite),
              serverRandom.count == 32,
              let publicKeyMessage = LyraAuthHandshake.lengthDelimited(5, in: cipherSuite),
              let serverPubData = LyraAuthHandshake.lengthDelimited(2, in: publicKeyMessage),
              let p256Key,
              let serverPub = try? P256.KeyAgreement.PublicKey(x963Representation: serverPubData),
              let secret = try? p256Key.sharedSecretFromKeyAgreement(with: serverPub)
                  .withUnsafeBytes({ Data($0) })
        else {
            state = .failed("bad upgrade reply")
            onEvent("mishare sender upgrade reply parse failed")
            return
        }
        // The Mac tries clientRandom+serverRandom ("cs") first and keeps the
        // variant that decrypts; it answers with that same variant.
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            salt: LyraMeshHkdf.salt,
            info: clientRandom + serverRandom,
            outputByteCount: 32
        )
        channelKey = key

        var channelRequest = Data()
        LyraProtoWriter.appendVarintField(1, value: UInt64(channelId), to: &channelRequest)
        LyraProtoWriter.appendLengthDelimitedField(4, value: transKey, to: &channelRequest)
        LyraProtoWriter.appendLengthDelimitedField(5, value: transRandom, to: &channelRequest)
        var privateData = Data()
        LyraProtoWriter.appendLengthDelimitedField(10, value: channelRequest, to: &privateData)
        var request = Data()
        LyraProtoWriter.appendLengthDelimitedField(2, value: Data(serviceName.utf8), to: &request)
        LyraProtoWriter.appendLengthDelimitedField(3, value: privateData, to: &request)
        send(
            inner: LogiConnInnerFrame(frameType: 1, payload: .request(request)),
            server: server, encryptWith: key
        )
        state = .requesting
        onEvent("mishare sender conn request sent")
    }

    private func sendRequestOfPeerPort(server: LyraPhoneMeshServer, key: SymmetricKey) {
        var body = Data()
        LyraProtoWriter.appendVarintField(1, value: UInt64(channelId), to: &body)
        LyraProtoWriter.appendLengthDelimitedField(4, value: transKey, to: &body)
        let command = LyraChannelProtocol.encode(type: .requestOfPeerPort, body: body)
        guard let sealed = LyraAuthHandshake.gcmSeal(command, using: key) else { return }
        var payload = Data()
        payload.append(UInt8(identity.netId & 0xFF))
        payload.append(1)
        payload.append(sealed)
        sendMeshFrame(LyraMeshPack.Frame(packType: 5, payload: payload), server: server)
    }

    // MARK: - Sends

    private func send(
        inner: LogiConnInnerFrame, server: LyraPhoneMeshServer, encryptWith key: SymmetricKey? = nil
    ) {
        if let host = dialHost, let port = dialPort {
            server.sendLogi(connId: connId, inner: inner, encryptWith: key, toHost: host, port: port)
        } else {
            server.sendLogi(connId: connId, inner: inner, encryptWith: key)
        }
    }

    private func sendMeshFrame(_ frame: LyraMeshPack.Frame, server: LyraPhoneMeshServer) {
        if let host = dialHost, let port = dialPort {
            server.send(frame: frame, to: host, port: port)
        } else {
            server.sendToPeer(frame: frame)
        }
    }

    private static func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress { arc4random_buf(base, count) }
        }
        return data
    }
}
