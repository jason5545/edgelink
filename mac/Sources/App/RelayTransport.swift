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
    private let hostId: String
    private let deviceId: String
    private let task: URLSessionWebSocketTask

    init(hostId: String, deviceId: String, task: URLSessionWebSocketTask) {
        self.hostId = hostId
        self.deviceId = deviceId
        self.task = task
    }

    func send(_ bytes: Data) async throws {
        DiagnosticsLog.info("relay.transport.mac.binary_out hostId=\(hostId) deviceId=\(deviceId) bytes=\(bytes.count)")
        try await task.send(.data(bytes))
    }

    func receive() async throws -> Data? {
        while true {
            let message = try await task.receive()
            switch message {
            case .data(let data):
                DiagnosticsLog.info("relay.transport.mac.binary_in hostId=\(hostId) deviceId=\(deviceId) bytes=\(data.count)")
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
