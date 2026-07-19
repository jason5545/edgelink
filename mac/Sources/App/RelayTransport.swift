import EdgeLinkKit
import Foundation

final class RelayTransport {
    private let endpoint: URL
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(endpoint: URL, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    func connect(hostId: String, identity: LocalIdentity) async throws -> ByteChannel {
        DiagnosticsLog.info("relay.transport.mac.open_start hostId=\(hostId) deviceId=\(identity.deviceId)")
        let task = session.webSocketTask(with: try relayURL(hostId: hostId))
        let channel = RelayWebSocketChannel(hostId: hostId, deviceId: identity.deviceId, task: task)
        task.resume()

        do {
            let timestamp = Int64(Date().timeIntervalSince1970)
            let auth = try RelayAuth.envelope(hostId: hostId, identity: identity, timestampSeconds: timestamp)
            try await channel.sendText(String(data: encoder.encode(auth), encoding: .utf8) ?? "")
            let ready = try await channel.receiveText()
            let readyEnvelope = try decoder.decode(RelayReadyEnvelope.self, from: Data(ready.utf8))
            guard readyEnvelope.t == "relay.ready" else {
                DiagnosticsLog.warn("relay.transport.mac.unexpected_ready hostId=\(hostId) text=\(ready)")
                throw RelayTransportError.unexpectedReadyMessage
            }
            DiagnosticsLog.info("relay.transport.mac.ready hostId=\(hostId) deviceId=\(identity.deviceId) role=\(readyEnvelope.b.role)")
            channel.startKeepalive()
            return channel
        } catch {
            channel.close()
            throw error
        }
    }

    private func relayURL(hostId: String) throws -> URL {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw RelayTransportError.invalidEndpoint
        }
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "hostId", value: hostId))
        components.queryItems = queryItems
        guard let url = components.url else {
            throw RelayTransportError.invalidEndpoint
        }
        return url
    }
}

private final class RelayWebSocketChannel: ByteChannel, @unchecked Sendable {
    private static let keepaliveIntervalNanoseconds: UInt64 = 15_000_000_000
    private static let pongTimeoutNanoseconds: UInt64 = 10_000_000_000

    private let hostId: String
    private let deviceId: String
    private let task: URLSessionWebSocketTask
    private let lifecycleLock = NSLock()
    private var keepaliveTask: Task<Void, Never>?
    private var isClosed = false
    private var binaryFramesSent: UInt64 = 0
    private var binaryFramesReceived: UInt64 = 0

    init(hostId: String, deviceId: String, task: URLSessionWebSocketTask) {
        self.hostId = hostId
        self.deviceId = deviceId
        self.task = task
    }

    func send(_ bytes: Data) async throws {
        let count = nextBinaryFrameCount(sent: true)
        if count <= 3 || count % 100 == 0 {
            DiagnosticsLog.info("relay.transport.mac.binary_out hostId=\(hostId) deviceId=\(deviceId) count=\(count) bytes=\(bytes.count)")
        }
        try await task.send(.data(bytes))
    }

    func receive() async throws -> Data? {
        while true {
            let message = try await task.receive()
            switch message {
            case .data(let data):
                let count = nextBinaryFrameCount(sent: false)
                if count <= 3 || count % 100 == 0 {
                    DiagnosticsLog.info("relay.transport.mac.binary_in hostId=\(hostId) deviceId=\(deviceId) count=\(count) bytes=\(data.count)")
                }
                return data
            case .string(let text):
                DiagnosticsLog.warn("relay.transport.mac.text_ignored hostId=\(hostId) deviceId=\(deviceId) text=\(text)")
                continue
            @unknown default:
                DiagnosticsLog.warn("relay.transport.mac.unknown_message hostId=\(hostId) deviceId=\(deviceId)")
                continue
            }
        }
    }

    private func nextBinaryFrameCount(sent: Bool) -> UInt64 {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        if sent {
            binaryFramesSent &+= 1
            return binaryFramesSent
        }
        binaryFramesReceived &+= 1
        return binaryFramesReceived
    }

    func close() {
        let taskToCancel: Task<Void, Never>?

        lifecycleLock.lock()
        if isClosed {
            lifecycleLock.unlock()
            return
        }
        isClosed = true
        taskToCancel = keepaliveTask
        keepaliveTask = nil
        lifecycleLock.unlock()

        DiagnosticsLog.info("relay.transport.mac.close hostId=\(hostId) deviceId=\(deviceId)")
        taskToCancel?.cancel()
        task.cancel(with: .goingAway, reason: nil)
    }

    func sendText(_ text: String) async throws {
        DiagnosticsLog.info("relay.transport.mac.text_out hostId=\(hostId) deviceId=\(deviceId) bytes=\(Data(text.utf8).count)")
        try await task.send(.string(text))
    }

    func receiveText() async throws -> String {
        while true {
            let message = try await task.receive()
            switch message {
            case .string(let text):
                DiagnosticsLog.info("relay.transport.mac.text_in hostId=\(hostId) deviceId=\(deviceId) bytes=\(Data(text.utf8).count)")
                return text
            case .data:
                DiagnosticsLog.warn("relay.transport.mac.binary_ignored_waiting_text hostId=\(hostId) deviceId=\(deviceId)")
                continue
            @unknown default:
                DiagnosticsLog.warn("relay.transport.mac.unknown_message_waiting_text hostId=\(hostId) deviceId=\(deviceId)")
                continue
            }
        }
    }

    func startKeepalive() {
        let previousTask: Task<Void, Never>?
        let newTask = Task { [weak self] in
            guard let self else {
                return
            }
            await self.runKeepalive()
        }

        lifecycleLock.lock()
        if isClosed {
            lifecycleLock.unlock()
            newTask.cancel()
            return
        }
        previousTask = keepaliveTask
        keepaliveTask = newTask
        lifecycleLock.unlock()

        previousTask?.cancel()
    }

    private func runKeepalive() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: Self.keepaliveIntervalNanoseconds)
                try Task.checkCancellation()
                try await sendPingWithTimeout()
            } catch is CancellationError {
                return
            } catch {
                DiagnosticsLog.error("relay.transport.mac.ping_failed hostId=\(hostId) deviceId=\(deviceId)", error)
                close()
                return
            }
        }
    }

    private func sendPingWithTimeout() async throws {
        let waiter = RelayPingWaiter()
        let timeoutTask = Task {
            do {
                try await Task.sleep(nanoseconds: Self.pongTimeoutNanoseconds)
                waiter.resume(throwing: RelayKeepaliveError.pongTimedOut)
            } catch {
                return
            }
        }
        defer { timeoutTask.cancel() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter.setContinuation(continuation)
                task.sendPing { error in
                    if let error {
                        waiter.resume(throwing: error)
                    } else {
                        waiter.resume()
                    }
                }
            }
        } onCancel: {
            waiter.resume(throwing: CancellationError())
        }
    }
}

private final class RelayPingWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var completedResult: Result<Void, Error>?

    func setContinuation(_ continuation: CheckedContinuation<Void, Error>) {
        let resultToResume: Result<Void, Error>?

        lock.lock()
        if let completedResult {
            resultToResume = completedResult
        } else {
            self.continuation = continuation
            resultToResume = nil
        }
        lock.unlock()

        if let resultToResume {
            resume(continuation, with: resultToResume)
        }
    }

    func resume() {
        resume(with: .success(()))
    }

    func resume(throwing error: Error) {
        resume(with: .failure(error))
    }

    private func resume(with result: Result<Void, Error>) {
        let continuationToResume: CheckedContinuation<Void, Error>?

        lock.lock()
        if completedResult != nil {
            continuationToResume = nil
        } else {
            completedResult = result
            continuationToResume = continuation
            continuation = nil
        }
        lock.unlock()

        if let continuationToResume {
            resume(continuationToResume, with: result)
        }
    }

    private func resume(_ continuation: CheckedContinuation<Void, Error>, with result: Result<Void, Error>) {
        switch result {
        case .success:
            continuation.resume(returning: ())
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

private struct RelayReadyEnvelope: Decodable {
    struct Body: Decodable {
        let role: String
    }

    let t: String
    let b: Body
}

enum RelayTransportError: Error {
    case invalidEndpoint
    case unexpectedReadyMessage
}

private enum RelayKeepaliveError: Error {
    case pongTimedOut
}
