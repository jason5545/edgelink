import EdgeLinkKit
import Foundation
import XCTest

// Pins the reverse-sync reply frame: a leading 0x00 type byte (the announce's
// 01 00 00 header is rejected by the phone's FrameParse) followed by the
// syncFrame wrapping a full TrustedDeviceInfo that mirrors the officially
// paired Mac's DevRepo entry (64-hex full id in f3, short id in f23, mesh
// port in f25, relayCall service blob).
final class LyraSyncReplyPayloadTests: XCTestCase {
    private func fields(_ data: Data) throws -> [LyraProtoReader.Field] {
        try LyraProtoReader.readFields(from: data)
    }

    private func lengthDelimited(_ fieldNumber: Int, in data: Data) -> Data? {
        (try? fields(data))?.first { $0.number == fieldNumber && $0.wireType == 2 }?.lengthDelimitedValue
    }

    private func varint(_ fieldNumber: Int, in data: Data) -> UInt64? {
        (try? fields(data))?.first { $0.number == fieldNumber && $0.wireType == 0 }?.varintValue
    }

    func testSyncReplyPayloadShape() throws {
        let fullId = "721572C384AE0AE9FB38162882E4FFF7D1BE0199B22F1CBCA7D018B5B71AEA59"
        let services = [
            LyraTrustedDeviceInfo.Service(name: "miLyraShare", package: "com.edgelink.mac"),
            LyraTrustedDeviceInfo.Service(
                name: "relayCall", package: "com.ios.phone", data: Data([0x03, 0x01, 0x01, 0x01])
            ),
        ]
        let deviceKey = Data((0..<32).map { UInt8($0 ^ 0x5A) })
        let deviceInfo = LyraTrustedDeviceInfo.syncReplyDeviceInfoFrame(
            deviceName: "MacBook Pro",
            deviceType: 4,
            fullDeviceIdHex: fullId,
            shortDeviceIdHex: "721572C3",
            uidHash: "61F250B63BE702E35785999767C221163AF7238995757F598034B753E3AF0733",
            hwModel: "Mac17,6",
            lyraVersion: "5.1.208.10.fullCnRelease.0512164",
            services: services,
            meshPort: 43181,
            ipAddress: "10.5.48.51",
            osVersion: "26.6.0",
            accountNumericId: "32717118",
            syncUuid: "3c688e8c-c5df-4f9d-a163-4c193bd30582",
            deviceKey: deviceKey
        )
        let payload = LyraTrustedDeviceInfo.syncReplyPayload(deviceInfo: deviceInfo)

        XCTAssertEqual(payload.first, 0x00)
        let frame = payload.dropFirst()
        XCTAssertEqual(varint(1, in: Data(frame)), 2)
        let wrapper = try XCTUnwrap(lengthDelimited(6, in: Data(frame)))
        XCTAssertEqual(varint(2, in: wrapper), 1)
        let info = try XCTUnwrap(lengthDelimited(3, in: wrapper))

        XCTAssertEqual(
            lengthDelimited(3, in: info).flatMap { String(data: $0, encoding: .utf8) }, fullId
        )
        XCTAssertEqual(
            lengthDelimited(23, in: info).flatMap { String(data: $0, encoding: .utf8) }, "721572C3"
        )
        XCTAssertEqual(varint(25, in: info), 43181)
        XCTAssertEqual(lengthDelimited(13, in: info), deviceKey)
        XCTAssertNil(lengthDelimited(15, in: info), "cred block is opt-in")
        XCTAssertEqual(
            lengthDelimited(19, in: info).flatMap { String(data: $0, encoding: .utf8) }, "cn"
        )
        XCTAssertEqual(
            lengthDelimited(31, in: info).flatMap { String(data: $0, encoding: .utf8) },
            "32717118_\(fullId.lowercased())"
        )
        XCTAssertEqual(
            lengthDelimited(39, in: info).flatMap { String(data: $0, encoding: .utf8) }, "32717118"
        )
        let serviceFrames = try fields(info).filter { $0.number == 14 && $0.wireType == 2 }
        XCTAssertEqual(serviceFrames.count, 2)
        let relay = serviceFrames.compactMap(\.lengthDelimitedValue).first {
            lengthDelimited(1, in: $0).flatMap { String(data: $0, encoding: .utf8) } == "relayCall"
        }
        XCTAssertEqual(
            lengthDelimited(2, in: try XCTUnwrap(relay)).flatMap { String(data: $0, encoding: .utf8) },
            "com.ios.phone"
        )
        XCTAssertEqual(lengthDelimited(3, in: try XCTUnwrap(relay)), Data([0x03, 0x01, 0x01, 0x01]))
    }

    // The device-initiated push uses the type-1 sync frame (same shape the
    // phone pushes) — the only route into the phone's HandleSyncDevMsg cred
    // checks that stamp the conn trusted type.
    func testSyncPushPayloadShape() throws {
        let deviceInfo = LyraTrustedDeviceInfo.syncReplyDeviceInfoFrame(            deviceName: "MacBook Pro",
            deviceType: 4,
            fullDeviceIdHex: "721572C384AE0AE9FB38162882E4FFF7D1BE0199B22F1CBCA7D018B5B71AEA59",
            shortDeviceIdHex: "721572C3",
            uidHash: "61F250B63BE702E35785999767C221163AF7238995757F598034B753E3AF0733",
            hwModel: "Mac17,6",
            lyraVersion: "5.1.208.10.fullCnRelease.0512164",
            services: [],
            meshPort: 43181,
            ipAddress: "10.5.48.51",
            osVersion: "26.6.0",
            accountNumericId: "32717118",
            syncUuid: "3c688e8c-c5df-4f9d-a163-4c193bd30582"
        )
        var groupInfo = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &groupInfo)
        LyraProtoWriter.appendLengthDelimitedField(3, value: Data([0xAA, 0xBB]), to: &groupInfo)
        let payload = LyraTrustedDeviceInfo.syncPushPayload(deviceInfo: deviceInfo, groupInfo: groupInfo)

        XCTAssertEqual(payload.first, 0x00)
        let frame = payload.dropFirst()
        XCTAssertEqual(varint(1, in: Data(frame)), 1)
        let sync = try XCTUnwrap(lengthDelimited(5, in: Data(frame)))
        XCTAssertEqual(varint(1, in: sync), 1)
        let info = try XCTUnwrap(lengthDelimited(2, in: sync))
        XCTAssertEqual(
            lengthDelimited(3, in: info).flatMap { String(data: $0, encoding: .utf8) },
            "721572C384AE0AE9FB38162882E4FFF7D1BE0199B22F1CBCA7D018B5B71AEA59"
        )
        XCTAssertEqual(lengthDelimited(3, in: sync), groupInfo)
    }
}
