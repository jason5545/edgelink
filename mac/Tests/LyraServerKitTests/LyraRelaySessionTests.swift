import CryptoKit
import EdgeLinkKit
import LyraServerKit
import XCTest

final class LyraRelaySessionTests: XCTestCase {
    func testClientHostHandshakePingPongAndEcho() async throws {
        let pair = LoopbackChannelPair()
        let hostIdentity = makeRelayTestIdentity(deviceId: "123456789", name: "FakeHost")
        let clientIdentity = makeRelayTestIdentity(deviceId: "987654321", name: "FakePhone")

        let hostEchoed = expectation(description: "host receives debug.echo")
        let clientGotPong = expectation(description: "client receives pong")

        let hostSession = LyraRelaySession(
            channel: pair.hostSide,
            identity: hostIdentity,
            onEnvelope: { type, plaintext in
                guard type == "debug.echo",
                      let echo = try? JSONDecoder().decode(Envelope<RelayEchoBody>.self, from: plaintext),
                      echo.b.text == "hello host" else {
                    return
                }
                hostEchoed.fulfill()
            }
        )
        let clientSession = LyraRelaySession(
            channel: pair.clientSide,
            identity: clientIdentity,
            onPong: { rttMs, _ in
                if rttMs >= 0 {
                    clientGotPong.fulfill()
                }
            }
        )

        async let hostAccept: Void = hostSession.acceptAsHost(
            pinnedClientPublicKey: clientIdentity.publicKey
        )
        async let clientConnect: Void = clientSession.connectAsClient(
            pinnedHostPublicKey: hostIdentity.publicKey
        )
        try await (hostAccept, clientConnect)

        let hostLoop = Task { try await hostSession.receiveLoop() }
        let clientLoop = Task { try await clientSession.receiveLoop() }

        try await clientSession.sendPing()
        try await clientSession.sendEnvelope("debug.echo", RelayEchoBody(text: "hello host"))

        await fulfillment(of: [hostEchoed, clientGotPong], timeout: 5)

        pair.hostSide.close()
        pair.clientSide.close()
        hostLoop.cancel()
        clientLoop.cancel()
    }

    func testRelayIdentityStoreRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyra-relay-identity-\(UUID().uuidString)")
        let store = LyraRelayIdentityStore(
            url: directory.appendingPathComponent("relay-identity.json")
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertNil(try store.load())

        let registrar = StubDeviceRegistrar(deviceId: "135792468")
        let registered = try await store.loadOrRegister(
            registrar: registrar,
            name: "FakePhone",
            platform: "android"
        )
        XCTAssertEqual(registered.deviceId, "135792468")
        XCTAssertEqual(registrar.platforms, ["android"])

        let reloaded = try XCTUnwrap(try store.load())
        XCTAssertEqual(reloaded.deviceId, registered.deviceId)
        XCTAssertEqual(reloaded.publicKey, registered.publicKey)

        let again = try await store.loadOrRegister(
            registrar: StubDeviceRegistrar(deviceId: "999999999"),
            name: "FakePhone",
            platform: "android"
        )
        XCTAssertEqual(again.deviceId, registered.deviceId)
    }
}

private struct RelayEchoBody: Codable, Sendable {
    let text: String
}

private final class StubDeviceRegistrar: DeviceRegistrar, @unchecked Sendable {
    let deviceId: String
    private(set) var platforms: [String] = []

    init(deviceId: String) {
        self.deviceId = deviceId
    }

    func register(pubkey: Data, name: String, platform: String) async throws -> String {
        platforms.append(platform)
        return deviceId
    }
}
