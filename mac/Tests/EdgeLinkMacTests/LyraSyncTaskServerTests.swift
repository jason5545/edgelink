import CryptoKit
import EdgeLinkKit
import Foundation
import XCTest

// Pins the quick-conn sync-task server: the phone's reverse sync task embeds
// private_data (trailing field 4 of the phys sync request) carrying a logi
// opening with an AuthHandshake client_notify; the answer must go back inside
// the phys sync response private_data, after which client_finished and the
// encrypted logi REQUEST continue on the embedded logi conn.
final class LyraSyncTaskServerTests: XCTestCase {
    private static let defaultsKeys = [
        "xiaomiTrustIdentityPrivHex",
        "xiaomiTrustIdentityPubB64",
        "xiaomiTrustPeerIdentityPubB64",
        "xiaomiTrustPeerAccountPubB64",
        "xiaomiTrustSessionKeyHex",
        "xiaomiTrustTicketHex",
    ]

    private var savedValues: [String: String?] = [:]
    private let serverIdentity = P256.Signing.PrivateKey()
    private let phoneIdentity = P256.Signing.PrivateKey()

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        for key in Self.defaultsKeys {
            savedValues[key] = defaults.string(forKey: key)
        }
        defaults.set(serverIdentity.rawRepresentation.map { String(format: "%02x", $0) }.joined(),
                     forKey: "xiaomiTrustIdentityPrivHex")
        defaults.set(serverIdentity.publicKey.x963Representation.base64EncodedString(),
                     forKey: "xiaomiTrustIdentityPubB64")
        defaults.set(phoneIdentity.publicKey.x963Representation.base64EncodedString(),
                     forKey: "xiaomiTrustPeerIdentityPubB64")
    }

    override func tearDown() {
        let defaults = UserDefaults.standard
        for key in Self.defaultsKeys {
            if let value = savedValues[key] ?? nil {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        super.tearDown()
    }

    // MARK: - Fixtures

    private struct ClientSide {
        var connId: UInt32
        var handshakeId: UInt64
        var ephKey: P256.KeyAgreement.PrivateKey
        var clientRandom: Data
        var requestTrailingFields: [LyraProtoReader.Field]
    }

    private func makeClient(service: String = LyraSyncTaskServer.syncServiceName) -> ClientSide {
        let connId: UInt32 = 0x00AB_CDEF
        let handshakeId: UInt64 = 7
        let ephKey = P256.KeyAgreement.PrivateKey()
        var clientRandom = Data(count: 32)
        clientRandom.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress { arc4random_buf(base, 32) }
        }

        var publicKeyMessage = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &publicKeyMessage)
        LyraProtoWriter.appendLengthDelimitedField(
            2, value: ephKey.publicKey.x963Representation, to: &publicKeyMessage
        )
        var cipherSuite = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &cipherSuite)
        LyraProtoWriter.appendLengthDelimitedField(2, value: clientRandom, to: &cipherSuite)
        LyraProtoWriter.appendVarintField(3, value: 64, to: &cipherSuite)
        LyraProtoWriter.appendVarintField(4, value: 2, to: &cipherSuite)
        LyraProtoWriter.appendLengthDelimitedField(5, value: publicKeyMessage, to: &cipherSuite)
        var clientNotify = Data()
        LyraProtoWriter.appendLengthDelimitedField(1, value: cipherSuite, to: &clientNotify)
        LyraProtoWriter.appendVarintField(2, value: 4, to: &clientNotify)
        LyraProtoWriter.appendLengthDelimitedField(3, value: Data([0x08, 0x01]), to: &clientNotify)
        LyraProtoWriter.appendLengthDelimitedField(4, value: Data([0x08, 0x01]), to: &clientNotify)
        var authFrame = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &authFrame)
        LyraProtoWriter.appendLengthDelimitedField(2, value: clientNotify, to: &authFrame)
        var handshake = Data()
        LyraProtoWriter.appendVarintField(1, value: 4, to: &handshake)
        LyraProtoWriter.appendVarintField(2, value: 5, to: &handshake)
        LyraProtoWriter.appendLengthDelimitedField(7, value: authFrame, to: &handshake)
        var upgrade = Data()
        LyraProtoWriter.appendVarintField(1, value: handshakeId, to: &upgrade)
        LyraProtoWriter.appendLengthDelimitedField(2, value: handshake, to: &upgrade)
        let quickConn = LogiConnInnerFrame(frameType: 6, payload: .upgrade(upgrade))

        var syncInfo = Data()
        LyraProtoWriter.appendVarintField(1, value: 10000, to: &syncInfo)
        LyraProtoWriter.appendVarintField(2, value: 16, to: &syncInfo)
        LyraProtoWriter.appendLengthDelimitedField(4, value: Data(service.utf8), to: &syncInfo)
        LyraProtoWriter.appendLengthDelimitedField(5, value: Data([0x0A, 0x01, 0x00]), to: &syncInfo)
        LyraProtoWriter.appendLengthDelimitedField(8, value: quickConn.serialized(), to: &syncInfo)

        let inner = LogiConnInnerFrame(frameType: 5, payload: .syncInfo(syncInfo))
        let logiConn = LogiConnFrame(
            logiConnId: connId, localNetId: 1, remoteNetId: 0, inner: inner.serialized()
        )
        var wrapper = Data()
        LyraProtoWriter.appendLengthDelimitedField(1, value: logiConn.serialized(), to: &wrapper)
        var privateData = Data()
        LyraProtoWriter.appendLengthDelimitedField(2, value: wrapper, to: &privateData)
        LyraProtoWriter.appendVarintField(5, value: 128, to: &privateData)

        var request = Data()
        LyraProtoWriter.appendVarintField(1, value: 1_700_000_000_000, to: &request)
        LyraProtoWriter.appendLengthDelimitedField(2, value: Data([0x0A, 0x01, 0x00]), to: &request)
        LyraProtoWriter.appendVarintField(3, value: 256, to: &request)
        LyraProtoWriter.appendLengthDelimitedField(4, value: privateData, to: &request)
        LyraProtoWriter.appendVarintField(5, value: 128, to: &request)

        let parsed = PhysConnSyncDeviceInfoRequest(parsing: request)
        XCTAssertNotNil(parsed)
        return ClientSide(
            connId: connId,
            handshakeId: handshakeId,
            ephKey: ephKey,
            clientRandom: clientRandom,
            requestTrailingFields: parsed?.trailingFields ?? []
        )
    }

    private func lengthDelimited(_ fieldNumber: Int, in data: Data) -> Data? {
        guard let fields = try? LyraProtoReader.readFields(from: data) else { return nil }
        return fields.first { $0.number == fieldNumber && $0.wireType == 2 }?.lengthDelimitedValue
    }

    private func varint(_ fieldNumber: Int, in data: Data) -> UInt64? {
        guard let fields = try? LyraProtoReader.readFields(from: data) else { return nil }
        return fields.first { $0.number == fieldNumber && $0.wireType == 0 }?.varintValue
    }

    private struct ServerNotify {
        var serverRandom: Data
        var serverPub: Data
        var encSig: Data
        var sharedZ: Data
        var sessionKey: SymmetricKey
    }

    private struct Failure: Error {}

    private func unwrapServerNotify(
        _ privateData: Data, client: ClientSide
    ) throws -> (logiConn: LogiConnFrame, notify: ServerNotify) {
        let pdFields = try LyraProtoReader.readFields(from: privateData)
        let wrapper = try XCTUnwrap(pdFields.first { $0.number == 2 && $0.wireType == 2 }?.lengthDelimitedValue)
        let logiConnData = try XCTUnwrap(lengthDelimited(1, in: wrapper))
        let logiConn = try XCTUnwrap(LogiConnFrame(parsing: logiConnData))
        XCTAssertEqual(logiConn.logiConnId, client.connId)
        XCTAssertEqual(logiConn.remoteNetId, 1)
        let inner = try XCTUnwrap(LogiConnInnerFrame(parsing: logiConn.inner))
        guard case let .syncInfo(syncInfoData) = inner.payload else {
            XCTFail("expected sync_info payload")
            throw Failure()
        }
        XCTAssertEqual(varint(1, in: syncInfoData), 10000)
        XCTAssertEqual(varint(2, in: syncInfoData), 40)
        XCTAssertNotNil(lengthDelimited(5, in: syncInfoData))
        let quickConn = try XCTUnwrap(lengthDelimited(8, in: syncInfoData))
        let qcInner = try XCTUnwrap(LogiConnInnerFrame(parsing: quickConn))
        XCTAssertEqual(qcInner.frameType, 6)
        guard case let .upgrade(upgradeData) = qcInner.payload else {
            XCTFail("expected upgrade payload")
            throw Failure()
        }
        XCTAssertEqual(varint(1, in: upgradeData), client.handshakeId)
        let handshake = try XCTUnwrap(lengthDelimited(2, in: upgradeData))
        XCTAssertEqual(varint(1, in: handshake), 4)
        XCTAssertEqual(varint(2, in: handshake), 5)
        let authFrame = try XCTUnwrap(lengthDelimited(7, in: handshake))
        XCTAssertEqual(varint(1, in: authFrame), 2)
        let serverNotify = try XCTUnwrap(lengthDelimited(3, in: authFrame))
        let selected = try XCTUnwrap(lengthDelimited(1, in: serverNotify))
        let serverRandom = try XCTUnwrap(lengthDelimited(2, in: selected))
        XCTAssertEqual(serverRandom.count, 32)
        XCTAssertEqual(varint(3, in: selected), 64)
        XCTAssertEqual(varint(4, in: selected), 2)
        let outGPK = try XCTUnwrap(lengthDelimited(5, in: selected))
        let serverPub = try XCTUnwrap(lengthDelimited(2, in: outGPK))
        XCTAssertEqual(serverPub.count, 65)
        let encSig = try XCTUnwrap(lengthDelimited(2, in: serverNotify))

        let peerKey = try P256.KeyAgreement.PublicKey(x963Representation: serverPub)
        let z = try client.ephKey.sharedSecretFromKeyAgreement(with: peerKey).withUnsafeBytes { Data($0) }
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: encSig.prefix(12)),
            ciphertext: encSig.dropFirst(12).dropLast(16),
            tag: encSig.suffix(16)
        )
        let sigDer = try AES.GCM.open(box, using: SymmetricKey(data: z))
        let signature = try P256.Signing.ECDSASignature(derRepresentation: sigDer)
        XCTAssertTrue(
            serverIdentity.publicKey.isValidSignature(
                signature, for: SHA256.hash(data: serverPub + client.ephKey.publicKey.x963Representation)
            )
        )
        let sessionKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: z),
            salt: Data([
                0x5e, 0xd5, 0xa3, 0xf8, 0x36, 0xf6, 0xb5, 0x4f,
                0x7b, 0x1e, 0xfa, 0xd0, 0x27, 0x14, 0xd5, 0x17,
                0x7b, 0x8a, 0x1f, 0x0f, 0x19, 0xe3, 0x69, 0xcc,
                0x0b, 0xe8, 0xd9, 0x8b, 0xa6, 0x29, 0x73, 0x17
            ]),
            info: client.clientRandom + serverRandom,
            outputByteCount: 32
        )
        return (
            logiConn,
            ServerNotify(
                serverRandom: serverRandom, serverPub: serverPub, encSig: encSig,
                sharedZ: z, sessionKey: sessionKey
            )
        )
    }

    private func makeClientFinishedFrame(
        client: ClientSide, notify: ServerNotify, signingKey: P256.Signing.PrivateKey? = nil
    ) throws -> LogiConnFrame {
        let signer = signingKey ?? phoneIdentity
        let signature = try signer.signature(
            for: SHA256.hash(data: client.ephKey.publicKey.x963Representation + notify.serverPub)
        )
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(
            signature.derRepresentation, using: SymmetricKey(data: notify.sharedZ), nonce: nonce
        )
        var blob = Data()
        blob.append(contentsOf: nonce.withUnsafeBytes { Data($0) })
        blob.append(sealed.ciphertext)
        blob.append(sealed.tag)
        var clientFinished = Data()
        LyraProtoWriter.appendLengthDelimitedField(1, value: blob, to: &clientFinished)
        var authFrame = Data()
        LyraProtoWriter.appendVarintField(1, value: 3, to: &authFrame)
        LyraProtoWriter.appendLengthDelimitedField(4, value: clientFinished, to: &authFrame)
        var handshake = Data()
        LyraProtoWriter.appendVarintField(1, value: 4, to: &handshake)
        LyraProtoWriter.appendVarintField(2, value: 5, to: &handshake)
        LyraProtoWriter.appendLengthDelimitedField(7, value: authFrame, to: &handshake)
        var upgrade = Data()
        LyraProtoWriter.appendVarintField(1, value: client.handshakeId, to: &upgrade)
        LyraProtoWriter.appendLengthDelimitedField(2, value: handshake, to: &upgrade)
        let inner = LogiConnInnerFrame(frameType: 6, payload: .upgrade(upgrade))
        return LogiConnFrame(
            logiConnId: client.connId, localNetId: 1, remoteNetId: 1, inner: inner.serialized()
        )
    }

    // MARK: - Tests

    func testNoPrivateDataYieldsNil() {
        let server = LyraSyncTaskServer()
        XCTAssertNil(server.responsePrivateData(requestTrailingFields: []))
    }

    func testNonSyncServiceIgnored() {
        let server = LyraSyncTaskServer()
        let client = makeClient(service: "com.example:other")
        XCTAssertNil(server.responsePrivateData(requestTrailingFields: client.requestTrailingFields))
    }

    func testQuickConnHandshakeAndLogiResponse() throws {
        let server = LyraSyncTaskServer()
        let client = makeClient()

        let privateData = try XCTUnwrap(
            server.responsePrivateData(requestTrailingFields: client.requestTrailingFields)?.privateData
        )
        let (_, notify) = try unwrapServerNotify(privateData, client: client)

        let stray = LogiConnFrame(logiConnId: client.connId &+ 1, inner: Data())
        XCTAssertFalse(server.handles(logiConn: stray))

        let clientFinished = try makeClientFinishedFrame(client: client, notify: notify)
        XCTAssertTrue(server.handles(logiConn: clientFinished))
        let finishedReplies = server.handleLogiConn(clientFinished)
        XCTAssertEqual(finishedReplies.count, 1)
        let serverFinishedFrame = try XCTUnwrap(finishedReplies.first)
        XCTAssertFalse(serverFinishedFrame.flag)
        XCTAssertEqual(serverFinishedFrame.logiConnId, client.connId)
        let finishedInner = try XCTUnwrap(LogiConnInnerFrame(parsing: serverFinishedFrame.inner))
        guard case let .upgrade(finishedUpgrade) = finishedInner.payload else {
            XCTFail("expected server_finished upgrade")
            throw Failure()
        }
        let finishedHandshake = try XCTUnwrap(lengthDelimited(2, in: finishedUpgrade))
        let finishedAuth = try XCTUnwrap(lengthDelimited(7, in: finishedHandshake))
        XCTAssertEqual(varint(1, in: finishedAuth), 4)
        let serverFinished = try XCTUnwrap(lengthDelimited(5, in: finishedAuth))
        let finishedBlob = try XCTUnwrap(lengthDelimited(1, in: serverFinished))
        let proofBox = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: finishedBlob.prefix(12)),
            ciphertext: finishedBlob.dropFirst(12).dropLast(16),
            tag: finishedBlob.suffix(16)
        )
        let proof = try AES.GCM.open(proofBox, using: notify.sessionKey)
        XCTAssertEqual(proof, notify.sharedZ + notify.serverPub)
        XCTAssertEqual(server.sessionKeys.count, 1)

        var request = Data()
        LyraProtoWriter.appendLengthDelimitedField(
            2, value: Data(LyraSyncTaskServer.syncServiceName.utf8), to: &request
        )
        LyraProtoWriter.appendVarintField(4, value: 16, to: &request)
        LyraProtoWriter.appendVarintField(5, value: 10000, to: &request)
        let requestInner = LogiConnInnerFrame(frameType: 1, payload: .request(request))
        let requestNonce = AES.GCM.Nonce()
        let requestSealed = try AES.GCM.seal(
            requestInner.serialized(), using: notify.sessionKey, nonce: requestNonce
        )
        var encryptedInner = Data()
        encryptedInner.append(contentsOf: requestNonce.withUnsafeBytes { Data($0) })
        encryptedInner.append(requestSealed.ciphertext)
        encryptedInner.append(requestSealed.tag)
        let encryptedRequest = LogiConnFrame(
            logiConnId: client.connId, localNetId: 1, remoteNetId: 1, flag: true, inner: encryptedInner
        )
        let responses = server.handleLogiConn(encryptedRequest)
        XCTAssertEqual(responses.count, 1)
        let responseFrame = try XCTUnwrap(responses.first)
        XCTAssertTrue(responseFrame.flag)
        let responseBox = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: responseFrame.inner.prefix(12)),
            ciphertext: responseFrame.inner.dropFirst(12).dropLast(16),
            tag: responseFrame.inner.suffix(16)
        )
        let responsePlain = try AES.GCM.open(responseBox, using: notify.sessionKey)
        let decodedResponse = try XCTUnwrap(LogiConnInnerFrame(parsing: responsePlain))
        XCTAssertEqual(decodedResponse.frameType, 2)
        guard case let .response(responseData) = decodedResponse.payload else {
            XCTFail("expected logi response payload")
            throw Failure()
        }
        XCTAssertEqual(varint(1, in: responseData), 0)
        XCTAssertEqual(varint(3, in: responseData), 1)

        XCTAssertTrue(server.handleLogiConn(encryptedRequest).isEmpty)
    }

    // Live 2026-08-05: auth_type 4 dials sign client_finished with the phone's
    // account identity key (Mijia cert), not the pairing key. With the account
    // key registered, the handshake must complete even when the pairing key is
    // different.
    func testClientFinishedSignedWithAccountKeyCompletes() throws {
        let accountIdentity = P256.Signing.PrivateKey()
        let defaults = UserDefaults.standard
        defaults.set(
            accountIdentity.publicKey.x963Representation.base64EncodedString(),
            forKey: "xiaomiTrustPeerAccountPubB64"
        )
        defaults.set(
            P256.Signing.PrivateKey().publicKey.x963Representation.base64EncodedString(),
            forKey: "xiaomiTrustPeerIdentityPubB64"
        )

        let server = LyraSyncTaskServer()
        let client = makeClient()
        let privateData = try XCTUnwrap(
            server.responsePrivateData(requestTrailingFields: client.requestTrailingFields)?.privateData
        )
        let (_, notify) = try unwrapServerNotify(privateData, client: client)

        let clientFinished = try makeClientFinishedFrame(
            client: client, notify: notify, signingKey: accountIdentity
        )
        let replies = server.handleLogiConn(clientFinished)
        XCTAssertEqual(replies.count, 1, "account-key client_finished must complete the handshake")
        XCTAssertEqual(server.sessionKeys.count, 1)
    }

    func testBadClientFinishedSignatureYieldsNoReply() throws {
        let server = LyraSyncTaskServer()
        let client = makeClient()
        _ = server.responsePrivateData(requestTrailingFields: client.requestTrailingFields)

        var clientRandom2 = Data(count: 32)
        clientRandom2.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress { arc4random_buf(base, 32) }
        }
        let wrongKey = P256.KeyAgreement.PrivateKey()
        var gpk = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &gpk)
        LyraProtoWriter.appendLengthDelimitedField(
            2, value: wrongKey.publicKey.x963Representation, to: &gpk
        )
        let signature = try phoneIdentity.signature(
            for: SHA256.hash(data: wrongKey.publicKey.x963Representation + Data(count: 65))
        )
        let zKey = SymmetricKey(data: clientRandom2)
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(signature.derRepresentation, using: zKey, nonce: nonce)
        var blob = Data()
        blob.append(contentsOf: nonce.withUnsafeBytes { Data($0) })
        blob.append(sealed.ciphertext)
        blob.append(sealed.tag)
        var clientFinished = Data()
        LyraProtoWriter.appendLengthDelimitedField(1, value: blob, to: &clientFinished)
        var authFrame = Data()
        LyraProtoWriter.appendVarintField(1, value: 3, to: &authFrame)
        LyraProtoWriter.appendLengthDelimitedField(4, value: clientFinished, to: &authFrame)
        var handshake = Data()
        LyraProtoWriter.appendVarintField(1, value: 4, to: &handshake)
        LyraProtoWriter.appendVarintField(2, value: 5, to: &handshake)
        LyraProtoWriter.appendLengthDelimitedField(7, value: authFrame, to: &handshake)
        var upgrade = Data()
        LyraProtoWriter.appendVarintField(1, value: client.handshakeId, to: &upgrade)
        LyraProtoWriter.appendLengthDelimitedField(2, value: handshake, to: &upgrade)
        let inner = LogiConnInnerFrame(frameType: 6, payload: .upgrade(upgrade))
        let frame = LogiConnFrame(logiConnId: client.connId, localNetId: 1, inner: inner.serialized())

        XCTAssertTrue(server.handleLogiConn(frame).isEmpty)
        XCTAssertTrue(server.sessionKeys.isEmpty)
    }
}
