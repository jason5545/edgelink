import Foundation
import XCTest

// Pins the announce-target selection: after a network move the persisted /
// in-memory phone endpoint points into the old subnet and must be skipped
// (and evicted) in favor of a reachable, most-recently-heard endpoint.
final class LyraAnnounceEndpointTests: XCTestCase {
    private typealias Iface = LANPinnedPhoneIP.InterfaceAddress

    private let homeInterfaces = [Iface(address: "10.0.0.154", netmask: "255.255.255.0")]
    private let officeEndpoint = "10.5.51.107:49758"
    private let homeEndpoint = "10.0.0.126:49758"

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "LyraAnnounceEndpointTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testSelectSkipsStaleSubnetCandidate() {
        let selected = LyraMeshResponder.selectReachableEndpoint(
            candidates: [officeEndpoint, homeEndpoint],
            interfaces: homeInterfaces
        )
        XCTAssertEqual(selected, homeEndpoint)
    }

    func testSelectPrefersMostRecentlyHeardReachable() {
        let selected = LyraMeshResponder.selectReachableEndpoint(
            candidates: [homeEndpoint, "10.0.0.200:49758"],
            interfaces: homeInterfaces
        )
        XCTAssertEqual(selected, homeEndpoint)
    }

    func testSelectReturnsNilWhenEveryCandidateIsStale() {
        XCTAssertNil(
            LyraMeshResponder.selectReachableEndpoint(
                candidates: [officeEndpoint, "192.168.7.9:49758"],
                interfaces: homeInterfaces
            )
        )
    }

    func testSelectSkipsMalformedAndNonIPv4Candidates() {
        let selected = LyraMeshResponder.selectReachableEndpoint(
            candidates: ["not-an-endpoint", "some-host.local:49758", homeEndpoint],
            interfaces: homeInterfaces
        )
        XCTAssertEqual(selected, homeEndpoint)
    }

    func testEvictDropsStaleLastAndHistoryEntries() {
        defaults.set(officeEndpoint, forKey: "lyraLastPhoneMeshEndpoint")
        defaults.set(Date().timeIntervalSince1970, forKey: "lyraLastPhoneMeshEndpointTime")
        defaults.set(
            [officeEndpoint, homeEndpoint, "192.168.7.9:49758"],
            forKey: "lyraPhoneMeshEndpointHistory"
        )

        let evicted = LyraMeshResponder.evictStalePhoneEndpoints(
            interfaces: homeInterfaces, defaults: defaults
        )

        XCTAssertNil(defaults.string(forKey: "lyraLastPhoneMeshEndpoint"))
        XCTAssertEqual(
            defaults.stringArray(forKey: "lyraPhoneMeshEndpointHistory"),
            [homeEndpoint]
        )
        XCTAssertTrue(evicted.contains(officeEndpoint))
        XCTAssertTrue(evicted.contains("192.168.7.9:49758"))
        XCTAssertFalse(evicted.contains(homeEndpoint))
    }

    func testEvictKeepsReachableEndpoints() {
        defaults.set(homeEndpoint, forKey: "lyraLastPhoneMeshEndpoint")
        defaults.set([homeEndpoint], forKey: "lyraPhoneMeshEndpointHistory")

        let evicted = LyraMeshResponder.evictStalePhoneEndpoints(
            interfaces: homeInterfaces, defaults: defaults
        )

        XCTAssertTrue(evicted.isEmpty)
        XCTAssertEqual(defaults.string(forKey: "lyraLastPhoneMeshEndpoint"), homeEndpoint)
        XCTAssertEqual(defaults.stringArray(forKey: "lyraPhoneMeshEndpointHistory"), [homeEndpoint])
    }
}
