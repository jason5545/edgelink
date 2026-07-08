import CryptoKit
import Foundation

public struct DeviceIdentity: Sendable {
    public let deviceId: String
    public let name: String
    public let publicKey: Data

    public init(deviceId: String, name: String, publicKey: Data) {
        self.deviceId = deviceId
        self.name = name
        self.publicKey = publicKey
    }
}

public protocol IdentityStore: Sendable {
    func loadIdentity() throws -> DeviceIdentity?
    func saveIdentity(_ identity: DeviceIdentity) throws
}
