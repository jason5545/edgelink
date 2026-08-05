import EdgeLinkKit
import Foundation

public actor LyraRelaySession {
    public enum LyraRelaySessionError: Error {
        case closedBeforeHandshake
        case notEstablished
    }

    private let channel: any ByteChannel
    private let identity: LocalIdentity
    private let log: @Sendable (String) -> Void
    private var established: EstablishedHandshake?

    private let onEnvelope: @Sendable (String, Data) -> Void
    private let onPong: @Sendable (_ rttMs: Int64, _ offsetMs: Int64) -> Void

    public init(
        channel: any ByteChannel,
        identity: LocalIdentity,
        log: @escaping @Sendable (String) -> Void = { _ in },
        onEnvelope: @escaping @Sendable (String, Data) -> Void = { _, _ in },
        onPong: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }
    ) {
        self.channel = channel
        self.identity = identity
        self.log = log
        self.onEnvelope = onEnvelope
        self.onPong = onPong
    }

    public var deviceId: String {
        identity.deviceId
    }

    public func connectAsClient(pinnedHostPublicKey: Data) async throws {
        let start = try HandshakeSession.startInitiator(identity: identity)
        try await channel.send(start.hello)
        while let frame = try await channel.receive() {
            guard isHandshakeAck(frame) else {
                continue
            }
            let finish = try HandshakeSession.finishInitiator(
                state: start.state,
                ack: frame,
                identity: identity,
                pinnedHostPublicKey: pinnedHostPublicKey
            )
            try await channel.send(finish.confirm)
            established = finish.established
            log("hs.client.established deviceId=\(identity.deviceId)")
            return
        }
        throw LyraRelaySessionError.closedBeforeHandshake
    }

    public func acceptAsHost(pinnedClientPublicKey: Data) async throws {
        while let frame = try await channel.receive() {
            guard isHandshakeHello(frame) else {
                continue
            }
            let ack = try HandshakeSession.acceptHello(
                frame,
                identity: identity,
                pinnedClientPublicKey: pinnedClientPublicKey
            )
            try await channel.send(ack.ack)
            while let confirmFrame = try await channel.receive() {
                guard isHandshakeConfirm(confirmFrame) else {
                    continue
                }
                established = try HandshakeSession.finishResponder(
                    state: ack.state,
                    confirm: confirmFrame,
                    pinnedClientPublicKey: pinnedClientPublicKey
                )
                log("hs.host.established deviceId=\(identity.deviceId)")
                return
            }
            throw LyraRelaySessionError.closedBeforeHandshake
        }
        throw LyraRelaySessionError.closedBeforeHandshake
    }

    public func sendPlaintext(_ plaintext: Data) async throws {
        guard var session = established else {
            throw LyraRelaySessionError.notEstablished
        }
        let frame = try session.channel.seal(plaintext)
        established = session
        try await channel.send(frame)
    }

    public func sendEnvelope<Body: Codable & Sendable>(_ type: String, _ body: Body) async throws {
        try await sendPlaintext(JSONEncoder().encode(Envelope(t: type, b: body)))
    }

    public func sendPing() async throws {
        try await sendEnvelope(
            EnvelopeType.statusPing,
            StatusPingBody(t0: Int64(Date().timeIntervalSince1970 * 1000))
        )
    }

    public func receiveLoop() async throws {
        while let frame = try await channel.receive() {
            guard var session = established else {
                continue
            }
            let plaintext = try session.channel.open(frame)
            established = session

            guard let peek = try? JSONDecoder().decode(LyraRelayEnvelopePeek.self, from: plaintext) else {
                continue
            }
            switch peek.t {
            case EnvelopeType.statusPing:
                let ping = try? JSONDecoder().decode(Envelope<StatusPingBody>.self, from: plaintext)
                let receivedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
                let pong = StatusPongBody(
                    t0: ping?.b.t0,
                    ta: receivedAtMs,
                    tb: Int64(Date().timeIntervalSince1970 * 1000)
                )
                try await sendEnvelope(EnvelopeType.statusPong, pong)
            case EnvelopeType.statusPong:
                if let pong = try? JSONDecoder().decode(Envelope<StatusPongBody>.self, from: plaintext),
                   let t0 = pong.b.t0, let ta = pong.b.ta, let tb = pong.b.tb {
                    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
                    let rttMs = nowMs - t0
                    let offsetMs = (ta + tb) / 2 - (t0 + rttMs / 2)
                    onPong(rttMs, offsetMs)
                }
            default:
                break
            }
            onEnvelope(peek.t, plaintext)
        }
    }

    private func isHandshakeHello(_ frame: Data) -> Bool {
        guard let envelope = try? HandshakeWire.decodeSignedPeer(frame) else {
            return false
        }
        return envelope.t == HandshakeType.hello
    }

    private func isHandshakeAck(_ frame: Data) -> Bool {
        guard let envelope = try? HandshakeWire.decodeSignedPeer(frame) else {
            return false
        }
        return envelope.t == HandshakeType.ack
    }

    private func isHandshakeConfirm(_ frame: Data) -> Bool {
        guard let envelope = try? HandshakeWire.decodeConfirm(frame) else {
            return false
        }
        return envelope.t == HandshakeType.confirm
    }
}

private struct LyraRelayEnvelopePeek: Decodable {
    let t: String
}
