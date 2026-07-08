import Foundation

public struct HandshakePeer: Equatable, Sendable {
    public let deviceId: String
    public let ephemeralPublicKey: Data
    public let nonce: Data

    public init(deviceId: String, ephemeralPublicKey: Data, nonce: Data) {
        self.deviceId = deviceId
        self.ephemeralPublicKey = ephemeralPublicKey
        self.nonce = nonce
    }
}

public enum HandshakeEncoding {
    public static func peerRecord(_ peer: HandshakePeer) -> Data {
        var out = Data()
        appendLengthPrefixed(Data(peer.deviceId.utf8), to: &out)
        appendLengthPrefixed(peer.ephemeralPublicKey, to: &out)
        appendLengthPrefixed(peer.nonce, to: &out)
        return out
    }

    private static func appendLengthPrefixed(_ value: Data, to output: inout Data) {
        precondition(value.count <= UInt16.max)
        output.append(UInt8((value.count >> 8) & 0xff))
        output.append(UInt8(value.count & 0xff))
        output.append(value)
    }
}
