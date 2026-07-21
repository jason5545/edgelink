import CryptoKit
import Foundation
import Network

public final class LyraChannelSocket: @unchecked Sendable {
    public enum SocketError: Error, Equatable, Sendable {
        case listenerNotReady
    }

    public var onPeerConnected: ((NWEndpoint) -> Void)?
    public var onMessage: ((Data, NWEndpoint) -> Void)?
    public var onRawDatagram: ((Data, NWEndpoint) -> Void)?
    public var onStateChanged: ((NWListener.State) -> Void)?

    public private(set) var boundPort: UInt16?

    private struct SessionState {
        var nextSendSn: UInt32 = 0
        var recvUna: UInt32 = 0
        var packetBuffer = Data()
        var fragmentBuffer = Data()
        var fragmentComplete = false
    }

    private let queue = DispatchQueue(label: "edgelink.lyra.channel", qos: .userInitiated)
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var sessions: [ObjectIdentifier: SessionState] = [:]
    private var peerKey: SymmetricKey?
    private var localKey: SymmetricKey?

    public init() {}

    deinit {
        stop()
    }

    public func start(peerKey: Data, localKey: Data) throws {
        stop()
        self.peerKey = SymmetricKey(data: peerKey)
        self.localKey = SymmetricKey(data: localKey)
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
        guard let localKey else { return }
        let fragments = try LyraChannelFragment.encode(message: message, key: localKey)
        for fragment in fragments {
            let packet = try LyraSocketPacket.encode(plaintext: fragment, key: localKey)
            try sendPacket(packet)
        }
    }

    private func sendPacket(_ packet: Data) throws {
        for (id, connection) in connections {
            var state = sessions[id] ?? SessionState()
            let datagram = LyraMeshDatagram.encode(
                tick: LyraMeshSocket.tick(),
                sn: state.nextSendSn,
                una: state.recvUna,
                payload: packet
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
                        if state.packetBuffer.isEmpty, state.fragmentBuffer.isEmpty {
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

    private func drainPackets(id: ObjectIdentifier, state: inout SessionState, endpoint: NWEndpoint) {
        guard let peerKey else { return }
        while let frameLength = LyraSocketPacket.frameLength(prefix: state.packetBuffer),
              frameLength > 0,
              state.packetBuffer.count >= frameLength
        {
            let frame = Data(state.packetBuffer.prefix(frameLength))
            state.packetBuffer.removeFirst(frameLength)
            guard let (fragment, _) = try? LyraSocketPacket.decode(frame, key: peerKey) else {
                continue
            }
            guard let (chunk, offset, _, isLast) = try? LyraChannelFragment.decode(fragment: fragment, key: peerKey) else {
                continue
            }
            if offset == 0 {
                state.fragmentBuffer = Data()
                state.fragmentComplete = false
            }
            state.fragmentBuffer.append(chunk)
            if isLast {
                let message = state.fragmentBuffer
                state.fragmentBuffer = Data()
                state.fragmentComplete = true
                onMessage?(message, endpoint)
            }
        }
        if let frameLength = LyraSocketPacket.frameLength(prefix: state.packetBuffer), frameLength <= 0 {
            state.packetBuffer = Data()
        }
    }
}
