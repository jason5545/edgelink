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
        var recvBuffer = Data()
        var pendingSegments: [UInt32: Data] = [:]
    }

    // The phone's KCP input drops over-MTU UDP datagrams (its own pushes arrive
    // as 1400-byte datagrams = 1376 stream bytes + 24-byte segment header), so
    // large frames must be split into <=1376-byte stream chunks on send.
    private static let maxSegmentPayload = 1376

    private let queue = DispatchQueue(label: "edgelink.lyra.mesh", qos: .userInitiated)
    private var listener: NWListener?
    private var inboundConnections: [ObjectIdentifier: NWConnection] = [:]
    private var outboundConnections: [String: NWConnection] = [:]
    private var sessionStates: [ObjectIdentifier: KcpSessionState] = [:]
    private var lastActivityByConnection: [ObjectIdentifier: Date] = [:]
    private var physKeepaliveTimer: DispatchSourceTimer?

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
        startPhysKeepalives()
    }

    public func stop() {
        physKeepaliveTimer?.cancel()
        physKeepaliveTimer = nil
        lastActivityByConnection.removeAll()
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
        let id: ObjectIdentifier
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
            let newId = ObjectIdentifier(newConnection)
            receive(on: newConnection, id: newId)
            connection = newConnection
        }
        id = ObjectIdentifier(connection)
        let encoded = try LyraMeshPack.encode(frame)
        sendEncoded(encoded, on: connection, id: id)
    }

    // Writes an encoded frame as one or more KCP stream segments (chunked at
    // maxSegmentPayload), advancing the per-connection send sequence.
    private func sendEncoded(_ encoded: Data, on connection: NWConnection, id: ObjectIdentifier) {
        var state = sessionStates[id] ?? KcpSessionState()
        let tick = Self.tick()
        var offset = 0
        while offset < encoded.count {
            let end = min(offset + Self.maxSegmentPayload, encoded.count)
            let datagram = LyraMeshDatagram.encode(
                tick: tick,
                sn: state.nextSendSn,
                una: state.recvUna,
                payload: encoded[offset..<end]
            )
            state.nextSendSn &+= 1
            connection.send(content: datagram, completion: .idempotent)
            offset = end
        }
        sessionStates[id] = state
    }

    public func sendInbound(frame: LyraMeshPack.Frame, toEndpointDescription endpointDescription: String) throws {
        try queue.sync {
            try sendInboundOnQueue(frame: frame, toEndpointDescription: endpointDescription)
        }
    }

    public func sendInboundAsync(frame: LyraMeshPack.Frame, toEndpointDescription endpointDescription: String) {
        queue.async { [weak self] in
            try? self?.sendInboundOnQueue(frame: frame, toEndpointDescription: endpointDescription)
        }
    }

    private func sendInboundOnQueue(frame: LyraMeshPack.Frame, toEndpointDescription endpointDescription: String) throws {
        guard let (id, connection) = inboundConnections.first(where: { _, connection in
            (connection.currentPath?.remoteEndpoint ?? connection.endpoint).debugDescription == endpointDescription
        }) else {
            throw SocketError.invalidEndpoint
        }
        let encoded = try LyraMeshPack.encode(frame)
        sendEncoded(encoded, on: connection, id: id)
    }

    public static func tick() -> UInt32 {
        UInt32(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }

    public func startPhysKeepalives(interval: TimeInterval = 5, activityTimeout: TimeInterval = 15) {
        physKeepaliveTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.sendPhysKeepalives(activityTimeout: activityTimeout)
        }
        physKeepaliveTimer = timer
        timer.resume()
    }

    private func sendPhysKeepalives(activityTimeout: TimeInterval) {
        let now = Date()
        for (id, connection) in inboundConnections {
            guard let lastActivity = lastActivityByConnection[id],
                  now.timeIntervalSince(lastActivity) <= activityTimeout
            else {
                continue
            }
            var payload = Data()
            LyraProtoWriter.appendVarintField(1, value: UInt64(Self.tick()), to: &payload)
            LyraProtoWriter.appendVarintField(2, value: 1, to: &payload)
            let physConn = PhysConnFrame(field2: 4, payload: .keepAliveRequest(payload))
            let miFrame = MiConnectFrame(version: 0, logiConnFrames: [], physConnFrame: physConn)
            let frame = LyraMeshPack.Frame(packType: 1, payload: miFrame.serialized())
            guard let encoded = try? LyraMeshPack.encode(frame) else {
                continue
            }
            var state = sessionStates[id] ?? KcpSessionState()
            let datagram = LyraMeshDatagram.encode(
                tick: Self.tick(),
                sn: state.nextSendSn,
                una: state.recvUna,
                payload: encoded
            )
            state.nextSendSn &+= 1
            sessionStates[id] = state
            connection.send(content: datagram, completion: .idempotent)
        }
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
                self.lastActivityByConnection[id] = nil
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
                   !segment.payload.isEmpty
                {
                    lastActivityByConnection[id] = Date()
                    var state = self.sessionStates[id] ?? KcpSessionState()
                    let isDuplicate = segment.sn < state.recvUna
                    if !isDuplicate {
                        state.pendingSegments[segment.sn] = segment.payload
                        if state.pendingSegments.count > 64 {
                            state.pendingSegments = [:]
                            state.recvBuffer.removeAll()
                        }
                        var next = state.recvUna
                        while let payload = state.pendingSegments.removeValue(forKey: next) {
                            state.recvBuffer.append(payload)
                            next &+= 1
                        }
                        state.recvUna = next
                        if state.recvBuffer.count > 1_000_000 {
                            state.recvBuffer.removeAll()
                        }
                    }
                    self.sessionStates[id] = state
                    let ack = LyraMeshDatagram.encodeAck(tick: Self.tick(), sn: segment.sn, una: state.recvUna)
                    connection.send(content: ack, completion: .idempotent)
                    if !isDuplicate {
                        self.drainFrames(on: connection, id: id, endpoint: endpoint)
                    }
                }
            }
            if error == nil {
                self.receive(on: connection, id: id)
            }
        }
    }

    // The mesh stream is length-prefixed LyraMeshPack frames over an ordered
    // KCP segment stream; a frame can span segments and a segment can carry
    // multiple frames, so decode from a persistent per-connection buffer.
    private func drainFrames(on connection: NWConnection, id: ObjectIdentifier, endpoint: NWEndpoint) {
        let reply: ReplyHandler = { responseFrame in
            let encoded = try LyraMeshPack.encode(responseFrame)
            self.sendEncoded(encoded, on: connection, id: id)
        }
        while var state = self.sessionStates[id], state.recvBuffer.count >= LyraMeshPack.headerLength {
            do {
                let decoded = try LyraMeshPack.decode(state.recvBuffer)
                state.recvBuffer.removeFirst(decoded.consumedBytes)
                self.sessionStates[id] = state
                self.onFrame?(decoded.frame, endpoint, reply)
            } catch LyraMeshPack.PackError.truncated {
                break
            } catch {
                state.recvBuffer.removeFirst()
                self.sessionStates[id] = state
            }
        }
    }
}

public enum LyraMeshHkdf {
    public static let salt = Data([
        0x5E, 0xD5, 0xA3, 0xF8, 0x36, 0xF6, 0xB5, 0x4F,
        0x7B, 0x1E, 0xFA, 0xD0, 0x27, 0x14, 0xD5, 0x17,
        0x7B, 0x8A, 0x1F, 0x0F, 0x19, 0xE3, 0x69, 0xCC,
        0x0B, 0xE8, 0xD9, 0x8B, 0xA6, 0x29, 0x73, 0x17
    ])
}
