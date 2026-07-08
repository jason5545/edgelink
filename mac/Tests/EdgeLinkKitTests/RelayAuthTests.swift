import CryptoKit
import XCTest
@testable import EdgeLinkKit

final class RelayAuthTests: XCTestCase {
    func testRelayAuthMessageVector() throws {
        let message = RelayAuth.message(deviceId: "949758990", timestampSeconds: 1_751_941_000)
        XCTAssertEqual(String(data: message, encoding: .utf8), "EdgeLink relay auth v1\n949758990\n1751941000")
    }

    func testRelayAuthEnvelopeVerifiesWithPublicKey() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let identity = LocalIdentity(deviceId: "949758990", name: "Jason's Mac", signingKey: privateKey)
        let envelope = try RelayAuth.envelope(hostId: "949758990", identity: identity, timestampSeconds: 1_751_941_000)
        let signature = Data(base64Encoded: envelope.b.sig)!

        XCTAssertTrue(privateKey.publicKey.isValidSignature(
            signature,
            for: RelayAuth.message(deviceId: "949758990", timestampSeconds: 1_751_941_000)
        ))
    }
}
