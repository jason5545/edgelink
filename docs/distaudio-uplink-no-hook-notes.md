# distaudio uplink: why the native runtime never delivers, and the no-hook path

Status as of 2026-08-07. **No-hook path verified live and now the default.**
Companion to `mac/Sources/App/LyraDistAudioWFD.swift` +
`android/app/src/main/kotlin/com/edgelink/app/CallUplinkInjector.kt`.

## Question

Mac mic reaches the phone sink intact (parseRTP ok, `ATSParser new Stream
mPID[4352] mType[131]`, `first payload pcm audio`, renderer `ARate 262kbps`
for the whole call), yet `MiPlaySharedMemory` RuntimeToClient `doWritePacket`
stays 0 and the DAS AudioTrack drains 0 frames. Why does the runtime never
hand decoded audio to the call stream?

## Evidence chain (static, from `/tmp/milink` disassembly + audiomonitor jadx)

1. **The official distaudio downlink does not use the shared-memory/renderer
   path at all.** In `IDistAudioManager` (audiomonitor, jadx), remote audio
   is delivered by the Java callback
   `MiCastClient.StateCallback.onReceiveData(MediaData)` →
   `DistAudioStream.playCastAudioData` → `doPlay` (AES-ECB decrypt with
   `ResourceManager.getRemoteKey()`) → `AudioTrack`. The terminal hop is
   `DistAudioStream.createAudioDownlinkStream`: `AudioAttributes(flags=2304,
   usage=USAGE_VOICE_COMMUNICATION, contentType=SPEECH)`, 16k mono s16,
   `setPreferredDevice(getDevices(GET_DEVICES_OUTPUTS).first{type ==
   TYPE_TELEPHONY(18)})`. That is the modem-uplink injection — a plain
   AudioTrack pinned at the telephony sink.

2. **`RuntimeToClient` + `mIsPhoneRelay` belong to the mirror/relay runtime,
   not to the distaudio terminal hop.** `mirror::Renderer`
   (`libCastService-jni.so` @0x1d64f0 and `libaudiomirror-jni.so` @0x22fd40)
   reads `IMirrorOption` keys 0x100408, 0x100706, 0x100707 (= mIsPhoneRelay),
   0x100203, 0x100109 at construction; the `MiPlaySharedMemory_Audio_RuntimeToClient`
   region + `doWritePacket` live in the same lib and feed the *client SDK*
   (`libCastSdk-jni.so` `onGetAudioMMapKey_RuntimeToClient`) which then fires
   `onReceiveData`. So the native gap we observe is specifically
   "runtime → SDK shared memory", one hop *above* the telephony AudioTrack.

3. **Nobody in any examined lib ever sets 0x100707.** Searched
   libCastService-jni, libaudiomirror-jni, libCastSdk-jni, libmilink,
   libmilinkrt, libmisruntime: the only reference is the Renderer *reading*
   it. `ServiceConfigManager::getConfigMap` builds 4 per-(serviceId, role)
   config lambdas (one keyed 0x2000000); none of the string tables contain
   any "phone relay" hint. The flag evidently comes from session/device
   config the official tablet relay negotiates — but note (1): even if we
   got it to 1, it would only enable the shared-memory delivery *into
   onReceiveData*, i.e. it would reproduce what the hook already bypasses.

4. **The real privilege boundary is the telephony route, not the runtime.**
   audiomonitor is `android:sharedUserId="android.uid.system"` with
   `MODIFY_PHONE_STATE` + `CAPTURE_AUDIO_OUTPUT`. Routing an AudioTrack to
   `TYPE_TELEPHONY` is what requires that privilege. The Shizuku user
   service (`com.edgelink.app:shizuku`) runs as uid 0, which framework
   permission checks (`ActivityManager.checkComponentPermission`) grant the
   same way as SYSTEM_UID — so it should be able to replicate the exact
   official terminal hop with no hook and no distaudio session.

## Consequence: no-hook design (implemented and verified live 2026-08-07)

`CallUplinkInjector` (runs inside the root Shizuku service): owns TCP :19307
(same ELMA framing), builds the audiomonitor-identical AudioTrack
(USAGE_VOICE_COMMUNICATION, flags 2304, 16k mono s16,
setPreferredDevice(TYPE_TELEPHONY)) and writes the PCM directly. This is now
the DEFAULT path — no debug gate. Endpoint ownership is arbitrated
internally by `debug.edgelink.call_inject_mode` (set only by the injector);
the audiomonitor hook defers by default and exists purely as the automatic
fallback if the root route is ever refused.

Live verification (IVR call, 2026-08-07 21:07–21:09):
`telephony device found` → `setPreferredDevice=true` → `track playing` →
`injected` climbing at ~32KB/s with `head` (playback head) advancing in
lockstep (16k samples/s), `dropped=0`, IVR heard the Mac mic. uid 0 passes
the telephony-route permission check exactly like android.uid.system.

Two failure modes found and fixed during bring-up:

1. **Endpoint hijack by eviction.** `AndroidDistAudioUplinkForwarder` (this
   app) also connects to 19307 — immediately, silently, without the magic —
   and the original connect-time eviction let that empty connection displace
   the Mac's validated sender 500ms after handshake, resetting the Mac's
   NWConnection for the whole call. Fix: a client only becomes the active
   sender after its ELMA magic validates; unvalidated connections are
   dropped without touching the incumbent.
2. **Mac inject connection had no retry.** Any reset ended inject for the
   rest of the call. Fix: `scheduleInjectRetry` reconnects every 1s until
   stop.
