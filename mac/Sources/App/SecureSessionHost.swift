import EdgeLinkKit
import Foundation

actor SecureSessionHost {
    private let channel: ByteChannel
    private let identity: LocalIdentity
    private let peer: PinnedPeer
    private let dispatcher: CommandDispatcher
    private var established: EstablishedHandshake?

    init(
        channel: ByteChannel,
        identity: LocalIdentity,
        peer: PinnedPeer,
        dispatcher: CommandDispatcher
    ) {
        self.channel = channel
        self.identity = identity
        self.peer = peer
        self.dispatcher = dispatcher
    }

    func connect() async throws {
        DiagnosticsLog.info("hs.mac.wait_hello hostId=\(identity.deviceId) clientId=\(peer.deviceId)")
        while let frame = try await channel.receive() {
            guard isHandshakeHello(frame) else {
                DiagnosticsLog.warn("hs.mac.stale_frame_ignored hostId=\(identity.deviceId) clientId=\(peer.deviceId) bytes=\(frame.count)")
                continue
            }
            try await performHandshake(firstHello: frame, reason: "initial")
            return
        }
        throw SecureSessionHostError.closedBeforeHandshake
    }

    private func performHandshake(firstHello hello: Data, reason: String) async throws {
        established = nil
        DiagnosticsLog.info("hs.mac.hello_in reason=\(reason) bytes=\(hello.count)")
        let ack = try HandshakeSession.acceptHello(
            hello,
            identity: identity,
            pinnedClientPublicKey: peer.publicKey
        )
        DiagnosticsLog.info("hs.mac.ack_out reason=\(reason) bytes=\(ack.ack.count)")
        try await channel.send(ack.ack)

        guard let confirm = try await channel.receive() else {
            throw SecureSessionHostError.closedBeforeHandshake
        }
        DiagnosticsLog.info("hs.mac.confirm_in reason=\(reason) bytes=\(confirm.count)")
        established = try HandshakeSession.finishResponder(
            state: ack.state,
            confirm: confirm,
            pinnedClientPublicKey: peer.publicKey
        )
        DiagnosticsLog.info("hs.mac.established reason=\(reason) hostId=\(identity.deviceId) clientId=\(peer.deviceId)")
    }

    func sendPlaintext(_ plaintext: Data) async throws {
        var session = try requireEstablished()
        let frame = try session.channel.seal(plaintext)
        established = session
        DiagnosticsLog.info("secure.mac.frame_out plaintext=\(plaintext.count) frame=\(frame.count)")
        try await channel.send(frame)
    }

    func receiveLoop() async throws {
        while let frame = try await channel.receive() {
            if isHandshakeHello(frame) {
                DiagnosticsLog.info("hs.mac.rehandshake_detected hostId=\(identity.deviceId) clientId=\(peer.deviceId) bytes=\(frame.count)")
                try await performHandshake(firstHello: frame, reason: "reconnect")
                continue
            }

            var session = try requireEstablished()
            let plaintext = try session.channel.open(frame)
            established = session
            DiagnosticsLog.info("secure.mac.frame_in frame=\(frame.count) plaintext=\(plaintext.count)")

            if let response = try dispatcher.handle(plaintext) {
                try await sendPlaintext(response)
            }
        }
    }

    private func requireEstablished() throws -> EstablishedHandshake {
        guard let established else {
            throw SecureSessionHostError.notEstablished
        }
        return established
    }

    private func isHandshakeHello(_ frame: Data) -> Bool {
        guard let envelope = try? HandshakeWire.decodeSignedPeer(frame) else {
            return false
        }
        return envelope.t == HandshakeType.hello
    }
}

enum SecureSessionHostError: Error {
    case closedBeforeHandshake
    case notEstablished
}
