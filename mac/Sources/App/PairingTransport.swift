import EdgeLinkKit
import Foundation

final class PairingTransport {
    private let baseURL: URL
    private let webSocketURL: URL
    private let session: URLSession
    private let encoder = JSONEncoder()

    init(baseURL: URL, webSocketURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.webSocketURL = webSocketURL
        self.session = session
    }

    func start(identity: LocalIdentity) async throws {
        let request = PairStartRequest(
            hostId: identity.deviceId,
            hostPk: identity.publicKey.base64EncodedString(),
            name: identity.name
        )
        try await post(path: "/v1/pair/start", body: request)
    }

    func confirm(_ confirmation: PairConfirmRequest) async throws {
        try await post(path: "/v1/pair/confirm", body: confirmation)
    }

    func connect(hostId: String) async throws -> PairingTextChannel {
        let task = session.webSocketTask(with: try pairURL(hostId: hostId))
        let channel = PairingTextChannel(task: task)
        task.resume()
        return channel
    }

    private func post<Body: Encodable>(path: String, body: Body) async throws {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try encoder.encode(body)

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw PairingTransportError.requestFailed
        }
    }

    private func pairURL(hostId: String) throws -> URL {
        guard var components = URLComponents(url: webSocketURL, resolvingAgainstBaseURL: false) else {
            throw PairingTransportError.invalidEndpoint
        }
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "hostId", value: hostId))
        components.queryItems = queryItems
        guard let url = components.url else {
            throw PairingTransportError.invalidEndpoint
        }
        return url
    }
}

final class PairingTextChannel: @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func receive() async throws -> String? {
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

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}

enum PairingTransportError: Error {
    case invalidEndpoint
    case requestFailed
}
