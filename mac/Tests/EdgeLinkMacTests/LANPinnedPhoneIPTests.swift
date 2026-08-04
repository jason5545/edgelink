import XCTest

final class LANPinnedPhoneIPTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "LANPinnedPhoneIPTests")!
        defaults.removePersistentDomain(forName: "LANPinnedPhoneIPTests")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "LANPinnedPhoneIPTests")
        defaults = nil
        super.tearDown()
    }

    private let homeLAN = [
        LANPinnedPhoneIP.InterfaceAddress(address: "192.168.1.5", netmask: "255.255.255.0")
    ]

    func testRecordedPinIsReturnedOnSameSubnet() {
        LANPinnedPhoneIP.record("192.168.1.50", defaults: defaults)

        XCTAssertEqual(
            LANPinnedPhoneIP.current(defaults: defaults, interfaces: homeLAN),
            "192.168.1.50"
        )
    }

    func testPinIsDroppedAfterNetworkMove() {
        LANPinnedPhoneIP.record("172.20.10.2", defaults: defaults)

        XCTAssertNil(LANPinnedPhoneIP.current(defaults: defaults, interfaces: homeLAN))
    }

    func testPinIsKeptOnHotspotSubnet() {
        LANPinnedPhoneIP.record("172.20.10.1", defaults: defaults)
        let hotspot = [
            LANPinnedPhoneIP.InterfaceAddress(address: "172.20.10.4", netmask: "255.255.255.240")
        ]

        XCTAssertEqual(
            LANPinnedPhoneIP.current(defaults: defaults, interfaces: hotspot),
            "172.20.10.1"
        )
    }

    func testExpiredPinIsDropped() {
        let stale = Date().addingTimeInterval(-LANPinnedPhoneIP.maxAge - 60)
        LANPinnedPhoneIP.record("192.168.1.50", defaults: defaults, now: stale)

        XCTAssertNil(LANPinnedPhoneIP.current(defaults: defaults, interfaces: homeLAN))
    }

    func testMissingPinReturnsNil() {
        XCTAssertNil(LANPinnedPhoneIP.current(defaults: defaults, interfaces: homeLAN))
    }

    func testPinIsKeptWhenNoInterfacesAreUp() {
        LANPinnedPhoneIP.record("172.20.10.1", defaults: defaults)

        XCTAssertEqual(
            LANPinnedPhoneIP.current(defaults: defaults, interfaces: []),
            "172.20.10.1"
        )
    }

    func testSubnetMatchingRespectsNetmask() {
        let slash16 = [
            LANPinnedPhoneIP.InterfaceAddress(address: "192.168.7.5", netmask: "255.255.0.0")
        ]
        let slash24 = [
            LANPinnedPhoneIP.InterfaceAddress(address: "192.168.7.5", netmask: "255.255.255.0")
        ]

        XCTAssertTrue(LANPinnedPhoneIP.isOnLocalNetwork("192.168.1.50", interfaces: slash16))
        XCTAssertFalse(LANPinnedPhoneIP.isOnLocalNetwork("192.168.1.50", interfaces: slash24))
    }

    func testAnyMatchingInterfaceKeepsPin() {
        let multi = [
            LANPinnedPhoneIP.InterfaceAddress(address: "10.0.0.5", netmask: "255.255.255.0"),
            LANPinnedPhoneIP.InterfaceAddress(address: "192.168.1.5", netmask: "255.255.255.0")
        ]

        XCTAssertTrue(LANPinnedPhoneIP.isOnLocalNetwork("192.168.1.50", interfaces: multi))
        XCTAssertFalse(LANPinnedPhoneIP.isOnLocalNetwork("172.20.10.1", interfaces: multi))
    }

    func testInvalidPinAddressIsRejected() {
        XCTAssertFalse(LANPinnedPhoneIP.isOnLocalNetwork("not-an-ip", interfaces: homeLAN))
    }
}
