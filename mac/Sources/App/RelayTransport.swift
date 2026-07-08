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
        let task = session.webSocketTask(with: try relayURL(hostId: hostId))
        let channel = RelayWebSocketChannel(task: task)
        task.resume()

        let timestamp = Int64(Date().timeIntervalSince1970)
        let auth = try RelayAuth.envelope(hostId: hostId, identity: identity, timestampSeconds: timestamp)
        try await channel.sendText(String(data: encoder.encode(auth), encoding: .utf8) ?? "")
        let ready = try await channel.receiveText()
        guard try decoder.decode(RelayReadyEnvelope.self, from: Data(ready.utf8)).t == "relay.ready" else {
            throw RelayTransportError.unexpectedReadyMessage
        }
        return channel
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
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func send(_ bytes: Data) async throws {
        try await task.send(.data(bytes))
    }

    func receive() async throws -> Data? {
        while true {
            let message = try await task.receive()
            switch message {
            case .data(let data):
                return data
            case .string:
                continue
            @unknown default:
                continue
            }
        }
    }

    func sendText(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func receiveText() async throws -> String {
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
