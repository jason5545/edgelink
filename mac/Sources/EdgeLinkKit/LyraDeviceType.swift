import Foundation

// Pins the default deviceType Mac advertises over announce + sync-push
// paths. The phone's MiShare router (s2/p.e(RemoteDevice)) buckets by
// KEY_DEVICE_TYPE: 11–17 (Apple family) → j3/i.v() Apple branch (so the
// device surfaces as "MacBook Pro"); ==21 (PC class) → j3/i.L() which
// unconditionally routes to wlanConnect(medium 128) and surfaces as
// "小米筆記型電腦" (pc_xiaomi_device_model_name, vendor_id=34).
//
// Default 11 (not 14) is deliberate, live 2026-09-05 20:25: two INDEPENDENT
// phone-side filters hard-accept only deviceType 2/4/11 and silently drop
// everything else, with no pin/pairing exemption:
//   1. TeleService RelayServiceFilterUtils.updateFilteredServiceInfo — the
//      relay map (RING delivery); worked around until now via the
//      pref_device_answered pin.
//   2. InCallUI DistAudioDeviceProvider.isDeviceSupportType — the relay
//      audio route map. With 14 the provider never registers the Mac, so
//      RelayPresenter.connectRelayAudio() finds no route and the call audio
//      stays on the local (DAS-muted) mic — the far end hears nothing even
//      with the full DAS micast uplink flowing. The tdi type is a separate
//      surface from the phys-conn handshake type (LyraMeshAnnouncer pins
//      that to the enrolled cert's 14), so 11 here does not touch pairing.
public enum LyraDeviceType {
    /// Apple family original (Mac) — superseded as the default by 11; kept
    /// as the named constant for tests and future gating work.
    public static let appleFamily: UInt32 = 14
    /// The only Apple-family type the phone's relay/audio filters accept
    /// (2/4/11). Same MiShare routing bucket as 14 (11–17 → j3/i.v()).
    public static let relayAcceptedFamily: UInt32 = 11
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
        return stored > 0 ? UInt32(stored) : relayAcceptedFamily
    }
}
