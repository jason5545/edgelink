import EdgeLinkKit
import Foundation
import XCTest
@testable import EdgeLink

// Pins the default deviceType that Mac advertises over announce + sync-push
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
final class LyraDeviceTypeFallbackTests: XCTestCase {
    private let overrideKey = "xiaomiDeviceTypeOverride"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: overrideKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: overrideKey)
        super.tearDown()
    }

    func testMeshAnnouncerDefaultIsAppleFamily() {
        XCTAssertEqual(
            LyraMeshAnnouncer.announcedDeviceType, 14,
            "Mac announce tdi must be 14 (Apple family) so the phone shows the device as 'MacBook Pro' rather than the PC-class fallback '小米筆記型電腦'."
        )
    }

    func testSyncReplyDefaultIsAppleFamily() {
        XCTAssertEqual(
            LyraSyncReply.defaultDeviceType, 14,
            "Mac sync-push tdi must be 14 (Apple family) for the same reason as the announce tdi — the two must agree or the phone's DevRepo entry flips on every exchange."
        )
    }

    func testMeshAnnouncerOverrideForcesPCClass() {
        UserDefaults.standard.set(21, forKey: overrideKey)
        XCTAssertEqual(LyraMeshAnnouncer.announcedDeviceType, 21)
    }

    func testSyncReplyOverrideForcesPCClass() {
        UserDefaults.standard.set(21, forKey: overrideKey)
        XCTAssertEqual(LyraSyncReply.defaultDeviceType, 21)
    }

    // Live 19:50 trace (commit 836316183 base) had type 14 + mDNS TXT
    // already at 0x0e (deviceTypeMacBook). The phone surfaces that as
    // "MacBook Pro" — pinned by XiaomiMiShareDiscoveryPayloadTests. The
    // remaining leg of the chain is the announce/sync-push tdi value
    // (this file); the union must read 14 for the device to land in the
    // Apple bucket end-to-end.
    func testDiscoveryPayloadAndAnnounceAgreeOnType14() throws {
        let data = try XiaomiMiShareDiscoveryAppData.build(
            deviceIdHex: "721572C3",
            displayName: "MacBook Pro"
        )
        let parsed = XiaomiMiShareDiscoveryAppData(data: data)
        XCTAssertEqual(parsed.deviceType, XiaomiMiShareDiscoveryAppData.deviceTypeMacBook)
        XCTAssertEqual(UInt32(parsed.deviceType ?? 0), LyraMeshAnnouncer.announcedDeviceType)
    }
}
