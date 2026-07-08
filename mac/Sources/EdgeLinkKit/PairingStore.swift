import Foundation

public struct PinnedPeer: Codable, Equatable, Sendable {
    public let deviceId: String
    public let name: String
    public let publicKey: Data
    public let pairedAt: Date

    public init(deviceId: String, name: String, publicKey: Data, pairedAt: Date) {
        precondition(DeviceID.isValid(deviceId), "Device ID must be 9 digits without a leading zero.")
        self.deviceId = deviceId
        self.name = name
        self.publicKey = publicKey
        self.pairedAt = pairedAt
    }
}

public protocol PairingStore: Sendable {
    func loadPeer(deviceId: String) throws -> PinnedPeer?
    func savePeer(_ peer: PinnedPeer) throws
}

public final class InMemoryPairingStore: PairingStore, @unchecked Sendable {
    private var peers: [String: PinnedPeer] = [:]

    public init() {}

    public func loadPeer(deviceId: String) throws -> PinnedPeer? {
        peers[deviceId]
    }

    public func savePeer(_ peer: PinnedPeer) throws {
        peers[peer.deviceId] = peer
    }
}
