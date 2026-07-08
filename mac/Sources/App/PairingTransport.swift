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
        DiagnosticsLog.info("pair.transport.mac.start_http hostId=\(identity.deviceId)")
        let request = PairStartRequest(
            hostId: identity.deviceId,
            hostPk: identity.publicKey.base64EncodedString(),
            name: identity.name
        )
        try await post(path: "/v1/pair/start", body: request)
    }

    func confirm(_ confirmation: PairConfirmRequest) async throws {
        DiagnosticsLog.info("pair.transport.mac.confirm_http hostId=\(confirmation.hostId) clientId=\(confirmation.clientId) role=\(confirmation.role)")
        try await post(path: "/v1/pair/confirm", body: confirmation)
    }

    func connect(hostId: String) async throws -> PairingTextChannel {
        DiagnosticsLog.info("pair.transport.mac.ws_open_start hostId=\(hostId)")
        let task = session.webSocketTask(with: try pairURL(hostId: hostId))
        let channel = PairingTextChannel(hostId: hostId, task: task)
        task.resume()
        return channel
    }

    private func post<Body: Encodable>(path: String, body: Body) async throws {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await session.data(for: request)
        let responseBody = String(data: data, encoding: .utf8) ?? ""
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            DiagnosticsLog.error("pair.transport.mac.http_failed path=\(path) status=\(status) body=\(responseBody)")
            throw PairingTransportError.requestFailed
        }
        DiagnosticsLog.info("pair.transport.mac.http_ok path=\(path) status=\(http.statusCode) body=\(responseBody)")
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
    private let hostId: String
    private let task: URLSessionWebSocketTask

    init(hostId: String, task: URLSessionWebSocketTask) {
        self.hostId = hostId
        self.task = task
    }

    func send(_ text: String) async throws {
        DiagnosticsLog.info("pair.transport.mac.ws_send hostId=\(hostId) bytes=\(Data(text.utf8).count)")
        try await task.send(.string(text))
    }

    func receive() async throws -> String? {
        while true {
            let message = try await task.receive()
            switch message {
            case .string(let text):
                DiagnosticsLog.info("pair.transport.mac.ws_text hostId=\(hostId) bytes=\(Data(text.utf8).count)")
                return text
            case .data:
                DiagnosticsLog.warn("pair.transport.mac.ws_binary_ignored hostId=\(hostId)")
                continue
            @unknown default:
                DiagnosticsLog.warn("pair.transport.mac.ws_unknown_message hostId=\(hostId)")
                continue
            }
        }
    }

    func close() {
        DiagnosticsLog.info("pair.transport.mac.ws_close hostId=\(hostId)")
        task.cancel(with: .normalClosure, reason: nil)
    }
}

enum PairingTransportError: Error {
    case invalidEndpoint
    case requestFailed
}
