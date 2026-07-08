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
        guard let hello = try await channel.receive() else {
            throw SecureSessionHostError.closedBeforeHandshake
        }
        let ack = try HandshakeSession.acceptHello(
            hello,
            identity: identity,
            pinnedClientPublicKey: peer.publicKey
        )
        try await channel.send(ack.ack)

        guard let confirm = try await channel.receive() else {
            throw SecureSessionHostError.closedBeforeHandshake
        }
        established = try HandshakeSession.finishResponder(
            state: ack.state,
            confirm: confirm,
            pinnedClientPublicKey: peer.publicKey
        )
    }

    func sendPlaintext(_ plaintext: Data) async throws {
        var session = try requireEstablished()
        let frame = try session.channel.seal(plaintext)
        established = session
        try await channel.send(frame)
    }

    func receiveLoop() async throws {
        while let frame = try await channel.receive() {
            var session = try requireEstablished()
            let plaintext = try session.channel.open(frame)
            established = session

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
}

enum SecureSessionHostError: Error {
    case closedBeforeHandshake
    case notEstablished
}
