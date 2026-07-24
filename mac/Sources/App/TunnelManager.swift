import EdgeLinkKit
import Foundation
import Network

// MARK: - EdgeLink TCP Tunnel Manager (Route b)
// Manages TCP port forwarding over EdgeLink secure envelopes for non-Xiaomi peers.

actor TunnelManager {
    struct TunnelInfo: Sendable {
        let tunnelId: String
        let direction: TunnelDirection
        let targetHost: String
        let targetPort: Int
        let label: String?
        var activeStreams: Int = 0
        var bytesTransferred: Int = 0
    }

    private struct StreamState {
        var connection: NWConnection?
        var listener: NWListener?
        var state: TunnelStreamState = .opening
        var sendCredit: Int = TunnelConstants.initialCredit
        var recvCredit: Int = TunnelConstants.initialCredit
        var nextSeq: Int = 0
        var lastActivity: Date = Date()
        var bytesIn: Int = 0
        var bytesOut: Int = 0
    }

    private var tunnels: [String: TunnelInfo] = [:]
    private var streams: [String: [Int: StreamState]] = [:]
    private var listeners: [String: NWListener] = [:]
    private var nextStreamId: [String: Int] = [:]
    private var allowlist = TunnelAllowlist()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    var sendHandler: (@Sendable (Data) async throws -> Void)?
    var onTunnelStateChanged: (@Sendable () -> Void)?

    // MARK: - Public API

    func setSendHandler(_ handler: @escaping @Sendable (Data) async throws -> Void) {
        sendHandler = handler
    }

    func activeTunnels() -> [TunnelInfo] {
        Array(tunnels.values)
    }

    func allowlistSnapshot() -> TunnelAllowlist {
        allowlist
    }

    // MARK: - Local Forward (Mac listens, peer dials target)

    func startLocalForward(targetHost: String, targetPort: Int, label: String?) async throws -> Int {
        guard allowlist.isAllowed(host: targetHost, port: targetPort) else {
            throw TunnelManagerError.notAllowed
        }

        let tunnelId = UUID().uuidString
        let info = TunnelInfo(
            tunnelId: tunnelId,
            direction: .local,
            targetHost: targetHost,
            targetPort: targetPort,
            label: label
        )
        tunnels[tunnelId] = info
        streams[tunnelId] = [:]
        nextStreamId[tunnelId] = 1

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let randomPort = NWEndpoint.Port(rawValue: UInt16.random(in: 40000...60000))!
        let listener = try NWListener(using: parameters, on: randomPort)
        listeners[tunnelId] = listener

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task { await self.acceptLocalConnection(connection, tunnelId: tunnelId) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                Task { await self?.removeTunnel(tunnelId: tunnelId) }
            }
        }
        listener.start(queue: .global(qos: .userInitiated))

        let openBody = TunnelOpenBody(
            tunnelId: tunnelId,
            direction: .local,
            targetHost: targetHost,
            targetPort: targetPort,
            label: label
        )
        try await sendEnvelope(EnvelopeType.tunnelOpen, body: openBody)

        guard let port = listener.port?.rawValue else {
            throw TunnelManagerError.listenerFailed
        }
        onTunnelStateChanged?()
        return Int(port)
    }

    // MARK: - Remote Forward (peer listens, Mac dials target)

    func startRemoteForward(targetHost: String, targetPort: Int, label: String?) async throws {
        guard allowlist.isAllowed(host: targetHost, port: targetPort) else {
            throw TunnelManagerError.notAllowed
        }

        let tunnelId = UUID().uuidString
        let info = TunnelInfo(
            tunnelId: tunnelId,
            direction: .remote,
            targetHost: targetHost,
            targetPort: targetPort,
            label: label
        )
        tunnels[tunnelId] = info
        streams[tunnelId] = [:]
        nextStreamId[tunnelId] = 1

        let openBody = TunnelOpenBody(
            tunnelId: tunnelId,
            direction: .remote,
            targetHost: targetHost,
            targetPort: targetPort,
            label: label
        )
        try await sendEnvelope(EnvelopeType.tunnelOpen, body: openBody)
        onTunnelStateChanged?()
    }

    func removeTunnel(tunnelId: String) async {
        listeners[tunnelId]?.cancel()
        listeners[tunnelId] = nil
        if let tunnelStreams = streams[tunnelId] {
            for (_, var stream) in tunnelStreams {
                stream.connection?.cancel()
                stream.listener?.cancel()
            }
        }
        streams[tunnelId] = nil
        tunnels[tunnelId] = nil
        nextStreamId[tunnelId] = nil
        onTunnelStateChanged?()
    }

    func resetAllStreams() async {
        for (tunnelId, tunnelStreams) in streams {
            for (streamId, var stream) in tunnelStreams {
                stream.connection?.cancel()
                streams[tunnelId]?[streamId] = nil
                let closeBody = TunnelCloseBody(tunnelId: tunnelId, streamId: streamId, fin: false, reset: true)
                try? await sendEnvelope(EnvelopeType.tunnelClose, body: closeBody)
            }
        }
        onTunnelStateChanged?()
    }

    // MARK: - Inbound Envelope Handling

    func handleEnvelope(type: String, plaintext: Data) async {
        switch type {
        case EnvelopeType.tunnelOpen:
            guard let envelope = try? decoder.decode(Envelope<TunnelOpenBody>.self, from: plaintext) else { return }
            await handleTunnelOpen(envelope.b)
        case EnvelopeType.tunnelOpenResult:
            guard let envelope = try? decoder.decode(Envelope<TunnelOpenResultBody>.self, from: plaintext) else { return }
            await handleTunnelOpenResult(envelope.b)
        case EnvelopeType.tunnelData:
            guard let envelope = try? decoder.decode(Envelope<TunnelDataBody>.self, from: plaintext) else { return }
            await handleTunnelData(envelope.b)
        case EnvelopeType.tunnelClose:
            guard let envelope = try? decoder.decode(Envelope<TunnelCloseBody>.self, from: plaintext) else { return }
            await handleTunnelClose(envelope.b)
        case EnvelopeType.tunnelError:
            guard let envelope = try? decoder.decode(Envelope<TunnelErrorBody>.self, from: plaintext) else { return }
            await handleTunnelError(envelope.b)
        case EnvelopeType.tunnelFlow:
            guard let envelope = try? decoder.decode(Envelope<TunnelFlowBody>.self, from: plaintext) else { return }
            await handleTunnelFlow(envelope.b)
        default:
            break
        }
    }

    // MARK: - Private: Local Forward

    private func acceptLocalConnection(_ connection: NWConnection, tunnelId: String) async {
        guard tunnels[tunnelId] != nil else {
            connection.cancel()
            return
        }

        let streamId = nextStreamId[tunnelId] ?? 1
        nextStreamId[tunnelId] = streamId + 1

        var stream = StreamState(connection: connection, state: .open)
        streams[tunnelId]?[streamId] = stream
        tunnels[tunnelId]?.activeStreams += 1

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed, .cancelled:
                Task { await self.handleLocalDisconnect(tunnelId: tunnelId, streamId: streamId) }
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
        readFromLocalSocket(tunnelId: tunnelId, streamId: streamId)
        onTunnelStateChanged?()
    }

    private func readFromLocalSocket(tunnelId: String, streamId: Int) {
        guard let stream = streams[tunnelId]?[streamId],
              let connection = stream.connection,
              stream.sendCredit > 0 else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: min(TunnelChunker.maxChunkSize, streams[tunnelId]?[streamId]?.sendCredit ?? TunnelChunker.maxChunkSize)) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            Task {
                if let data, !data.isEmpty {
                    await self.sendTunnelData(tunnelId: tunnelId, streamId: streamId, data: data, fin: false)
                    self.readFromLocalSocket(tunnelId: tunnelId, streamId: streamId)
                } else if isComplete || error != nil {
                    await self.sendTunnelData(tunnelId: tunnelId, streamId: streamId, data: Data(), fin: true)
                }
            }
        }
    }

    private func handleLocalDisconnect(tunnelId: String, streamId: Int) async {
        guard var stream = streams[tunnelId]?[streamId], stream.state != .closed else { return }
        stream.state = .closed
        stream.connection?.cancel()
        streams[tunnelId]?[streamId] = nil
        tunnels[tunnelId]?.activeStreams -= 1
        let closeBody = TunnelCloseBody(tunnelId: tunnelId, streamId: streamId, fin: true, reset: false)
        try? await sendEnvelope(EnvelopeType.tunnelClose, body: closeBody)
        onTunnelStateChanged?()
    }

    // MARK: - Private: Send Data

    private func sendTunnelData(tunnelId: String, streamId: Int, data: Data, fin: Bool) async {
        guard var stream = streams[tunnelId]?[streamId] else { return }
        stream.lastActivity = Date()
        stream.bytesOut += data.count
        stream.sendCredit -= data.count
        streams[tunnelId]?[streamId] = stream
        tunnels[tunnelId]?.bytesTransferred += data.count

        let chunks = TunnelChunker.chunk(data)
        for chunk in chunks {
            let isLastChunk = chunk.isLast && fin
            let body = TunnelDataBody(
                tunnelId: tunnelId,
                streamId: streamId,
                seq: chunk.seq,
                payload: TunnelChunker.payloadBase64(chunk.data),
                fin: isLastChunk
            )
            try? await sendEnvelope(EnvelopeType.tunnelData, body: body)
        }

        if data.isEmpty && fin {
            let body = TunnelDataBody(tunnelId: tunnelId, streamId: streamId, seq: 0, payload: "", fin: true)
            try? await sendEnvelope(EnvelopeType.tunnelData, body: body)
        }
    }

    // MARK: - Private: Inbound Handlers

    private func handleTunnelOpen(_ body: TunnelOpenBody) async {
        guard allowlist.isAllowed(host: body.targetHost, port: body.targetPort) else {
            let errorBody = TunnelErrorBody(tunnelId: body.tunnelId, code: .notAllowed, message: "Target not in allowlist")
            try? await sendEnvelope(EnvelopeType.tunnelError, body: errorBody)
            return
        }

        if body.direction == .remote {
            let info = TunnelInfo(
                tunnelId: body.tunnelId,
                direction: .remote,
                targetHost: body.targetHost,
                targetPort: body.targetPort,
                label: body.label
            )
            tunnels[body.tunnelId] = info
            streams[body.tunnelId] = [:]
            nextStreamId[body.tunnelId] = 1

            let resultBody = TunnelOpenResultBody(tunnelId: body.tunnelId, ok: true)
            try? await sendEnvelope(EnvelopeType.tunnelOpenResult, body: resultBody)
            onTunnelStateChanged?()
        }
    }

    private func handleTunnelOpenResult(_ body: TunnelOpenResultBody) async {
        guard var info = tunnels[body.tunnelId] else { return }
        if !body.ok {
            DiagnosticsLog.warn("tunnel.mac.open_rejected tunnelId=\(body.tunnelId) error=\(body.error ?? "unknown")")
            tunnels[body.tunnelId] = nil
            streams[body.tunnelId] = nil
        }
        _ = info
        onTunnelStateChanged?()
    }

    private func handleTunnelData(_ body: TunnelDataBody) async {
        guard var stream = streams[body.tunnelId]?[body.streamId] else {
            if body.fin { return }
            let errorBody = TunnelErrorBody(tunnelId: body.tunnelId, streamId: body.streamId, code: .streamNotFound)
            try? await sendEnvelope(EnvelopeType.tunnelError, body: errorBody)
            return
        }

        stream.lastActivity = Date()
        stream.recvCredit -= body.payload.count
        streams[body.tunnelId]?[body.streamId] = stream

        if let data = TunnelChunker.payloadFromBase64(body.payload), !data.isEmpty {
            stream.bytesIn += data.count
            tunnels[body.tunnelId]?.bytesTransferred += data.count
            if let connection = stream.connection {
                connection.send(content: data, completion: .contentProcessed { [weak self] error in
                    if error != nil {
                        Task { await self?.handleLocalDisconnect(tunnelId: body.tunnelId, streamId: body.streamId) }
                    }
                })
            }
        }

        if body.fin {
            stream.state = .halfClosedRemote
            stream.connection?.forceCancel()
            streams[body.tunnelId]?[body.streamId] = nil
            tunnels[body.tunnelId]?.activeStreams -= 1
            onTunnelStateChanged?()
        }

        if stream.recvCredit < TunnelConstants.initialCredit * 3 / 4 {
            let grant = TunnelConstants.initialCredit - stream.recvCredit
            stream.recvCredit = TunnelConstants.initialCredit
            streams[body.tunnelId]?[body.streamId] = stream
            let flowBody = TunnelFlowBody(tunnelId: body.tunnelId, streamId: body.streamId, credit: grant)
            try? await sendEnvelope(EnvelopeType.tunnelFlow, body: flowBody)
        }
    }

    private func handleTunnelClose(_ body: TunnelCloseBody) async {
        guard var stream = streams[body.tunnelId]?[body.streamId] else { return }
        stream.connection?.cancel()
        stream.state = .closed
        streams[body.tunnelId]?[body.streamId] = nil
        tunnels[body.tunnelId]?.activeStreams -= 1
        onTunnelStateChanged?()
    }

    private func handleTunnelError(_ body: TunnelErrorBody) async {
        DiagnosticsLog.warn("tunnel.mac.error tunnelId=\(body.tunnelId) streamId=\(body.streamId.map(String.init) ?? "nil") code=\(body.code.rawValue) msg=\(body.message ?? "")")
        if let streamId = body.streamId {
            streams[body.tunnelId]?[streamId]?.connection?.cancel()
            streams[body.tunnelId]?[streamId] = nil
            tunnels[body.tunnelId]?.activeStreams -= 1
        }
        onTunnelStateChanged?()
    }

    private func handleTunnelFlow(_ body: TunnelFlowBody) async {
        guard var stream = streams[body.tunnelId]?[body.streamId] else { return }
        let wasBlocked = stream.sendCredit <= 0
        stream.sendCredit += body.credit
        streams[body.tunnelId]?[body.streamId] = stream
        if wasBlocked {
            readFromLocalSocket(tunnelId: body.tunnelId, streamId: body.streamId)
        }
    }

    // MARK: - Private: Helpers

    private func sendEnvelope<T: Codable & Sendable>(_ type: String, body: T) async throws {
        let data = try encoder.encode(Envelope(t: type, b: body))
        try await sendHandler?(data)
    }
}

enum TunnelManagerError: Error {
    case notAllowed
    case listenerFailed
    case tunnelNotFound
}
