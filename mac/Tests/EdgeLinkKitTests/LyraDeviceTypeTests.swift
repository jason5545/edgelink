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

    func testDefaultIsRelayAcceptedFamily() {
        // Live 2026-09-05 20:25: with 14 the InCallUI DistAudioDeviceProvider
        // (isDeviceSupportType: 2/4/11) never registers the Mac, so
        // RelayPresenter.connectRelayAudio() no-ops and the call audio
        // stays on the DAS-muted local mic — the far end hears nothing.
        // 11 is the only Apple-family type both phone filters accept.
        XCTAssertEqual(LyraDeviceType.resolve(), 11)
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
        XCTAssertEqual(LyraDeviceType.relayAcceptedFamily, 11)
        XCTAssertEqual(LyraDeviceType.pcClass, 21)
    }

    // Both type surfaces must agree on the relay-accepted Apple-family
    // value: the mDNS discovery TXT (the DAS/InCallUI hardware type) and
    // the announce/sync-push tdi (the DevRepo trusted type). Live
    // 2026-09-05 20:53: tdi alone at 11 left the DAS HardwareInfo at 14
    // (read from the TXT) and the InCallUI filter still rejected the Mac.
    func testDiscoveryPayloadAndResolverAgreeOnType11() throws {
        let data = try XiaomiMiShareDiscoveryAppData.build(
            deviceIdHex: "721572C3",
            displayName: "MacBook Pro"
        )
        let parsed = XiaomiMiShareDiscoveryAppData(data: data)
        XCTAssertEqual(parsed.deviceType, XiaomiMiShareDiscoveryAppData.deviceTypeRelayAccepted)
        XCTAssertEqual(UInt32(parsed.deviceType ?? 0), LyraDeviceType.resolve())
    }
}
