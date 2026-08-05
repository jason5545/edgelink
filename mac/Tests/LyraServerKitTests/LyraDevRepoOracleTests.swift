import CryptoKit
import EdgeLinkKit
import LyraServerKit
import XCTest

// Pins the oracle's acceptance model (binary + ground-truth aligned
// 2026-08-05): the announce never stamps trusted type; BOTH the type-1 push
// and the type-2 reply run the tdi.f15 TrustedGroupInfoFrame cred checks;
// AddOnlineDevice needs a non-zero trusted type and a resolvable f13 key.
final class LyraDevRepoOracleTests: XCTestCase {
    private func makeDevice(
        fullId: String = "AA",
        withKey: Bool = true,
        withCredBlock: Data? = nil,
        services: [LyraTrustedDevice.Service] = []
    ) -> LyraTrustedDevice {
        var device = LyraTrustedDevice()
        device.deviceName = "MacBook Pro"
        device.fullDeviceIdHex = fullId
        device.deviceKey = withKey ? Data(repeating: 0x42, count: 32) : nil
        device.credBlock = withCredBlock
        device.services = services
        return device
    }

    // The phone fixture: account keypair + its Mijia-shape cert. Registering
    // the cert in trustedCerts is the oracle-side equivalent of the phone
    // having the cert's uid on the account.
    private func makeTrustedIdentity() -> (identity: LyraPhoneIdentity, groupInfo: Data) {
        let identity = LyraPhoneIdentity.generate()
        let groupInfo = identity.accountCertCredBlock()!
        return (identity, groupInfo)
    }

    private func trustFixtureCert(_ oracle: LyraDevRepoOracle, _ identity: LyraPhoneIdentity) {
        oracle.trustedCerts[identity.accountCertData!] = identity.accountPubKeyData
    }

    func testAnnounceNeverStampsTrustedType() {
        let oracle = LyraDevRepoOracle()
        let record = oracle.handleAnnounce(device: makeDevice())
        XCTAssertEqual(record.trustedType, 0)
        XCTAssertFalse(record.online)
        XCTAssertTrue(record.rejectionReasons.contains("AddOnlineDevice err trusted_type 0"))
    }

    func testPushWithoutCredsKeepsTrustedTypeZero() {
        let oracle = LyraDevRepoOracle()
        let record = oracle.handleSyncPush(
            device: makeDevice(), groupInfo: nil, connHadFullHandshake: true
        )
        XCTAssertEqual(record.trustedType, 0)
        XCTAssertFalse(record.online)
        XCTAssertTrue(record.rejectionReasons.contains("no group cred (tdi.f15 absent)"))
    }

    func testPushWithAccountCertCredStampsAndGoesOnline() throws {
        let oracle = LyraDevRepoOracle()
        let (identity, groupInfo) = makeTrustedIdentity()
        trustFixtureCert(oracle, identity)

        let record = oracle.handleSyncPush(
            device: makeDevice(services: [
                LyraTrustedDevice.Service(name: "relayCall", package: "com.ios.phone", data: nil),
            ]),
            groupInfo: groupInfo,
            connHadFullHandshake: true
        )
        XCTAssertEqual(record.trustedType, 1)
        XCTAssertTrue(record.online)
        XCTAssertTrue(record.rejectionReasons.isEmpty)
        // The account slot verified; the shared slot runs but is not the gate.
        XCTAssertTrue(record.checks.contains { $0.kind == .accountCertCred && $0.passed })
        // The announce that follows the push now passes AddOnlineDevice.
        let announced = oracle.handleAnnounce(device: makeDevice())
        XCTAssertTrue(announced.online)
        // TeleService's gate finds the relayCall service.
        XCTAssertNotNil(oracle.relayServiceDevice())
    }

    func testPushWithoutDeviceKeyStaysOffline() throws {
        let oracle = LyraDevRepoOracle()
        let (identity, groupInfo) = makeTrustedIdentity()
        trustFixtureCert(oracle, identity)

        let record = oracle.handleSyncPush(
            device: makeDevice(withKey: false), groupInfo: groupInfo, connHadFullHandshake: true
        )
        XCTAssertFalse(record.online)
        XCTAssertTrue(record.rejectionReasons.contains("client not have device key"))
        XCTAssertNil(oracle.resolveDeviceKey(for: "AA"))
    }

    // 0731 ground truth: the real Mac registered online (trusted_type 1)
    // through the REPLY path — HandleReplyDevMsg runs the same cred checks.
    func testReplyPathAlsoStampsTrustedType() throws {
        let oracle = LyraDevRepoOracle()
        let (identity, groupInfo) = makeTrustedIdentity()
        trustFixtureCert(oracle, identity)

        let record = oracle.handleSyncReply(
            device: makeDevice(services: [
                LyraTrustedDevice.Service(name: "relayCall", package: "com.ios.phone", data: nil),
            ]),
            groupInfo: groupInfo
        )
        XCTAssertEqual(record.trustedType, 1)
        XCTAssertTrue(record.online)
        XCTAssertNotNil(oracle.resolveDeviceKey(for: "AA"))
    }

    func testReplyWithoutCredsStaysOffline() {
        let oracle = LyraDevRepoOracle()
        let record = oracle.handleSyncReply(device: makeDevice())
        XCTAssertEqual(record.trustedType, 0)
        XCTAssertFalse(record.online)
        XCTAssertNotNil(oracle.resolveDeviceKey(for: "AA"))
    }

    // A cert cred signed by an unregistered cert must not pass — the
    // phone-side equivalent of CheckCertCred's "not same account".
    func testCertCredRejectsUnregisteredCert() throws {
        let oracle = LyraDevRepoOracle()
        let (identity, groupInfo) = makeTrustedIdentity()
        _ = identity
        // Deliberately do NOT register the cert.
        let record = oracle.handleSyncPush(
            device: makeDevice(), groupInfo: groupInfo, connHadFullHandshake: true
        )
        XCTAssertEqual(record.trustedType, 0)
        XCTAssertFalse(record.online)
        XCTAssertTrue(record.rejectionReasons.contains { $0.hasPrefix("CheckCertCred failed") })
    }
}
