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
        XCTAssertEqual(payload.displayName, "簡瑞成的POCO F8 Ultra")
    }

    func testParsesCapturedPhoneAppDataWithModelName() throws {
        let payload = try XCTUnwrap(
            XiaomiMiShareDiscoveryAppData(
                base64Encoded: "AkEBJthT61gfAAUZLxcaAwoDAY+zAQEgIwAjAlSaAg1QT0NPIEY4IFVsdHJh"
            )
        )

        XCTAssertEqual(payload.deviceIdHex, "26D853EB")
        XCTAssertEqual(payload.displayName, "POCO F8 Ultra")
    }

    func testBuildsMacDiscoveryAppData() throws {
        let data = try XiaomiMiShareDiscoveryAppData.build(
            deviceIdHex: "A1B2C3D4",
            displayName: "EdgeLink Mac"
        )
        let payload = XiaomiMiShareDiscoveryAppData(data: data)

        XCTAssertEqual(payload.deviceIdHex, "A1B2C3D4")
        XCTAssertEqual(payload.displayName, "EdgeLink Mac")
        XCTAssertEqual(
            try XiaomiMiShareDiscoveryAppData.buildBase64(
                deviceIdHex: "A1B2C3D4",
                displayName: "EdgeLink Mac"
            ),
            data.base64EncodedString()
        )
    }

    func testRejectsInvalidPublisherInputs() {
        XCTAssertThrowsError(
            try XiaomiMiShareDiscoveryAppData.build(deviceIdHex: "not-id", displayName: "EdgeLink Mac")
        )
        XCTAssertThrowsError(
            try XiaomiMiShareDiscoveryAppData.build(deviceIdHex: "A1B2C3D4", displayName: " ")
        )
    }
}
