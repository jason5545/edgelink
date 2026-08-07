import CryptoKit
import EdgeLinkKit
import Foundation
import Network

// TeleService's relayCall client: dials com.ios.phone:relayCall on the
// announce mesh conn once the Mac is online with the relayCall service.
// sync_info carries the key_index + auth-reuse cred + quick-conn
// ConnRequestFrame (all AES-GCM'd with the announce session key); after the
// logi response + ack, the Mac answers responseOfPeerPort in a plaintext
// packType-5 command and the call channel comes up for relay:// URIs.
public final class LyraRelayCallRole: LyraServiceHandler {
    public static let relayServiceName = "com.ios.phone:relayCall"
    public static let servicePackage = "com.ios.phone"
    public let serviceName = "com.ios.phone:relayCall"

    public enum State: Sendable, Equatable {
        case idle
        case dialing
        case awaitingPeerPort
        case channelUp
        case failed(String)
    }

    public var onEvent: (String) -> Void = { _ in }
    public private(set) var state: State = .idle
    // Assertion surface
    public private(set) var logiResponseReceived = false
    public private(set) var peerPort: UInt16 = 0
    public private(set) var lastRingResponse: String?

    private let identity: LyraPhoneIdentity
    // Relay-transport harness: the relayCall channel crosses the relay
    // session through this pipe instead of dialing the peer port over UDP.
    private let channelTransport: LyraChannelDatagramPipe?
    private var connId: UInt32 = 0
    private var sessionKey: SymmetricKey?
    private var channelSocket: LyraChannelDatagramPipe?
    private var transKey = Data()
    private let clientChannelId: UInt64 = 7
    private var methodCounter: UInt64 = 0

    public init(identity: LyraPhoneIdentity, channelTransport: LyraChannelDatagramPipe? = nil) {
        self.identity = identity
        self.channelTransport = channelTransport
    }

    // Dials the Mac's relayCall service over the established announce conn
    // (sessionKey = the announce AuthHandshake session key).
    public func dial(server: LyraPhoneMeshServer, sessionKey: SymmetricKey) {
        state = .dialing
        self.sessionKey = sessionKey
        connId = UInt32.random(in: 1...UInt32.max)
        server.adoptOutboundConn(connId: connId, handler: self)
        transKey = LyraPhoneIdentity.randomBytes(32)

        var peerPortRequest = Data()
        LyraProtoWriter.appendVarintField(1, value: clientChannelId, to: &peerPortRequest)
        LyraProtoWriter.appendLengthDelimitedField(4, value: transKey, to: &peerPortRequest)
        LyraProtoWriter.appendLengthDelimitedField(5, value: LyraPhoneIdentity.randomBytes(32), to: &peerPortRequest)
        var userInfo = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &userInfo)
        LyraProtoWriter.appendLengthDelimitedField(2, value: Data(Self.servicePackage.utf8), to: &userInfo)
        LyraProtoWriter.appendLengthDelimitedField(
            3, value: Data(Self.colonHex(LyraPhoneIdentity.randomBytes(32)).utf8), to: &userInfo
        )
        LyraProtoWriter.appendLengthDelimitedField(10, value: peerPortRequest, to: &userInfo)
        var request = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &request)
        LyraProtoWriter.appendLengthDelimitedField(2, value: Data(Self.relayServiceName.utf8), to: &request)
        LyraProtoWriter.appendLengthDelimitedField(3, value: userInfo, to: &request)
        var connRequest = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &connRequest)
        LyraProtoWriter.appendLengthDelimitedField(2, value: request, to: &connRequest)
        guard let quickConn = LyraAuthHandshake.gcmSeal(connRequest, using: sessionKey) else {
            state = .failed("quick-conn seal failed")
            return
        }

        var syncInfo = Data()
        LyraProtoWriter.appendVarintField(1, value: 10000, to: &syncInfo)
        LyraProtoWriter.appendVarintField(2, value: 16, to: &syncInfo)
        LyraProtoWriter.appendVarintField(3, value: 1, to: &syncInfo)
        LyraProtoWriter.appendLengthDelimitedField(4, value: Data(Self.relayServiceName.utf8), to: &syncInfo)
        LyraProtoWriter.appendLengthDelimitedField(5, value: identity.uidFeatureInfo(), to: &syncInfo)
        if let encCred = identity.encryptedLocalCred(using: sessionKey) {
            LyraProtoWriter.appendLengthDelimitedField(6, value: encCred, to: &syncInfo)
        }
        LyraProtoWriter.appendLengthDelimitedField(8, value: quickConn, to: &syncInfo)
        let inner = LogiConnInnerFrame(frameType: 5, payload: .syncInfo(syncInfo))
        server.sendLogi(connId: connId, inner: inner)

        // The peer-port answer arrives as a plaintext packType-5 command.
        let previousHandler = server.plaintextCommandHandler
        server.plaintextCommandHandler = { [weak self] command in
            guard let self, self.handlePlaintextCommand(command, server: server) else {
                return previousHandler?(command) ?? false
            }
            return true
        }
        onEvent("relayCall dialed connId=\(connId)")
    }

    public func hangup(server: LyraPhoneMeshServer) {
        channelSocket?.stop()
        channelSocket = nil
        server.forgetConn(connId: connId)
        state = .idle
    }

    // MARK: - Frames from the Mac

    public func handleServiceSyncInfo(
        syncInfoData: Data, logiConn: LogiConnFrame, server: LyraPhoneMeshServer
    ) {
        onEvent("relayCall server sync_info")
    }

    public func handleServiceLogiConn(_ logiConn: LogiConnFrame, server: LyraPhoneMeshServer) {
        guard logiConn.flag, let key = sessionKey,
              let plaintext = LyraAuthHandshake.gcmOpen(logiConn.inner, using: key),
              let inner = LogiConnInnerFrame(parsing: plaintext)
        else { return }
        if case .response = inner.payload {
            logiResponseReceived = true
            state = .awaitingPeerPort
            // Ack so the Mac sends responseOfPeerPort.
            let ack = LogiConnInnerFrame(frameType: 3, payload: .responseAck(Data()))
            server.sendLogi(connId: connId, inner: ack, encryptWith: key)
            onEvent("relayCall logi response, ack sent")
        }
    }

    private func handlePlaintextCommand(_ command: Data, server: LyraPhoneMeshServer) -> Bool {
        guard let (header, body) = try? LyraChannelProtocol.decode(command),
              header.type == LyraChannelProtocol.CommandType.responseOfPeerPort.rawValue
        else { return false }
        let fields = (try? LyraProtoReader.readFields(from: body)) ?? []
        var port: UInt16 = 0
        for field in fields where field.number == 3 {
            port = UInt16(field.varintValue ?? 0)
        }
        guard port != 0 else { return false }
        peerPort = port
        connectChannel(server: server)
        return true
    }

    private func connectChannel(server: LyraPhoneMeshServer) {
        let socket: LyraChannelDatagramPipe = channelTransport ?? LyraChannelSocket()
        socket.onNegotiated = { [weak self] serverChannelId, mtu in
            self?.state = .channelUp
            self?.onEvent("relayCall channel up serverChannelId=\(serverChannelId) mtu=\(mtu)")
        }
        socket.onMessage = { [weak self] message, _ in
            self?.handleChannelMessage(message)
        }
        do {
            try socket.connect(host: "127.0.0.1", port: peerPort, socketKey: transKey)
            try socket.sendClientNegotiation(
                channelId: UInt32(clientChannelId), version: 1, mtu: 0xFF00
            )
            channelSocket = socket
        } catch {
            state = .failed("channel connect failed: \(error)")
            onEvent("relayCall channel connect failed: \(error)")
        }
    }

    // MARK: - relay:// URI scripting

    // Simulates an incoming call on the phone: ring request to the Mac.
    public func sendRing(number: String, callState: String = "incoming") {
        methodCounter += 1
        let json = "{\"address\":\"\(number)\",\"callstate\":\"\(callState)\"}"
        sendURI(method: "ring", id: methodCounter, kind: "request", query: json)
    }

    public func sendCallStateIdle() {
        methodCounter += 1
        sendURI(method: "call_state_idle", id: methodCounter, kind: "request", query: "{}")
    }

    private func sendURI(method: String, id: UInt64, kind: String, query: String) {
        guard let socket = channelSocket, !transKey.isEmpty else { return }
        let uri = "relay://\(method):\(id)/\(kind)?\(query)"
        do {
            try socket.sendVariant(
                channelFrame: LyraChannelSocket.wrapChannelFrame(Data(uri.utf8)),
                key: transKey,
                singleLayer: true
            )
            onEvent("relayCall uri tx \(uri)")
        } catch {
            onEvent("relayCall uri tx failed: \(error)")
        }
    }

    private func handleChannelMessage(_ message: Data) {
        var payload = message
        if let (tag, child) = try? LyraExpressTLVParser.parseOneOf(message), tag == 1,
           let payloadNode = LyraExpressTLVParser.firstChild(
               0, in: LyraExpressTLVParser.children(of: child)
           )
        {
            payload = payloadNode.payload
        }
        // The Mac protobuf-wraps its URIs ({f1: text}); the real phone sends
        // the raw string. Accept both.
        if String(data: payload, encoding: .utf8)?.hasPrefix("relay://") != true,
           let unwrapped = LyraAuthHandshake.lengthDelimited(1, in: payload)
        {
            payload = unwrapped
        }
        guard let text = String(data: payload, encoding: .utf8), text.hasPrefix("relay://") else {
            return
        }
        onEvent("relayCall uri rx \(text)")
        if text.contains("/response?") {
            lastRingResponse = text
        }
    }

    public func handleServiceMeshCommand(payload: Data, server: LyraPhoneMeshServer) -> Bool {
        false
    }

    private static func colonHex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}
