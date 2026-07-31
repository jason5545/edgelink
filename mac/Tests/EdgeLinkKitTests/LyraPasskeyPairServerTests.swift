import CryptoKit
import XCTest
@testable import EdgeLinkKit

final class LyraPasskeyPairServerTests: XCTestCase {
    private let passkey = "123456"
    private let serverIdentity = P256.Signing.PrivateKey()
    private let clientIdentity = P256.Signing.PrivateKey()

    private struct SentFrame {
        var family: UInt64 = 0
        var messageType: UInt64 = 0
        var alertCode: UInt64?
        var pairMsgType: UInt64?
        var pairFields: [LyraProtoReader.Field] = []
    }

    private final class Recorder {
        var sent: [SentFrame] = []
        var events: [LyraPasskeyPairServer.Event] = []
    }

    private func makeServer(passkey: String, recorder: Recorder) -> LyraPasskeyPairServer {
        let server = LyraPasskeyPairServer(passkey: passkey, identityPrivateKey: serverIdentity)
        server.onSend = { handshake in
            var frame = SentFrame()
            guard let fields = try? LyraProtoReader.readFields(from: handshake) else {
                recorder.sent.append(frame)
                return
            }
            frame.family = fields.first { $0.number == 1 }?.varintValue ?? 0
            frame.messageType = fields.first { $0.number == 2 }?.varintValue ?? 0
            if let alert = fields.first(where: { $0.number == 3 })?.lengthDelimitedValue,
               let alertFields = try? LyraProtoReader.readFields(from: alert)
            {
                frame.alertCode = alertFields.first { $0.number == 1 }?.varintValue
            }
            if let pair = fields.first(where: { $0.number == 4 })?.lengthDelimitedValue,
               let pairFields = try? LyraProtoReader.readFields(from: pair)
            {
                frame.pairMsgType = pairFields.first { $0.number == 1 }?.varintValue
                frame.pairFields = pairFields
            }
            recorder.sent.append(frame)
        }
        server.onEvent = { recorder.events.append($0) }
        return server
    }

    private func clientHandshakeFrame(msgType: UInt64, oneofField: Int, subFrame: Data) -> Data {
        var pair = Data()
        LyraProtoWriter.appendVarintField(1, value: msgType, to: &pair)
        LyraProtoWriter.appendLengthDelimitedField(oneofField, value: subFrame, to: &pair)
        var handshake = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &handshake)
        LyraProtoWriter.appendVarintField(2, value: 2, to: &handshake)
        LyraProtoWriter.appendLengthDelimitedField(4, value: pair, to: &handshake)
        return handshake
    }

    private func clientNotifyFrame(clientRandom: Data, publicKey: Data) -> Data {
        var gpk = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &gpk)
        LyraProtoWriter.appendLengthDelimitedField(2, value: publicKey, to: &gpk)
        var suites = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &suites)
        LyraProtoWriter.appendLengthDelimitedField(2, value: clientRandom, to: &suites)
        LyraProtoWriter.appendVarintField(3, value: 0x40, to: &suites)
        LyraProtoWriter.appendVarintField(4, value: 2, to: &suites)
        LyraProtoWriter.appendLengthDelimitedField(5, value: gpk, to: &suites)
        var notify = Data()
        LyraProtoWriter.appendLengthDelimitedField(1, value: suites, to: &notify)
        return clientHandshakeFrame(msgType: 1, oneofField: 2, subFrame: notify)
    }

    private func bytesFrame(msgType: UInt64, oneofField: Int, payload: Data) -> Data {
        var sub = Data()
        LyraProtoWriter.appendLengthDelimitedField(1, value: payload, to: &sub)
        return clientHandshakeFrame(msgType: msgType, oneofField: oneofField, subFrame: sub)
    }

    private func subFields(in fields: [LyraProtoReader.Field], oneof: Int) -> [LyraProtoReader.Field]? {
        guard let body = fields.first(where: { $0.number == oneof })?.lengthDelimitedValue,
              let sub = try? LyraProtoReader.readFields(from: body)
        else { return nil }
        return sub
    }

    func testFullEightFlightPairing() throws {
        let recorder = Recorder()
        let server = makeServer(passkey: passkey, recorder: recorder)
        server.begin()
        XCTAssertEqual(recorder.events, [.displayPasskey(passkey)])

        let clientEphemeral = P256.KeyAgreement.PrivateKey()
        let clientRandom = LyraPasskeyPairServer.randomBytes(32)
        let clientNonce = LyraPasskeyPairServer.randomBytes(32)

        // Flight 1 → 2: ClientNotify → ServerConfirm
        server.handle(handshakeFrame: clientNotifyFrame(
            clientRandom: clientRandom,
            publicKey: clientEphemeral.publicKey.x963Representation
        ))
        XCTAssertEqual(recorder.sent.count, 1)
        let serverConfirm = recorder.sent[0]
        XCTAssertEqual(serverConfirm.messageType, 2)
        XCTAssertEqual(serverConfirm.pairMsgType, 2)
        let confirmFields = try XCTUnwrap(subFields(in: serverConfirm.pairFields, oneof: 3))
        let selectedBytes = try XCTUnwrap(confirmFields.first { $0.number == 1 }?.lengthDelimitedValue)
        let selected = try XCTUnwrap(try? LyraProtoReader.readFields(from: selectedBytes))
        let serverRandom = try XCTUnwrap(selected.first { $0.number == 2 }?.lengthDelimitedValue)
        XCTAssertEqual(serverRandom.count, 32)
        let serverGPK = try XCTUnwrap(selected.first { $0.number == 5 }?.lengthDelimitedValue)
        let serverGPKFields = try XCTUnwrap(try? LyraProtoReader.readFields(from: serverGPK))
        let serverPub = try XCTUnwrap(serverGPKFields.first { $0.number == 2 }?.lengthDelimitedValue)
        let serverH = try XCTUnwrap(confirmFields.first { $0.number == 2 }?.lengthDelimitedValue)
        XCTAssertEqual(serverH.count, 32)

        let serverEphemeralPub = try P256.KeyAgreement.PublicKey(x963Representation: serverPub)
        let z = try clientEphemeral.sharedSecretFromKeyAgreement(with: serverEphemeralPub)
            .withUnsafeBytes { Data($0) }

        // Flight 3 → 4: ClientConfirm → ServerVerify
        let clientH = LyraPasskeyPairServer.confirmHMAC(z: z, passkey: passkey, nonce: clientNonce)
        server.handle(handshakeFrame: bytesFrame(msgType: 3, oneofField: 4, payload: clientH))
        XCTAssertEqual(recorder.sent.count, 2)
        let serverVerify = recorder.sent[1]
        XCTAssertEqual(serverVerify.pairMsgType, 4)
        let verifyFields = try XCTUnwrap(subFields(in: serverVerify.pairFields, oneof: 5))
        let serverNonce = try XCTUnwrap(verifyFields.first { $0.number == 1 }?.lengthDelimitedValue)
        XCTAssertEqual(serverNonce.count, 32)

        // Client now verifies ServerConfirm's H with the revealed server nonce.
        XCTAssertEqual(
            serverH,
            LyraPasskeyPairServer.confirmHMAC(z: z, passkey: passkey, nonce: serverNonce)
        )

        // Flight 5 → 6: ClientVerify → ServerKeyExchange
        server.handle(handshakeFrame: bytesFrame(msgType: 5, oneofField: 6, payload: clientNonce))
        XCTAssertEqual(recorder.sent.count, 3)
        let serverKeyExchange = recorder.sent[2]
        XCTAssertEqual(serverKeyExchange.pairMsgType, 6)
        let kxFields = try XCTUnwrap(subFields(in: serverKeyExchange.pairFields, oneof: 7))
        let kxBlob = try XCTUnwrap(kxFields.first { $0.number == 1 }?.lengthDelimitedValue)

        let sessionKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: z),
            salt: clientNonce,
            info: serverNonce,
            outputByteCount: 32
        )
        let openedPub = try XCTUnwrap(LyraPasskeyPairServer.open(kxBlob, with: sessionKey))
        XCTAssertEqual(openedPub, serverIdentity.publicKey.x963Representation)

        // Flight 7 → 8: ClientKeyExchange → ServerFinished
        let clientKX = try XCTUnwrap(
            LyraPasskeyPairServer.seal(clientIdentity.publicKey.x963Representation, with: sessionKey)
        )
        server.handle(handshakeFrame: bytesFrame(msgType: 7, oneofField: 8, payload: clientKX))
        XCTAssertEqual(recorder.sent.count, 4)
        let serverFinished = recorder.sent[3]
        XCTAssertEqual(serverFinished.pairMsgType, 8)
        let finFields = try XCTUnwrap(subFields(in: serverFinished.pairFields, oneof: 9))
        let finBlob = try XCTUnwrap(finFields.first { $0.number == 1 }?.lengthDelimitedValue)
        let finishedPlain = try XCTUnwrap(LyraPasskeyPairServer.open(finBlob, with: sessionKey))
        XCTAssertEqual(finishedPlain, Data("bind success".utf8))

        XCTAssertEqual(recorder.events.last, .completed(peerIdentityPubKey: clientIdentity.publicKey.x963Representation))
    }

    func testWrongPasskeySendsAlert101() throws {
        let recorder = Recorder()
        let server = makeServer(passkey: passkey, recorder: recorder)
        let clientEphemeral = P256.KeyAgreement.PrivateKey()
        let clientRandom = LyraPasskeyPairServer.randomBytes(32)
        let clientNonce = LyraPasskeyPairServer.randomBytes(32)
        server.handle(handshakeFrame: clientNotifyFrame(
            clientRandom: clientRandom,
            publicKey: clientEphemeral.publicKey.x963Representation
        ))
        let confirmFields = try XCTUnwrap(subFields(in: recorder.sent[0].pairFields, oneof: 3))
        let selectedBytes = try XCTUnwrap(confirmFields.first { $0.number == 1 }?.lengthDelimitedValue)
        let selected = try XCTUnwrap(try? LyraProtoReader.readFields(from: selectedBytes))
        let serverGPK = try XCTUnwrap(selected.first { $0.number == 5 }?.lengthDelimitedValue)
        let serverGPKFields = try XCTUnwrap(try? LyraProtoReader.readFields(from: serverGPK))
        let serverPub = try XCTUnwrap(serverGPKFields.first { $0.number == 2 }?.lengthDelimitedValue)
        let serverEphemeralPub = try P256.KeyAgreement.PublicKey(x963Representation: serverPub)
        let z = try clientEphemeral.sharedSecretFromKeyAgreement(with: serverEphemeralPub)
            .withUnsafeBytes { Data($0) }

        // Client uses a DIFFERENT passkey ("654321") — must be rejected.
        let badH = LyraPasskeyPairServer.confirmHMAC(z: z, passkey: "654321", nonce: clientNonce)
        server.handle(handshakeFrame: bytesFrame(msgType: 3, oneofField: 4, payload: badH))
        server.handle(handshakeFrame: bytesFrame(msgType: 5, oneofField: 6, payload: clientNonce))

        let alert = recorder.sent.last
        XCTAssertEqual(alert?.messageType, 1)
        XCTAssertEqual(alert?.alertCode, LyraPasskeyPairServer.AlertCode.incorrectPinCode)
        XCTAssertEqual(recorder.events.last, .failed(code: 101, message: "incorrect pin code"))
    }

    func testPeerPortResponsePlaintextFraming() throws {
        // Official: 16B ChannelProtocol header + body, header
        // `10 00 03 10 00 <len>` + 10 zero bytes; body = f1(server channel
        // id), f2(client channel id echo), f3(port), f5=1, f7=32B key.
        let key = Data((0..<32).map { UInt8($0) })
        let body = LyraMitrustResponse.peerPortResponseBody(
            clientChannelId: 18, serverChannelId: 6, port: 46186, serverKey: key
        )
        XCTAssertEqual(body.count, 44)
        let command = LyraChannelProtocol.encode(type: .responseOfPeerPort, body: body)
        XCTAssertEqual(command.count, 60)
        XCTAssertEqual(Array(command.prefix(6)), [0x10, 0x00, 0x03, 0x10, 0x00, 0x3C])
        XCTAssertEqual(Array(command[6..<16]), [UInt8](repeating: 0, count: 10))
        let (header, decodedBody) = try LyraChannelProtocol.decode(command)
        XCTAssertEqual(header.type, LyraChannelProtocol.CommandType.responseOfPeerPort.rawValue)
        let fields = try LyraProtoReader.readFields(from: decodedBody)
        XCTAssertEqual(fields.count, 5)
        XCTAssertEqual(fields.first { $0.number == 1 }?.varintValue, 18)
        XCTAssertEqual(fields.first { $0.number == 2 }?.varintValue, 6)
        XCTAssertEqual(fields.first { $0.number == 3 }?.varintValue, 46186)
        XCTAssertEqual(fields.first { $0.number == 5 }?.varintValue, 1)
        XCTAssertEqual(fields.first { $0.number == 7 }?.lengthDelimitedValue, key)

        // Server channel id 0 → f2 elided (official RecentApps response, 58B).
        let zeroBody = LyraMitrustResponse.peerPortResponseBody(
            clientChannelId: 2, serverChannelId: 0, port: 46186, serverKey: key
        )
        XCTAssertEqual(zeroBody.count, 42)
        XCTAssertEqual(LyraChannelProtocol.encode(type: .responseOfPeerPort, body: zeroBody).count, 58)
    }

    func testResponseUserInfoMatchesOfficialSchema() throws {
        let nodeId = (0..<32).map { String(format: "%02X", $0) }.joined(separator: ":")
        XCTAssertEqual(nodeId.count, 95)
        let userInfo = LyraMitrustResponse.serverUserInfo(
            package: "com.xiaomi.trustservice", nodeIdColonHex: nodeId
        )
        let fields = try LyraProtoReader.readFields(from: userInfo)
        XCTAssertEqual(fields.first { $0.number == 1 }?.varintValue, 1)
        XCTAssertEqual(
            fields.first { $0.number == 2 }?.lengthDelimitedValue,
            Data("com.xiaomi.trustservice".utf8)
        )
        XCTAssertEqual(fields.first { $0.number == 3 }?.lengthDelimitedValue, Data(nodeId.utf8))
        // Official f5 system_data from parse4-final.txt (29B).
        let officialSystemData = Data([
            0x01, 0x00, 0xff, 0xff, 0x00, 0x00, 0x00, 0x15, 0x00, 0x03,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0xff, 0x00,
            0x00, 0x06, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x01
        ])
        XCTAssertEqual(fields.first { $0.number == 5 }?.lengthDelimitedValue, officialSystemData)
        XCTAssertEqual(fields.first { $0.number == 6 }?.varintValue, 1)
        XCTAssertEqual(fields.first { $0.number == 8 }?.varintValue, 136)

        let response = LyraMitrustResponse.logiConnResponse(userInfo: userInfo)
        let responseFields = try LyraProtoReader.readFields(from: response)
        XCTAssertEqual(responseFields.first { $0.number == 1 }?.varintValue, 0)
        XCTAssertEqual(responseFields.first { $0.number == 2 }?.lengthDelimitedValue, userInfo)
        XCTAssertEqual(responseFields.first { $0.number == 3 }?.varintValue, 1)
    }

    func testCompareCodeFormat() {
        let code = LyraKeyAgreeCompareCode.generate(
            z: LyraPasskeyPairServer.randomBytes(32),
            clientRandom: LyraPasskeyPairServer.randomBytes(32),
            serverRandom: LyraPasskeyPairServer.randomBytes(32)
        )
        XCTAssertEqual(code.count, 6)
        XCTAssertEqual(code, code.uppercased())
        let z = LyraPasskeyPairServer.randomBytes(32)
        let cr = LyraPasskeyPairServer.randomBytes(32)
        let sr = LyraPasskeyPairServer.randomBytes(32)
        XCTAssertEqual(
            LyraKeyAgreeCompareCode.generate(z: z, clientRandom: cr, serverRandom: sr),
            LyraKeyAgreeCompareCode.generate(z: z, clientRandom: cr, serverRandom: sr)
        )
    }
}
