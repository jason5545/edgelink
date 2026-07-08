import Foundation

public struct Envelope<Body: Codable & Sendable>: Codable, Sendable {
    public let t: String
    public let b: Body

    public init(t: String, b: Body) {
        self.t = t
        self.b = b
    }
}

public struct EmptyBody: Codable, Sendable {
    public init() {}
}

public enum EnvelopeType {
    public static let statusPing = "status.ping"
    public static let inputPointer = "input.pointer"
    public static let inputKey = "input.key"
    public static let inputText = "input.text"
    public static let clipboardSet = "clipboard.set"
}
