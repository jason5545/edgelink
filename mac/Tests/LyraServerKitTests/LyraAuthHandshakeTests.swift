import CryptoKit
import EdgeLinkKit
import LyraServerKit
import XCTest

// Round-trips the 4-step AuthHandshake between the kit's client and server
// roles and checks both derive the same session key.
final class LyraAuthHandshakeTests: XCTestCase {
    func testClientServerRoundTrip() throws {
        let phoneIdentity = LyraPhoneIdentity.generate()
        let macIdentity = P256.Signing.PrivateKey()

        let server = LyraAuthHandshake.Server(identity: phoneIdentity)
        let client = LyraAuthHandshake.Client(identity: phoneIdentity)

        let clientNotify = client.makeClientNotify()
        let serverNotify = try XCTUnwrap(server.handleClientNotify(authFrame: clientNotify))
        let clientFinished = try XCTUnwrap(client.handleServerNotify(authFrame: serverNotify))

        // The phone verifies the Mac's signature against the paired identity
        // — here the client used the phone identity, so pair with itself.
        let serverFinished = try XCTUnwrap(
            server.handleClientFinished(
                authFrame: clientFinished,
                peerIdentityPubKey: phoneIdentity.identityPubKeyData
            )
        )
        let clientResult = try XCTUnwrap(client.handleServerFinished(authFrame: serverFinished.serverFinished))

        let serverKeyData = serverFinished.result.sessionKey.withUnsafeBytes { Data($0) }
        let clientKeyData = clientResult.sessionKey.withUnsafeBytes { Data($0) }
        XCTAssertEqual(serverKeyData, clientKeyData)
        let serverTicket = serverFinished.result.ticket.withUnsafeBytes { Data($0) }
        let clientTicket = clientResult.ticket.withUnsafeBytes { Data($0) }
        XCTAssertEqual(serverTicket, clientTicket)
        _ = macIdentity
    }

    func testClientFinishedRejectedWithWrongPeerIdentity() throws {
        let phoneIdentity = LyraPhoneIdentity.generate()
        let server = LyraAuthHandshake.Server(identity: phoneIdentity)
        let client = LyraAuthHandshake.Client(identity: phoneIdentity)

        let clientNotify = client.makeClientNotify()
        let serverNotify = try XCTUnwrap(server.handleClientNotify(authFrame: clientNotify))
        let clientFinished = try XCTUnwrap(client.handleServerNotify(authFrame: serverNotify))

        let wrongIdentity = P256.Signing.PrivateKey()
        XCTAssertNil(
            server.handleClientFinished(
                authFrame: clientFinished,
                peerIdentityPubKey: wrongIdentity.publicKey.x963Representation
            )
        )
    }

    func testServerFinishedRejectsTamperedProof() throws {
        let phoneIdentity = LyraPhoneIdentity.generate()
        let server = LyraAuthHandshake.Server(identity: phoneIdentity)
        let client = LyraAuthHandshake.Client(identity: phoneIdentity)

        let clientNotify = client.makeClientNotify()
        let serverNotify = try XCTUnwrap(server.handleClientNotify(authFrame: clientNotify))
        let clientFinished = try XCTUnwrap(client.handleServerNotify(authFrame: serverNotify))
        let serverFinished = try XCTUnwrap(
            server.handleClientFinished(
                authFrame: clientFinished,
                peerIdentityPubKey: phoneIdentity.identityPubKeyData
            )
        )

        var tamperedProof = Data([0xDE, 0xAD])
        var tamperedFinished = Data()
        LyraProtoWriter.appendLengthDelimitedField(1, value: tamperedProof, to: &tamperedFinished)
        var tamperedAuthFrame = Data()
        LyraProtoWriter.appendVarintField(1, value: 4, to: &tamperedAuthFrame)
        LyraProtoWriter.appendLengthDelimitedField(5, value: tamperedFinished, to: &tamperedAuthFrame)
        XCTAssertNil(client.handleServerFinished(authFrame: tamperedAuthFrame))
        _ = serverFinished
    }
}
