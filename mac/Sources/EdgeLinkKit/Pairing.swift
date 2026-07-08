import CryptoKit
import Foundation

public struct SASCode: Equatable, Sendable {
    public let numeric: String
    public let display: String

    public init(numeric: String) {
        self.numeric = numeric
        self.display = "\(numeric.prefix(3)) \(numeric.suffix(3))"
    }
}

public enum Pairing {
    public static func commitment(hostPublicKey: Data, hostNonce: Data) -> Data {
        sha256(hostPublicKey + hostNonce)
    }

    public static func sas(hostPublicKey: Data, clientPublicKey: Data, hostNonce: Data, clientNonce: Data) -> SASCode {
        let digest = sha256(hostPublicKey + clientPublicKey + hostNonce + clientNonce)
        var remainder = 0
        for byte in digest {
            remainder = (remainder * 256 + Int(byte)) % 1_000_000
        }
        return SASCode(numeric: String(format: "%06d", remainder))
    }

    private static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }
}
