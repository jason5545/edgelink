import XCTest
@testable import EdgeLinkKit

final class XiaomiMiShareDiscoveryPayloadTests: XCTestCase {
    func testParsesCapturedPhoneAppDataWithOwnerName() throws {
        let payload = try XCTUnwrap(
            XiaomiMiShareDiscoveryAppData(
                base64Encoded: "AkEBi8VLY2HyAAUZPxcCBwoDAbTeAQEgIwAjAoZFAhnnsKHnkZ7miJDnmoRQT0NPIEY4IFVsdHJh"
            )
        )

        XCTAssertEqual(payload.deviceIdHex, "8BC54B63")
        XCTAssertEqual(payload.deviceType, XiaomiMiShareDiscoveryAppData.deviceTypePhone)
        XCTAssertEqual(payload.accountIdHex, "61F2")
        XCTAssertEqual(payload.displayName, "簡瑞成的POCO F8 Ultra")
    }

    func testParsesCapturedPhoneAppDataWithModelName() throws {
        let payload = try XCTUnwrap(
            XiaomiMiShareDiscoveryAppData(
                base64Encoded: "AkEBJthT61gfAAUZLxcaAwoDAY+zAQEgIwAjAlSaAg1QT0NPIEY4IFVsdHJh"
            )
        )

        XCTAssertEqual(payload.deviceIdHex, "26D853EB")
        XCTAssertEqual(payload.deviceType, XiaomiMiShareDiscoveryAppData.deviceTypePhone)
        XCTAssertEqual(payload.accountIdHex, "581F")
        XCTAssertEqual(payload.displayName, "POCO F8 Ultra")
    }

    func testBuildsMacDiscoveryAppData() throws {
        let data = try XiaomiMiShareDiscoveryAppData.build(
            deviceIdHex: "A1B2C3D4",
            displayName: "EdgeLink Mac"
        )
        let payload = XiaomiMiShareDiscoveryAppData(data: data)

        XCTAssertEqual(payload.deviceIdHex, "A1B2C3D4")
        XCTAssertEqual(payload.deviceType, XiaomiMiShareDiscoveryAppData.deviceTypeMacBook)
        XCTAssertEqual(payload.accountIdHex, "581F")
        XCTAssertEqual(payload.displayName, "EdgeLink Mac")
        XCTAssertEqual(
            try XiaomiMiShareDiscoveryAppData.buildBase64(
                deviceIdHex: "A1B2C3D4",
                displayName: "EdgeLink Mac"
            ),
            data.base64EncodedString()
        )
    }

    func testBuildsMacDiscoveryAppDataWithObservedAccountHash() throws {
        let data = try XiaomiMiShareDiscoveryAppData.build(
            deviceIdHex: "721572C3",
            displayName: "MacBook Pro",
            accountIdHex: "61F2"
        )
        let payload = XiaomiMiShareDiscoveryAppData(data: data)

        XCTAssertEqual(payload.deviceIdHex, "721572C3")
        XCTAssertEqual(payload.deviceType, XiaomiMiShareDiscoveryAppData.deviceTypeMacBook)
        XCTAssertEqual(payload.accountIdHex, "61F2")
        XCTAssertEqual(payload.displayName, "MacBook Pro")
    }

    func testBuildsAppDataWithMeshPort() throws {
        let data = try XiaomiMiShareDiscoveryAppData.build(
            deviceIdHex: "A1B2C3D4",
            displayName: "EdgeLink Mac",
            meshPort: 0xE897
        )
        let payload = XiaomiMiShareDiscoveryAppData(data: data)

        XCTAssertEqual(payload.meshPort, 0xE897)
        XCTAssertEqual(Array(data)[19...20], [0xE8, 0x97])
    }

    func testParsesCapturedPhoneAppDataMeshPort() throws {
        let phone = try XCTUnwrap(
            XiaomiMiShareDiscoveryAppData(
                base64Encoded: "AkEBi8VLY2HyAAUZPxMDBwoDAeiXAQEgIwAjAqRGAhnnsKHnkZ7miJDnmoRQT0NPIEY4IFVsdHJh"
            )
        )
        XCTAssertEqual(phone.meshPort, 0xE897)
    }

    func testRejectsInvalidPublisherInputs() {
        XCTAssertThrowsError(
            try XiaomiMiShareDiscoveryAppData.build(deviceIdHex: "not-id", displayName: "EdgeLink Mac")
        )
        XCTAssertThrowsError(
            try XiaomiMiShareDiscoveryAppData.build(deviceIdHex: "A1B2C3D4", displayName: " ")
        )
    }

    func testEncodesLyraMDNSSRVRecordWithDeviceIdHostTarget() throws {
        let srv = try XiaomiLyraMDNSRecordEncoder.srvRecord(
            port: 5353,
            targetFQDN: "721572C3.local."
        )
        let target = try XiaomiLyraMDNSRecordEncoder.dnsName("721572C3.local.")

        XCTAssertEqual(Array(srv.prefix(6)), [0x00, 0x00, 0x00, 0x00, 0x14, 0xe9])
        XCTAssertEqual(Data(srv.dropFirst(6)), target)
    }

    func testEncodesOfficialMacShapedSingleTXTRecord() throws {
        let appData = try XiaomiMiShareDiscoveryAppData.buildBase64(
            deviceIdHex: "721572C3",
            displayName: "MacBook Pro"
        )
        let txt = try XiaomiLyraMDNSRecordEncoder.txtRecord(entries: [("AppData", appData)])
        let entry = "AppData=\(appData)"

        XCTAssertEqual(txt.first, UInt8(entry.utf8.count))
        XCTAssertEqual(String(data: txt.dropFirst(), encoding: .utf8), entry)
        XCTAssertEqual(entry.utf8.count, 68)
    }
}
