import Foundation

public struct DeviceRegistrationRequest: Codable, Equatable, Sendable {
    public let pubkey: String
    public let name: String
    public let platform: String

    public init(pubkey: String, name: String, platform: String) {
        self.pubkey = pubkey
        self.name = name
        self.platform = platform
    }
}

public struct DeviceRegistrationResponse: Codable, Equatable, Sendable {
    public let deviceId: String
}

public protocol DeviceRegistrar: Sendable {
    func register(pubkey: Data, name: String, platform: String) async throws -> String
}

public final class WorkerDeviceRegistrar: DeviceRegistrar, Sendable {
    private let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func register(pubkey: Data, name: String, platform: String = "macos") async throws -> String {
        var request = URLRequest(url: baseURL.appending(path: "/v1/device/register"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(DeviceRegistrationRequest(
            pubkey: pubkey.base64EncodedString(),
            name: name,
            platform: platform
        ))

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RegistrationError.requestFailed
        }
        let decoded = try JSONDecoder().decode(DeviceRegistrationResponse.self, from: data)
        return decoded.deviceId
    }
}

public enum RegistrationError: Error {
    case requestFailed
}
