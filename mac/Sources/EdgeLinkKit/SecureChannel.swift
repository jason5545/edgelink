import Foundation

public enum SecureChannelDirection: Sendable {
    case initiatorToResponder
    case responderToInitiator

    public var aad: Data {
        switch self {
        case .initiatorToResponder:
            return Data("EdgeLink frame v1 i2r".utf8)
        case .responderToInitiator:
            return Data("EdgeLink frame v1 r2i".utf8)
        }
    }
}

public struct FrameCounter: Sendable {
    public private(set) var value: UInt64

    public init(value: UInt64 = 0) {
        self.value = value
    }

    public mutating func next() -> UInt64 {
        defer { value += 1 }
        return value
    }
}
