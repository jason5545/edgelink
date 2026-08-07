package com.edgelink.app

// The call-uplink inject (Mac mic -> modem uplink during a relayed call)
// has two implementations that share one TCP endpoint (19307, "ELMA"
// framing):
//
//  - shizuku: the default. The root Shizuku service writes the PCM straight
//             into a USAGE_VOICE_COMMUNICATION AudioTrack routed at
//             TYPE_TELEPHONY — the same terminal path audiomonitor's own
//             DistAudioStream uses — with no LSPosed hook and no distaudio
//             session (the service process is uid 0, which framework
//             permission checks grant like audiomonitor's android.uid.system
//             + MODIFY_PHONE_STATE; verified live 2026-08-07:
//             setPreferredDevice=true, ~32KB/s injected, head climbing).
//  - hook:    automatic fallback only. The LSPosed feed inside
//             com.miui.audiomonitor (DistAudioStream.playCastAudioData).
//
// debug.edgelink.call_inject_mode is the internal arbitration between the
// two, set only by the injector itself: the Shizuku injector owns the
// endpoint while mode=shizuku, and the audiomonitor hook defers. If the
// injector cannot establish the route it writes mode=hook and restarts
// audiomonitor so the fallback feed rebinds.
object CallInjectMode {
    const val PROPERTY = "debug.edgelink.call_inject_mode"
    const val MODE_HOOK = "hook"
    const val MODE_SHIZUKU = "shizuku"

    // The hook listens only when the injector has explicitly handed the
    // endpoint back (fallback). Any other value — including unset — keeps
    // the endpoint with the Shizuku injector.
    fun hookShouldListen(currentMode: String?): Boolean = currentMode == MODE_HOOK

    fun injectorOwnsEndpoint(currentMode: String?): Boolean = currentMode != MODE_HOOK
}
