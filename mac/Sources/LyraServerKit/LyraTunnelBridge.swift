import EdgeLinkKit
import Foundation
import Network

public actor LyraTunnelBridge {
    public typealias SendHandler = @Sendable (Data) async throws -> Void

    // Connection-refused dial budget (500 ms apart): long enough to cover the
    // phone's async WFD RTSP listener startup after OPEN_MIRROR_SCREEN.
    private let dialRetryAttempts: Int

    private struct StreamState {
        let connection: NWConnection
        var recvCredit: Int = TunnelConstants.initialCredit
        var sendCredit: Int = TunnelConstants.initialCredit
        var bytesIn: Int = 0
        var bytesOut: Int = 0
    }

    private struct TunnelState {
        let direction: TunnelDirection
        let targetHost: String
        let targetPort: Int
        let label: String?
        var streams: [Int: StreamState] = [:]
        var nextStreamId: Int = 1
        var listener: NWListener?
    }

    private let sendHandler: SendHandler
    private let log: @Sendable (String) -> Void
    private var tunnels: [String: TunnelState] = [:]
    private var allowlist = TunnelAllowlist()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        sendHandler: @escaping SendHandler,
        log: @escaping @Sendable (String) -> Void = { _ in },
        dialRetryAttempts: Int = 12
    ) {
        self.sendHandler = sendHandler
        self.log = log
        self.dialRetryAttempts = dialRetryAttempts
    }

    public static func handles(_ type: String) -> Bool {
        switch type {
        case EnvelopeType.tunnelOpen,
             EnvelopeType.tunnelOpenResult,
             EnvelopeType.tunnelData,
             EnvelopeType.tunnelClose,
             EnvelopeType.tunnelError,
             EnvelopeType.tunnelFlow:
            return true
        default:
            return false
        }
    }

    public func handleEnvelope(type: String, plaintext: Data) async {
        switch type {
        case EnvelopeType.tunnelOpen:
            guard let envelope = try? decoder.decode(Envelope<TunnelOpenBody>.self, from: plaintext) else { return }
            await handleTunnelOpen(envelope.b)
        case EnvelopeType.tunnelOpenResult:
            guard let envelope = try? decoder.decode(Envelope<TunnelOpenResultBody>.self, from: plaintext) else { return }
            if !envelope.b.ok {
                log("tunnel.phone.open_rejected tunnelId=\(envelope.b.tunnelId) error=\(envelope.b.error ?? "unknown")")
                await removeTunnel(tunnelId: envelope.b.tunnelId)
            }
        case EnvelopeType.tunnelData:
            guard let envelope = try? decoder.decode(Envelope<TunnelDataBody>.self, from: plaintext) else { return }
            await handleTunnelData(envelope.b)
        case EnvelopeType.tunnelClose:
            guard let envelope = try? decoder.decode(Envelope<TunnelCloseBody>.self, from: plaintext) else { return }
            closeStream(tunnelId: envelope.b.tunnelId, streamId: envelope.b.streamId)
        case EnvelopeType.tunnelError:
            guard let envelope = try? decoder.decode(Envelope<TunnelErrorBody>.self, from: plaintext) else { return }
            log("tunnel.phone.error tunnelId=\(envelope.b.tunnelId) code=\(envelope.b.code.rawValue)")
            if let streamId = envelope.b.streamId {
                closeStream(tunnelId: envelope.b.tunnelId, streamId: streamId)
            }
        case EnvelopeType.tunnelFlow:
            guard let envelope = try? decoder.decode(Envelope<TunnelFlowBody>.self, from: plaintext) else { return }
            tunnels[envelope.b.tunnelId]?.streams[envelope.b.streamId]?.sendCredit += envelope.b.credit
        default:
            break
        }
    }

    public func removeTunnel(tunnelId: String) {
        guard let tunnel = tunnels.removeValue(forKey: tunnelId) else { return }
        tunnel.listener?.cancel()
        for (_, stream) in tunnel.streams {
            stream.connection.cancel()
        }
    }

    public func resetAll() {
        for tunnelId in tunnels.keys {
            removeTunnel(tunnelId: tunnelId)
        }
    }

    public var activeTunnelCount: Int {
        tunnels.count
    }

    private func handleTunnelOpen(_ body: TunnelOpenBody) async {
        guard allowlist.isAllowed(host: body.targetHost, port: body.targetPort) else {
            try? await sendEnvelope(EnvelopeType.tunnelError, TunnelErrorBody(
                tunnelId: body.tunnelId,
                code: .notAllowed,
                message: "Target not in allowlist"
            ))
            return
        }

        if body.direction == .local {
            tunnels[body.tunnelId] = TunnelState(
                direction: .local,
                targetHost: body.targetHost,
                targetPort: body.targetPort,
                label: body.label
            )
            try? await sendEnvelope(EnvelopeType.tunnelOpenResult, TunnelOpenResultBody(tunnelId: body.tunnelId, ok: true))
            log("tunnel.phone.open_accepted tunnelId=\(body.tunnelId) target=\(body.targetHost):\(body.targetPort)")
        } else {
            await startRemoteForward(body)
        }
    }

    private func startRemoteForward(_ body: TunnelOpenBody) async {
        do {
            let parameters = NWParameters.tcp
            parameters.requiredInterfaceType = .loopback
            let listener = try NWListener(using: parameters)
            var tunnel = TunnelState(
                direction: .remote,
                targetHost: body.targetHost,
                targetPort: body.targetPort,
                label: body.label,
                listener: listener
            )
            tunnels[body.tunnelId] = tunnel

            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                Task { await self.acceptRemoteConnection(tunnelId: body.tunnelId, connection: connection) }
            }
            listener.start(queue: .global(qos: .userInitiated))

            guard let listenPort = await waitForListenerPort(listener) else {
                await removeTunnel(tunnelId: body.tunnelId)
                try? await sendEnvelope(EnvelopeType.tunnelError, TunnelErrorBody(
                    tunnelId: body.tunnelId,
                    code: .internalError,
                    message: "listener_failed"
                ))
                return
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed = state {
                    Task { await self?.removeTunnel(tunnelId: body.tunnelId) }
                }
            }
            tunnel.listener = listener
            tunnels[body.tunnelId] = tunnel
            try? await sendEnvelope(EnvelopeType.tunnelOpenResult, TunnelOpenResultBody(
                tunnelId: body.tunnelId,
                ok: true,
                listenPort: Int(listenPort.rawValue)
            ))
            log("tunnel.phone.remote_listen tunnelId=\(body.tunnelId) port=\(listenPort.rawValue)")
        } catch {
            try? await sendEnvelope(EnvelopeType.tunnelError, TunnelErrorBody(
                tunnelId: body.tunnelId,
                code: .internalError,
                message: "\(error)"
            ))
        }
    }

    private func acceptRemoteConnection(tunnelId: String, connection: NWConnection) {
        guard var tunnel = tunnels[tunnelId] else {
            connection.cancel()
            return
        }
        let streamId = tunnel.nextStreamId
        tunnel.nextStreamId += 1
        tunnel.streams[streamId] = StreamState(connection: connection)
        tunnels[tunnelId] = tunnel

        connection.start(queue: .global(qos: .userInitiated))
        startReadLoop(tunnelId: tunnelId, streamId: streamId, connection: connection)

        Task {
            try? await sendEnvelope(EnvelopeType.tunnelOpen, TunnelOpenBody(
                tunnelId: tunnelId,
                direction: .remote,
                targetHost: tunnel.targetHost,
                targetPort: tunnel.targetPort,
                label: "stream:\(streamId)"
            ))
        }
    }

    private func handleTunnelData(_ body: TunnelDataBody) async {
        guard let tunnel = tunnels[body.tunnelId] else { return }

        if tunnel.streams[body.streamId] == nil {
            guard tunnel.direction == .local else { return }
            let dialed = await dialTarget(
                tunnelId: body.tunnelId,
                streamId: body.streamId,
                host: tunnel.targetHost,
                port: tunnel.targetPort
            )
            if !dialed {
                try? await sendEnvelope(EnvelopeType.tunnelError, TunnelErrorBody(
                    tunnelId: body.tunnelId,
                    streamId: body.streamId,
                    code: .targetRefused,
                    message: "Cannot connect to \(tunnel.targetHost):\(tunnel.targetPort)"
                ))
                return
            }
        }

        guard var stream = tunnels[body.tunnelId]?.streams[body.streamId] else { return }
        stream.recvCredit -= body.payload.count

        if let data = TunnelChunker.payloadFromBase64(body.payload), !data.isEmpty {
            stream.bytesIn += data.count
            stream.connection.send(content: data, completion: .idempotent)
        }

        if body.fin {
            stream.connection.send(
                content: nil,
                contentContext: .finalMessage,
                isComplete: true,
                completion: .idempotent
            )
        }

        if stream.recvCredit < TunnelConstants.initialCredit * 3 / 4 {
            let grant = TunnelConstants.initialCredit - stream.recvCredit
            stream.recvCredit = TunnelConstants.initialCredit
            tunnels[body.tunnelId]?.streams[body.streamId] = stream
            try? await sendEnvelope(EnvelopeType.tunnelFlow, TunnelFlowBody(
                tunnelId: body.tunnelId,
                streamId: body.streamId,
                credit: grant
            ))
        } else {
            tunnels[body.tunnelId]?.streams[body.streamId] = stream
        }
    }

    private func dialTarget(tunnelId: String, streamId: Int, host: String, port: Int) async -> Bool {
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
            return false
        }
        // Retry connection-refused: the Xiaomi mirror WFD RTSP listener comes
        // up asynchronously after the phone processes OPEN_MIRROR_SCREEN, so
        // the first dial can land before it listens (the LAN path tolerates
        // this via the Mac WFD client's connect retries). Give up when the
        // tunnel is torn down or the attempt budget runs out.
        var attempt = 0
        while attempt < dialRetryAttempts {
            attempt += 1
            let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
            let ready = await waitForReady(connection, timeout: 1.5)
            if ready {
                tunnels[tunnelId]?.streams[streamId] = StreamState(connection: connection)
                startReadLoop(tunnelId: tunnelId, streamId: streamId, connection: connection)
                log("tunnel.phone.dial_ok tunnelId=\(tunnelId) stream=\(streamId) attempts=\(attempt) target=\(host):\(port)")
                return true
            }
            connection.cancel()
            guard tunnels[tunnelId] != nil else { return false }
            guard attempt < dialRetryAttempts else { break }
            log("tunnel.phone.dial_retry tunnelId=\(tunnelId) stream=\(streamId) attempt=\(attempt) target=\(host):\(port)")
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        log("tunnel.phone.dial_failed tunnelId=\(tunnelId) stream=\(streamId) attempts=\(attempt) target=\(host):\(port)")
        return false
    }

    private func startReadLoop(tunnelId: String, streamId: Int, connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: TunnelChunker.maxChunkSize) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            Task {
                await self.handleSocketReceive(
                    tunnelId: tunnelId,
                    streamId: streamId,
                    connection: connection,
                    data: data,
                    isComplete: isComplete,
                    error: error
                )
            }
        }
    }

    private func handleSocketReceive(
        tunnelId: String,
        streamId: Int,
        connection: NWConnection,
        data: Data?,
        isComplete: Bool,
        error: Error?
    ) async {
        if let data, !data.isEmpty {
            tunnels[tunnelId]?.streams[streamId]?.bytesOut += data.count
            for chunk in TunnelChunker.chunk(data) {
                try? await sendEnvelope(EnvelopeType.tunnelData, TunnelDataBody(
                    tunnelId: tunnelId,
                    streamId: streamId,
                    seq: chunk.seq,
                    payload: TunnelChunker.payloadBase64(chunk.data),
                    fin: false
                ))
            }
            startReadLoop(tunnelId: tunnelId, streamId: streamId, connection: connection)
            return
        }

        if isComplete || error != nil {
            try? await sendEnvelope(EnvelopeType.tunnelData, TunnelDataBody(
                tunnelId: tunnelId,
                streamId: streamId,
                seq: 0,
                payload: "",
                fin: true
            ))
            closeStream(tunnelId: tunnelId, streamId: streamId)
            return
        }

        startReadLoop(tunnelId: tunnelId, streamId: streamId, connection: connection)
    }

    private func closeStream(tunnelId: String, streamId: Int) {
        guard let stream = tunnels[tunnelId]?.streams.removeValue(forKey: streamId) else { return }
        stream.connection.cancel()
    }

    private func sendEnvelope<Body: Codable & Sendable>(_ type: String, _ body: Body) async throws {
        try await sendHandler(encoder.encode(Envelope(t: type, b: body)))
    }

    private func waitForReady(_ connection: NWConnection, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            let gate = SingleResumeGate<Bool>()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    gate.resume(with: true, continuation: continuation)
                case .failed, .cancelled:
                    gate.resume(with: false, continuation: continuation)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                gate.resume(with: false, continuation: continuation)
            }
        }
    }

    private func waitForListenerPort(_ listener: NWListener) async -> NWEndpoint.Port? {
        await withCheckedContinuation { continuation in
            let gate = SingleResumeGate<NWEndpoint.Port?>()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    gate.resume(with: listener.port, continuation: continuation)
                case .failed, .cancelled:
                    gate.resume(with: nil, continuation: continuation)
                default:
                    break
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                gate.resume(with: nil, continuation: continuation)
            }
        }
    }
}

private final class SingleResumeGate<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func resume(with value: Value, continuation: CheckedContinuation<Value, Never>) {
        lock.lock()
        if resumed {
            lock.unlock()
            return
        }
        resumed = true
        lock.unlock()
        continuation.resume(returning: value)
    }
}
