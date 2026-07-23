import EdgeLinkKit
import Foundation
import Network

final class LANSessionListener: @unchecked Sendable {
    static let port: UInt16 = 7_105
    static let serviceType = "_edgelink._tcp"

    private let queue = DispatchQueue(label: "EdgeLink.LANSessionListener")
    private let stateLock = NSLock()
    private var listener: NWListener?
    private let onAccept: (ByteChannel) -> Void

    init(onAccept: @escaping (ByteChannel) -> Void) {
        self.onAccept = onAccept
    }

    func start(serviceName: String) {
        let shouldStart = stateLock.withLock { () -> Bool in
            listener == nil
        }
        guard shouldStart else {
            return
        }
        do {
            guard let port = NWEndpoint.Port(rawValue: Self.port) else {
                DiagnosticsLog.warn("lan.mac.session_listen_failed invalid_port")
                return
            }
            let nextListener = try NWListener(using: .tcp, on: port)
            nextListener.service = NWListener.Service(name: serviceName, type: Self.serviceType)
            stateLock.withLock {
                listener = nextListener
            }
            nextListener.stateUpdateHandler = { [weak self, weak nextListener] state in
                guard let self, let nextListener else {
                    return
                }
                switch state {
                case .ready:
                    DiagnosticsLog.info("lan.mac.session_listening port=\(Self.port) type=\(Self.serviceType)")
                case .failed(let error):
                    self.stateLock.withLock {
                        if self.listener === nextListener {
                            self.listener = nil
                        }
                    }
                    DiagnosticsLog.error("lan.mac.session_listen_failed port=\(Self.port)", error)
                    nextListener.cancel()
                case .cancelled:
                    self.stateLock.withLock {
                        if self.listener === nextListener {
                            self.listener = nil
                        }
                    }
                default:
                    break
                }
            }
            nextListener.newConnectionHandler = { [weak self] connection in
                guard let self else {
                    connection.cancel()
                    return
                }
                DiagnosticsLog.info("lan.mac.session_accepted endpoint=\(connection.endpoint)")
                self.onAccept(LANTCPByteChannel(connection: connection, queue: self.queue))
            }
            nextListener.start(queue: queue)
        } catch {
            DiagnosticsLog.error("lan.mac.session_listen_failed port=\(Self.port)", error)
        }
    }

    func stop() {
        let activeListener = stateLock.withLock { () -> NWListener? in
            let activeListener = listener
            listener = nil
            return activeListener
        }
        activeListener?.cancel()
    }
}

final class LANTCPByteChannel: ByteChannel, @unchecked Sendable {
    private static let maxFrameBytes = 4 * 1024 * 1024

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let stateLock = NSLock()
    private var isClosed = false
    private var receiveBuffer = Data()

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func send(_ bytes: Data) async throws {
        var frame = Data()
        var length = UInt32(bytes.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(bytes)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: frame,
                contentContext: .defaultMessage,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }

    func receive() async throws -> Data? {
        while true {
            if receiveBuffer.count >= 4 {
                let header = [UInt8](receiveBuffer.prefix(4))
                let length = (Int(header[0]) << 24) | (Int(header[1]) << 16) | (Int(header[2]) << 8) | Int(header[3])
                guard length <= Self.maxFrameBytes else {
                    close()
                    throw LANChannelError.frameTooLarge
                }
                if receiveBuffer.count >= 4 + length {
                    let payload = Data(receiveBuffer.dropFirst(4).prefix(length))
                    receiveBuffer.removeFirst(4 + length)
                    return payload
                }
            }
            guard let chunk = try await receiveChunk() else {
                return nil
            }
            receiveBuffer.append(chunk)
        }
    }

    func close() {
        let shouldClose = stateLock.withLock { () -> Bool in
            if isClosed {
                return false
            }
            isClosed = true
            return true
        }
        guard shouldClose else {
            return
        }
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else {
                return
            }
            switch state {
            case .failed(let error):
                DiagnosticsLog.error("lan.mac.channel_failed", error)
                self.close()
            case .cancelled:
                self.close()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receiveChunk() async throws -> Data? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                    return
                }
                if isComplete {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: Data())
            }
        }
    }
}

enum LANChannelError: Error {
    case frameTooLarge
}
