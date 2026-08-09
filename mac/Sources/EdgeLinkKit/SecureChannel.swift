import CryptoKit
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

    public mutating func advance(to nextValue: UInt64) {
        precondition(nextValue >= value)
        value = nextValue
    }
}

public enum SecureChannelRole: Sendable {
    case initiator
    case responder
}

public struct SecureChannel: Sendable {
    private let sendKey: Data
    private let receiveKey: Data
    private let sendDirection: SecureChannelDirection
    private let receiveDirection: SecureChannelDirection
    private var sendCounter = FrameCounter()
    // Sliding-window anti-replay (IPsec-style): the relay data channel is
    // unordered, so late frames legitimately arrive below the highest seen
    // counter. The old single minimumCounter check rejected those as
    // replays, and the receive loops rethrew — one reorder killed the whole
    // session. A 64-bit window accepts late frames while still rejecting
    // true duplicates and ancient replays.
    private static let receiveWindowBits: UInt64 = 64
    private var receiveMax: UInt64 = 0
    private var receiveWindow: UInt64 = 0
    private var hasReceivedFrame = false

    public init(keys: SecureChannelKeys, role: SecureChannelRole) {
        switch role {
        case .initiator:
            sendKey = keys.initiatorToResponder
            receiveKey = keys.responderToInitiator
            sendDirection = .initiatorToResponder
            receiveDirection = .responderToInitiator
        case .responder:
            sendKey = keys.responderToInitiator
            receiveKey = keys.initiatorToResponder
            sendDirection = .responderToInitiator
            receiveDirection = .initiatorToResponder
        }
    }

    public mutating func seal(_ plaintext: Data) throws -> Data {
        try SecureFrame.sealVersioned(
            plaintext: plaintext,
            key: sendKey,
            direction: sendDirection,
            counter: sendCounter.next()
        )
    }

    public mutating func open(_ frame: Data) throws -> Data {
        let counter = try SecureFrame.versionedCounter(of: frame)
        if isReplay(counter: counter) {
            throw SecureFrameError.replayedFrame
        }
        let opened = try SecureFrame.openVersioned(
            frame: frame,
            key: receiveKey,
            direction: receiveDirection,
            minimumCounter: 0
        )
        markReceived(counter: opened.counter)
        return opened.plaintext
    }

    private func isReplay(counter: UInt64) -> Bool {
        guard hasReceivedFrame else { return false }
        if counter > receiveMax { return false }
        // Bit i tracks counter (receiveMax - i), so bit 0 is the max itself.
        let delta = receiveMax - counter
        if delta >= Self.receiveWindowBits { return true }
        return (receiveWindow & (1 &<< delta)) != 0
    }

    private mutating func markReceived(counter: UInt64) {
        if !hasReceivedFrame {
            hasReceivedFrame = true
            receiveMax = counter
            receiveWindow = 1
            return
        }
        if counter > receiveMax {
            let shift = counter - receiveMax
            if shift >= Self.receiveWindowBits {
                receiveWindow = 0
            } else {
                receiveWindow &<<= shift
            }
            receiveMax = counter
            receiveWindow |= 1
            return
        }
        let delta = receiveMax - counter
        if delta < Self.receiveWindowBits {
            receiveWindow |= (1 &<< delta)
        }
    }
}

public struct OpenedSecureFrame: Sendable {
    public let counter: UInt64
    public let plaintext: Data
}

public enum SecureFrame {
    public static let maxCiphertextAndTagLength = 64 * 1024

    public static func nonce(counter: UInt64) throws -> ChaChaPoly.Nonce {
        var bytes = Data(repeating: 0, count: 12)
        for offset in 0..<8 {
            bytes[4 + offset] = UInt8((counter >> UInt64((7 - offset) * 8)) & 0xff)
        }
        return try ChaChaPoly.Nonce(data: bytes)
    }

    public static func seal(plaintext: Data, key: Data, direction: SecureChannelDirection, counter: UInt64) throws -> Data {
        precondition(key.count == 32)
        let symmetricKey = SymmetricKey(data: key)
        let sealed = try ChaChaPoly.seal(
            plaintext,
            using: symmetricKey,
            nonce: nonce(counter: counter),
            authenticating: direction.aad
        )
        let ciphertextAndTag = sealed.ciphertext + sealed.tag
        guard ciphertextAndTag.count <= maxCiphertextAndTagLength else {
            throw SecureFrameError.frameTooLarge
        }
        return UInt32(ciphertextAndTag.count).bigEndianData + ciphertextAndTag
    }

    public static func sealVersioned(
        plaintext: Data,
        key: Data,
        direction: SecureChannelDirection,
        counter: UInt64
    ) throws -> Data {
        let legacyFrame = try seal(
            plaintext: plaintext,
            key: key,
            direction: direction,
            counter: counter
        )
        return legacyFrame.prefix(4) + counter.bigEndianData + legacyFrame.dropFirst(4)
    }

    // The counter embedded in a versioned frame (plaintext prefix), for
    // anti-replay checks before decryption.
    public static func versionedCounter(of frame: Data) throws -> UInt64 {
        guard frame.count >= 12 else {
            throw SecureFrameError.truncatedFrame
        }
        return UInt64(bigEndianData: frame.dropFirst(4).prefix(8))
    }

    public static func openVersioned(
        frame: Data,
        key: Data,
        direction: SecureChannelDirection,
        minimumCounter: UInt64
    ) throws -> OpenedSecureFrame {
        guard frame.count >= 12 else {
            throw SecureFrameError.truncatedFrame
        }
        let length = Int(UInt32(bigEndianData: frame.prefix(4)))
        guard length <= maxCiphertextAndTagLength else {
            throw SecureFrameError.frameTooLarge
        }
        guard frame.count == 12 + length, length >= 16 else {
            throw SecureFrameError.truncatedFrame
        }
        let counter = UInt64(bigEndianData: frame.dropFirst(4).prefix(8))
        guard counter >= minimumCounter else {
            throw SecureFrameError.replayedFrame
        }
        let legacyFrame = frame.prefix(4) + frame.dropFirst(12)
        return OpenedSecureFrame(
            counter: counter,
            plaintext: try open(
                frame: legacyFrame,
                key: key,
                direction: direction,
                counter: counter
            )
        )
    }

    public static func open(frame: Data, key: Data, direction: SecureChannelDirection, counter: UInt64) throws -> Data {
        precondition(key.count == 32)
        guard frame.count >= 4 else {
            throw SecureFrameError.truncatedFrame
        }
        let length = Int(UInt32(bigEndianData: frame.prefix(4)))
        guard length <= maxCiphertextAndTagLength else {
            throw SecureFrameError.frameTooLarge
        }
        guard frame.count == 4 + length, length >= 16 else {
            throw SecureFrameError.truncatedFrame
        }

        let payload = frame.dropFirst(4)
        let ciphertext = payload.dropLast(16)
        let tag = payload.suffix(16)
        let box = try ChaChaPoly.SealedBox(
            nonce: nonce(counter: counter),
            ciphertext: ciphertext,
            tag: tag
        )
        return try ChaChaPoly.open(
            box,
            using: SymmetricKey(data: key),
            authenticating: direction.aad
        )
    }
}

public enum SecureFrameError: Error {
    case frameTooLarge
    case truncatedFrame
    case replayedFrame
}

private extension UInt32 {
    var bigEndianData: Data {
        var value = bigEndian
        return Data(bytes: &value, count: MemoryLayout<UInt32>.size)
    }

    init(bigEndianData data: Data.SubSequence) {
        precondition(data.count == 4)
        self = data.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}

private extension UInt64 {
    var bigEndianData: Data {
        var value = bigEndian
        return Data(bytes: &value, count: MemoryLayout<UInt64>.size)
    }

    init(bigEndianData data: Data.SubSequence) {
        precondition(data.count == 8)
        self = data.reduce(0) { ($0 << 8) | UInt64($1) }
    }
}
