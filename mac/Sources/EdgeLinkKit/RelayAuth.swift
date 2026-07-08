import CryptoKit
import Foundation

public struct RelayAuthEnvelope: Codable, Equatable, Sendable {
    public struct Body: Codable, Equatable, Sendable {
        public let hostId: String
        public let deviceId: String
        public let ts: Int64
        public let sig: String
    }

    public let t: String
    public let b: Body
}

public enum RelayAuth {
    public static func message(deviceId: String, timestampSeconds: Int64) -> Data {
        Data("EdgeLink relay auth v1\n\(deviceId)\n\(timestampSeconds)".utf8)
    }

    public static func envelope(hostId: String, identity: LocalIdentity, timestampSeconds: Int64) throws -> RelayAuthEnvelope {
        let signature = try identity.signingKey.signature(for: message(deviceId: identity.deviceId, timestampSeconds: timestampSeconds))
        return RelayAuthEnvelope(
            t: "relay.auth",
            b: .init(
                hostId: hostId,
                deviceId: identity.deviceId,
                ts: timestampSeconds,
                sig: signature.base64EncodedString()
            )
        )
    }
}
