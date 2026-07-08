import XCTest
@testable import EdgeLinkKit

final class IdentityTests: XCTestCase {
    func testDeviceIDDisplay() {
        XCTAssertTrue(DeviceID.isValid("949758990"))
        XCTAssertFalse(DeviceID.isValid("049758990"))
        XCTAssertEqual(DeviceID.display("949758990"), "949 758 990")
    }
}
