import Foundation

// MARK: - EdgeLink TCP Tunnel Protocol (Route b)
// Clean-room protocol for TCP port forwarding over EdgeLink secure envelopes.
// Works on any Android device via the existing E2EE relay/LAN transport.

// MARK: - Envelope Types

public enum TunnelEnvelopeType {
    public static let open = "tunnel.open"
    public static let openResult = "tunnel.open.result"
    public static let data = "tunnel.data"
    public static let close = "tunnel.close"
    public static let error = "tunnel.error"
    public static let flow = "tunnel.flow"
}

// MARK: - Direction

public enum TunnelDirection: String, Codable, Sendable {
    case local
    case remote
}

// MARK: - Error Codes

public enum TunnelErrorCode: String, Codable, Sendable {
    case targetRefused = "target_refused"
    case targetTimeout = "target_timeout"
    case notAllowed = "not_allowed"
    case tunnelNotFound = "tunnel_not_found"
    case streamNotFound = "stream_not_found"
    case flowViolation = "flow_violation"
    case internalError = "internal_error"
}

// MARK: - Stream State

public enum TunnelStreamState: Sendable, Equatable {
    case opening
    case open
    case halfClosedLocal
    case halfClosedRemote
    case closed
}

// MARK: - Envelope Bodies

public struct TunnelOpenBody: Codable, Equatable, Sendable {
    public let tunnelId: String
    public let direction: TunnelDirection
    public let targetHost: String
    public let targetPort: Int
    public let label: String?

    public init(tunnelId: String, direction: TunnelDirection, targetHost: String, targetPort: Int, label: String? = nil) {
        self.tunnelId = tunnelId
        self.direction = direction
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.label = label
    }
}

public struct TunnelOpenResultBody: Codable, Equatable, Sendable {
    public let tunnelId: String
    public let ok: Bool
    public let error: String?
    public let listenPort: Int?

    public init(tunnelId: String, ok: Bool, error: String? = nil, listenPort: Int? = nil) {
        self.tunnelId = tunnelId
        self.ok = ok
        self.error = error
        self.listenPort = listenPort
    }
}

public struct TunnelDataBody: Codable, Equatable, Sendable {
    public let tunnelId: String
    public let streamId: Int
    public let seq: Int
    public let payload: String
    public let fin: Bool

    public init(tunnelId: String, streamId: Int, seq: Int, payload: String, fin: Bool = false) {
        self.tunnelId = tunnelId
        self.streamId = streamId
        self.seq = seq
        self.payload = payload
        self.fin = fin
    }
}

public struct TunnelCloseBody: Codable, Equatable, Sendable {
    public let tunnelId: String
    public let streamId: Int
    public let fin: Bool
    public let reset: Bool

    public init(tunnelId: String, streamId: Int, fin: Bool = true, reset: Bool = false) {
        self.tunnelId = tunnelId
        self.streamId = streamId
        self.fin = fin
        self.reset = reset
    }
}

public struct TunnelErrorBody: Codable, Equatable, Sendable {
    public let tunnelId: String
    public let streamId: Int?
    public let code: TunnelErrorCode
    public let message: String?

    public init(tunnelId: String, streamId: Int? = nil, code: TunnelErrorCode, message: String? = nil) {
        self.tunnelId = tunnelId
        self.streamId = streamId
        self.code = code
        self.message = message
    }
}

public struct TunnelFlowBody: Codable, Equatable, Sendable {
    public let tunnelId: String
    public let streamId: Int
    public let credit: Int

    public init(tunnelId: String, streamId: Int, credit: Int) {
        self.tunnelId = tunnelId
        self.streamId = streamId
        self.credit = credit
    }
}

// MARK: - Chunking

public enum TunnelChunker {
    public static let maxChunkSize = 32 * 1024

    public struct Chunk: Equatable, Sendable {
        public let seq: Int
        public let data: Data
        public let isLast: Bool
    }

    public static func chunk(_ data: Data) -> [Chunk] {
        guard !data.isEmpty else {
            return [Chunk(seq: 0, data: Data(), isLast: true)]
        }
        var chunks: [Chunk] = []
        var offset = 0
        var seq = 0
        while offset < data.count {
            let end = min(offset + maxChunkSize, data.count)
            let slice = Data(data[offset..<end])
            let isLast = end >= data.count
            chunks.append(Chunk(seq: seq, data: slice, isLast: isLast))
            offset = end
            seq += 1
        }
        return chunks
    }

    public static func payloadBase64(_ data: Data) -> String {
        data.base64EncodedString()
    }

    public static func payloadFromBase64(_ base64: String) -> Data? {
        Data(base64Encoded: base64)
    }
}

// MARK: - Reassembly

public struct TunnelReassembler: Sendable {
    private var buffers: [String: StreamBuffer] = [:]

    private struct StreamBuffer: Sendable {
        var chunks: [Int: Data] = [:]
        var nextSeq = 0
        var complete = false
    }

    public init() {}

    private static func key(tunnelId: String, streamId: Int) -> String {
        "\(tunnelId):\(streamId)"
    }

    public mutating func append(tunnelId: String, streamId: Int, seq: Int, data: Data, fin: Bool) -> Data? {
        let key = Self.key(tunnelId: tunnelId, streamId: streamId)
        var buffer = buffers[key] ?? StreamBuffer()

        if seq == buffer.nextSeq {
            buffer.chunks[seq] = data
            buffer.nextSeq += 1
            while let next = buffer.chunks[buffer.nextSeq] {
                _ = next
                buffer.nextSeq += 1
            }
        } else {
            buffer.chunks[seq] = data
        }

        if fin {
            buffer.complete = true
        }

        buffers[key] = buffer

        if buffer.complete || fin {
            var result = Data()
            for i in 0..<buffer.nextSeq {
                if let chunk = buffer.chunks[i] {
                    result.append(chunk)
                }
            }
            buffers[key] = nil
            return result
        }

        return nil
    }

    public mutating func reset(tunnelId: String, streamId: Int) {
        let key = Self.key(tunnelId: tunnelId, streamId: streamId)
        buffers[key] = nil
    }

    public mutating func resetAll() {
        buffers.removeAll()
    }
}

// MARK: - Allowlist

public struct TunnelAllowlist: Sendable {
    public struct Rule: Sendable, Equatable {
        public let host: String
        public let port: Int?

        public init(host: String, port: Int? = nil) {
            self.host = host
            self.port = port
        }
    }

    public private(set) var rules: [Rule]

    public init(rules: [Rule] = TunnelAllowlist.defaultRules) {
        self.rules = rules
    }

    public static let defaultRules: [Rule] = [
        Rule(host: "127.0.0.1", port: nil),
        Rule(host: "::1", port: nil),
        Rule(host: "localhost", port: nil),
    ]

    public static let adbPort = 5555

    public func isAllowed(host: String, port: Int) -> Bool {
        for rule in rules {
            let hostMatch = rule.host == host || rule.host == "localhost" && (host == "127.0.0.1" || host == "::1")
            if hostMatch {
                if rule.port == nil || rule.port == port {
                    return true
                }
            }
        }
        return false
    }

    public mutating func addRule(_ rule: Rule) {
        rules.append(rule)
    }

    public mutating func removeRule(at index: Int) {
        guard index < rules.count else { return }
        rules.remove(at: index)
    }
}

// MARK: - Constants

public enum TunnelConstants {
    public static let initialCredit = 1024 * 1024
    public static let streamIdleTimeout: TimeInterval = 60
    public static let tunnelIdleTimeout: TimeInterval = 300
}
