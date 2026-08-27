import Foundation

// Pins the default deviceType Mac advertises over announce + sync-push
// paths. The phone's MiShare router (s2/p.e(RemoteDevice)) buckets by
// KEY_DEVICE_TYPE: 11–17 (Apple family) → j3/i.v() Apple branch (so the
// device surfaces as "MacBook Pro"); ==21 (PC class) → j3/i.L() which
// unconditionally routes to wlanConnect(medium 128) and surfaces as
// "小米筆記型電腦" (pc_xiaomi_device_model_name, vendor_id=34).
//
// Default 14 is the Apple-family choice. The override key stays in App
// target (UserDefaults); the resolver reads it directly. The constant
// lives here so the unit-test bundle (which cannot @testable-import the
// app target) can pin the fallback deterministically.
public enum LyraDeviceType {
    /// Apple family (Mac) — what we want the phone to see us as.
    public static let appleFamily: UInt32 = 14
    /// PC class — fallback if a future routing regression forces it.
    public static let pcClass: UInt32 = 21
    /// UserDefaults key for the debug override.
    public static let overrideKey = "xiaomiDeviceTypeOverride"

    /// Resolves the deviceType Mac should advertise, honoring the debug
    /// override if set. App-target call sites (LyraMeshAnnouncer,
    /// LyraSyncReply) read this so the announce tdi and the sync-push
    /// tdi always agree.
    public static func resolve(overriding override: UInt32? = nil) -> UInt32 {
        if let override, override > 0 { return override }
        let stored = UserDefaults.standard.integer(forKey: overrideKey)
        return stored > 0 ? UInt32(stored) : appleFamily
    }
}
