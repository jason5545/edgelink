import CryptoKit
import Foundation
import Network

public final class LyraChannelSocket: @unchecked Sendable {
    public enum SocketError: Error, Equatable, Sendable {
        case listenerNotReady
    }

    public var onPeerConnected: ((NWEndpoint) -> Void)?
    public var onNegotiated: ((UInt32, UInt32) -> Void)?
    public var onMessage: ((Data, NWEndpoint) -> Void)?
    public var onRawDatagram: ((Data, NWEndpoint) -> Void)?
    public var onStateChanged: ((NWListener.State) -> Void)?
    public var onDecryptFailure: ((String) -> Void)?

    public private(set) var boundPort: UInt16?

    private struct SessionState {
        var nextSendSn: UInt32 = 0
        var recvUna: UInt32 = 0
        var packetBuffer = Data()
        var negotiated = false
        var announced = false
        var fragments: [Int: Data] = [:]
        var fragmentExpectedTotal = 0
    }

    private let queue = DispatchQueue(label: "edgelink.lyra.channel", qos: .userInitiated)
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var sessions: [ObjectIdentifier: SessionState] = [:]
    private var socketKey: SymmetricKey?
    private var serverChannelId: UInt32 = 5

    public init() {}

    deinit {
        stop()
    }

    public func start(socketKey: Data, serverChannelId: UInt32 = 5) throws {
        stop()
        self.socketKey = SymmetricKey(data: socketKey)
        self.serverChannelId = serverChannelId
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state {
                self.boundPort = self.listener?.port?.rawValue
            }
            self.onStateChanged?(state)
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    public func stop() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        for connection in connections.values {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
        connections.removeAll()
        sessions.removeAll()
        boundPort = nil
    }

    public func send(message: Data) throws {
        guard let socketKey else { return }
        let channelFrame = Self.wrapChannelFrame(message)
        try sendEncrypted(channelFrame, key: socketKey, singleLayer: false)
    }

    public static func wrapChannelFrame(_ message: Data) -> Data {
        LyraExpressTLV.oneOfNode(
            tag: 0xFFFF,
            selectedTag: 1,
            child: LyraExpressTLV.containerNode(tag: 1, children: [
                LyraExpressTLV.stringNode(tag: 0, value: message)
            ])
        )
    }

    public func sendVariant(channelFrame: Data, key: Data, singleLayer: Bool) throws {
        try sendEncrypted(channelFrame, key: SymmetricKey(data: key), singleLayer: singleLayer)
    }

    private func sendEncrypted(_ channelFrame: Data, key: SymmetricKey, singleLayer: Bool) throws {
        if singleLayer {
            let packet = try LyraSocketPacket.encode(plaintext: channelFrame, key: key)
            try sendDatagram(packet)
            return
        }
        let fragments = try LyraChannelFragment.encode(message: channelFrame, key: key)
        for fragment in fragments {
            let packet = try LyraSocketPacket.encode(plaintext: fragment, key: key)
            try sendDatagram(packet)
        }
    }

    private func sendRaw(_ payload: Data) throws {
        try sendDatagram(payload)
    }

    private func sendDatagram(_ payload: Data) throws {
        for (id, connection) in connections {
            var state = sessions[id] ?? SessionState()
            let datagram = LyraMeshDatagram.encode(
                tick: LyraMeshSocket.tick(),
                sn: state.nextSendSn,
                una: state.recvUna,
                payload: payload
            )
            state.nextSendSn &+= 1
            sessions[id] = state
            connection.send(content: datagram, completion: .idempotent)
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .cancelled, .failed:
                self.connections[id] = nil
                self.sessions[id] = nil
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, id: id)
    }

    private func receive(on connection: NWConnection, id: ObjectIdentifier) {
        connection.receiveMessage { [weak self] content, _, _, error in
            guard let self else { return }
            if let content, !content.isEmpty {
                let endpoint = connection.currentPath?.remoteEndpoint ?? connection.endpoint
                self.onRawDatagram?(content, endpoint)
                if let segment = try? LyraMeshDatagram.decodeSegment(content),
                   segment.command == LyraMeshDatagram.commandPush
                {
                    var state = self.sessions[id] ?? SessionState()
                    let isDuplicate = segment.sn < state.recvUna
                    if !isDuplicate {
                        state.recvUna = segment.sn &+ 1
                    }
                    self.sessions[id] = state
                    let ack = LyraMeshDatagram.encodeAck(
                        tick: LyraMeshSocket.tick(),
                        sn: segment.sn,
                        una: state.recvUna
                    )
                    connection.send(content: ack, completion: .idempotent)
                    if !isDuplicate {
                        if !state.announced {
                            state.announced = true
                            self.sessions[id] = state
                            self.onPeerConnected?(endpoint)
                        }
                        state.packetBuffer.append(segment.payload)
                        self.drainPackets(id: id, state: &state, endpoint: endpoint)
                        self.sessions[id] = state
                    }
                }
            }
            if error == nil {
                self.receive(on: connection, id: id)
            }
        }
    }

    public var candidateKeys: [Data] = []

    private func decryptionKeys() -> [SymmetricKey] {
        var keys: [SymmetricKey] = []
        if let socketKey {
            keys.append(socketKey)
        }
        for candidate in candidateKeys where candidate.count >= 16 {
            keys.append(SymmetricKey(data: candidate))
        }
        return keys
    }

    private func openPacketAndFragment(_ frame: Data) -> (chunk: Data, offset: Int, total: Int, isLast: Bool)? {
        for key in decryptionKeys() {
            guard let (fragment, _) = try? LyraSocketPacket.decode(frame, key: key) else {
                continue
            }
            if let decoded = try? LyraChannelFragment.decode(fragment: fragment, key: key) {
                return decoded
            }
            if let oneOf = try? LyraExpressTLVParser.parseOneOf(fragment) {
                _ = oneOf
                return (fragment, 0, 1, true)
            }
        }
        return nil
    }

    private func drainPackets(id: ObjectIdentifier, state: inout SessionState, endpoint: NWEndpoint) {
        guard socketKey != nil else { return }
        while !state.packetBuffer.isEmpty {
            let first = state.packetBuffer[state.packetBuffer.startIndex]
            let second = state.packetBuffer[state.packetBuffer.index(state.packetBuffer.startIndex, offsetBy: 1)]
            if first == 0x01, second == 0x01 {
                guard state.packetBuffer.count >= 10 else { return }
                let tlvLength = 8 + Int(Self.readUInt32BE(state.packetBuffer, at: 4))
                guard state.packetBuffer.count >= tlvLength else { return }
                let tlv = Data(state.packetBuffer.prefix(tlvLength))
                state.packetBuffer.removeFirst(tlvLength)
                handlePlaintextTLV(tlv, state: &state)
            } else if first == 0x81, second == 0x04 {
                guard let frameLength = LyraSocketPacket.frameLength(prefix: state.packetBuffer), frameLength > 0 else {
                    state.packetBuffer = Data()
                    return
                }
                guard state.packetBuffer.count >= frameLength else { return }
                let frame = Data(state.packetBuffer.prefix(frameLength))
                state.packetBuffer.removeFirst(frameLength)
                guard let (chunk, offset, total, isLast) = openPacketAndFragment(frame) else {
                    onDecryptFailure?("socket_packet bytes=\(frame.count)")
                    continue
                }
                if total <= 1 || isLast && offset == 0 {
                    deliver(chunk: chunk, offset: offset, total: total, state: &state, endpoint: endpoint)
                } else {
                    state.fragments[offset] = chunk
                    state.fragmentExpectedTotal = total
                    deliver(chunk: chunk, offset: offset, total: total, state: &state, endpoint: endpoint)
                }
            } else {
                state.packetBuffer = Data()
                return
            }
        }
    }

    private func deliver(chunk: Data, offset: Int, total: Int, state: inout SessionState, endpoint: NWEndpoint) {
        if total <= 1 {
            state.fragments.removeAll()
            state.fragmentExpectedTotal = 0
            onMessage?(chunk, endpoint)
            return
        }
        state.fragments[offset] = chunk
        state.fragmentExpectedTotal = total
        guard state.fragments.count == total else { return }
        var message = Data()
        for key in state.fragments.keys.sorted() {
            if let part = state.fragments[key] {
                message.append(part)
            }
        }
        state.fragments.removeAll()
        state.fragmentExpectedTotal = 0
        onMessage?(message, endpoint)
    }

    private func handlePlaintextTLV(_ tlv: Data, state: inout SessionState) {
        guard let (selectedTag, children) = Self.parseOneOf(tlv) else {
            onDecryptFailure?("negotiation_tlv_parse bytes=\(tlv.count)")
            return
        }
        if selectedTag == 0, children.count >= 3 {
            let peerChannelId = children[0]
            let version = children[1]
            let mtu = children[2]
            let reply = LyraExpressTLV.oneOfNode(
                tag: 0xFFFF,
                selectedTag: 4,
                child: LyraExpressTLV.containerNode(tag: 4, children: [
                    LyraExpressTLV.int32Node(tag: 0, value: serverChannelId),
                    LyraExpressTLV.int32Node(tag: 1, value: 0xFF00)
                ])
            )
            do {
                try sendRaw(reply)
                state.negotiated = true
                onNegotiated?(peerChannelId, mtu)
            } catch {
                onDecryptFailure?("negotiation_reply_send_failed")
            }
            _ = version
        }
    }

    private static func parseOneOf(_ data: Data) -> (UInt32, [UInt32])? {
        let bytes = Array(data)
        guard bytes.count >= 10,
              bytes[0] == 0x01, bytes[1] == 0x01
        else { return nil }
        let selectedTag = UInt32((UInt16(bytes[8]) << 8) | UInt16(bytes[9]))
        guard bytes.count >= 18,
              bytes[10] == 0x01, bytes[11] == 0x00
        else { return nil }
        var values: [UInt32] = []
        var index = 18
        while index + 12 <= bytes.count {
            let nodeType = UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1])
            let nodeLength = Int(Self.readUInt32BE(data, at: index + 4))
            guard nodeType == 0x0003, nodeLength == 4, index + 8 + nodeLength <= bytes.count else { break }
            let value = Self.readUInt32BE(data, at: index + 8)
            values.append(value)
            index += 8 + nodeLength
        }
        return (selectedTag, values)
    }

    private static func readUInt32BE(_ data: Data, at offset: Int) -> UInt32 {
        let i = data.index(data.startIndex, offsetBy: offset)
        return (UInt32(data[i]) << 24) | (UInt32(data[i + 1]) << 16) | (UInt32(data[i + 2]) << 8) | UInt32(data[i + 3])
    }
}
