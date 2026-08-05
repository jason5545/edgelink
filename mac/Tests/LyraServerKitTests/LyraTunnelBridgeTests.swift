import EdgeLinkKit
import LyraServerKit
import XCTest

final class LyraTunnelBridgeTests: XCTestCase {
    func testLocalForwardEchoOverRelaySession() async throws {
        let echoServer = TCPEchoServer()
        let echoPort = try echoServer.start()
        defer { echoServer.stop() }

        let pair = LoopbackChannelPair()
        let hostIdentity = makeRelayTestIdentity(deviceId: "123456789", name: "FakeHost")
        let clientIdentity = makeRelayTestIdentity(deviceId: "987654321", name: "FakePhone")

        let openResultSeen = expectation(description: "host sees tunnel.open.result ok")
        let echoReceived = expectation(description: "host receives echoed tunnel.data")

        let hostSession = LyraRelaySession(
            channel: pair.hostSide,
            identity: hostIdentity,
            onEnvelope: { type, plaintext in
                switch type {
                case EnvelopeType.tunnelOpenResult:
                    if let envelope = try? JSONDecoder().decode(Envelope<TunnelOpenResultBody>.self, from: plaintext),
                       envelope.b.ok {
                        openResultSeen.fulfill()
                    }
                case EnvelopeType.tunnelData:
                    if let envelope = try? JSONDecoder().decode(Envelope<TunnelDataBody>.self, from: plaintext),
                       let data = TunnelChunker.payloadFromBase64(envelope.b.payload),
                       String(decoding: data, as: UTF8.self) == "relay tunnel works" {
                        echoReceived.fulfill()
                    }
                default:
                    break
                }
            }
        )

        let clientSessionRef = SessionRef()
        let tunnelBridge = LyraTunnelBridge(sendHandler: { data in
            try await clientSessionRef.session?.sendPlaintext(data)
        })
        let clientSession = LyraRelaySession(
            channel: pair.clientSide,
            identity: clientIdentity,
            onEnvelope: { type, plaintext in
                if LyraTunnelBridge.handles(type) {
                    await tunnelBridge.handleEnvelope(type: type, plaintext: plaintext)
                }
            }
        )
        clientSessionRef.session = clientSession

        async let hostAccept: Void = hostSession.acceptAsHost(pinnedClientPublicKey: clientIdentity.publicKey)
        async let clientConnect: Void = clientSession.connectAsClient(pinnedHostPublicKey: hostIdentity.publicKey)
        try await (hostAccept, clientConnect)

        let hostLoop = Task { try await hostSession.receiveLoop() }
        let clientLoop = Task { try await clientSession.receiveLoop() }
        defer {
            pair.hostSide.close()
            pair.clientSide.close()
            hostLoop.cancel()
            clientLoop.cancel()
        }

        let tunnelId = "test-tunnel-1"
        try await hostSession.sendEnvelope(EnvelopeType.tunnelOpen, TunnelOpenBody(
            tunnelId: tunnelId,
            direction: .local,
            targetHost: "127.0.0.1",
            targetPort: Int(echoPort),
            label: "test"
        ))

        await fulfillment(of: [openResultSeen], timeout: 5)

        try await hostSession.sendEnvelope(EnvelopeType.tunnelData, TunnelDataBody(
            tunnelId: tunnelId,
            streamId: 1,
            seq: 0,
            payload: TunnelChunker.payloadBase64(Data("relay tunnel works".utf8))
        ))

        await fulfillment(of: [echoReceived], timeout: 5)

        try await hostSession.sendEnvelope(EnvelopeType.tunnelClose, TunnelCloseBody(
            tunnelId: tunnelId,
            streamId: 1
        ))
    }

    func testDialFailureReportsTargetRefused() async throws {
        let pair = LoopbackChannelPair()
        let hostIdentity = makeRelayTestIdentity(deviceId: "123456789", name: "FakeHost")
        let clientIdentity = makeRelayTestIdentity(deviceId: "987654321", name: "FakePhone")

        let refusedSeen = expectation(description: "host sees target_refused")

        let hostSession = LyraRelaySession(
            channel: pair.hostSide,
            identity: hostIdentity,
            onEnvelope: { type, plaintext in
                guard type == EnvelopeType.tunnelError,
                      let envelope = try? JSONDecoder().decode(Envelope<TunnelErrorBody>.self, from: plaintext),
                      envelope.b.code == .targetRefused else {
                    return
                }
                refusedSeen.fulfill()
            }
        )

        let clientSessionRef = SessionRef()
        let tunnelBridge = LyraTunnelBridge(sendHandler: { data in
            try await clientSessionRef.session?.sendPlaintext(data)
        })
        let clientSession = LyraRelaySession(
            channel: pair.clientSide,
            identity: clientIdentity,
            onEnvelope: { type, plaintext in
                if LyraTunnelBridge.handles(type) {
                    await tunnelBridge.handleEnvelope(type: type, plaintext: plaintext)
                }
            }
        )
        clientSessionRef.session = clientSession

        async let hostAccept: Void = hostSession.acceptAsHost(pinnedClientPublicKey: clientIdentity.publicKey)
        async let clientConnect: Void = clientSession.connectAsClient(pinnedHostPublicKey: hostIdentity.publicKey)
        try await (hostAccept, clientConnect)

        let hostLoop = Task { try await hostSession.receiveLoop() }
        let clientLoop = Task { try await clientSession.receiveLoop() }
        defer {
            pair.hostSide.close()
            pair.clientSide.close()
            hostLoop.cancel()
            clientLoop.cancel()
        }

        let tunnelId = "test-tunnel-refused"
        try await hostSession.sendEnvelope(EnvelopeType.tunnelOpen, TunnelOpenBody(
            tunnelId: tunnelId,
            direction: .local,
            targetHost: "127.0.0.1",
            targetPort: 1,
            label: "test"
        ))
        try await hostSession.sendEnvelope(EnvelopeType.tunnelData, TunnelDataBody(
            tunnelId: tunnelId,
            streamId: 1,
            seq: 0,
            payload: TunnelChunker.payloadBase64(Data("x".utf8))
        ))

        await fulfillment(of: [refusedSeen], timeout: 10)
    }
}

private final class SessionRef: @unchecked Sendable {
    var session: LyraRelaySession?
}
