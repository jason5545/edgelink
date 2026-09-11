import EdgeLinkKit
import XCTest

// Selection policy for the Tailscale exit-node escape (see
// LANEgressInterface): only destinations inside a non-tunnel interface's
// subnet get interface-bound; internet, tailnet and loopback destinations
// keep system routing.
final class LANEgressInterfaceTests: XCTestCase {
    // The live interface set from the 2026-09-11 outage machine: en0 owns
    // the phone's /22, utun4 (Tailscale, exit node) owns the tailnet /32.
    private let tailscaleSet = [
        LANEgressInterface.LocalInterface(name: "en0", address: "10.5.51.139", netmask: "255.255.252.0"),
        LANEgressInterface.LocalInterface(name: "utun4", address: "100.89.162.36", netmask: "255.255.255.255"),
    ]

    override func tearDown() {
        LANEgressInterface.resetTestOverrides()
        super.tearDown()
    }

    private func pick(_ host: String, _ interfaces: [LANEgressInterface.LocalInterface]) -> String? {
        LANEgressInterface.lanInterface(forDestination: host, interfaces: interfaces)?.name
    }

    func testPhoneOnLANSubnetSelectsLANInterface() {
        XCTAssertEqual(pick("10.5.49.21", tailscaleSet), "en0")
    }

    func testGatewayInsideSubnetAlsoSelects() {
        XCTAssertEqual(pick("10.5.48.1", tailscaleSet), "en0")
    }

    func testTailnetAddressKeepsSystemRouting() {
        // 100.64.0.0/10 lives on the utun interface — binding en0 for a
        // tailnet peer would break it, and binding utun is the routing
        // table's job.
        XCTAssertNil(pick("100.89.162.36", tailscaleSet))
        XCTAssertNil(pick("100.64.10.131", tailscaleSet))
    }

    func testInternetAddressKeepsSystemRouting() {
        XCTAssertNil(pick("8.8.8.8", tailscaleSet))
        XCTAssertNil(pick("192.0.2.1", tailscaleSet))
    }

    func testLoopbackNeverSelected() {
        let withLoopback = tailscaleSet + [
            LANEgressInterface.LocalInterface(name: "lo0", address: "127.0.0.1", netmask: "255.0.0.0"),
        ]
        XCTAssertNil(pick("127.0.0.1", withLoopback))
    }

    func testHostnameNotSelected() {
        XCTAssertNil(pick("xiaomi-phone.local", tailscaleSet))
        XCTAssertNil(pick("", tailscaleSet))
    }

    func testLongestPrefixWins() {
        let dual = [
            LANEgressInterface.LocalInterface(name: "en0", address: "10.5.51.139", netmask: "255.255.252.0"),
            LANEgressInterface.LocalInterface(name: "en5", address: "10.5.49.200", netmask: "255.255.255.0"),
        ]
        XCTAssertEqual(pick("10.5.49.21", dual), "en5")
        XCTAssertEqual(pick("10.5.48.1", dual), "en0")
    }

    func testTunnelInterfaceNeverSelectedEvenWhenSubnetMatches() {
        // A tunnel that (address-wise) contains the destination must not be
        // chosen — its subnet existing is exactly the hijack being escaped.
        let hijacked = [
            LANEgressInterface.LocalInterface(name: "utun4", address: "10.5.48.1", netmask: "255.255.252.0"),
        ]
        XCTAssertNil(pick("10.5.49.21", hijacked))
    }

    func testTunnelNameDetection() {
        for name in ["utun0", "utun4", "ipsec0", "ppp0", "tun0", "tap0", "wg0"] {
            XCTAssertTrue(LANEgressInterface.isTunnelInterfaceName(name), name)
        }
        for name in ["en0", "en5", "awdl0", "llw0", "bridge100", "lo0", "anpi0"] {
            XCTAssertFalse(LANEgressInterface.isTunnelInterfaceName(name), name)
        }
    }

    func testCurrentLocalInterfacesHonorsOverride() {
        LANEgressInterface.localInterfacesOverride = tailscaleSet
        XCTAssertEqual(LANEgressInterface.currentLocalInterfaces(), tailscaleSet)
    }

    func testEmptyHostAndGarbageNeverCrash() {
        XCTAssertNil(pick("999.999.999.999", tailscaleSet))
        XCTAssertNil(pick("::1", tailscaleSet))
        XCTAssertNil(pick("10.5.49.21", []))
    }
}
