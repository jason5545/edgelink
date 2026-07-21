import Foundation
import Network

public final class LyraMeshSocket: @unchecked Sendable {
    public enum SocketError: Error, Equatable, Sendable {
        case listenerNotReady
        case invalidEndpoint
    }

    public typealias ReplyHandler = (LyraMeshPack.Frame) throws -> Void

    public var onFrame: ((LyraMeshPack.Frame, NWEndpoint, ReplyHandler) -> Void)?
    public var onRawDatagram: ((Data, NWEndpoint) -> Void)?
    public var onStateChanged: ((NWListener.State) -> Void)?

    public private(set) var boundPort: UInt16?

    private struct KcpSessionState {
        var nextSendSn: UInt32 = 0
        var recvUna: UInt32 = 0
    }

    private let queue = DispatchQueue(label: "edgelink.lyra.mesh", qos: .userInitiated)
    private var listener: NWListener?
    private var inboundConnections: [ObjectIdentifier: NWConnection] = [:]
    private var outboundConnections: [String: NWConnection] = [:]
    private var sessionStates: [ObjectIdentifier: KcpSessionState] = [:]

    public init() {}

    deinit {
        stop()
    }

    public func start(preferredPort: UInt16? = nil) throws {
        stop()
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        let nwPort: NWEndpoint.Port? = preferredPort.flatMap { NWEndpoint.Port(rawValue: $0) }
        let listener = try NWListener(using: parameters, on: nwPort ?? .any)
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
        for connection in inboundConnections.values {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
        inboundConnections.removeAll()
        for connection in outboundConnections.values {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
        outboundConnections.removeAll()
        boundPort = nil
    }

    public func send(frame: LyraMeshPack.Frame, to host: String, port: UInt16) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw SocketError.invalidEndpoint
        }
        let key = "\(host):\(port)"
        let connection: NWConnection
        if let existing = outboundConnections[key] {
            connection = existing
        } else {
            let newConnection = NWConnection(
                host: NWEndpoint.Host(host),
                port: nwPort,
                using: .udp
            )
            outboundConnections[key] = newConnection
            newConnection.start(queue: queue)
            connection = newConnection
        }
        let datagram = LyraMeshDatagram.encode(tick: Self.tick(), payload: try LyraMeshPack.encode(frame))
        connection.send(content: datagram, completion: .idempotent)
    }

    public static func tick() -> UInt32 {
        UInt32(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        inboundConnections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .cancelled, .failed:
                self.inboundConnections[id] = nil
                self.sessionStates[id] = nil
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
                    var state = self.sessionStates[id] ?? KcpSessionState()
                    let isDuplicate = segment.sn < state.recvUna
                    if !isDuplicate {
                        state.recvUna = segment.sn &+ 1
                    }
                    self.sessionStates[id] = state
                    let ack = LyraMeshDatagram.encodeAck(tick: Self.tick(), sn: segment.sn, una: state.recvUna)
                    connection.send(content: ack, completion: .idempotent)
                    if !isDuplicate, let decoded = try? LyraMeshPack.decode(segment.payload) {
                        let reply: ReplyHandler = { responseFrame in
                            var replyState = self.sessionStates[id] ?? KcpSessionState()
                            let datagram = LyraMeshDatagram.encode(
                                tick: Self.tick(),
                                sn: replyState.nextSendSn,
                                una: replyState.recvUna,
                                payload: try LyraMeshPack.encode(responseFrame)
                            )
                            replyState.nextSendSn &+= 1
                            self.sessionStates[id] = replyState
                            connection.send(content: datagram, completion: .idempotent)
                        }
                        self.onFrame?(decoded.frame, endpoint, reply)
                    }
                }
            }
            if error == nil {
                self.receive(on: connection, id: id)
            }
        }
    }
}
