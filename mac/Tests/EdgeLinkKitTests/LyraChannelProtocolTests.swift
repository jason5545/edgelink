import CryptoKit
@testable import EdgeLinkKit
import XCTest

final class LyraChannelProtocolTests: XCTestCase {
    func testPeerPortResponseMatchesOfficial60ByteLayout() {
        let key = Data(repeating: 0xAA, count: 32)
        let frame = LyraChannelProtocol.encodePeerPortResponse(
            peerChannelId: 28,
            serverChannelId: 5,
            port: 64608,
            key: key
        )
        XCTAssertEqual(frame.count, 60)
        var expected = Data([0x10, 0x00, 0x03, 0x10, 0x00, 0x3C, 0x00, 0x00, 0x00])
        expected.append(contentsOf: [0, 0, 0, 0, 0, 0, 0])
        var body = Data()
        LyraProtoWriter.appendVarintField(1, value: 28, to: &body)
        LyraProtoWriter.appendVarintField(2, value: 5, to: &body)
        LyraProtoWriter.appendVarintField(3, value: 64608, to: &body)
        LyraProtoWriter.appendVarintField(5, value: 1, to: &body)
        LyraProtoWriter.appendLengthDelimitedField(7, value: key, to: &body)
        expected.append(body)
        XCTAssertEqual(frame, expected)
    }

    func testPeerPortResponseWithoutKey() {
        let frame = LyraChannelProtocol.encodePeerPortResponse(
            peerChannelId: 0,
            serverChannelId: 5,
            port: 5000,
            key: Data()
        )
        let (header, body) = try! LyraChannelProtocol.decode(frame)
        XCTAssertEqual(header.type, 3)
        XCTAssertEqual(header.argument, 0)
        let fields = try! LyraProtoReader.readFields(from: body)
        XCTAssertEqual(fields.count, 4)
    }

    func testDecodeRequestOfPeerPort() {
        var body = Data()
        LyraProtoWriter.appendVarintField(1, value: 28, to: &body)
        LyraProtoWriter.appendVarintField(2, value: 0, to: &body)
        LyraProtoWriter.appendVarintField(3, value: 0, to: &body)
        LyraProtoWriter.appendLengthDelimitedField(4, value: Data(repeating: 0x11, count: 32), to: &body)
        let frame = LyraChannelProtocol.encode(type: .requestOfPeerPort, body: body)
        let (header, decodedBody) = try! LyraChannelProtocol.decode(frame)
        XCTAssertEqual(header.type, 2)
        let request = LyraChannelProtocol.PeerPortRequest(parsing: decodedBody)
        XCTAssertNotNil(request)
        XCTAssertEqual(request?.channelId, 28)
        XCTAssertEqual(request?.transKey, Data(repeating: 0x11, count: 32))
    }

    func testSocketPacketRoundTrip() throws {
        let key = SymmetricKey(size: .bits256)
        let plaintext = Data((0..<200).map { UInt8($0 & 0xFF) })
        let packet = try LyraSocketPacket.encode(plaintext: plaintext, key: key)
        XCTAssertEqual(packet.count, plaintext.count + 32)
        XCTAssertEqual(packet[0], 0x81)
        XCTAssertEqual(packet[1], 0x04)
        let (decoded, consumed) = try LyraSocketPacket.decode(packet, key: key)
        XCTAssertEqual(decoded, plaintext)
        XCTAssertEqual(consumed, packet.count)
    }

    func testSocketPacketRejectsWrongKey() throws {
        let packet = try LyraSocketPacket.encode(plaintext: Data([1, 2, 3]), key: SymmetricKey(size: .bits256))
        XCTAssertThrowsError(try LyraSocketPacket.decode(packet, key: SymmetricKey(size: .bits256))) { error in
            XCTAssertEqual(error as? LyraSocketPacket.PacketError, .decryptionFailed)
        }
    }

    func testFragmentRoundTrip() throws {
        let key = SymmetricKey(size: .bits256)
        let message = Data((0..<99).map { UInt8($0 & 0xFF) })
        let fragments = try LyraChannelFragment.encode(message: message, key: key)
        XCTAssertEqual(fragments.count, 1)
        let (chunk, offset, total, isLast) = try LyraChannelFragment.decode(fragment: fragments[0], key: key)
        XCTAssertEqual(chunk, message)
        XCTAssertEqual(offset, 0)
        XCTAssertEqual(total, 1)
        XCTAssertTrue(isLast)
    }

    func testFragmentMultiFrameRoundTrip() throws {
        let key = SymmetricKey(size: .bits256)
        let message = Data((0..<3000).map { UInt8($0 & 0xFF) })
        let fragments = try LyraChannelFragment.encode(message: message, key: key)
        XCTAssertEqual(fragments.count, 3)
        var reassembled = Data()
        var lastTotal = 0
        for fragment in fragments {
            let (chunk, _, total, _) = try LyraChannelFragment.decode(fragment: fragment, key: key)
            lastTotal = total
            reassembled.append(chunk)
        }
        XCTAssertEqual(lastTotal, 3)
        XCTAssertEqual(reassembled, message)
    }

    func testLogiConnRequestTransKeyExtraction() {
        let hex = "080112dd020801122b636f6d2e7869616f6d692e6879706572436f6e6e6563743a6d694c79726153686172655472616e736665721aa1020801121d636f6d2e6d6975692e6d6973686172652e636f6e6e65637469766974791a5f43393a30303a39443a30313a45423a46393a46353a44303a33303a32423a43373a31423a32463a45393a41413a39413a34373a41343a33323a42423a41313a37333a30383a41333a31313a31423a37353a44373a42323a31343a39303a323522344151482f2f774141414234414141454141414541414141554141554141414141414178425555464251554642515546425154303d2a1d0100ffff0000001500030000000000040000ff000006000100000001013001524608192220f87307334155237b9e9e4edc94e03209cab9aa5bed8b719422066d0d1444f9622a20c8670ac95f190553a6c2906ffe54b0bba98533b5e754c7121ab9cf21daf0cba520302898753080013801"
        let data = Data(hexString: hex)
        guard let innerFrame = LogiConnInnerFrame(parsing: data),
              case let .request(requestData) = innerFrame.payload
        else {
            XCTFail("request not parsed")
            return
        }
        let fields = try! LyraProtoReader.readFields(from: requestData)
        let privateData = fields.first { $0.number == 3 && $0.wireType == 2 }?.lengthDelimitedValue
        XCTAssertEqual(privateData?.count, 289)
        let pdFields = try! LyraProtoReader.readFields(from: privateData!)
        let keyField = pdFields.first { $0.number == 3 && $0.wireType == 2 }?.lengthDelimitedValue
        XCTAssertEqual(keyField?.count, 95)
        let keyString = String(data: keyField!, encoding: .utf8)!
        XCTAssertTrue(keyString.hasPrefix("C9:00:9D:01"))
        let bytes = keyString.split(separator: ":").compactMap { UInt8($0, radix: 16) }
        XCTAssertEqual(bytes.count, 32)
        XCTAssertEqual(Data(bytes).prefix(4), Data([0xC9, 0x00, 0x9D, 0x01]))
        let channelBlob = pdFields.first { $0.number == 10 && $0.wireType == 2 }?.lengthDelimitedValue
        XCTAssertEqual(channelBlob?.count, 70)
        let innerFields = try! LyraProtoReader.readFields(from: channelBlob!)
        let channelId = innerFields.first { $0.number == 1 && $0.wireType == 0 }?.varintValue
        XCTAssertEqual(channelId, 25)
        let transKey = innerFields.first { $0.number == 4 && $0.wireType == 2 }?.lengthDelimitedValue
        XCTAssertEqual(transKey?.count, 32)
        XCTAssertEqual(transKey?.prefix(4), Data([0xF8, 0x73, 0x07, 0x33]))
        let random = innerFields.first { $0.number == 5 && $0.wireType == 2 }?.lengthDelimitedValue
        XCTAssertEqual(random?.count, 32)
    }
}

private extension Data {
    init(hexString: String) {
        var data = Data()
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            data.append(UInt8(hexString[index..<next], radix: 16)!)
            index = next
        }
        self = data
    }
}
