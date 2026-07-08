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
    public static let statusPong = "status.pong"
    public static let inputPointer = "input.pointer"
    public static let inputKey = "input.key"
    public static let inputText = "input.text"
    public static let clipboardSet = "clipboard.set"
}

public struct InputPointerBody: Codable, Equatable, Sendable {
    public let dx: Double
    public let dy: Double
    public let scrollX: Double?
    public let scrollY: Double?
    public let btn: String?

    public init(dx: Double = 0, dy: Double = 0, scrollX: Double? = nil, scrollY: Double? = nil, btn: String? = nil) {
        self.dx = dx
        self.dy = dy
        self.scrollX = scrollX
        self.scrollY = scrollY
        self.btn = btn
    }
}

public struct InputKeyBody: Codable, Equatable, Sendable {
    public let key: String
    public let mods: [String]

    public init(key: String, mods: [String] = []) {
        self.key = key
        self.mods = mods
    }
}

public struct InputTextBody: Codable, Equatable, Sendable {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

public struct ClipboardSetBody: Codable, Equatable, Sendable {
    public let text: String
    public let ts: Int64
    public let hash: String

    public init(text: String, ts: Int64, hash: String) {
        self.text = text
        self.ts = ts
        self.hash = hash
    }
}
