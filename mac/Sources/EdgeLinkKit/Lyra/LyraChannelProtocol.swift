import CryptoKit
import Foundation

public enum LyraChannelProtocol {
    public static let headerLength = 16

    public enum CommandType: UInt8, Sendable {
        case externalData = 1
        case requestOfPeerPort = 2
        case responseOfPeerPort = 3
        case requestOfCreateProxyChannel = 5
        case responseOfCreateProxyChannel = 6
    }

    public struct Header: Equatable, Sendable {
        public var type: UInt8
        public var argument: UInt16

        public init(type: UInt8, argument: UInt16 = 0) {
            self.type = type
            self.argument = argument
        }
    }

    public enum ProtocolError: Error, Equatable, Sendable {
        case truncated
        case badHeaderLength
    }

    public static func encode(type: CommandType, argument: UInt16 = 0, body: Data) -> Data {
        var data = Data(capacity: headerLength + body.count)
        let totalLength = headerLength + body.count
        data.append(contentsOf: [0x10, 0x00, type.rawValue, 0x10])
        data.append(UInt8((totalLength >> 8) & 0xFF))
        data.append(UInt8(totalLength & 0xFF))
        if argument != 0 {
            data.append(0x12)
            data.append(UInt8((argument >> 8) & 0xFF))
            data.append(UInt8(argument & 0xFF))
        } else {
            data.append(contentsOf: [0x00, 0x00, 0x00])
        }
        data.append(contentsOf: [0, 0, 0, 0, 0, 0, 0])
        data.append(body)
        return data
    }

    public static func decode(_ data: Data) throws -> (header: Header, body: Data) {
        let bytes = Array(data)
        guard bytes.count >= headerLength else {
            throw ProtocolError.truncated
        }
        guard bytes[0] == 0x10, bytes[1] == 0x00 else {
            throw ProtocolError.badHeaderLength
        }
        let totalLength = (Int(bytes[4]) << 8) | Int(bytes[5])
        guard totalLength >= headerLength, bytes.count >= totalLength else {
            throw ProtocolError.truncated
        }
        let argument: UInt16 = bytes[6] != 0 ? (UInt16(bytes[7]) << 8) | UInt16(bytes[8]) : 0
        return (Header(type: bytes[2], argument: argument), Data(bytes[headerLength..<totalLength]))
    }

    public struct PeerPortRequest: Equatable, Sendable {
        public var channelId: UInt32
        public var field2: UInt32
        public var field3: UInt32
        public var transKey: Data
        public var extra: Data

        public init(channelId: UInt32, field2: UInt32 = 0, field3: UInt32 = 0, transKey: Data = Data(), extra: Data = Data()) {
            self.channelId = channelId
            self.field2 = field2
            self.field3 = field3
            self.transKey = transKey
            self.extra = extra
        }

        public init?(parsing data: Data) {
            guard let fields = try? LyraProtoReader.readFields(from: data) else {
                return nil
            }
            var channelId: UInt32 = 0
            var field2: UInt32 = 0
            var field3: UInt32 = 0
            var transKey = Data()
            var extra = Data()
            for field in fields {
                switch (field.number, field.wireType) {
                case (1, 0): channelId = UInt32(field.varintValue ?? 0)
                case (2, 0): field2 = UInt32(field.varintValue ?? 0)
                case (3, 0): field3 = UInt32(field.varintValue ?? 0)
                case (4, 2): transKey = field.lengthDelimitedValue ?? Data()
                case (5, 2): extra = field.lengthDelimitedValue ?? Data()
                default: continue
                }
            }
            self.init(channelId: channelId, field2: field2, field3: field3, transKey: transKey, extra: extra)
        }
    }

    public static func encodePeerPortResponse(
        peerChannelId: UInt32,
        serverChannelId: UInt32,
        port: UInt32,
        key: Data
    ) -> Data {
        var body = Data()
        LyraProtoWriter.appendVarintField(1, value: UInt64(peerChannelId), to: &body)
        LyraProtoWriter.appendVarintField(2, value: UInt64(serverChannelId), to: &body)
        LyraProtoWriter.appendVarintField(3, value: UInt64(port), to: &body)
        LyraProtoWriter.appendVarintField(5, value: 1, to: &body)
        if !key.isEmpty {
            LyraProtoWriter.appendLengthDelimitedField(7, value: key, to: &body)
        }
        return encode(type: .responseOfPeerPort, body: body)
    }
}

public enum LyraSocketPacket {
    public static let overhead = 4 + 12 + 16

    public enum PacketError: Error, Equatable, Sendable {
        case truncated
        case badMagic
        case decryptionFailed
    }

    public static func encode(plaintext: Data, key: SymmetricKey) throws -> Data {
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
        let totalLength = overhead + plaintext.count
        var data = Data(capacity: totalLength)
        data.append(contentsOf: [0x81, 0x04])
        data.append(UInt8((totalLength >> 8) & 0xFF))
        data.append(UInt8(totalLength & 0xFF))
        data.append(contentsOf: nonce.withUnsafeBytes { Data($0) })
        data.append(sealed.ciphertext)
        data.append(sealed.tag)
        return data
    }

    public static func frameLength(prefix: Data) -> Int? {
        let bytes = Array(prefix)
        guard bytes.count >= 4 else { return nil }
        guard bytes[0] == 0x81, bytes[1] == 0x04 else { return -1 }
        return (Int(bytes[2]) << 8) | Int(bytes[3])
    }

    public static func decode(_ data: Data, key: SymmetricKey) throws -> (plaintext: Data, consumed: Int) {
        let bytes = Array(data)
        guard let totalLength = frameLength(prefix: data), totalLength > 0 else {
            throw PacketError.badMagic
        }
        guard bytes.count >= totalLength, totalLength >= overhead else {
            throw PacketError.truncated
        }
        let nonce = Data(bytes[4..<16])
        let ciphertext = Data(bytes[16..<(totalLength - 16)])
        let tag = Data(bytes[(totalLength - 16)..<totalLength])
        let sealedBox = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: nonce),
            ciphertext: ciphertext,
            tag: tag
        )
        guard let plaintext = try? AES.GCM.open(sealedBox, using: key) else {
            throw PacketError.decryptionFailed
        }
        return (plaintext, totalLength)
    }
}

public enum LyraChannelFragment {
    public static let flagsLast: UInt16 = 0xB882
    public static let flagsMore: UInt16 = 0x9882
    public static let maxPayload = 1200

    public enum FragmentError: Error, Equatable, Sendable {
        case truncated
    }

    public static func encode(message: Data, key: SymmetricKey) throws -> [Data] {
        let chunks: [Data] = stride(from: 0, to: max(message.count, 1), by: maxPayload).map {
            let end = min($0 + maxPayload, message.count)
            return $0 < end ? Data(message[$0..<end]) : Data()
        }
        let total = chunks.count
        var frames: [Data] = []
        var offset = 0
        for (index, chunk) in chunks.enumerated() {
            let nonce = AES.GCM.Nonce()
            let sealed = try AES.GCM.seal(chunk, using: key, nonce: nonce)
            let isLast = index == total - 1
            let fragmentLength = 8 + 12 + chunk.count + 16
            var frame = Data(capacity: fragmentLength)
            let flags = isLast ? flagsLast : flagsMore
            frame.append(UInt8(flags & 0xFF))
            frame.append(UInt8((flags >> 8) & 0xFF))
            let payloadLength = fragmentLength - 8
            frame.append(UInt8((payloadLength >> 8) & 0xFF))
            frame.append(UInt8(payloadLength & 0xFF))
            frame.append(UInt8((offset >> 8) & 0xFF))
            frame.append(UInt8(offset & 0xFF))
            frame.append(UInt8((total >> 8) & 0xFF))
            frame.append(UInt8(total & 0xFF))
            frame.append(contentsOf: nonce.withUnsafeBytes { Data($0) })
            frame.append(sealed.ciphertext)
            frame.append(sealed.tag)
            frames.append(frame)
            offset += chunk.count
        }
        return frames
    }

    public static func decode(fragment data: Data, key: SymmetricKey) throws -> (chunk: Data, offset: Int, total: Int, isLast: Bool) {
        let bytes = Array(data)
        guard bytes.count >= 8 + 12 + 16 else {
            throw FragmentError.truncated
        }
        let flags = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        let payloadLength = (Int(bytes[2]) << 8) | Int(bytes[3])
        let offset = (Int(bytes[4]) << 8) | Int(bytes[5])
        let total = (Int(bytes[6]) << 8) | Int(bytes[7])
        guard bytes.count >= 8 + payloadLength, payloadLength >= 28 else {
            throw FragmentError.truncated
        }
        let nonce = Data(bytes[8..<20])
        let ciphertext = Data(bytes[20..<(8 + payloadLength - 16)])
        let tag = Data(bytes[(8 + payloadLength - 16)..<(8 + payloadLength)])
        let sealedBox = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: nonce),
            ciphertext: ciphertext,
            tag: tag
        )
        let chunk = try AES.GCM.open(sealedBox, using: key)
        return (chunk, offset, total, flags == flagsLast)
    }
}
