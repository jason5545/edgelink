import EdgeLinkKit
import Foundation
import XCTest

// Pins the default deviceType Mac advertises over announce + sync-push
// paths. The phone's MiShare router (s2/p.e(RemoteDevice)) buckets by
// KEY_DEVICE_TYPE: 11–17 (Apple family) → j3/i.v() Apple branch (so the
// device surfaces as "MacBook Pro"); ==21 (PC class) → j3/i.L() which
// unconditionally routes to wlanConnect(medium 128) and surfaces as
// "小米筆記型電腦" (pc_xiaomi_device_model_name, vendor_id=34).
//
// Default 14 is the Apple-family choice. Setting
// `defaults write com.edgelink.mac xiaomiDeviceTypeOverride 21` flips back
// to PC-class routing for debugging. These tests clear the override before
// reading the default to ensure the baseline stays pinned.
final class LyraDeviceTypeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: LyraDeviceType.overrideKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: LyraDeviceType.overrideKey)
        super.tearDown()
    }

    func testDefaultIsAppleFamily() {
        XCTAssertEqual(LyraDeviceType.resolve(), 14)
    }

    func testOverrideForcesPCClass() {
        UserDefaults.standard.set(21, forKey: LyraDeviceType.overrideKey)
        XCTAssertEqual(LyraDeviceType.resolve(), 21)
    }

    func testExplicitOverrideArgumentWins() {
        // The parameter exists so future call sites can pass through a
        // per-request override (e.g. a debug menu) without touching
        // UserDefaults. An explicit non-zero argument must beat the
        // stored override.
        UserDefaults.standard.set(21, forKey: LyraDeviceType.overrideKey)
        XCTAssertEqual(LyraDeviceType.resolve(overriding: 14), 14)
    }

    func testConstants() {
        // The bucket boundaries are load-bearing — pin them so a future
        // refactor doesn't silently shift the meaning of "Apple family".
        XCTAssertEqual(LyraDeviceType.appleFamily, 14)
        XCTAssertEqual(LyraDeviceType.pcClass, 21)
    }

    // Live 19:50 trace (commit 836316183 base) had type 14 + mDNS TXT
    // already at 0x0e (deviceTypeMacBook). The phone surfaces that as
    // "MacBook Pro" — pinned by XiaomiMiShareDiscoveryPayloadTests. The
    // remaining leg of the chain is the announce/sync-push tdi value
    // (this file); the union must read 14 for the device to land in the
    // Apple bucket end-to-end.
    func testDiscoveryPayloadAndResolverAgreeOnType14() throws {
        let data = try XiaomiMiShareDiscoveryAppData.build(
            deviceIdHex: "721572C3",
            displayName: "MacBook Pro"
        )
        let parsed = XiaomiMiShareDiscoveryAppData(data: data)
        XCTAssertEqual(parsed.deviceType, XiaomiMiShareDiscoveryAppData.deviceTypeMacBook)
        XCTAssertEqual(UInt32(parsed.deviceType ?? 0), LyraDeviceType.resolve())
    }
}
