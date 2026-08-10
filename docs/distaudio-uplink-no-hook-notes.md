# distaudio uplink: why the native runtime never delivers, and the no-hook path

Status as of 2026-08-08. **No-hook path verified live and now the only
path** — the audiomonitor LSPosed hook, its fallback arbitration and the
keepalive loop were removed. Companion to
`mac/Sources/App/LyraDistAudioWFD.swift` +
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
(ELMA framing), builds the audiomonitor-identical AudioTrack
(USAGE_VOICE_COMMUNICATION, flags 2304, 16k mono s16,
setPreferredDevice(TYPE_TELEPHONY)) and writes the PCM directly. This is the
ONLY path — no debug gate, no arbitration property, no fallback.

**2026-08-08: hook and fallback removed.** The old LSPosed feed inside
`com.miui.audiomonitor` (TCP server → AES-ECB →
`DistAudioStream.playCastAudioData`), the `debug.edgelink.call_inject_mode`
arbitration (`CallInjectMode`), the audiomonitor kill/restart in the
injector, and the `AudioMonitorKeepalive` chain (service-side cgroup loop,
AIDL methods, connector start/stop) are all deleted. The module no longer
hooks `com.miui.audiomonitor` (`MiLinkPrivilegeHookPolicy.shouldHook`
returns false for it; remove it from the LSPosed module scope). Accepted
risk: if a future MIUI update refuses the uid-0 telephony route, call uplink
is broken for that call — the injector retries every 2s for the whole call
and logs a heartbeat, so the refusal is visible evidence to fix the route,
not a silent fallback trigger.

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

## 2026-08-10: the native path exists — MirrorCallService PHONERELAY sink

Follow-up research (pulled + jadx'd `captures/audiomonitor/`,
`captures/teleservice/`; disasm libCastService-jni/libmirror-jni) reversed
the "nobody writes 0x100707" conclusion's practical impact:

1. **0x100707 (`Business_IsPhoneRelay`) has exactly one writer**: Mirror.apk
   `i2/C0885B` (CallRelayAudioManager) `setAudioSinkOption(6, 1)` — public
   key 6 → internal 0x100707 via libmirror-jni's option registry — when the
   phone's `com.xiaomi.mirror.relay.G` (MirrorCallService) starts a
   `PHONERELAY` audio sink against the pad. Not reachable via any DistAudio
   RPC (the 8-method `distAudio.*` interface has no setOption/config).
2. **The trigger chain rides the cast DeviceChannel** (the phone passively
   accepts our channel on `com.xiaomi.mirror:cast`; live ours-logcat shows
   `MirrorCallService: sendKeyBytes` → `TYPE_MIRROR_CALL_KEY` to us,
   unanswered): SimpleEventMessage event 23 = ECDH P-256 KeyData JSON
   (`{keyBytes: [X509 SPKI as a Gson byte[] int array], p2pIp, port}` —
   NOT base64: base64 makes the phone's Gson parser throw
   "Expected BEGIN_ARRAY but was STRING at $.keyBytes" and FCs
   com.xiaomi.mirror, live 2026-08-10), event 24/31 = call start /
   sink-start(port), event 25 = stop. ECDH secret → AES key [0..16) + IV
   [16..32).
3. **Media plane**: the sink pulls miplaycast RTSP (same dialect as the
   distaudio server) with LPCM mode 3 = 8 kHz mono
   (`AudioFormats::mTable` entry 3 = {16, 0x1f40, 1} — no 8 kHz AAC encoder
   exists on macOS, and the SDK's PCM path is already proven by the
   distaudio stream). Per-PES IV in PES_private_data; first
   `min(256, len) & ~15` payload bytes AES-128-CBC with the ECDH key/IV
   (AESPART, `TSPacketizer::packetize` @0x19c69c, choseType 4).
4. **Official MIC-as-call-mic verdict**: YES — TeleService
   `connectDistAudioDevice` is bidirectional; remote mic →
   `MiCastClient.onReceiveData` → `DistAudioStream.playCastAudioData` →
   AudioTrack pinned at `TYPE_TELEPHONY`. On this CN build the Mirror.apk
   PHONERELAY sink is the equivalent native terminal hop for relayed calls.

Implemented Mac-side: `LyraMirrorCallRelaySession` (KeyData exchange, call
state from relayCall `update_call_state` callState 4) +
`LyraMirrorCallAudioSource` (RTSP + ff02 PCM TS + AESPART), wired into
`LyraCastTrustSession` (simpleEvent routing). Loopback-verified against
`LyraMirrorCallRelayRole` (the LyraServerKit mock phone).
**Not yet live-verified against the real phone.** CallUplinkInjector stays
as-is until then; note both paths can be live simultaneously during
verification (injector writes PCM fed by the distaudio uplink, the phone's
own sink plays the PHONERELAY stream) — expect double uplink audio on the
first live call; gate the injector after the native path proves out.
