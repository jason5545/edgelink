import XCTest
@testable import EdgeLinkKit

final class PairingTests: XCTestCase {
    func testSASVectorV1() throws {
        let hostPk = Data(base64Encoded: "A6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg=")!
        let clientPk = Data(base64Encoded: "Kay64UG8yvCyLhqU000LxzYeUm0L/hLIl5S8kyKWbdc=")!
        let nonceH = Data(base64Encoded: "QEFCQ0RFRkdISUpLTE1OT1BRUlNUVVZXWFlaW1xdXl8=")!
        let nonceC = Data(base64Encoded: "YGFiY2RlZmdoaWprbG1ub3BxcnN0dXZ3eHl6e3x9fn8=")!

        XCTAssertEqual(Pairing.commitment(hostPublicKey: hostPk, hostNonce: nonceH).base64EncodedString(), "GmEr3dD+3U/Bfxizfu8qM7FXrqdyXRB2xrkM7vRepm0=")
        XCTAssertEqual(Pairing.sas(hostPublicKey: hostPk, clientPublicKey: clientPk, hostNonce: nonceH, clientNonce: nonceC).display, "260 433")
    }
}
