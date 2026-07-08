import Foundation

public protocol ByteChannel: Sendable {
    func send(_ bytes: Data) async throws
    func receive() async throws -> Data?
}

public enum TransportKind: String, Sendable {
    case relay
    case lan
}
