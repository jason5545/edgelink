import CryptoKit
import EdgeLinkKit
import Foundation
import XCTest

// Pins the quick-conn sync-task server: the phone's reverse sync task embeds
// private_data (trailing field 4 of the phys sync request) carrying a logi
// opening with an AuthHandshake client_notify; the phys sync response stays
// private_data-less and the answer (f8-less server sync_info + server_notify)
// goes out as standalone logi frames, after which client_finished and the
// encrypted logi REQUEST continue on the embedded logi conn.
final class LyraSyncTaskServerTests: XCTestCase {
    private static let defaultsKeys = [
        "xiaomiTrustIdentityPrivHex",
        "xiaomiTrustIdentityPubB64",
        "xiaomiTrustPeerIdentityPubB64",
        "xiaomiTrustPeerAccountPubB64",
        "xiaomiTrustSessionKeyHex",
        "xiaomiTrustTicketHex",
        "xiaomiTrustSessionKeyRingHex",
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

    private enum EmbeddedFamily {
        case auth
        case accountPair
    }

    private func makeClient(
        service: String = LyraSyncTaskServer.syncServiceName,
        family: EmbeddedFamily = .auth
    ) -> ClientSide {
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
        LyraProtoWriter.appendVarintField(3, value: family == .accountPair ? 16 : 64, to: &cipherSuite)
        LyraProtoWriter.appendVarintField(4, value: family == .accountPair ? 8 : 2, to: &cipherSuite)
        LyraProtoWriter.appendLengthDelimitedField(5, value: publicKeyMessage, to: &cipherSuite)
        var clientNotify = Data()
        LyraProtoWriter.appendLengthDelimitedField(1, value: cipherSuite, to: &clientNotify)
        var handshake = Data()
        switch family {
        case .auth:
            LyraProtoWriter.appendVarintField(2, value: 4, to: &clientNotify)
            LyraProtoWriter.appendLengthDelimitedField(3, value: Data([0x08, 0x01]), to: &clientNotify)
            LyraProtoWriter.appendLengthDelimitedField(4, value: Data([0x08, 0x01]), to: &clientNotify)
            var authFrame = Data()
            LyraProtoWriter.appendVarintField(1, value: 1, to: &authFrame)
            LyraProtoWriter.appendLengthDelimitedField(2, value: clientNotify, to: &authFrame)
            LyraProtoWriter.appendVarintField(1, value: 4, to: &handshake)
            LyraProtoWriter.appendVarintField(2, value: 5, to: &handshake)
            LyraProtoWriter.appendLengthDelimitedField(7, value: authFrame, to: &handshake)
        case .accountPair:
            var accountFrame = Data()
            LyraProtoWriter.appendVarintField(1, value: 1, to: &accountFrame)
            LyraProtoWriter.appendLengthDelimitedField(2, value: clientNotify, to: &accountFrame)
            LyraProtoWriter.appendVarintField(1, value: 2, to: &handshake)
            LyraProtoWriter.appendVarintField(2, value: 4, to: &handshake)
            LyraProtoWriter.appendLengthDelimitedField(6, value: accountFrame, to: &handshake)
        }
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

    private static let sessionSalt = Data([
        0x5e, 0xd5, 0xa3, 0xf8, 0x36, 0xf6, 0xb5, 0x4f,
        0x7b, 0x1e, 0xfa, 0xd0, 0x27, 0x14, 0xd5, 0x17,
        0x7b, 0x8a, 0x1f, 0x0f, 0x19, 0xe3, 0x69, 0xcc,
        0x0b, 0xe8, 0xd9, 0x8b, 0xa6, 0x29, 0x73, 0x17
    ])

    // Account-pair family session-key salt (libmicontinuity.so
    // AccountPairHandshake, 2026-08-06) — different from the AUTH family.
    private static let accountPairSessionSalt = Data([
        0x32, 0x9b, 0xfc, 0x53, 0x39, 0x36, 0x55, 0xd7,
        0x5a, 0xb0, 0x83, 0x98, 0xca, 0x91, 0x91, 0xef,
        0xfa, 0xa3, 0x37, 0xf2, 0xe0, 0xbe, 0xb5, 0x73,
        0xb1, 0xf9, 0xa3, 0xd0, 0x15, 0x57, 0x64, 0x80
    ])

    private struct AccountPairNotify {
        var serverRandom: Data
        var serverPub: Data
        var sharedZ: Data
        var sessionKey: SymmetricKey
    }

    // Verifies an account-pair server_notify frame (step 2): selected cipher
    // 16/8, 32B server_random, 65B server pub, and encSig opening under Z to
    // {certDER, ECDSA-SHA256(serverEph‖clientEph) by the enrolled cert key}.
    private func unwrapAccountPairServerNotify(
        accountFrame: Data,
        client: ClientSide,
        certKey: P256.Signing.PrivateKey,
        expectedCertDER: Data,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> AccountPairNotify {
        XCTAssertEqual(varint(1, in: accountFrame), 2, file: file, line: line)
        let serverNotify = try XCTUnwrap(lengthDelimited(3, in: accountFrame), file: file, line: line)
        let selected = try XCTUnwrap(lengthDelimited(1, in: serverNotify), file: file, line: line)
        let serverRandom = try XCTUnwrap(lengthDelimited(2, in: selected), file: file, line: line)
        XCTAssertEqual(serverRandom.count, 32, file: file, line: line)
        XCTAssertEqual(varint(3, in: selected), 16, file: file, line: line)
        XCTAssertEqual(varint(4, in: selected), 8, file: file, line: line)
        let outGPK = try XCTUnwrap(lengthDelimited(5, in: selected), file: file, line: line)
        let serverPub = try XCTUnwrap(lengthDelimited(2, in: outGPK), file: file, line: line)
        XCTAssertEqual(serverPub.count, 65, file: file, line: line)
        let encSig = try XCTUnwrap(lengthDelimited(2, in: serverNotify), file: file, line: line)
        XCTAssertNotNil(lengthDelimited(3, in: serverNotify), file: file, line: line)
        XCTAssertNotNil(lengthDelimited(4, in: serverNotify), file: file, line: line)

        let peerKey = try P256.KeyAgreement.PublicKey(x963Representation: serverPub)
        let z = try client.ephKey.sharedSecretFromKeyAgreement(with: peerKey).withUnsafeBytes { Data($0) }
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: encSig.prefix(12)),
            ciphertext: encSig.dropFirst(12).dropLast(16),
            tag: encSig.suffix(16)
        )
        let credMessage = try AES.GCM.open(box, using: SymmetricKey(data: z))
        let cert = try XCTUnwrap(lengthDelimited(1, in: credMessage), file: file, line: line)
        XCTAssertEqual(cert, expectedCertDER, file: file, line: line)
        let sig = try XCTUnwrap(lengthDelimited(2, in: credMessage), file: file, line: line)
        let ecdsaSig = try P256.Signing.ECDSASignature(derRepresentation: sig)
        XCTAssertTrue(
            certKey.publicKey.isValidSignature(
                ecdsaSig, for: SHA256.hash(data: serverPub + client.ephKey.publicKey.x963Representation)
            ),
            file: file, line: line
        )
        let sessionKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: z),
            salt: Self.accountPairSessionSalt,
            info: client.clientRandom + serverRandom,
            outputByteCount: 32
        )
        return AccountPairNotify(
            serverRandom: serverRandom, serverPub: serverPub, sharedZ: z, sessionKey: sessionKey
        )
    }

    // Pulls the account-pair server_notify out of a standalone logi frame
    // (upgrade → handshake {2,4}+f6).
    private func unwrapAccountPairServerNotifyFrame(
        _ frame: LogiConnFrame,
        client: ClientSide,
        certKey: P256.Signing.PrivateKey,
        expectedCertDER: Data,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> AccountPairNotify {
        XCTAssertEqual(frame.logiConnId, client.connId, file: file, line: line)
        let inner = try XCTUnwrap(LogiConnInnerFrame(parsing: frame.inner), file: file, line: line)
        guard case let .upgrade(upgradeData) = inner.payload else {
            XCTFail("expected upgrade payload", file: file, line: line)
            throw Failure()
        }
        XCTAssertEqual(varint(1, in: upgradeData), client.handshakeId, file: file, line: line)
        let handshake = try XCTUnwrap(lengthDelimited(2, in: upgradeData), file: file, line: line)
        XCTAssertEqual(varint(1, in: handshake), 2, file: file, line: line)
        XCTAssertEqual(varint(2, in: handshake), 4, file: file, line: line)
        let accountFrame = try XCTUnwrap(lengthDelimited(6, in: handshake), file: file, line: line)
        return try unwrapAccountPairServerNotify(
            accountFrame: accountFrame, client: client,
            certKey: certKey, expectedCertDER: expectedCertDER,
            file: file, line: line
        )
    }

    private func makeAccountPairClientFinishedFrame(
        client: ClientSide,
        notify: AccountPairNotify,
        phoneCertKey: P256.Signing.PrivateKey,
        phoneCertDER: Data
    ) throws -> LogiConnFrame {
        let phoneSig = try phoneCertKey.signature(
            for: SHA256.hash(data: client.ephKey.publicKey.x963Representation + notify.serverPub)
        )
        var phoneCred = Data()
        LyraProtoWriter.appendLengthDelimitedField(1, value: phoneCertDER, to: &phoneCred)
        LyraProtoWriter.appendLengthDelimitedField(2, value: phoneSig.derRepresentation, to: &phoneCred)
        let credNonce = AES.GCM.Nonce()
        let credSealed = try AES.GCM.seal(phoneCred, using: SymmetricKey(data: notify.sharedZ), nonce: credNonce)
        var credBlob = Data()
        credBlob.append(contentsOf: credNonce.withUnsafeBytes { Data($0) })
        credBlob.append(credSealed.ciphertext)
        credBlob.append(credSealed.tag)
        let proofNonce = AES.GCM.Nonce()
        let proofSealed = try AES.GCM.seal(Data(count: 24), using: notify.sessionKey, nonce: proofNonce)
        var proof = Data()
        proof.append(contentsOf: proofNonce.withUnsafeBytes { Data($0) })
        proof.append(proofSealed.ciphertext)
        proof.append(proofSealed.tag)

        var clientFinished = Data()
        LyraProtoWriter.appendLengthDelimitedField(1, value: credBlob, to: &clientFinished)
        LyraProtoWriter.appendLengthDelimitedField(2, value: proof, to: &clientFinished)
        var finishedAccountFrame = Data()
        LyraProtoWriter.appendVarintField(1, value: 3, to: &finishedAccountFrame)
        LyraProtoWriter.appendLengthDelimitedField(4, value: clientFinished, to: &finishedAccountFrame)
        var finishedHandshake = Data()
        LyraProtoWriter.appendVarintField(1, value: 2, to: &finishedHandshake)
        LyraProtoWriter.appendVarintField(2, value: 4, to: &finishedHandshake)
        LyraProtoWriter.appendLengthDelimitedField(6, value: finishedAccountFrame, to: &finishedHandshake)
        var finishedUpgrade = Data()
        LyraProtoWriter.appendVarintField(1, value: client.handshakeId, to: &finishedUpgrade)
        LyraProtoWriter.appendLengthDelimitedField(2, value: finishedHandshake, to: &finishedUpgrade)
        let finishedInner = LogiConnInnerFrame(frameType: 6, payload: .upgrade(finishedUpgrade))
        return LogiConnFrame(
            logiConnId: client.connId, localNetId: 1, remoteNetId: 1, inner: finishedInner.serialized()
        )
    }

    private func assertAccountPairServerFinished(
        _ frame: LogiConnFrame?,
        client: ClientSide,
        notify: AccountPairNotify,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let frame = try XCTUnwrap(frame, file: file, line: line)
        XCTAssertEqual(frame.logiConnId, client.connId, file: file, line: line)
        let inner = try XCTUnwrap(LogiConnInnerFrame(parsing: frame.inner), file: file, line: line)
        guard case let .upgrade(upgradeData) = inner.payload else {
            XCTFail("expected server_finished upgrade", file: file, line: line)
            throw Failure()
        }
        let handshake = try XCTUnwrap(lengthDelimited(2, in: upgradeData), file: file, line: line)
        XCTAssertEqual(varint(1, in: handshake), 2, file: file, line: line)
        XCTAssertEqual(varint(2, in: handshake), 4, file: file, line: line)
        let accountFrame = try XCTUnwrap(lengthDelimited(6, in: handshake), file: file, line: line)
        XCTAssertEqual(varint(1, in: accountFrame), 4, file: file, line: line)
        let serverFinished = try XCTUnwrap(lengthDelimited(5, in: accountFrame), file: file, line: line)
        let proofBlob = try XCTUnwrap(lengthDelimited(1, in: serverFinished), file: file, line: line)
        let proofBox = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: proofBlob.prefix(12)),
            ciphertext: proofBlob.dropFirst(12).dropLast(16),
            tag: proofBlob.suffix(16)
        )
        XCTAssertEqual(
            try AES.GCM.open(proofBox, using: notify.sessionKey),
            notify.sharedZ + notify.serverPub,
            file: file, line: line
        )
    }

    private func makeEncryptedDataFrame(
        client: ClientSide, inner: LogiConnInnerFrame, sessionKey: SymmetricKey
    ) throws -> LogiConnFrame {
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(inner.serialized(), using: sessionKey, nonce: nonce)
        var encryptedInner = Data()
        encryptedInner.append(contentsOf: nonce.withUnsafeBytes { Data($0) })
        encryptedInner.append(sealed.ciphertext)
        encryptedInner.append(sealed.tag)
        return LogiConnFrame(
            logiConnId: client.connId, localNetId: 1, remoteNetId: 1, flag: true, inner: encryptedInner
        )
    }

    private func openEncryptedFrame(
        _ frame: LogiConnFrame, sessionKey: SymmetricKey
    ) throws -> LogiConnInnerFrame {
        XCTAssertTrue(frame.flag)
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: frame.inner.prefix(12)),
            ciphertext: frame.inner.dropFirst(12).dropLast(16),
            tag: frame.inner.suffix(16)
        )
        let plaintext = try AES.GCM.open(box, using: sessionKey)
        return try XCTUnwrap(LogiConnInnerFrame(parsing: plaintext))
    }

    // On-conn AUTH-family client_notify (the phone's "continue normal conn
    // from quick conn" fallback sends this on the logi conn).
    private func makeClientNotifyFrame(client: ClientSide) -> LogiConnFrame {
        var publicKeyMessage = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &publicKeyMessage)
        LyraProtoWriter.appendLengthDelimitedField(
            2, value: client.ephKey.publicKey.x963Representation, to: &publicKeyMessage
        )
        var cipherSuite = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &cipherSuite)
        LyraProtoWriter.appendLengthDelimitedField(2, value: client.clientRandom, to: &cipherSuite)
        LyraProtoWriter.appendVarintField(3, value: 64, to: &cipherSuite)
        LyraProtoWriter.appendVarintField(4, value: 2, to: &cipherSuite)
        LyraProtoWriter.appendLengthDelimitedField(5, value: publicKeyMessage, to: &cipherSuite)
        var clientNotify = Data()
        LyraProtoWriter.appendLengthDelimitedField(1, value: cipherSuite, to: &clientNotify)
        var authFrame = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &authFrame)
        LyraProtoWriter.appendLengthDelimitedField(2, value: clientNotify, to: &authFrame)
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

    // Parses our on-conn AUTH-family server_notify ({4,5}+f7).
    private func unwrapServerNotify(
        _ frame: LogiConnFrame, client: ClientSide
    ) throws -> ServerNotify {
        XCTAssertEqual(frame.logiConnId, client.connId)
        let inner = try XCTUnwrap(LogiConnInnerFrame(parsing: frame.inner))
        guard case let .upgrade(upgradeData) = inner.payload else {
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
        return ServerNotify(
            serverRandom: serverRandom, serverPub: serverPub, encSig: encSig,
            sharedZ: z, sessionKey: sessionKey
        )
    }

    // The standalone server sync_info frame must be f8-less — the handshake
    // answer rides separate standalone logi frames, never sync_info f8.
    private func assertF8LessSyncInfoFrame(
        _ frame: LogiConnFrame, client: ClientSide,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        XCTAssertEqual(frame.logiConnId, client.connId, file: file, line: line)
        let inner = try XCTUnwrap(LogiConnInnerFrame(parsing: frame.inner), file: file, line: line)
        guard case let .syncInfo(syncInfoData) = inner.payload else {
            XCTFail("expected sync_info payload", file: file, line: line)
            throw Failure()
        }
        XCTAssertEqual(varint(1, in: syncInfoData), 10000, file: file, line: line)
        XCTAssertEqual(varint(2, in: syncInfoData), 40, file: file, line: line)
        XCTAssertNotNil(lengthDelimited(4, in: syncInfoData), file: file, line: line)
        XCTAssertNil(lengthDelimited(8, in: syncInfoData), "server sync_info must be f8-less", file: file, line: line)
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

        // AUTH-family embedded client_notify: no phys private_data; standalone
        // f8-less sync_info + AUTH server_notify (official Mac shape).
        let built = try XCTUnwrap(
            server.responsePrivateData(requestTrailingFields: client.requestTrailingFields)
        )
        XCTAssertNil(built.privateData, "embedded client_notify dials get no phys private_data")
        XCTAssertEqual(built.logiFrames.count, 2)
        try assertF8LessSyncInfoFrame(built.logiFrames[0], client: client)
        XCTAssertTrue(server.handles(logiConn: LogiConnFrame(logiConnId: client.connId, inner: Data())))

        let stray = LogiConnFrame(logiConnId: client.connId &+ 1, inner: Data())
        XCTAssertFalse(server.handles(logiConn: stray))

        let notify = try unwrapServerNotify(built.logiFrames[1], client: client)

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
        let finishedAuth = try XCTUnwrap(lengthDelimited(7, in: finishedHandshake), "on-conn auth frames must ride the AUTH-family wrapper (f7)")
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
        let built = try XCTUnwrap(
            server.responsePrivateData(requestTrailingFields: client.requestTrailingFields)
        )
        XCTAssertNil(built.privateData)
        XCTAssertEqual(built.logiFrames.count, 2)
        try assertF8LessSyncInfoFrame(built.logiFrames[0], client: client)
        let notifyReplies = server.handleLogiConn(makeClientNotifyFrame(client: client))
        let notify = try unwrapServerNotify(try XCTUnwrap(notifyReplies.first), client: client)

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
        _ = server.handleLogiConn(makeClientNotifyFrame(client: client))

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

    // Live 2026-08-05 (real phone, sync task 28 dial): the sync-task quick-conn
    // client_notify is the ACCOUNT-PAIR family — handshake wrapper {2,4} with
    // the frame in f6. The official Mac (pcap) leaves the phys sync response
    // private_data-less and answers with a standalone account-pair
    // server_notify on the conn; embedding even an f8-less sync_info in the
    // phys response hard-fails the phone ("auth reuse failed: service check
    // error", no fallback). Structural assertions only: the fixture's client
    // ephemeral private key is unknown, so encSig can't be opened here — full
    // crypto verification lives in testEmbeddedAccountPairClientNotifyCompletesSync.
    func testRealPhoneF6WrappedClientNotifyAccepted() throws {
        let serverCertKey = P256.Signing.PrivateKey()
        let serverCertDER = makeSelfSignedCert(
            pubX963: serverCertKey.publicKey.x963Representation, cn: "lyra.test-uid.test-did.14"
        )
        MiTrustTicketStore.enrolledCertOverride = {
            MijiaEnrolledCert(
                certDERBase64: serverCertDER.base64EncodedString(),
                privateKeyBase64: serverCertKey.rawRepresentation.base64EncodedString(),
                did: "test-did",
                enrolledAt: Date()
            )
        }
        defer { MiTrustTicketStore.enrolledCertOverride = nil }

        let realSyncInfo = try XCTUnwrap(MiTrustTicketStore.data(fromHex:
            "08904e1010220830303135303332332a2c0a084bab18b6596b8e401220d0a2e7f19" +
            "eba0e72f00a1e89320b70539aea10dd121b65a227fdc1dfe16cae33428d0108063a" +
            "8801082012830108021004327d080112790a6f0801122006625644e0305732699a8" +
            "197387d75e5f57f85e067639aadde6fc5bdeaee08fa181020082a450801124104e1" +
            "b6b38f1f6b6d3b88deb7bd12f462bb0ac38be00494420b65ee21cdda2ec71196598" +
            "d09e53de94120041860c278798f27468ba788dbf055318ad368174363f512020801" +
            "1a020801"
        ))
        let inner = LogiConnInnerFrame(frameType: 5, payload: .syncInfo(realSyncInfo))
        let logiConn = LogiConnFrame(
            logiConnId: 4_110_687_169, localNetId: 1, remoteNetId: 0, inner: inner.serialized()
        )
        var wrapper = Data()
        LyraProtoWriter.appendLengthDelimitedField(1, value: logiConn.serialized(), to: &wrapper)
        var privateData = Data()
        LyraProtoWriter.appendLengthDelimitedField(2, value: wrapper, to: &privateData)
        var request = Data()
        LyraProtoWriter.appendLengthDelimitedField(4, value: privateData, to: &request)
        let trailingFields = try LyraProtoReader.readFields(from: request)

        let server = LyraSyncTaskServer()
        let built = try XCTUnwrap(
            server.responsePrivateData(requestTrailingFields: trailingFields),
            "f6 account-pair client_notify must get a server_notify answer"
        )
        XCTAssertNil(built.privateData, "official Mac leaves the phys response private_data-less")
        XCTAssertEqual(built.logiFrames.count, 2)

        let syncInfoFrame = built.logiFrames[0]
        XCTAssertEqual(syncInfoFrame.logiConnId, 4_110_687_169)
        let syncInfoInner = try XCTUnwrap(LogiConnInnerFrame(parsing: syncInfoFrame.inner))
        guard case let .syncInfo(outSyncInfo) = syncInfoInner.payload else {
            XCTFail("expected sync_info payload")
            return
        }
        XCTAssertEqual(varint(1, in: outSyncInfo), 10000)
        XCTAssertEqual(varint(2, in: outSyncInfo), 40)
        XCTAssertNotNil(lengthDelimited(4, in: outSyncInfo))
        XCTAssertNil(lengthDelimited(8, in: outSyncInfo), "server sync_info must be f8-less")

        let notifyFrame = built.logiFrames[1]
        XCTAssertEqual(notifyFrame.logiConnId, 4_110_687_169)
        let notifyInner = try XCTUnwrap(LogiConnInnerFrame(parsing: notifyFrame.inner))
        guard case let .upgrade(upgradeData) = notifyInner.payload else {
            XCTFail("expected server_notify upgrade payload")
            return
        }
        let handshake = try XCTUnwrap(lengthDelimited(2, in: upgradeData))
        XCTAssertEqual(varint(1, in: handshake), 2)
        XCTAssertEqual(varint(2, in: handshake), 4)
        let accountFrame = try XCTUnwrap(lengthDelimited(6, in: handshake))
        XCTAssertEqual(varint(1, in: accountFrame), 2)
        let serverNotify = try XCTUnwrap(lengthDelimited(3, in: accountFrame))
        let selected = try XCTUnwrap(lengthDelimited(1, in: serverNotify))
        XCTAssertEqual(try XCTUnwrap(lengthDelimited(2, in: selected)).count, 32)
        XCTAssertEqual(varint(3, in: selected), 16)
        XCTAssertEqual(varint(4, in: selected), 8)
        let outGPK = try XCTUnwrap(lengthDelimited(5, in: selected))
        XCTAssertEqual(try XCTUnwrap(lengthDelimited(2, in: outGPK)).count, 65)
        XCTAssertFalse(try XCTUnwrap(lengthDelimited(2, in: serverNotify)).isEmpty)
        XCTAssertTrue(server.handles(logiConn: LogiConnFrame(logiConnId: 4_110_687_169, inner: Data())))
    }

    // Account-pair handshake (family 2, cert-cred) reversed from the official
    // Mac (2026-08-05 pcap): server_notify carries AES-GCM(Z, {cert, sig}),
    // client_finished the phone's cert+sig, server_finished the AUTH-style proof.
    func testAccountPairHandshakeCompletes() throws {
        let serverCertKey = P256.Signing.PrivateKey()
        let serverCertDER = makeSelfSignedCert(
            pubX963: serverCertKey.publicKey.x963Representation, cn: "lyra.test-uid.test-did.14"
        )
        MiTrustTicketStore.enrolledCertOverride = {
            MijiaEnrolledCert(
                certDERBase64: serverCertDER.base64EncodedString(),
                privateKeyBase64: serverCertKey.rawRepresentation.base64EncodedString(),
                did: "test-did",
                enrolledAt: Date()
            )
        }
        defer { MiTrustTicketStore.enrolledCertOverride = nil }

        let phoneCertKey = P256.Signing.PrivateKey()
        let phoneCertDER = makeSelfSignedCert(
            pubX963: phoneCertKey.publicKey.x963Representation, cn: "lyra.phone-uid.phone-did.1"
        )

        let server = LyraSyncTaskServer()
        let client = makeClient()
        _ = server.responsePrivateData(requestTrailingFields: client.requestTrailingFields)

        // step 1: account-pair client_notify (family 2, handshake f6).
        let notifyFrame = makeAccountPairClientNotifyFrame(client: client)
        let notifyReplies = server.handleLogiConn(notifyFrame)
        XCTAssertEqual(notifyReplies.count, 1)
        let reply = try XCTUnwrap(notifyReplies.first)
        let inner = try XCTUnwrap(LogiConnInnerFrame(parsing: reply.inner))
        guard case let .upgrade(upgradeData) = inner.payload else {
            XCTFail("expected upgrade payload")
            return
        }
        let handshake = try XCTUnwrap(lengthDelimited(2, in: upgradeData))
        XCTAssertEqual(varint(1, in: handshake), 2)
        XCTAssertEqual(varint(2, in: handshake), 4)
        let accountFrame = try XCTUnwrap(lengthDelimited(6, in: handshake))
        let notify = try unwrapAccountPairServerNotify(
            accountFrame: accountFrame, client: client,
            certKey: serverCertKey, expectedCertDER: serverCertDER
        )

        // step 3: client_finished with the phone's cert + sig (clientEph‖serverEph).
        let finishedReplies = server.handleLogiConn(
            try makeAccountPairClientFinishedFrame(
                client: client, notify: notify,
                phoneCertKey: phoneCertKey, phoneCertDER: phoneCertDER
            )
        )
        XCTAssertEqual(finishedReplies.count, 1)
        try assertAccountPairServerFinished(finishedReplies.first, client: client, notify: notify)
        XCTAssertEqual(server.sessionKeys.count, 1)
    }

    // E2E through the embedded quick-conn path (the real phone's flow): the
    // account-pair client_notify embedded in the phys sync request is answered
    // by a server_notify in the response private_data (f8), then
    // client_finished, the encrypted REQUEST/RESPONSE and the payload exchange
    // all run on the logi conn.
    func testEmbeddedAccountPairClientNotifyCompletesSync() throws {
        let serverCertKey = P256.Signing.PrivateKey()
        let serverCertDER = makeSelfSignedCert(
            pubX963: serverCertKey.publicKey.x963Representation, cn: "lyra.test-uid.test-did.14"
        )
        MiTrustTicketStore.enrolledCertOverride = {
            MijiaEnrolledCert(
                certDERBase64: serverCertDER.base64EncodedString(),
                privateKeyBase64: serverCertKey.rawRepresentation.base64EncodedString(),
                did: "test-did",
                enrolledAt: Date()
            )
        }
        defer { MiTrustTicketStore.enrolledCertOverride = nil }

        let phoneCertKey = P256.Signing.PrivateKey()
        let phoneCertDER = makeSelfSignedCert(
            pubX963: phoneCertKey.publicKey.x963Representation, cn: "lyra.phone-uid.phone-did.1"
        )

        let server = LyraSyncTaskServer()
        let replyPayload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        server.syncPayloadProvider = { replyPayload }
        let client = makeClient(family: .accountPair)

        // step 1→2: embedded client_notify answered by a standalone
        // server_notify on the conn (no phys private_data).
        let built = try XCTUnwrap(
            server.responsePrivateData(requestTrailingFields: client.requestTrailingFields)
        )
        XCTAssertNil(built.privateData)
        XCTAssertEqual(built.logiFrames.count, 2)
        try assertF8LessSyncInfoFrame(built.logiFrames[0], client: client)
        let notify = try unwrapAccountPairServerNotifyFrame(
            built.logiFrames[1], client: client,
            certKey: serverCertKey, expectedCertDER: serverCertDER
        )
        XCTAssertTrue(server.handles(logiConn: LogiConnFrame(logiConnId: client.connId, inner: Data())))

        // step 3→4: client_finished on the logi conn → server_finished.
        let finishedReplies = server.handleLogiConn(
            try makeAccountPairClientFinishedFrame(
                client: client, notify: notify,
                phoneCertKey: phoneCertKey, phoneCertDER: phoneCertDER
            )
        )
        XCTAssertEqual(finishedReplies.count, 1)
        try assertAccountPairServerFinished(finishedReplies.first, client: client, notify: notify)
        XCTAssertEqual(server.sessionKeys.count, 1)

        // Encrypted logi REQUEST → minimal official-shape RESPONSE.
        var request = Data()
        LyraProtoWriter.appendLengthDelimitedField(
            2, value: Data(LyraSyncTaskServer.syncServiceName.utf8), to: &request
        )
        LyraProtoWriter.appendVarintField(4, value: 16, to: &request)
        LyraProtoWriter.appendVarintField(5, value: 10000, to: &request)
        let requestInner = LogiConnInnerFrame(frameType: 1, payload: .request(request))
        let encryptedRequest = try makeEncryptedDataFrame(
            client: client, inner: requestInner, sessionKey: notify.sessionKey
        )
        let responses = server.handleLogiConn(encryptedRequest)
        XCTAssertEqual(responses.count, 1)
        let decodedResponse = try openEncryptedFrame(
            try XCTUnwrap(responses.first), sessionKey: notify.sessionKey
        )
        XCTAssertEqual(decodedResponse.frameType, 2)
        guard case let .response(responseData) = decodedResponse.payload else {
            XCTFail("expected logi response payload")
            throw Failure()
        }
        XCTAssertEqual(varint(1, in: responseData), 0)
        XCTAssertEqual(varint(3, in: responseData), 1)

        // Payload push (PAYLOAD_V2 sync frame) → our TrustedDeviceInfo reply.
        let pushInner = LogiConnInnerFrame(frameType: 7, payload: .data(Data([0x01, 0x02, 0x03])))
        let pushFrame = try makeEncryptedDataFrame(
            client: client, inner: pushInner, sessionKey: notify.sessionKey
        )
        let pushReplies = server.handleLogiConn(pushFrame)
        XCTAssertEqual(pushReplies.count, 1)
        let decodedReply = try openEncryptedFrame(
            try XCTUnwrap(pushReplies.first), sessionKey: notify.sessionKey
        )
        XCTAssertEqual(decodedReply.frameType, 7)
        guard case let .data(replyData) = decodedReply.payload else {
            XCTFail("expected payload reply data")
            throw Failure()
        }
        XCTAssertEqual(replyData, replyPayload)
    }

    private func makeAccountPairClientNotifyFrame(client: ClientSide) -> LogiConnFrame {
        var publicKeyMessage = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &publicKeyMessage)
        LyraProtoWriter.appendLengthDelimitedField(
            2, value: client.ephKey.publicKey.x963Representation, to: &publicKeyMessage
        )
        var cipherSuite = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &cipherSuite)
        LyraProtoWriter.appendLengthDelimitedField(2, value: client.clientRandom, to: &cipherSuite)
        LyraProtoWriter.appendVarintField(3, value: 16, to: &cipherSuite)
        LyraProtoWriter.appendVarintField(4, value: 8, to: &cipherSuite)
        LyraProtoWriter.appendLengthDelimitedField(5, value: publicKeyMessage, to: &cipherSuite)
        var clientNotify = Data()
        LyraProtoWriter.appendLengthDelimitedField(1, value: cipherSuite, to: &clientNotify)
        var accountFrame = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &accountFrame)
        LyraProtoWriter.appendLengthDelimitedField(2, value: clientNotify, to: &accountFrame)
        var handshake = Data()
        LyraProtoWriter.appendVarintField(1, value: 2, to: &handshake)
        LyraProtoWriter.appendVarintField(2, value: 4, to: &handshake)
        LyraProtoWriter.appendLengthDelimitedField(6, value: accountFrame, to: &handshake)
        var upgrade = Data()
        LyraProtoWriter.appendVarintField(1, value: client.handshakeId, to: &upgrade)
        LyraProtoWriter.appendLengthDelimitedField(2, value: handshake, to: &upgrade)
        let inner = LogiConnInnerFrame(frameType: 6, payload: .upgrade(upgrade))
        return LogiConnFrame(
            logiConnId: client.connId, localNetId: 1, remoteNetId: 1, inner: inner.serialized()
        )
    }

    private func makeSelfSignedCert(pubX963: Data, cn: String) -> Data {
        let alg = MijiaCSR.derSeq(Data([0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02]))
        let ecAlg = MijiaCSR.derSeq(
            Data([0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01])
                + Data([0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07])
        )
        func name(_ cn: String, org: String) -> Data {
            let orgATV = MijiaCSR.derSeq(Data([0x06, 0x03, 0x55, 0x04, 0x0A]) + MijiaCSR.derUTF8(org))
            let cnATV = MijiaCSR.derSeq(Data([0x06, 0x03, 0x55, 0x04, 0x03]) + MijiaCSR.derUTF8(cn))
            return MijiaCSR.derSeq(MijiaCSR.derSet(orgATV) + MijiaCSR.derSet(cnATV))
        }
        func time(_ date: Date) -> Data {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyMMddHHmmss'Z'"
            fmt.timeZone = TimeZone(identifier: "UTC")
            return MijiaCSR.der(0x17, Data(fmt.string(from: date).utf8))
        }
        var tbs = Data()
        tbs.append(MijiaCSR.der(0xA0, MijiaCSR.derInteger(2)))
        tbs.append(MijiaCSR.derInteger(1))
        tbs.append(alg)
        tbs.append(name("", org: "Mijia Cloud"))
        tbs.append(MijiaCSR.derSeq(time(Date().addingTimeInterval(-3600)) + time(Date().addingTimeInterval(180 * 86400))))
        tbs.append(name(cn, org: ""))
        tbs.append(MijiaCSR.derSeq(ecAlg + MijiaCSR.derBitString(pubX963)))
        let tbsSeq = MijiaCSR.derSeq(tbs)
        let signingKey = P256.Signing.PrivateKey()
        let sig = (try? signingKey.signature(for: tbsSeq).derRepresentation) ?? Data(repeating: 0, count: 70)
        return MijiaCSR.derSeq(tbsSeq + alg + MijiaCSR.derBitString(sig))
    }

    func testAuthSessionKeyRingRetainsOlderKeys() throws {        let defaults = UserDefaults.standard
        let olderKey = Data((0..<32).map { UInt8($0 ^ 0x5A) })
        let newerKey = Data((0..<32).map { UInt8($0 ^ 0xA5) })
        MiTrustTicketStore.recordAuthSession(sessionKey: olderKey, ticket: Data(count: 32))
        MiTrustTicketStore.recordAuthSession(sessionKey: newerKey, ticket: Data(count: 32))

        let store = MiTrustTicketStore.current()
        var blob = Data()
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(Data([0x08, 0x01]), using: SymmetricKey(data: olderKey), nonce: nonce)
        blob.append(contentsOf: nonce.withUnsafeBytes { Data($0) })
        blob.append(sealed.ciphertext)
        blob.append(sealed.tag)
        let decrypted = store.decryptCredBlobWithKey(blob)
        XCTAssertEqual(decrypted?.plaintext, Data([0x08, 0x01]))

        let ring = defaults.stringArray(forKey: MiTrustTicketStore.sessionKeyRingDefaultsKey) ?? []
        let newerHex = newerKey.map { String(format: "%02x", $0) }.joined()
        let olderHex = olderKey.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(ring.first, newerHex)
        XCTAssertTrue(ring.contains(olderHex))
    }
}
