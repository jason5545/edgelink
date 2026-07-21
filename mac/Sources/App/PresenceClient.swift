import EdgeLinkKit
import Foundation

enum MacPowerPresence: String {
    case awake
    case sleeping
}

final class PresenceClient {
    private let baseURL: URL
    private let session: URLSession
    private let encoder = JSONEncoder()

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func report(hostId: String, identity: LocalIdentity, state: MacPowerPresence) async throws {
        let timestamp = Int64(Date().timeIntervalSince1970)
        let signature = try identity.signingKey.signature(
            for: RelayAuth.message(deviceId: identity.deviceId, timestampSeconds: timestamp)
        )
        let body = PresenceRequest(
            hostId: hostId,
            deviceId: identity.deviceId,
            state: state.rawValue,
            ts: timestamp,
            sig: signature.base64EncodedString()
        )
        var request = URLRequest(url: baseURL.appending(path: "/v1/presence"))
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw PresenceError.requestFailed(statusCode: statusCode, body: bodyText)
        }
    }
}

private struct PresenceRequest: Encodable {
    let hostId: String
    let deviceId: String
    let state: String
    let ts: Int64
    let sig: String
}

enum PresenceError: Error, CustomStringConvertible {
    case requestFailed(statusCode: Int, body: String)

    var description: String {
        switch self {
        case .requestFailed(let statusCode, let body):
            return "Presence request failed with HTTP \(statusCode): \(body)"
        }
    }
}
