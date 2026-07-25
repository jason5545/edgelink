import CryptoKit
import Foundation

public enum ClipboardBlobTransfer {
    public static let maxChunkSize = 32 * 1024
    public static let maxBlobBytes = 8 * 1024 * 1024
    public static let receiveTimeout: TimeInterval = 10

    public struct OutgoingChunk: Equatable, Sendable {
        public let seq: Int
        public let fin: Bool
        public let payloadBase64: String
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func chunk(_ data: Data) -> [OutgoingChunk] {
        guard !data.isEmpty else {
            return [OutgoingChunk(seq: 0, fin: true, payloadBase64: "")]
        }
        var chunks: [OutgoingChunk] = []
        var offset = 0
        var seq = 0
        while offset < data.count {
            let end = min(offset + maxChunkSize, data.count)
            let slice = Data(data[offset..<end])
            chunks.append(OutgoingChunk(seq: seq, fin: end >= data.count, payloadBase64: slice.base64EncodedString()))
            offset = end
            seq += 1
        }
        return chunks
    }
}

public struct ClipboardBlobReassembler: Sendable {
    public struct Result: Equatable, Sendable {
        public let data: Data
        public let mime: String?
    }

    public enum AppendOutcome: Equatable, Sendable {
        case pending
        case complete(Result)
        case notAvailable
        case hashMismatch
        case invalidChunk
    }

    private struct Buffer: Sendable {
        var chunks: [Int: Data] = [:]
        var nextSeq = 0
        var expectedHash: String?
        var mime: String?
    }

    private var buffer: Buffer?

    public init() {}

    public mutating func reset() {
        buffer = nil
    }

    public mutating func append(id: String, seq: Int, fin: Bool, hash: String?, mime: String?, payloadBase64: String) -> AppendOutcome {
        if fin && seq == 0 && payloadBase64.isEmpty {
            buffer = nil
            return .notAvailable
        }
        guard let data = ClipboardBlobTransfer.payloadFromBase64(payloadBase64) else {
            return .invalidChunk
        }
        var current = buffer ?? Buffer()
        if seq == 0 {
            current.expectedHash = hash
            current.mime = mime
        }
        if seq == current.nextSeq {
            current.chunks[seq] = data
            current.nextSeq += 1
            while current.chunks[current.nextSeq] != nil {
                current.nextSeq += 1
            }
        } else {
            current.chunks[seq] = data
        }
        buffer = current

        guard fin else { return .pending }
        var result = Data()
        for index in 0..<current.nextSeq {
            guard let chunk = current.chunks[index] else {
                buffer = nil
                return .invalidChunk
            }
            result.append(chunk)
        }
        buffer = nil
        if let expected = current.expectedHash,
           ClipboardBlobTransfer.sha256Hex(result) != expected {
            return .hashMismatch
        }
        return .complete(Result(data: result, mime: current.mime))
    }
}

extension ClipboardBlobTransfer {
    static func payloadFromBase64(_ base64: String) -> Data? {
        Data(base64Encoded: base64)
    }
}
