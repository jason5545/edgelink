import EdgeLinkKit
import Foundation

actor SecureSessionHost {
    private let channel: ByteChannel
    private let identity: LocalIdentity
    private let peer: PinnedPeer
    private let dispatcher: CommandDispatcher
    private let sendGate = SecureSessionSendGate()
    private var established: EstablishedHandshake?
    private var lastInboundActivityAt = Date.distantPast
    private var framesSent: UInt64 = 0
    private var framesReceived: UInt64 = 0

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

        let confirm = try await receiveHandshakeConfirm(reason: reason)
        DiagnosticsLog.info("hs.mac.confirm_in reason=\(reason) bytes=\(confirm.count)")
        established = try HandshakeSession.finishResponder(
            state: ack.state,
            confirm: confirm,
            pinnedClientPublicKey: peer.publicKey
        )
        lastInboundActivityAt = Date()
        DiagnosticsLog.info("hs.mac.established reason=\(reason) hostId=\(identity.deviceId) clientId=\(peer.deviceId)")
    }

    private func receiveHandshakeConfirm(reason: String) async throws -> Data {
        while let frame = try await channel.receive() {
            if isHandshakeConfirm(frame) {
                return frame
            }
            DiagnosticsLog.warn(
                "hs.mac.stale_confirm_frame_ignored reason=\(reason) " +
                    "hostId=\(identity.deviceId) clientId=\(peer.deviceId) bytes=\(frame.count)"
            )
        }
        throw SecureSessionHostError.closedBeforeHandshake
    }

    func sendPlaintext(_ plaintext: Data) async throws {
        await sendGate.lock()
        do {
            var session = try await waitForEstablished()
            let frame = try session.channel.seal(plaintext)
            established = session
            framesSent &+= 1
            if framesSent <= 3 || framesSent % 100 == 0 {
                DiagnosticsLog.info("secure.mac.frame_out count=\(framesSent) plaintext=\(plaintext.count) frame=\(frame.count)")
            }
            try await channel.send(frame)
            await sendGate.unlock()
        } catch {
            await sendGate.unlock()
            throw error
        }
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
            lastInboundActivityAt = Date()
            framesReceived &+= 1
            if framesReceived <= 3 || framesReceived % 100 == 0 {
                DiagnosticsLog.info("secure.mac.frame_in count=\(framesReceived) frame=\(frame.count) plaintext=\(plaintext.count)")
            }

            if let response = try dispatcher.handle(plaintext) {
                try await sendPlaintext(response)
            }
        }
    }

    func inboundIdleDuration(at now: Date = Date()) -> TimeInterval {
        now.timeIntervalSince(lastInboundActivityAt)
    }

    private func requireEstablished() throws -> EstablishedHandshake {
        guard let established else {
            throw SecureSessionHostError.notEstablished
        }
        return established
    }

    private func waitForEstablished() async throws -> EstablishedHandshake {
        for _ in 0..<500 {
            if let established {
                return established
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw SecureSessionHostError.notEstablished
    }

    private func isHandshakeHello(_ frame: Data) -> Bool {
        guard let envelope = try? HandshakeWire.decodeSignedPeer(frame) else {
            return false
        }
        return envelope.t == HandshakeType.hello
    }

    private func isHandshakeConfirm(_ frame: Data) -> Bool {
        guard let envelope = try? HandshakeWire.decodeConfirm(frame) else {
            return false
        }
        return envelope.t == HandshakeType.confirm
    }
}

enum SecureSessionHostError: Error {
    case closedBeforeHandshake
    case notEstablished
}

private actor SecureSessionSendGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        if !isLocked {
            isLocked = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func unlock() {
        guard !waiters.isEmpty else {
            isLocked = false
            return
        }

        waiters.removeFirst().resume()
    }
}
