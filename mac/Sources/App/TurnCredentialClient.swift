import EdgeLinkKit
import Foundation

struct ScreenIceServerConfig: Equatable {
    let urls: [String]
    let username: String?
    let credential: String?
}

struct TurnCredentialSnapshot: Equatable {
    let urls: [String]
    let username: String
    let credential: String
    let ttlSeconds: Int
    let issuedAt: Int64
    let expiresAt: Int64
    let realm: String
    let iceServers: [ScreenIceServerConfig]

    func isFresh(now: Date = Date()) -> Bool {
        Int64(now.timeIntervalSince1970) < expiresAt - 60
    }

    var diagnosticSummary: String {
        "urls=\(urls.joined(separator: ",")) ttl=\(ttlSeconds) expiresAt=\(expiresAt) realm=\(realm)"
    }
}

final class TurnCredentialClient {
    private let baseURL: URL
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func fetch(hostId: String, identity: LocalIdentity) async throws -> TurnCredentialSnapshot {
        let timestamp = Int64(Date().timeIntervalSince1970)
        let signature = try identity.signingKey.signature(
            for: RelayAuth.message(deviceId: identity.deviceId, timestampSeconds: timestamp)
        )
        let body = TurnCredentialRequest(
            hostId: hostId,
            deviceId: identity.deviceId,
            ts: timestamp,
            sig: signature.base64EncodedString()
        )
        var request = URLRequest(url: baseURL.appending(path: "/v1/turn/credentials"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TurnCredentialError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw TurnCredentialError.requestFailed(statusCode: http.statusCode, body: body)
        }

        let decoded = try decoder.decode(TurnCredentialResponse.self, from: data)
        let decodedIceServers = decoded.iceServers
            .map { ScreenIceServerConfig(urls: $0.urls, username: $0.username, credential: $0.credential) }
            .filter { !$0.urls.isEmpty }
        let iceServers = decodedIceServers.isEmpty
            ? [ScreenIceServerConfig(urls: decoded.urls, username: decoded.username, credential: decoded.credential)]
            : decodedIceServers

        return TurnCredentialSnapshot(
            urls: decoded.urls,
            username: decoded.username,
            credential: decoded.credential,
            ttlSeconds: decoded.ttlSeconds,
            issuedAt: decoded.issuedAt,
            expiresAt: decoded.expiresAt,
            realm: decoded.realm,
            iceServers: iceServers.filter { !$0.urls.isEmpty }
        )
    }
}

private struct TurnCredentialRequest: Encodable {
    let hostId: String
    let deviceId: String
    let ts: Int64
    let sig: String
}

private struct TurnCredentialResponse: Decodable {
    let urls: [String]
    let username: String
    let credential: String
    let ttlSeconds: Int
    let issuedAt: Int64
    let expiresAt: Int64
    let realm: String
    let iceServers: [TurnIceServerResponse]
}

private struct TurnIceServerResponse: Decodable {
    let urls: [String]
    let username: String?
    let credential: String?
}

enum TurnCredentialError: Error, CustomStringConvertible {
    case invalidResponse
    case requestFailed(statusCode: Int, body: String)

    var description: String {
        switch self {
        case .invalidResponse:
            return "Invalid TURN credential response."
        case .requestFailed(let statusCode, let body):
            return "TURN credential request failed with HTTP \(statusCode): \(body)"
        }
    }
}
