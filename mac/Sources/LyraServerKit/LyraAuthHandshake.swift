import CryptoKit
import EdgeLinkKit
import Foundation

// The 4-step AuthHandshake, as reversed from the phone (auth_type=4,
// GetType=4). Both roles are implemented as pure state machines so the mock
// server can be the phone (server) when the Mac dials, and the Mac (client)
// when a phone role dials out.
//
//   step 1 client_notify  {f1:cipherSuite{random, ephPub}}
//   step 2 server_notify  {f1:selected{random, ephPub}, f2:encSig}   (server)
//   step 3 client_finished{f1:encSig}                                (client)
//   step 4 server_finished{f1:{f1:encProof}}                         (server)
//
// encSig = AES-GCM(Z, identity-signature over eph-pub pair);
// proof  = AES-GCM(sessionKey, Z || serverEphPub);
// sessionKey = HKDF-SHA256(Z, salt: Self.sessionSalt, info: cRandom||sRandom)
// ticket     = HKDF-SHA256(Z, salt: Self.ticketSalt,  info: cRandom||sRandom)
public enum LyraAuthHandshake {
    public static let sessionSalt = Data([
        0x5e, 0xd5, 0xa3, 0xf8, 0x36, 0xf6, 0xb5, 0x4f,
        0x7b, 0x1e, 0xfa, 0xd0, 0x27, 0x14, 0xd5, 0x17,
        0x7b, 0x8a, 0x1f, 0x0f, 0x19, 0xe3, 0x69, 0xcc,
        0x0b, 0xe8, 0xd9, 0x8b, 0xa6, 0x29, 0x73, 0x17
    ])
    public static let ticketSalt = Data([
        0x0a, 0x5b, 0x87, 0x72, 0x08, 0xd4, 0xa1, 0xcf,
        0x76, 0xd3, 0x08, 0x09, 0x51, 0xdd, 0x1b, 0xb8,
        0x6b, 0x4e, 0x9e, 0xe2, 0x57, 0x92, 0x4b, 0xaf,
        0xdb, 0xa6, 0x2c, 0x5a, 0x67, 0x06, 0xe6, 0x18
    ])

    public struct Result: Sendable {
        public var sessionKey: SymmetricKey
        public var ticket: SymmetricKey
    }

    static func lengthDelimited(_ fieldNumber: Int, in data: Data) -> Data? {
        guard let fields = try? LyraProtoReader.readFields(from: data) else { return nil }
        return fields.first { $0.number == fieldNumber && $0.wireType == 2 }?.lengthDelimitedValue
    }

    static func varint(_ fieldNumber: Int, in data: Data) -> UInt64? {
        guard let fields = try? LyraProtoReader.readFields(from: data) else { return nil }
        return fields.first { $0.number == fieldNumber && $0.wireType == 0 }?.varintValue
    }

    // The phone wraps client auth frames in handshake f7 on some dials
    // (relayCall) and f6 on others (sync-task quick-conn, live 2026-08-05).
    public static func authFrame(fromHandshake handshake: Data) -> Data? {
        lengthDelimited(7, in: handshake) ?? lengthDelimited(6, in: handshake)
    }

    static func gcmSeal(_ plaintext: Data, using key: SymmetricKey) -> Data? {
        guard let sealed = try? AES.GCM.seal(plaintext, using: key) else { return nil }
        var out = Data()
        out.append(contentsOf: sealed.nonce.withUnsafeBytes { Data($0) })
        out.append(sealed.ciphertext)
        out.append(sealed.tag)
        return out
    }

    static func gcmOpen(_ combined: Data, using key: SymmetricKey) -> Data? {
        guard combined.count > 28 else { return nil }
        guard let box = try? AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: Data(combined.prefix(12))),
            ciphertext: Data(combined.dropFirst(12).dropLast(16)),
            tag: Data(combined.suffix(16))
        ) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }

    // MARK: - Server role (we are the phone; the peer dials us)

    public final class Server {
        private let identity: LyraPhoneIdentity
        private var ephPriv: P256.KeyAgreement.PrivateKey?
        private var clientEphPub = Data()
        private var sharedZ = Data()
        private var clientRandom = Data()
        private var serverRandom = Data()

        public init(identity: LyraPhoneIdentity) {
            self.identity = identity
        }

        // step 1 client_notify (the auth frame itself, f7 of the handshake
        // wrapper) → step 2 server_notify auth frame, or nil on parse failure.
        public func handleClientNotify(authFrame: Data) -> Data? {
            guard let clientNotify = LyraAuthHandshake.lengthDelimited(2, in: authFrame),
                  let cipherSuite = LyraAuthHandshake.lengthDelimited(1, in: clientNotify),
                  let clientRandom = LyraAuthHandshake.lengthDelimited(2, in: cipherSuite),
                  clientRandom.count == 32,
                  let publicKeyMessage = LyraAuthHandshake.lengthDelimited(5, in: cipherSuite),
                  let clientPub = LyraAuthHandshake.lengthDelimited(2, in: publicKeyMessage),
                  clientPub.count == 65, clientPub.first == 0x04,
                  let identityKey = identity.accountPrivateKey ?? identity.identityPrivateKey
            else { return nil }
            let privateKey = P256.KeyAgreement.PrivateKey()
            var serverRandom = Data(count: 32)
            serverRandom.withUnsafeMutableBytes { buffer in
                if let base = buffer.baseAddress { arc4random_buf(base, 32) }
            }
            let serverPub = privateKey.publicKey.x963Representation
            guard let peerKey = try? P256.KeyAgreement.PublicKey(x963Representation: clientPub),
                  let secret = try? privateKey.sharedSecretFromKeyAgreement(with: peerKey)
                    .withUnsafeBytes({ Data($0) }),
                  let signature = try? identityKey.signature(for: SHA256.hash(data: serverPub + clientPub)),
                  let encSig = LyraAuthHandshake.gcmSeal(
                      signature.derRepresentation, using: SymmetricKey(data: secret)
                  )
            else { return nil }
            ephPriv = privateKey
            clientEphPub = clientPub
            sharedZ = secret
            self.clientRandom = clientRandom
            self.serverRandom = serverRandom

            var outGpk = Data()
            LyraProtoWriter.appendVarintField(1, value: 1, to: &outGpk)
            LyraProtoWriter.appendLengthDelimitedField(2, value: serverPub, to: &outGpk)
            let offeredP3 = LyraAuthHandshake.varint(3, in: cipherSuite) ?? 0x40
            let offeredP4 = LyraAuthHandshake.varint(4, in: cipherSuite) ?? 2
            var selected = Data()
            LyraProtoWriter.appendVarintField(1, value: 1, to: &selected)
            LyraProtoWriter.appendLengthDelimitedField(2, value: serverRandom, to: &selected)
            LyraProtoWriter.appendVarintField(3, value: offeredP3, to: &selected)
            LyraProtoWriter.appendVarintField(4, value: offeredP4, to: &selected)
            LyraProtoWriter.appendLengthDelimitedField(5, value: outGpk, to: &selected)
            var truth = Data()
            LyraProtoWriter.appendVarintField(1, value: 1, to: &truth)
            var serverNotify = Data()
            LyraProtoWriter.appendLengthDelimitedField(1, value: selected, to: &serverNotify)
            LyraProtoWriter.appendLengthDelimitedField(2, value: encSig, to: &serverNotify)
            LyraProtoWriter.appendLengthDelimitedField(4, value: truth, to: &serverNotify)
            LyraProtoWriter.appendLengthDelimitedField(5, value: truth, to: &serverNotify)
            var outAuthFrame = Data()
            LyraProtoWriter.appendVarintField(1, value: 2, to: &outAuthFrame)
            LyraProtoWriter.appendLengthDelimitedField(3, value: serverNotify, to: &outAuthFrame)
            return outAuthFrame
        }

        // step 3 client_finished → (step 4 server_finished auth frame, keys).
        // The peer's identity public key must already be known (paired) so its
        // signature over (clientPub || serverPub) verifies.
        public func handleClientFinished(
            authFrame: Data, peerIdentityPubKey: Data
        ) -> (serverFinished: Data, result: Result)? {
            guard let clientFinished = LyraAuthHandshake.lengthDelimited(4, in: authFrame),
                  let encSigC = LyraAuthHandshake.lengthDelimited(1, in: clientFinished),
                  !encSigC.isEmpty,
                  let serverEphPub = ephPriv?.publicKey.x963Representation,
                  !sharedZ.isEmpty, !clientEphPub.isEmpty,
                  let sigC = LyraAuthHandshake.gcmOpen(encSigC, using: SymmetricKey(data: sharedZ)),
                  let peerIdentity = try? P256.Signing.PublicKey(x963Representation: peerIdentityPubKey),
                  let signature = try? P256.Signing.ECDSASignature(derRepresentation: sigC),
                  peerIdentity.isValidSignature(
                      signature, for: SHA256.hash(data: clientEphPub + serverEphPub)
                  )
            else { return nil }
            let zKey = SymmetricKey(data: sharedZ)
            let sessionKey = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: zKey,
                salt: LyraAuthHandshake.sessionSalt,
                info: clientRandom + serverRandom,
                outputByteCount: 32
            )
            let ticket = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: zKey,
                salt: LyraAuthHandshake.ticketSalt,
                info: clientRandom + serverRandom,
                outputByteCount: 32
            )
            guard let proof = LyraAuthHandshake.gcmSeal(sharedZ + serverEphPub, using: sessionKey)
            else { return nil }
            var serverFinished = Data()
            LyraProtoWriter.appendLengthDelimitedField(1, value: proof, to: &serverFinished)
            var outAuthFrame = Data()
            LyraProtoWriter.appendVarintField(1, value: 4, to: &outAuthFrame)
            LyraProtoWriter.appendLengthDelimitedField(5, value: serverFinished, to: &outAuthFrame)
            return (outAuthFrame, Result(sessionKey: sessionKey, ticket: ticket))
        }
    }

    // MARK: - Client role (we dial out, e.g. the phone's sync task dialing
    // the Mac's quick-conn server)

    public final class Client {
        private let identity: LyraPhoneIdentity
        private var ephPriv = P256.KeyAgreement.PrivateKey()
        private var clientRandom = Data()
        private var serverRandom = Data()
        private var sharedZ = Data()
        private var serverEphPub = Data()
        private var pendingSessionKey: SymmetricKey?

        public init(identity: LyraPhoneIdentity) {
            self.identity = identity
        }

        // Builds the step-1 client_notify auth frame (official mesh-announce
        // shape: f2=4, f3/f4 = 0801).
        public func makeClientNotify() -> Data {
            let ephemeral = P256.KeyAgreement.PrivateKey()
            var clientRandom = Data(count: 32)
            clientRandom.withUnsafeMutableBytes { buffer in
                if let base = buffer.baseAddress { arc4random_buf(base, 32) }
            }
            ephPriv = ephemeral
            self.clientRandom = clientRandom
            var publicKeyMessage = Data()
            LyraProtoWriter.appendVarintField(1, value: 1, to: &publicKeyMessage)
            LyraProtoWriter.appendLengthDelimitedField(
                2, value: ephemeral.publicKey.x963Representation, to: &publicKeyMessage
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
            return authFrame
        }

        // step 2 server_notify → step 3 client_finished auth frame. The
        // session key is derived here (same construction the Mac uses); the
        // server proof is checked in handleServerFinished.
        public func handleServerNotify(authFrame: Data) -> Data? {
            guard let serverNotify = LyraAuthHandshake.lengthDelimited(3, in: authFrame),
                  let selected = LyraAuthHandshake.lengthDelimited(1, in: serverNotify),
                  let serverRandom = LyraAuthHandshake.lengthDelimited(2, in: selected),
                  serverRandom.count == 32,
                  let publicKeyMessage = LyraAuthHandshake.lengthDelimited(5, in: selected),
                  let serverPub = LyraAuthHandshake.lengthDelimited(2, in: publicKeyMessage),
                  serverPub.count == 65, serverPub.first == 0x04,
                  let peerKey = try? P256.KeyAgreement.PublicKey(x963Representation: serverPub),
                  let secret = try? ephPriv.sharedSecretFromKeyAgreement(with: peerKey)
                    .withUnsafeBytes({ Data($0) }),
                  let identityKey = identity.accountPrivateKey ?? identity.identityPrivateKey,
                  let signature = try? identityKey.signature(
                      for: SHA256.hash(data: ephPriv.publicKey.x963Representation + serverPub)
                  ),
                  let encSig = LyraAuthHandshake.gcmSeal(
                      signature.derRepresentation, using: SymmetricKey(data: secret)
                  )
            else { return nil }
            sharedZ = secret
            serverEphPub = serverPub
            self.serverRandom = serverRandom
            pendingSessionKey = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: SymmetricKey(data: secret),
                salt: LyraAuthHandshake.sessionSalt,
                info: clientRandom + serverRandom,
                outputByteCount: 32
            )
            var clientFinished = Data()
            LyraProtoWriter.appendLengthDelimitedField(1, value: encSig, to: &clientFinished)
            var outAuthFrame = Data()
            LyraProtoWriter.appendVarintField(1, value: 3, to: &outAuthFrame)
            LyraProtoWriter.appendLengthDelimitedField(4, value: clientFinished, to: &outAuthFrame)
            return outAuthFrame
        }

        // step 4 server_finished → final keys when the proof checks out.
        public func handleServerFinished(authFrame: Data) -> Result? {
            guard let serverFinished = LyraAuthHandshake.lengthDelimited(5, in: authFrame),
                  let blob = LyraAuthHandshake.lengthDelimited(1, in: serverFinished),
                  let sessionKey = pendingSessionKey,
                  let proof = LyraAuthHandshake.gcmOpen(blob, using: sessionKey),
                  proof == sharedZ + serverEphPub
            else { return nil }
            let ticket = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: SymmetricKey(data: sharedZ),
                salt: LyraAuthHandshake.ticketSalt,
                info: clientRandom + serverRandom,
                outputByteCount: 32
            )
            return Result(sessionKey: sessionKey, ticket: ticket)
        }
    }
}
