import EdgeLinkKit
import Foundation

public struct LyraDevPairClient: Sendable {
    private let workerBaseURL: URL
    private let session: URLSession

    public init(workerBaseURL: URL, session: URLSession = .shared) {
        self.workerBaseURL = workerBaseURL
        self.session = session
    }

    public func pair(
        secret: String,
        hostId: String,
        hostPk: Data,
        hostName: String,
        clientId: String,
        clientPk: Data,
        clientName: String
    ) async throws {
        var request = URLRequest(url: workerBaseURL.appending(path: "/v1/dev/pair"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(LyraDevPairRequest(
            secret: secret,
            hostId: hostId,
            clientId: clientId,
            hostPk: hostPk.base64EncodedString(),
            clientPk: clientPk.base64EncodedString(),
            hostName: hostName,
            clientName: clientName
        ))

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LyraDevPairError.requestFailed("no_http_response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONDecoder().decode(LyraDevPairErrorBody.self, from: data))?.error
                ?? "http_\(http.statusCode)"
            throw LyraDevPairError.requestFailed(detail)
        }
    }
}

private struct LyraDevPairRequest: Encodable {
    let secret: String
    let hostId: String
    let clientId: String
    let hostPk: String
    let clientPk: String
    let hostName: String
    let clientName: String
}

private struct LyraDevPairErrorBody: Decodable {
    let error: String
}

public enum LyraDevPairError: Error {
    case requestFailed(String)
}
