import XCTest
@testable import EdgeLinkKit

final class LyraNetbusFrameTests: XCTestCase {
    func testMeshPackEncodeMatchesBinaryLayout() throws {
        let payload = Data([0xAA, 0xBB, 0xCC])
        let encoded = try LyraMeshPack.encode(LyraMeshPack.Frame(packType: 2, payload: payload))
        XCTAssertEqual(Array(encoded), [0x11, 0x04, 0x00, 0x07, 0xAA, 0xBB, 0xCC])
    }

    func testMeshPackRoundTrip() throws {
        let payload = Data((0..<300).map { UInt8($0 & 0xFF) })
        let frame = LyraMeshPack.Frame(packType: 1, payload: payload)
        let decoded = try LyraMeshPack.decode(try LyraMeshPack.encode(frame))
        XCTAssertEqual(decoded.frame, frame)
        XCTAssertEqual(decoded.consumedBytes, payload.count + 4)
    }

    func testMeshPackDecodeLengthIsBigEndian() throws {
        var bytes: [UInt8] = [0x09, 0x04, 0x01, 0x00]
        bytes.append(contentsOf: repeatElement(0x00, count: 252))
        let decoded = try LyraMeshPack.decode(Data(bytes))
        XCTAssertEqual(decoded.frame.packType, 1)
        XCTAssertEqual(decoded.frame.payload.count, 252)
        XCTAssertEqual(decoded.consumedBytes, 256)
    }

    func testMeshPackDecodeExtendedHeader() throws {
        let bytes: [UInt8] = [0x01, 0x06, 0x00, 0x08, 0xDE, 0xAD, 0xBE, 0xEF]
        let decoded = try LyraMeshPack.decode(Data(bytes))
        XCTAssertEqual(decoded.frame.extendedHeader, Data([0xDE, 0xAD]))
        XCTAssertEqual(decoded.frame.payload, Data([0xBE, 0xEF]))
    }

    func testMeshPackRejectsTruncatedFrame() {
        XCTAssertThrowsError(try LyraMeshPack.decode(Data([0x01, 0x04, 0x00])))
        XCTAssertThrowsError(try LyraMeshPack.decode(Data([0x01, 0x04, 0x00, 0x10, 0x00])))
    }

    func testMeshPackRejectsOversizeEncode() {
        let payload = Data(repeating: 0, count: 0x10000)
        XCTAssertThrowsError(try LyraMeshPack.encode(LyraMeshPack.Frame(packType: 0, payload: payload))) { error in
            XCTAssertEqual(error as? LyraMeshPack.PackError, .frameTooLarge(0x10004))
        }
    }

    func testVarintWriterGolden() {
        var data = Data()
        LyraProtoWriter.appendVarint(0, to: &data)
        LyraProtoWriter.appendVarint(1, to: &data)
        LyraProtoWriter.appendVarint(127, to: &data)
        LyraProtoWriter.appendVarint(128, to: &data)
        LyraProtoWriter.appendVarint(300, to: &data)
        LyraProtoWriter.appendVarint(0xFFFFFFFF, to: &data)
        XCTAssertEqual(Array(data), [
            0x00,
            0x01,
            0x7F,
            0x80, 0x01,
            0xAC, 0x02,
            0xFF, 0xFF, 0xFF, 0xFF, 0x0F
        ])
    }

    func testProtoReaderSkipsUnknownFields() throws {
        var data = Data()
        LyraProtoWriter.appendVarintField(1, value: 42, to: &data)
        LyraProtoWriter.appendVarintField(9, value: 7, to: &data)
        LyraProtoWriter.appendLengthDelimitedField(12, value: Data([1, 2]), to: &data)
        let fields = try LyraProtoReader.readFields(from: data)
        XCTAssertEqual(fields.map(\.number), [1, 9, 12])
        XCTAssertEqual(fields[0].varintValue, 42)
        XCTAssertEqual(fields[2].lengthDelimitedValue, Data([1, 2]))
    }

    func testLogiConnFrameGolden() {
        let frame = LogiConnFrame(logiConnId: 0x01020304, localNetId: 0x10, remoteNetId: 0x20, flag: true, inner: Data([0x08, 0x01]))
        let bytes = frame.serialized()
        var expected = Data()
        LyraProtoWriter.appendVarintField(1, value: 0x01020304, to: &expected)
        LyraProtoWriter.appendVarintField(2, value: 0x10, to: &expected)
        LyraProtoWriter.appendVarintField(3, value: 0x20, to: &expected)
        LyraProtoWriter.appendBoolField(4, value: true, to: &expected)
        LyraProtoWriter.appendLengthDelimitedField(5, value: Data([0x08, 0x01]), to: &expected)
        XCTAssertEqual(bytes, expected)

        let parsed = LogiConnFrame(parsing: bytes)
        XCTAssertEqual(parsed, frame)
    }

    func testMiConnectFrameRoundTrip() {
        let inner = LogiConnInnerFrame(frameType: 2, payload: .syncInfo(Data([0x38, 0x07])))
        let logi = LogiConnFrame(logiConnId: 0xABCD, inner: inner.serialized())
        let phys = PhysConnFrame(field1: 1, field2: 2, payload: .keepAliveRequest(Data()))
        let frame = MiConnectFrame(version: 0, logiConnFrames: [logi], physConnFrame: phys)

        let parsed = MiConnectFrame(parsing: frame.serialized())
        XCTAssertEqual(parsed?.version, 0)
        XCTAssertEqual(parsed?.logiConnFrames.count, 1)
        XCTAssertEqual(parsed?.logiConnFrames.first?.logiConnId, 0xABCD)
        XCTAssertEqual(parsed?.physConnFrame?.field1, 1)

        let parsedInner = parsed?.logiConnFrames.first.flatMap { LogiConnInnerFrame(parsing: $0.inner) }
        XCTAssertEqual(parsedInner?.frameType, 2)
        XCTAssertEqual(parsedInner?.payload, .syncInfo(Data([0x38, 0x07])))
    }

    func testPhysConnFramePayloadFieldNumbers() {
        XCTAssertEqual(PhysConnPayload.syncDeviceInfoRequest(Data()).fieldNumber, 3)
        XCTAssertEqual(PhysConnPayload.keepAliveRequest(Data()).fieldNumber, 6)
        XCTAssertEqual(PhysConnPayload.keepAliveResponse(Data()).fieldNumber, 7)
        XCTAssertEqual(PhysConnPayload.disconnectRequest(Data()).fieldNumber, 8)
        XCTAssertEqual(PhysConnPayload.disconnectResponse(Data()).fieldNumber, 9)
        XCTAssertNil(PhysConnPayload(fieldNumber: 10, data: Data()))
    }

    func testPhysConnFrameOmitsZeroScalarFields() {
        var payload = Data()
        LyraProtoWriter.appendVarintField(1, value: 1_752_346_656_768, to: &payload)
        let frame = PhysConnFrame(field2: 5, payload: .keepAliveResponse(payload))
        let serialized = frame.serialized()
        XCTAssertEqual(Array(serialized.prefix(2)), [0x10, 0x05])

        let parsed = PhysConnFrame(parsing: serialized)
        XCTAssertEqual(parsed?.field1, 0)
        XCTAssertEqual(parsed?.field2, 5)
        XCTAssertEqual(parsed?.payload, .keepAliveResponse(payload))
    }

    func testMeshPackCarryingMiConnectFrame() throws {
        let inner = LogiConnInnerFrame(frameType: 1, payload: .request(Data([0x28, 0x80, 0x01])))
        let logi = LogiConnFrame(logiConnId: 1, inner: inner.serialized())
        let mi = MiConnectFrame(version: 0, logiConnFrames: [logi])
        let encoded = try LyraMeshPack.encode(LyraMeshPack.Frame(packType: 0, payload: mi.serialized()))

        let decoded = try LyraMeshPack.decode(encoded)
        let parsed = MiConnectFrame(parsing: decoded.frame.payload)
        XCTAssertEqual(parsed?.logiConnFrames.first?.logiConnId, 1)
    }
}
