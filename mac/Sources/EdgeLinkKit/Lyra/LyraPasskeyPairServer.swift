import CryptoKit
import Foundation

// Server side of the lyra PasskeyPairHandshake (auth_type=1, HandshakeFrame
// family=1 / messageType=2, oneof field 4 = PasskeyEntryPairFrame).
// 8 flights: ClientNotify → ServerConfirm → ClientConfirm → ServerVerify →
// ClientVerify → ServerKeyExchange → ClientKeyExchange → ServerFinished.
// Crypto: Z = ECDH P-256 ephemeral; N = 32B nonce;
// H = HMAC-SHA256(key=Z, passkey‖Z‖N_own); K_sess = HKDF(Z, salt=N_client,
// info=N_server); KeyExchange/Finished = AES-256-GCM(K_sess, payload) as
// nonce12‖ct‖tag16. On success the phone writes a type-2 (365-day, no-uid)
// identity cred for our device id with `identityPublicKey`.
public final class LyraPasskeyPairServer {
    public enum Event: Equatable {
        case displayPasskey(String)
        case completed(peerIdentityPubKey: Data)
        case failed(code: UInt64, message: String)
    }

    public enum AlertCode {
        public static let incorrectPinCode: UInt64 = 101
        public static let notSameAccount: UInt64 = 201
        public static let notPaired: UInt64 = 301
    }

    public var onEvent: ((Event) -> Void)?
    public var onSend: ((Data) -> Void)?

    private enum State {
        case expectClientNotify
        case expectClientConfirm
        case expectClientVerify
        case expectClientKeyExchange
        case done
        case failed
    }

    public let passkey: String
    private let identityPrivateKey: P256.Signing.PrivateKey
    private var state: State = .expectClientNotify

    private var family: UInt64 = 1
    private var ephemeralPrivateKey: P256.KeyAgreement.PrivateKey?
    private var sharedZ = Data()
    private var clientRandom = Data()
    private var serverRandom = Data()
    private var serverNonce = Data()
    private var clientConfirmH = Data()
    private var sessionKey: SymmetricKey?
    private var offeredCipher3: UInt64 = 0
    private var offeredCipher4: UInt64 = 0

    public init(passkey: String? = nil, identityPrivateKey: P256.Signing.PrivateKey) {
        if let passkey {
            self.passkey = passkey
        } else {
            self.passkey = String(format: "%06d", Int.random(in: 0...999999))
        }
        self.identityPrivateKey = identityPrivateKey
    }

    public func begin() {
        onEvent?(.displayPasskey(passkey))
    }

    public func handle(handshakeFrame: Data) {
        guard let fields = try? LyraProtoReader.readFields(from: handshakeFrame),
              let pairFrame = Self.lengthDelimited(4, in: fields),
              let pairFields = try? LyraProtoReader.readFields(from: pairFrame),
              let msgType = Self.varint(1, in: pairFields)
        else {
            fail(code: AlertCode.incorrectPinCode, message: "bad passkey pair frame")
            return
        }
        if let incomingFamily = Self.varint(1, in: fields) {
            family = incomingFamily
        }
        switch (state, msgType) {
        case (.expectClientNotify, 1):
            handleClientNotify(pairFields)
        case (.expectClientConfirm, 3):
            handleClientConfirm(pairFields)
        case (.expectClientVerify, 5):
            handleClientVerify(pairFields)
        case (.expectClientKeyExchange, 7):
            handleClientKeyExchange(pairFields)
        default:
            DiagnosticsLogStub.warn("lyra.passkeypair unexpected msgType=\(msgType)")
        }
    }

    private func handleClientNotify(_ pairFields: [LyraProtoReader.Field]) {
        guard let clientNotify = Self.lengthDelimited(2, in: pairFields),
              let notifyFields = try? LyraProtoReader.readFields(from: clientNotify),
              let suites = Self.lengthDelimited(1, in: notifyFields),
              let suiteFields = try? LyraProtoReader.readFields(from: suites),
              let clientRandom = Self.lengthDelimited(2, in: suiteFields),
              clientRandom.count == 32,
              let publicKeyMessage = Self.lengthDelimited(5, in: suiteFields),
              let publicKeyFields = try? LyraProtoReader.readFields(from: publicKeyMessage),
              let publicKey = Self.lengthDelimited(2, in: publicKeyFields),
              publicKey.count == 65, publicKey.first == 0x04
        else {
            fail(code: AlertCode.incorrectPinCode, message: "bad client notify")
            return
        }
        offeredCipher3 = Self.varint(3, in: suiteFields) ?? 0
        offeredCipher4 = Self.varint(4, in: suiteFields) ?? 0
        let privateKey = P256.KeyAgreement.PrivateKey()
        let z: Data
        do {
            let peerKey = try P256.KeyAgreement.PublicKey(x963Representation: publicKey)
            z = try privateKey.sharedSecretFromKeyAgreement(with: peerKey).withUnsafeBytes { Data($0) }
        } catch {
            fail(code: AlertCode.incorrectPinCode, message: "ecdh failed")
            return
        }
        ephemeralPrivateKey = privateKey
        sharedZ = z
        self.clientRandom = clientRandom
        serverRandom = Self.randomBytes(32)
        serverNonce = Self.randomBytes(32)
        let serverH = Self.confirmHMAC(z: z, passkey: passkey, nonce: serverNonce)

        var outPublicKey = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &outPublicKey)
        LyraProtoWriter.appendLengthDelimitedField(2, value: privateKey.publicKey.x963Representation, to: &outPublicKey)

        var selected = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &selected)
        LyraProtoWriter.appendLengthDelimitedField(2, value: serverRandom, to: &selected)
        LyraProtoWriter.appendVarintField(3, value: offeredCipher3, to: &selected)
        LyraProtoWriter.appendVarintField(4, value: offeredCipher4, to: &selected)
        LyraProtoWriter.appendLengthDelimitedField(5, value: outPublicKey, to: &selected)

        var serverConfirm = Data()
        LyraProtoWriter.appendLengthDelimitedField(1, value: selected, to: &serverConfirm)
        LyraProtoWriter.appendLengthDelimitedField(2, value: serverH, to: &serverConfirm)

        sendPairFrame(msgType: 2, oneofField: 3, subFrame: serverConfirm)
        state = .expectClientConfirm
    }

    private func handleClientConfirm(_ pairFields: [LyraProtoReader.Field]) {
        guard let clientConfirm = Self.lengthDelimited(4, in: pairFields),
              let confirmFields = try? LyraProtoReader.readFields(from: clientConfirm),
              let h = Self.lengthDelimited(1, in: confirmFields),
              h.count == 32
        else {
            fail(code: AlertCode.incorrectPinCode, message: "bad client confirm")
            return
        }
        clientConfirmH = h
        var serverVerify = Data()
        LyraProtoWriter.appendLengthDelimitedField(1, value: serverNonce, to: &serverVerify)
        sendPairFrame(msgType: 4, oneofField: 5, subFrame: serverVerify)
        state = .expectClientVerify
    }

    private func handleClientVerify(_ pairFields: [LyraProtoReader.Field]) {
        guard let clientVerify = Self.lengthDelimited(6, in: pairFields),
              let verifyFields = try? LyraProtoReader.readFields(from: clientVerify),
              let clientNonce = Self.lengthDelimited(1, in: verifyFields),
              clientNonce.count == 32,
              !sharedZ.isEmpty
        else {
            fail(code: AlertCode.incorrectPinCode, message: "bad client verify")
            return
        }
        let expectedH = Self.confirmHMAC(z: sharedZ, passkey: passkey, nonce: clientNonce)
        guard expectedH == clientConfirmH else {
            sendAlert(code: AlertCode.incorrectPinCode, message: "incorrect pin code")
            fail(code: AlertCode.incorrectPinCode, message: "incorrect pin code")
            return
        }
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sharedZ),
            salt: clientNonce,
            info: serverNonce,
            outputByteCount: 32
        )
        sessionKey = key
        guard let blob = Self.seal(identityPrivateKey.publicKey.x963Representation, with: key) else {
            fail(code: AlertCode.incorrectPinCode, message: "key exchange seal failed")
            return
        }
        var serverKeyExchange = Data()
        LyraProtoWriter.appendLengthDelimitedField(1, value: blob, to: &serverKeyExchange)
        sendPairFrame(msgType: 6, oneofField: 7, subFrame: serverKeyExchange)
        state = .expectClientKeyExchange
    }

    private func handleClientKeyExchange(_ pairFields: [LyraProtoReader.Field]) {
        guard let clientKeyExchange = Self.lengthDelimited(8, in: pairFields),
              let exchangeFields = try? LyraProtoReader.readFields(from: clientKeyExchange),
              let blob = Self.lengthDelimited(1, in: exchangeFields),
              let sessionKey,
              let peerPub = Self.open(blob, with: sessionKey),
              peerPub.count == 65, peerPub.first == 0x04,
              let finished = Self.seal(Data("bind success".utf8), with: sessionKey)
        else {
            fail(code: AlertCode.incorrectPinCode, message: "bad client key exchange")
            return
        }
        var serverFinished = Data()
        LyraProtoWriter.appendLengthDelimitedField(1, value: finished, to: &serverFinished)
        sendPairFrame(msgType: 8, oneofField: 9, subFrame: serverFinished)
        state = .done
        onEvent?(.completed(peerIdentityPubKey: peerPub))
    }

    private func sendPairFrame(msgType: UInt64, oneofField: Int, subFrame: Data) {
        var pairFrame = Data()
        LyraProtoWriter.appendVarintField(1, value: msgType, to: &pairFrame)
        LyraProtoWriter.appendLengthDelimitedField(oneofField, value: subFrame, to: &pairFrame)
        var handshake = Data()
        LyraProtoWriter.appendVarintField(1, value: family, to: &handshake)
        LyraProtoWriter.appendVarintField(2, value: 2, to: &handshake)
        LyraProtoWriter.appendLengthDelimitedField(4, value: pairFrame, to: &handshake)
        onSend?(handshake)
    }

    private func sendAlert(code: UInt64, message: String) {
        var alert = Data()
        LyraProtoWriter.appendVarintField(1, value: code, to: &alert)
        LyraProtoWriter.appendLengthDelimitedField(2, value: Data(message.utf8), to: &alert)
        var handshake = Data()
        LyraProtoWriter.appendVarintField(1, value: family, to: &handshake)
        LyraProtoWriter.appendVarintField(2, value: 1, to: &handshake)
        LyraProtoWriter.appendLengthDelimitedField(3, value: alert, to: &handshake)
        onSend?(handshake)
    }

    private func fail(code: UInt64, message: String) {
        state = .failed
        onEvent?(.failed(code: code, message: message))
    }

    static func confirmHMAC(z: Data, passkey: String, nonce: Data) -> Data {
        var message = Data(passkey.utf8)
        message.append(z)
        message.append(nonce)
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: z))
        return Data(mac)
    }

    static func seal(_ plaintext: Data, with key: SymmetricKey) -> Data? {
        guard let sealed = try? AES.GCM.seal(plaintext, using: key) else { return nil }
        var blob = Data()
        blob.append(contentsOf: sealed.nonce.withUnsafeBytes { Data($0) })
        blob.append(sealed.ciphertext)
        blob.append(sealed.tag)
        return blob
    }

    static func open(_ blob: Data, with key: SymmetricKey) -> Data? {
        guard blob.count > 28,
              let nonce = try? AES.GCM.Nonce(data: blob.prefix(12)),
              let box = try? AES.GCM.SealedBox(
                  nonce: nonce,
                  ciphertext: blob.dropFirst(12).dropLast(16),
                  tag: blob.suffix(16)
              )
        else { return nil }
        return try? AES.GCM.open(box, using: key)
    }

    static func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { buffer in
            if let baseAddress = buffer.baseAddress {
                arc4random_buf(baseAddress, count)
            }
        }
        return data
    }

    private static func varint(_ number: Int, in fields: [LyraProtoReader.Field]) -> UInt64? {
        fields.first { $0.number == number && $0.wireType == 0 }?.varintValue
    }

    private static func lengthDelimited(_ number: Int, in fields: [LyraProtoReader.Field]) -> Data? {
        fields.first { $0.number == number && $0.wireType == 2 }?.lengthDelimitedValue
    }
}

public enum LyraKeyAgreeCompareCode {
    // KeyAgreeHandshake::GenerateCompareNum: HKDF-SHA256(ikm=Z, salt=below,
    // info=client_random‖server_random) → base64 → first 6 chars uppercased.
    private static let salt = Data([
        0x4e, 0x23, 0xed, 0x67, 0x88, 0x13, 0xea, 0x9f,
        0x6e, 0x28, 0xaa, 0xb1, 0x6c, 0x90, 0x0b, 0xc0,
        0x6e, 0xd4, 0x10, 0x27, 0x04, 0x8c, 0xce, 0x0b,
        0x19, 0x7a, 0xf1, 0xe9, 0xdd, 0x7e, 0xec, 0x9a
    ])

    public static func generate(z: Data, clientRandom: Data, serverRandom: Data) -> String {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: z),
            salt: salt,
            info: clientRandom + serverRandom,
            outputByteCount: 32
        )
        let base64 = key.withUnsafeBytes { Data($0) }.base64EncodedString()
        return String(base64.prefix(6)).uppercased()
    }
}

// Thin shim so EdgeLinkKit code can log without depending on the App layer.
enum DiagnosticsLogStub {
    static func warn(_ message: String) {
        NSLog("%@", message)
    }
}
