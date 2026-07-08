import CryptoKit
import Foundation

public enum DeviceID {
    public static func isValid(_ value: String) -> Bool {
        value.range(of: #"^[1-9][0-9]{8}$"#, options: .regularExpression) != nil
    }

    public static func display(_ value: String) -> String {
        guard value.count == 9 else { return value }
        let first = value.prefix(3)
        let secondStart = value.index(value.startIndex, offsetBy: 3)
        let secondEnd = value.index(value.startIndex, offsetBy: 6)
        let second = value[secondStart..<secondEnd]
        let third = value.suffix(3)
        return "\(first) \(second) \(third)"
    }
}

public struct DeviceIdentity: Sendable {
    public let deviceId: String
    public let name: String
    public let publicKey: Data

    public init(deviceId: String, name: String, publicKey: Data) {
        precondition(DeviceID.isValid(deviceId), "Device ID must be 9 digits without a leading zero.")
        self.deviceId = deviceId
        self.name = name
        self.publicKey = publicKey
    }
}

public struct LocalIdentity: Sendable {
    public let deviceId: String
    public let name: String
    public let signingKey: Curve25519.Signing.PrivateKey

    public var publicKey: Data {
        signingKey.publicKey.rawRepresentation
    }

    public init(deviceId: String, name: String, signingKey: Curve25519.Signing.PrivateKey) {
        precondition(DeviceID.isValid(deviceId), "Device ID must be 9 digits without a leading zero.")
        self.deviceId = deviceId
        self.name = name
        self.signingKey = signingKey
    }
}

public protocol IdentityStore: Sendable {
    func loadIdentity() throws -> LocalIdentity?
    func saveIdentity(_ identity: LocalIdentity) throws
}
