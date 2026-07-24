import EdgeLinkKit
import Foundation
import Network

// MARK: - Lyra micont TCP Tunnel Manager (Route a)
// Manages TCP tunneling through the phone's native TunnelManager via Lyra LogiConn TransDataType 6.

final class LyraTunnelManager {
    struct TunnelStream {
        let tunnelHandle: UInt32
        var connection: NWConnection?
        var state: TunnelStreamState = .opening
        var bytesIn: Int = 0
        var bytesOut: Int = 0
        var lastActivity: Date = Date()
        var paused: Bool = false
    }

    struct TunnelSession {
        let targetHost: String
        let targetPort: Int
        let label: String?
        var listener: NWListener?
        var listenPort: UInt16 = 0
        var streams: [UInt32: TunnelStream] = [:]
        var nextHandle: UInt32 = 1
        var bytesTransferred: Int = 0
    }

    private var sessions: [String: TunnelSession] = [:]
    private var handleToSession: [UInt32: String] = [:]
    private var allowlist = TunnelAllowlist()
    private let queue = DispatchQueue(label: "edgelink.lyra.tunnel", qos: .userInitiated)
    private var probeMode = true

    var sendTunnelFrame: ((Data) -> Void)?
    var onStateChanged: (() -> Void)?
    var diagnosticsHandler: ((String) -> Void)?

    init() {}

    // MARK: - Public API

    func startLocalForward(
        tunnelId: String,
        targetHost: String,
        targetPort: Int,
        label: String?,
        completion: @escaping (Result<UInt16, Error>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.allowlist.isAllowed(host: targetHost, port: targetPort) else {
                completion(.failure(LyraTunnelError.notAllowed))
                return
            }

            do {
                let parameters = NWParameters.tcp
                parameters.allowLocalEndpointReuse = true
                let listener = try NWListener(using: parameters, on: .any)
                var session = TunnelSession(
                    targetHost: targetHost,
                    targetPort: targetPort,
                    label: label,
                    listener: listener
                )

                listener.stateUpdateHandler = { [weak self] state in
                    if case .ready = state {
                        let port = listener.port?.rawValue ?? 0
                        self?.queue.async {
                            self?.sessions[tunnelId]?.listenPort = port
                            completion(.success(port))
                        }
                    } else if case .failed = state {
                        completion(.failure(LyraTunnelError.listenerFailed))
                    }
                }

                listener.newConnectionHandler = { [weak self] connection in
                    self?.queue.async {
                        self?.acceptConnection(connection, tunnelId: tunnelId)
                    }
                }

                listener.start(queue: queue)
                sessions[tunnelId] = session
                self.diagnosticsHandler?("lyra.tunnel.start_local tunnelId=\(tunnelId) target=\(targetHost):\(targetPort)")
            } catch {
                completion(.failure(error))
            }
        }
    }

    func removeTunnel(tunnelId: String) {
        queue.async { [weak self] in
            guard let self else { return }
            guard var session = self.sessions[tunnelId] else { return }
            session.listener?.cancel()
            for (handle, var stream) in session.streams {
                stream.connection?.cancel()
                let finish = TunnelActionFrame.finish(TunnelActionFrameFinish(tunnelHandle: handle))
                self.sendTunnelFrame?(finish.serialized())
                self.handleToSession[handle] = nil
            }
            self.sessions[tunnelId] = nil
            self.onStateChanged?()
        }
    }

    func resetAllStreams() {
        queue.async { [weak self] in
            guard let self else { return }
            for (tunnelId, var session) in self.sessions {
                for (handle, var stream) in session.streams {
                    stream.connection?.cancel()
                    let error = TunnelActionFrame.error(TunnelActionFrameError(tunnelHandle: handle, code: 1, message: "session_reset"))
                    self.sendTunnelFrame?(error.serialized())
                    self.handleToSession[handle] = nil
                }
                session.streams.removeAll()
                self.sessions[tunnelId] = session
            }
            self.onStateChanged?()
        }
    }

    func activeSessions() -> [(id: String, target: String, port: Int, streams: Int, bytes: Int)] {
        var result: [(String, String, Int, Int, Int)] = []
        for (id, session) in sessions {
            result.append((id, session.targetHost, session.targetPort, session.streams.count, session.bytesTransferred))
        }
        return result
    }

    // MARK: - Inbound Tunnel Frame Handling (from phone via TransDataType 6)

    func handleTunnelPayload(_ payload: Data) {
        queue.async { [weak self] in
            guard let self else { return }

            if self.probeMode {
                let hex = payload.prefix(64).map { String(format: "%02x", $0) }.joined()
                self.diagnosticsHandler?("lyra.tunnel.rx_probe bytes=\(payload.count) hex=\(hex)")
            }

            if let pack = TunnelActionFramePack(parsing: payload) {
                for frame in pack.frames {
                    self.handleActionFrame(frame)
                }
            } else if let frame = TunnelActionFrame(parsing: payload) {
                self.handleActionFrame(frame)
            } else {
                self.diagnosticsHandler?("lyra.tunnel.rx_unparsed bytes=\(payload.count)")
            }
        }
    }

    // MARK: - Private: Action Frame Dispatch

    private func handleActionFrame(_ frame: TunnelActionFrame) {
        switch frame {
        case .accept(let f):
            handleAccept(f)
        case .reject(let f):
            handleReject(f)
        case .pushData(let f):
            handlePushData(f)
        case .ackData(let f):
            handleAckData(f)
        case .finish(let f):
            handleFinish(f)
        case .error(let f):
            handleError(f)
        case .pause(let f):
            handlePause(f)
        case .resume(let f):
            handleResume(f)
        case .connect(let f):
            handleConnect(f)
        }
    }

    private func handleAccept(_ frame: TunnelActionFrameAccept) {
        guard let tunnelId = handleToSession[frame.tunnelHandle],
              var session = sessions[tunnelId],
              var stream = session.streams[frame.tunnelHandle] else { return }
        stream.state = .open
        session.streams[frame.tunnelHandle] = stream
        sessions[tunnelId] = session
        diagnosticsHandler?("lyra.tunnel.accept handle=\(frame.tunnelHandle)")
        onStateChanged?()
    }

    private func handleReject(_ frame: TunnelActionFrameReject) {
        guard let tunnelId = handleToSession[frame.tunnelHandle],
              var session = sessions[tunnelId] else { return }
        session.streams[frame.tunnelHandle]?.connection?.cancel()
        session.streams[frame.tunnelHandle] = nil
        sessions[tunnelId] = session
        handleToSession[frame.tunnelHandle] = nil
        diagnosticsHandler?("lyra.tunnel.reject handle=\(frame.tunnelHandle) reason=\(frame.reason)")
        onStateChanged?()
    }

    private func handlePushData(_ frame: TunnelActionFramePushData) {
        guard let tunnelId = handleToSession[frame.tunnelHandle],
              var session = sessions[tunnelId],
              var stream = session.streams[frame.tunnelHandle] else { return }

        stream.lastActivity = Date()
        stream.bytesIn += frame.payload.count
        session.bytesTransferred += frame.payload.count
        session.streams[frame.tunnelHandle] = stream
        sessions[tunnelId] = session

        if let connection = stream.connection {
            connection.send(content: frame.payload, completion: .contentProcessed { [weak self] error in
                if error != nil {
                    self?.queue.async {
                        self?.closeStream(tunnelId: tunnelId, handle: frame.tunnelHandle)
                    }
                }
            })
        }

        let ack = TunnelActionFrame.ackData(TunnelActionFrameAckData(
            tunnelHandle: frame.tunnelHandle,
            ackedBytes: UInt32(frame.payload.count)
        ))
        sendTunnelFrame?(ack.serialized())
    }

    private func handleAckData(_ frame: TunnelActionFrameAckData) {
        diagnosticsHandler?("lyra.tunnel.ack handle=\(frame.tunnelHandle) bytes=\(frame.ackedBytes)")
    }

    private func handleFinish(_ frame: TunnelActionFrameFinish) {
        guard let tunnelId = handleToSession[frame.tunnelHandle],
              var session = sessions[tunnelId],
              var stream = session.streams[frame.tunnelHandle] else { return }
        stream.state = .halfClosedRemote
        stream.connection?.forceCancel()
        session.streams[frame.tunnelHandle] = nil
        sessions[tunnelId] = session
        handleToSession[frame.tunnelHandle] = nil
        diagnosticsHandler?("lyra.tunnel.finish handle=\(frame.tunnelHandle)")
        onStateChanged?()
    }

    private func handleError(_ frame: TunnelActionFrameError) {
        guard let tunnelId = handleToSession[frame.tunnelHandle],
              var session = sessions[tunnelId] else { return }
        session.streams[frame.tunnelHandle]?.connection?.cancel()
        session.streams[frame.tunnelHandle] = nil
        sessions[tunnelId] = session
        handleToSession[frame.tunnelHandle] = nil
        diagnosticsHandler?("lyra.tunnel.error handle=\(frame.tunnelHandle) code=\(frame.code) msg=\(frame.message ?? "")")
        onStateChanged?()
    }

    private func handlePause(_ frame: TunnelActionFramePause) {
        guard let tunnelId = handleToSession[frame.tunnelHandle],
              var session = sessions[tunnelId],
              var stream = session.streams[frame.tunnelHandle] else { return }
        stream.paused = true
        session.streams[frame.tunnelHandle] = stream
        sessions[tunnelId] = session
        diagnosticsHandler?("lyra.tunnel.pause handle=\(frame.tunnelHandle)")
    }

    private func handleResume(_ frame: TunnelActionFrameResume) {
        guard let tunnelId = handleToSession[frame.tunnelHandle],
              var session = sessions[tunnelId],
              var stream = session.streams[frame.tunnelHandle] else { return }
        stream.paused = false
        session.streams[frame.tunnelHandle] = stream
        sessions[tunnelId] = session
        diagnosticsHandler?("lyra.tunnel.resume handle=\(frame.tunnelHandle)")
    }

    private func handleConnect(_ frame: TunnelActionFrameConnect) {
        diagnosticsHandler?("lyra.tunnel.connect_in handle=\(frame.tunnelHandle) dest=\(frame.destinationAddress)")
    }

    // MARK: - Private: Local Connection Handling

    private func acceptConnection(_ connection: NWConnection, tunnelId: String) {
        guard var session = sessions[tunnelId] else {
            connection.cancel()
            return
        }

        let handle = session.nextHandle
        session.nextHandle += 1

        let stream = TunnelStream(tunnelHandle: handle, connection: connection, state: .opening)
        session.streams[handle] = stream
        sessions[tunnelId] = session
        handleToSession[handle] = tunnelId

        let connect = TunnelActionFrame.connect(TunnelActionFrameConnect(
            tunnelHandle: handle,
            destinationAddress: "\(session.targetHost):\(session.targetPort)"
        ))
        sendTunnelFrame?(connect.serialized())

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.queue.async {
                    self?.closeStream(tunnelId: tunnelId, handle: handle)
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
        readFromSocket(tunnelId: tunnelId, handle: handle)
        diagnosticsHandler?("lyra.tunnel.new_stream handle=\(handle) tunnelId=\(tunnelId)")
        onStateChanged?()
    }

    private func readFromSocket(tunnelId: String, handle: UInt32) {
        guard let session = sessions[tunnelId],
              let stream = session.streams[handle],
              let connection = stream.connection,
              !stream.paused else { return }

        connection.receive(minimumIncompleteLength: 1, maximumLength: 32768) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.queue.async {
                if let data, !data.isEmpty {
                    self.sendPushData(tunnelId: tunnelId, handle: handle, data: data)
                    self.readFromSocket(tunnelId: tunnelId, handle: handle)
                } else if isComplete || error != nil {
                    self.sendFinish(tunnelId: tunnelId, handle: handle)
                }
            }
        }
    }

    private func sendPushData(tunnelId: String, handle: UInt32, data: Data) {
        guard var session = sessions[tunnelId], var stream = session.streams[handle] else { return }
        stream.bytesOut += data.count
        stream.lastActivity = Date()
        session.bytesTransferred += data.count
        session.streams[handle] = stream
        sessions[tunnelId] = session

        let pushData = TunnelActionFrame.pushData(TunnelActionFramePushData(
            tunnelHandle: handle,
            payload: data
        ))
        sendTunnelFrame?(pushData.serialized())
    }

    private func sendFinish(tunnelId: String, handle: UInt32) {
        let finish = TunnelActionFrame.finish(TunnelActionFrameFinish(tunnelHandle: handle))
        sendTunnelFrame?(finish.serialized())
        closeStream(tunnelId: tunnelId, handle: handle)
    }

    private func closeStream(tunnelId: String, handle: UInt32) {
        guard var session = sessions[tunnelId] else { return }
        session.streams[handle]?.connection?.cancel()
        session.streams[handle] = nil
        sessions[tunnelId] = session
        handleToSession[handle] = nil
        onStateChanged?()
    }
}

enum LyraTunnelError: Error {
    case notAllowed
    case listenerFailed
    case sessionNotFound
}
