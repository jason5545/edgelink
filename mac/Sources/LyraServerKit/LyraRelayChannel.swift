import EdgeLinkKit
import Foundation

public final class LyraRelayChannel: ByteChannel, @unchecked Sendable {
    private static let keepaliveIntervalNanoseconds: UInt64 = 15_000_000_000

    private let task: URLSessionWebSocketTask
    private let log: @Sendable (String) -> Void
    private let lifecycleLock = NSLock()
    private var keepaliveTask: Task<Void, Never>?
    private var isClosed = false
    private var resolvedRole = "unknown"

    public var role: String {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return resolvedRole
    }

    private init(task: URLSessionWebSocketTask, log: @escaping @Sendable (String) -> Void) {
        self.task = task
        self.log = log
    }

    public static func connect(
        endpoint: URL,
        hostId: String,
        identity: LocalIdentity,
        session: URLSession = .shared,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> LyraRelayChannel {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw LyraRelayChannelError.invalidEndpoint
        }
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "hostId", value: hostId))
        components.queryItems = queryItems
        guard let url = components.url else {
            throw LyraRelayChannelError.invalidEndpoint
        }

        let task = session.webSocketTask(with: url)
        let channel = LyraRelayChannel(task: task, log: log)
        task.resume()
        log("relay.open_start hostId=\(hostId) deviceId=\(identity.deviceId)")

        do {
            let timestamp = Int64(Date().timeIntervalSince1970)
            let auth = try RelayAuth.envelope(hostId: hostId, identity: identity, timestampSeconds: timestamp)
            try await channel.sendText(String(decoding: JSONEncoder().encode(auth), as: UTF8.self))
            let readyText = try await channel.receiveText()
            let ready = try JSONDecoder().decode(LyraRelayReadyEnvelope.self, from: Data(readyText.utf8))
            guard ready.t == "relay.ready" else {
                throw LyraRelayChannelError.unexpectedReadyMessage
            }
            channel.setRole(ready.b.role)
            log("relay.ready hostId=\(hostId) deviceId=\(identity.deviceId) role=\(ready.b.role) colo=\(ready.b.colo ?? "unknown")")
            channel.startKeepalive()
            return channel
        } catch {
            channel.close()
            throw error
        }
    }

    private func setRole(_ role: String) {
        lifecycleLock.lock()
        resolvedRole = role
        lifecycleLock.unlock()
    }

    public func send(_ bytes: Data) async throws {
        try await task.send(.data(bytes))
    }

    public func receive() async throws -> Data? {
        while true {
            let message = try await task.receive()
            switch message {
            case .data(let data):
                return data
            case .string(let text):
                if text != #"{"t":"pong"}"# {
                    log("relay.text_ignored text=\(text)")
                }
                continue
            @unknown default:
                continue
            }
        }
    }

    public func close() {
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

        log("relay.close")
        taskToCancel?.cancel()
        task.cancel(with: .goingAway, reason: nil)
    }

    private func sendText(_ text: String) async throws {
        try await task.send(.string(text))
    }

    private func receiveText() async throws -> String {
        while true {
            let message = try await task.receive()
            switch message {
            case .string(let text):
                return text
            case .data:
                continue
            @unknown default:
                continue
            }
        }
    }

    private func startKeepalive() {
        let newTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: Self.keepaliveIntervalNanoseconds)
                    try Task.checkCancellation()
                    try await self?.sendText(#"{"t":"ping"}"#)
                } catch is CancellationError {
                    return
                } catch {
                    self?.log("relay.ping_failed error=\(error)")
                    self?.close()
                    return
                }
            }
        }

        lifecycleLock.lock()
        if isClosed {
            lifecycleLock.unlock()
            newTask.cancel()
            return
        }
        keepaliveTask = newTask
        lifecycleLock.unlock()
    }
}

private struct LyraRelayReadyEnvelope: Decodable {
    struct Body: Decodable {
        let role: String
        let colo: String?
    }

    let t: String
    let b: Body
}

public enum LyraRelayChannelError: Error {
    case invalidEndpoint
    case unexpectedReadyMessage
}
