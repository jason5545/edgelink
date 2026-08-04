import CryptoKit
import EdgeLinkKit
import LyraServerKit
import XCTest

// Pins the oracle's acceptance model: announce never stamps trusted type,
// only the type-1 push does, and AddOnlineDevice needs both a non-zero
// trusted type and a resolvable f13 device key.
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
        XCTAssertTrue(record.rejectionReasons.contains("no creds in push (f15/groupInfo absent)"))
    }

    func testPushWithGroupCredStampsAndGoesOnline() throws {
        let oracle = LyraDevRepoOracle()
        let macIdentity = P256.Signing.PrivateKey()
        oracle.trustedPeerIdentities = [macIdentity.publicKey.x963Representation]

        var nonce = Data(count: 32)
        nonce.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress { arc4random_buf(base, 32) }
        }
        let signature = try macIdentity.signature(for: SHA256.hash(data: nonce))
        var pubKeyCred = Data()
        LyraProtoWriter.appendLengthDelimitedField(1, value: nonce, to: &pubKeyCred)
        LyraProtoWriter.appendLengthDelimitedField(2, value: signature.derRepresentation, to: &pubKeyCred)
        var credFeature = Data()
        LyraProtoWriter.appendVarintField(1, value: 2, to: &credFeature)
        LyraProtoWriter.appendLengthDelimitedField(3, value: pubKeyCred, to: &credFeature)
        var groupInfo = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &groupInfo)
        LyraProtoWriter.appendLengthDelimitedField(3, value: credFeature, to: &groupInfo)

        let record = oracle.handleSyncPush(
            device: makeDevice(services: [
                LyraTrustedDevice.Service(name: "relayCall", package: "com.ios.phone", data: nil),
            ]),
            groupInfo: groupInfo,
            connHadFullHandshake: true
        )
        XCTAssertNotEqual(record.trustedType, 0)
        XCTAssertTrue(record.online)
        XCTAssertTrue(record.rejectionReasons.isEmpty)
        // The announce that follows the push now passes AddOnlineDevice.
        let announced = oracle.handleAnnounce(device: makeDevice())
        XCTAssertTrue(announced.online)
        // TeleService's gate finds the relayCall service.
        XCTAssertNotNil(oracle.relayServiceDevice())
    }

    func testPushWithoutDeviceKeyStaysOffline() throws {
        let oracle = LyraDevRepoOracle()
        let macIdentity = P256.Signing.PrivateKey()
        oracle.trustedPeerIdentities = [macIdentity.publicKey.x963Representation]
        var nonce = Data(count: 32)
        nonce.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress { arc4random_buf(base, 32) }
        }
        let signature = try macIdentity.signature(for: SHA256.hash(data: nonce))
        var pubKeyCred = Data()
        LyraProtoWriter.appendLengthDelimitedField(1, value: nonce, to: &pubKeyCred)
        LyraProtoWriter.appendLengthDelimitedField(2, value: signature.derRepresentation, to: &pubKeyCred)
        var credFeature = Data()
        LyraProtoWriter.appendLengthDelimitedField(3, value: pubKeyCred, to: &credFeature)
        var groupInfo = Data()
        LyraProtoWriter.appendLengthDelimitedField(3, value: credFeature, to: &groupInfo)

        let record = oracle.handleSyncPush(
            device: makeDevice(withKey: false), groupInfo: groupInfo, connHadFullHandshake: true
        )
        XCTAssertFalse(record.online)
        XCTAssertTrue(record.rejectionReasons.contains("client not have device key"))
        XCTAssertNil(oracle.resolveDeviceKey(for: "AA"))
    }

    func testReplyPathStoresButNeverStamps() {
        let oracle = LyraDevRepoOracle()
        let record = oracle.handleSyncReply(device: makeDevice())
        XCTAssertEqual(record.trustedType, 0)
        XCTAssertFalse(record.online)
        XCTAssertNotNil(oracle.resolveDeviceKey(for: "AA"))
    }

    func testGroupCredRejectsUnknownIdentity() throws {
        let oracle = LyraDevRepoOracle()
        let unknownIdentity = P256.Signing.PrivateKey()
        var nonce = Data(count: 32)
        nonce.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress { arc4random_buf(base, 32) }
        }
        let signature = try unknownIdentity.signature(for: SHA256.hash(data: nonce))
        var pubKeyCred = Data()
        LyraProtoWriter.appendLengthDelimitedField(1, value: nonce, to: &pubKeyCred)
        LyraProtoWriter.appendLengthDelimitedField(2, value: signature.derRepresentation, to: &pubKeyCred)
        var credFeature = Data()
        LyraProtoWriter.appendLengthDelimitedField(3, value: pubKeyCred, to: &credFeature)
        var groupInfo = Data()
        LyraProtoWriter.appendLengthDelimitedField(3, value: credFeature, to: &groupInfo)

        let record = oracle.handleSyncPush(
            device: makeDevice(), groupInfo: groupInfo, connHadFullHandshake: true
        )
        XCTAssertEqual(record.trustedType, 0)
        XCTAssertFalse(record.online)
    }
}
