# MiLink APK Notes

Source inspected locally:

- Pulled from device package: `com.milink.service`
- Device package path: `/product/app/MiLinkOS3Global/MiLinkOS3Global.apk`
- Copied to ignored repo path: `captures/milink-apk/MiLinkOS3Global.apk`
- Decoded with apktool: `captures/milink-apk/decoded`
- Decompiled with JADX: `captures/milink-apk/jadx`
- Version: `17.1.2.0.2512232034-global`
- Version code: `1517010200`
- Test device manufacturer/model: `Xiaomi` / `25102PCBEG`

JADX finished with partial decompile errors, but the relevant manifest, XML service configs, and many
Java classes were readable.

## Useful For EdgeLink

### MI/POCO Capability Probe

The most practical Android-side integration point is:

```text
content://com.milink.service.circulate
method: check_permission
arg: common
```

The provider is exported in the MiLink APK manifest without a manifest-level permission:

```text
com.miui.circulate.world.permission.CirculateProvider
authority: com.milink.service.circulate
exported: true
```

Static code shows `check_permission` is a capability check, not a transport API. It validates whether
the local system has enough Xiaomi continuity pieces installed, including `com.xiaomi.mi_connect_service`
and `com.xiaomi.mirror`.

Observed on the Xiaomi test device:

```text
common -> true
recentlist_media -> false
recentlist_app -> true
controlcenter_media -> true
miplay_url_circulate -> true
pad_recentlist_app -> true
recentlist_app_task -> true
```

Practical EdgeLink use:

- Detect Xiaomi/Redmi/POCO first from `Build.MANUFACTURER`, `Build.BRAND`, and `Build.MODEL`.
- If it is a Xiaomi-family device, optionally call `CirculateProvider.check_permission("common")`.
- Treat a `true` result as "Xiaomi continuity stack is present", not as permission to use Xiaomi's
  private transport.
- Report this as peer metadata during pairing/registration, for example:
  - `deviceFamily: "xiaomi"`
  - `xiaomiContinuityAvailable: true`
  - optionally `xiaomiMiPlayUrlCirculate: true`

The provider call must be best-effort. Catch `SecurityException`, `IllegalArgumentException`, and
`UnsupportedOperationException`, then fall back to plain manufacturer detection.

### Settings And User Handoff Entrypoints

The APK exposes a few settings/help activities that can be useful if EdgeLink wants to guide a
MI/POCO user into the native Xiaomi settings:

- `miui.intent.action.MILINK_SETTING`
- `com.milink.service.action.joinNetworking`
- `com.milink.service.deviceworld`
- `milink://com.milink.service/circulate_world`
- `milink://com.milink.service/specification`
- `milink://com.milink.service/specification.float`
- `milink://com.milink.service/specificationOpt.floatOpt`

These are UI affordances only. They should not be required for EdgeLink core pairing or transfer.

### Xiaomi Service Names As Product Clues

The decoded XML configs confirm Xiaomi's continuity stack is built around same-account trusted
services and topics:

- `miHandoff`
- `universalClipboard`
- `NotificationTrans`
- `PairService`
- `cameraCommand`
- `DistDatabaseService`
- `shared_channel`
- `distributedHardware`
- `topic.name:handoff`
- `notifi_trans`

This is useful for understanding behavior and logs, but EdgeLink should keep its own protocol for
clipboard, notifications, file transfer, relay, and screen viewing.

## Not Worth Using Directly

### MiLink Cast Binder Services

`ClientV2PublicService` is exported and looks public, but every meaningful Binder method calls
`BaseClientService.b()` first. That function checks the caller UID package against a hardcoded
signature whitelist.

Observed whitelist packages include:

- `cn.wps.moffice_eng.xiaomi.lite`
- `cn.wps.xiaomi.abroad.lite`
- `cn.wps.moffice_eng`
- Xiaomi wearable / health packages
- `com.xiaomi.milink.autotest`

So this is not a normal third-party API. EdgeLink should not bind to:

- `com.milink.client.ClientService`
- `com.milink.client.ClientV2Service`
- `com.milink.client.ClientV2PublicService`
- `com.milink.client.ClientPhotoService`

### PublicMiLinkProvider

`content://com.milink.service.public` exposes status-like calls such as:

- `milink_casting`
- `is_small_window`
- `is_private_protect`

But the manifest requires:

```text
miui.permission.ACCESS_CAST_PROVIDER
```

Observed from ADB shell:

```text
Permission Denial: opening provider com.milink.data.PublicMiLinkProvider ...
requires miui.permission.ACCESS_CAST_PROVIDER
```

This is not usable for EdgeLink.

### Handoff / Clipboard / Notification / Pair Services

The interesting continuity services are exported, but protected by Xiaomi signature or privileged
permissions:

- `HandoffContinuityService`: `com.xiaomi.permission.BIND_CONTINUITY_LISTENER_SERVICE`
- `SysHandoffControlService`: `com.xiaomi.dist.permission.ACCESS_HANDOFF_CONTROL`
- `NotificationTransService`: `com.xiaomi.permission.BIND_CONTINUITY_LISTENER_SERVICE`
- `PairService`: `com.xiaomi.permission.BIND_CONTINUITY_LISTENER_SERVICE`
- `DistCameraProvider`: `com.xiaomi.dist.permission.DIST_HARDWARE_SERVICE`
- `DistCameraService`: `com.xiaomi.dist.permission.DIST_HARDWARE_SERVICE`

Universal clipboard has an exported provider:

```text
content://com.xiaomi.continuity.universal.clipboard
```

But the implementation expects an existing Xiaomi continuity session, `sessionId`, `itemId`, and an
approved calling app. It is a remote file/blob reader for authorized sessions, not a general clipboard
bridge.

### MiLink Runtime Provider

The runtime layer exposes:

- `content://provider.milink.mi.com/messenger`
- `content://milink.mi.com`
- `milink.intent.action.MESSENGER_SERVICE`

ADB shell can call `provider.milink.mi.com/messenger#ping` and get `code=0`, but shell UID is a
privileged caller and is not representative of a normal EdgeLink app. Static code shows the provider
path is gated by Xiaomi's `PrivilegedPackageManager`, which accepts same-signature/internal packages.

Treat this as private infrastructure.

### App Metadata Provider

`content://com.xiaomi.dist.provider.app_meta` is protected by:

```text
com.xiaomi.dist.permission.ACCESS_APP_META
```

The permission is declared as `normal` in the MiLink APK, so a future probe app could test it by
requesting the permission in its manifest. ADB shell did not have it:

```text
Permission Denial: opening provider com.xiaomi.dist.handoff.AppMetaContentProvider ...
requires com.xiaomi.dist.permission.ACCESS_APP_META
```

Do not rely on this until tested from EdgeLink's actual Android APK.

### Private Native SDKs

The APK ships native libraries that expose attractive APIs, but they are private first-party
infrastructure:

- `libmicontinuity_sdk.so`
- `libidmsdk.so`
- `libmilinkrt.so`
- `libmilink.so`
- `libCastSdk-jni.so`
- `libCastService-jni.so`
- `libmirror-jni.so`
- `libaudiomirror-jni.so`

They include discovery, session, channel, IDM, and mirror primitives, but these paths are tied to
Xiaomi signing, same-account trust, privileged permissions, and private protocol assumptions.

EdgeLink should not link or impersonate them.

## Suggested Implementation Shape

### Root Shizuku Diagnostic Probe

With Shizuku running as root, EdgeLink can run a bounded MiLink diagnostic probe through its
UserService. This is for capability discovery only, not a product dependency on Xiaomi's private SDK.

The current probe allows only these exact `content call` shapes:

- `content://com.milink.service.circulate`, `check_permission`, `common`
- `content://com.milink.service.circulate`, `check_permission`, `miplay_url_circulate`
- `content://provider.milink.mi.com/messenger`, `ping`
- `content://com.milink.service.public`, `milink_casting`

The Android app runs this once when Shizuku reports uid `0`, exposes a manual "MiLink" probe button
in the Shizuku section, and logs each result under `xiaomi.milink.root_probe`.

1. Keep one Android device-family helper:
   - `isXiaomiFamily = manufacturer/brand/model contains xiaomi, redmi, or poco`
   - include normalized manufacturer, brand, model, and product in diagnostics.

2. Add a best-effort Xiaomi capability probe:
   - only run when `isXiaomiFamily` is true.
   - call `content://com.milink.service.circulate` with `check_permission`, `arg = "common"`.
   - optionally call `miplay_url_circulate` as a second signal.
   - never block pairing or transfer on this probe.

3. Keep EdgeLink transport independent:
   - use EdgeLink relay/LAN protocol for files and clipboard.
   - use EdgeLink notification path for notifications.
   - use EdgeLink screen viewer path for screen viewing.

4. On Mac, combine this with the official Xiaomi HyperConnect finding:
   - if Android peer is Xiaomi-family and Mac has `hyperConnect://`, offer an optional native
     "Send with Xiaomi HyperConnect" action for local files.
   - otherwise keep normal EdgeLink transfer visible.

5. Add settings shortcuts only as user affordances:
   - open MiLink settings/help when the user needs to enable Xiaomi's native stack.

### Vector / Xposed Hook Path

Root UID alone is not enough for `provider.milink.mi.com/messenger`. The provider gates calls
through `com.milink.base.utils.p.e(Context, String)`, which checks the caller package against
MiLink's signature/internal/whitelist rules. The Messenger service path similarly checks
`com.milink.base.utils.p.d(Context)` against packages for `Binder.getCallingUid()`.

EdgeLink now ships an opt-in legacy Xposed module entry point:

- `assets/xposed_init` -> `com.edgelink.app.MiLinkPrivilegeXposedHook`
- Scope target: `com.milink.service`
- Runtime process guard: `com.milink.runtime` for `provider.milink.mi.com/messenger`
- Main process guard: `com.milink.service` for `ClientV2PublicService`
- Allowed caller package: `com.edgelink.app`

The hook returns `true` only for EdgeLink as the caller. It does not allow `com.android.shell`,
does not allow arbitrary null callers, and does not patch MiLink's APK on disk. On Android 16 +
KernelSU, this expects a Zygisk/Xposed-compatible runtime such as Vector with a working Zygisk
environment.

### Messenger Provider Transport

MiLink's provider-backed messenger client uses these stable calls:

- Register: `insert content://provider.milink.mi.com/messenger/register`
- Poll: `call content://provider.milink.mi.com`, method
  `content://provider.milink.mi.com/messenger#poll`, arg `<clientNo>`
- Send: `call content://provider.milink.mi.com`, method
  `content://provider.milink.mi.com/messenger#send`, arg `<clientNo>`, extras byte array `dat`
- Unregister: `delete <registeredUriWithoutCodeQuery>`

Registration returns a URI like
`content://provider.milink.mi.com/messenger/register/<uid>-<pid>?code=0`; the final path segment is
the `clientNo`. Poll returns `code`, `has_next`, optional `dat`, and optional `start`.

EdgeLink's current transport probe performs `ping -> register -> poll -> unregister`. It does not
send arbitrary packets yet; `send(dat)` is available internally after a real MiLink packet source is
chosen.

### EdgeLink MiLink Bridge

Xiaomi/HyperConnect discovery is not a required dependency for EdgeLink. On third-party ROMs such as
Xiaomi.eu, MiLink may expose useful local phone-side IPC while still failing to discover the Mac. The
bridge shape is therefore:

- Android uses the privileged MiLink provider/binder paths locally.
- Android reports MiLink capability state over EdgeLink's existing encrypted Mac session.
- Mac treats this as EdgeLink telemetry/control, not as a Xiaomi-discovered peer.

The first bridge envelope is `milink.status`. It reports:

- `route = edgelink.secure`
- `officialDiscoveryRequired = false`
- root/Shizuku probe status
- provider attribution status
- messenger transport status
- public cast binder status

The Android controller keeps the latest status and re-sends it when the secure session connects, so
an early automatic probe is not lost if it runs before the Mac relay session is ready.

The next bridge envelope is `milink.frame`. Once the EdgeLink secure session is established,
Android registers a MiLink messenger client, polls it, and forwards non-empty `dat` frames to Mac as
base64 payloads with `clientNo`, `sequence`, `bytes`, and `hasNext` metadata. The bridge unregisters
the MiLink client when the EdgeLink session ends.

This is intentionally receive-only for now. The provider `send(dat)` helper exists in code, but
EdgeLink should not emit unknown MiLink packets until a real packet source and command contract are
identified.

### Xiaomi Mirror Phone Continuity

Phone continuity is not on the MiLink messenger queue. On this ROM the SDK wrapper points to:

- Provider authority: `com.xiaomi.mirror.callprovider`
- Provider package/class: `com.xiaomi.mirror/.provider.CallProvider`
- Package path: `/product/priv-app/Mirror/Mirror.apk`
- Package UID: `android.uid.system` / appId `1000`

The phone-continuity SDK methods are provider calls:

- `getCallRelayService`
- `queryRemoteDevices`
- `queryRemoteDevice`
- `registerMediaRelayCallback`
- `unregisterMediaRelayCallback`
- `startMediaRelay`
- `stopMediaRelay`
- `setMediaRelayVolume`

`CallProvider` is exported without a manifest-level permission, but it performs an internal method
check in `com.xiaomi.mirror.provider.CallProvider#g(int uid, String method)`. Most methods require a
system/internal UID. `getCallRelayService` is additionally limited to Bluetooth UID `1001` or
packages accepted by `com.xiaomi.mirror.relay.N.c(uid, true)` (`com.android.incallui`,
`com.miui.home`, `com.mi.android.globallauncher`). EdgeLink's Xposed module therefore hooks only
that access check, only inside the `com.xiaomi.mirror` main process, only for caller packages that
resolve to `com.edgelink.app`, and only for the bounded phone-continuity method set above.

`getCallRelayService` returns an `ICallRelayService` binder. In this ROM's `Mirror.apk`,
`sendRelayMessage` and `registerCallRelayListener` are no-ops; `setCallState(int)` forwards into
`MirrorCallService.notifyMirrorCallState`. That binder is mainly the InCallUI/telephony state input
into Mirror, not a full Mac call-control surface by itself.

The actual call audio relay is in `com.xiaomi.mirror.relay.G` (`MirrorCallService`). It already owns
phone state listeners, microphone mute state, audio source/sink startup, ECDH key/port exchange, and
relay active settings. There are two related but different paths:

- Phone-to-pad call flow: `MirrorCallService.F(g0)` registers the opposite terminal when the phone
  sees an `AndroidPad`/PC/iPad/iPhone terminal. The audio implementation uses
  `MirrorControlAudioSource`/`MirrorControlAudioSink` with `PHONERELAY` and device direction
  `PHONE -> PAD` / `PAD -> PHONE`; this matches the official APK behavior where a phone call can
  flow to a Pad.
- Car media relay SDK flow: `startMediaRelay(deviceId)` is implemented in
  `SynergySdkHelperForCar` and requires a supported `AndroidPadCar`/Lyra remote whose
  `is_media_relay` is not `-1`.

EdgeLink currently probes this path by reading the call relay binder descriptor, querying remote
devices through a local `RemoteDeviceInfo` parcelable shim, and registering/unregistering an
`IMediaRelayCallback`. The probe deliberately does not call `setCallState`, `startMediaRelay`, or
`stopMediaRelay`.

For controlled reverse-engineering, the LSPosed module supports a disabled-by-default runtime
spoof:

- `debug.edgelink.mirror_fake_remote=pad` injects one Xiaomi `AndroidPad` remote device with id
  `edgelink-mac-mi-pad` into `queryRemoteDevices`, answers `queryRemoteDevice`, and makes Mirror's
  internal terminal lookup/device-type checks resolve the same fake pad.
- `debug.edgelink.mirror_fake_remote_attach=true` additionally calls
  `MirrorCallService.F(fakePadTerminal)` when the fake pad is prepared. This verifies the official
  phone-to-pad flow's `onOppositeTerminalConnected` gate without directly starting
  `MirrorControlAudioSource`/`MirrorControlAudioSink`.
- `debug.edgelink.mirror_fake_remote_key=true` additionally injects a fake peer event-23 `KeyData`
  through `MirrorCallService.D(strValue)` after the fake pad is attached. This exercises Mirror's
  own ECDH parser and should only log whether `mKey` becomes ready. While this key probe is enabled,
  the module blocks `onCallStart`, `startAudioSource`, and `startAudioSink` unless
  `debug.edgelink.mirror_fake_remote_audio=allow` is explicitly set.
- `debug.edgelink.mirror_fake_remote_using_pad=true` overrides the official `isUsingPad` check only
  inside the fake-pad probe path.
- `debug.edgelink.mirror_fake_remote_call_state=offhook|ringing|idle` dry-runs
  `MirrorCallService.s(state)` after the fake key becomes ready. This is for gate tracing; with the
  default audio guard, off-hook should reach `onCallStart` and then be blocked before audio startup.
- `debug.edgelink.mirror_fake_remote_audio_params=true` logs the `MirrorCallService` audio startup
  fields immediately before the default guard blocks `onCallStart`/source/sink startup. This records
  the candidate opposite id, shared-key length, string fields, int fields, and byte-array sizes
  without exposing key material or starting native audio.
- `debug.edgelink.mirror_fake_remote_audio_start=source|sink|both` keeps the default `onCallStart`
  guard in place but, immediately before blocking `onCallStart`, invokes the narrower native audio
  startup method(s). `true`/`probe` map to `source`. `sink`/`both` require
  `debug.edgelink.mirror_fake_remote_audio_sink_arg=<1..65535>` because the official sink entry
  point takes the peer source port from event `31`.
- `debug.edgelink.mirror_fake_remote_peer_ip=<host>` and
  `debug.edgelink.mirror_fake_remote_peer_port=<1..65535>` override the fake peer `KeyData` endpoint
  that Mirror stores as `n/p`. This is the candidate Mac-side PHONERELAY endpoint.
- `debug.edgelink.mirror_fake_remote_local_ip=<host>` and
  `debug.edgelink.mirror_fake_remote_local_port=<1..65535>` override the local `MirrorCallService`
  source endpoint fields `m/o`. This lets the fake Pad path dry-run with the phone's real WLAN/P2P
  endpoint even when no official Mirror group listener populated `m`.
- `debug.edgelink.mirror_fake_remote=car` injects the same id as `AndroidPadCar` for the separate
  car media-relay path.
- Any empty or unknown value leaves the spoof fully off.

On the current Xiaomi.eu device, `pad` mode has been verified through logcat: `queryRemoteDevices`
returns one `AndroidPad` candidate for `all`, `xiaomi`, and `androidPad`, while `androidPadCar`
stays at zero. With `debug.edgelink.mirror_fake_remote_attach=true`, the attach probe reaches
`MirrorCallService.F(fakePadTerminal)` and logs
`attached=true oppositeId=edgelink-mac-mi-pad`. With
`debug.edgelink.mirror_fake_remote_key=true`, the key probe reaches
`MirrorCallService.D(strValue)` and logs `keyReady=true sharedKeyBytes=32`; audio startup remained
blocked by the default guard. With
`debug.edgelink.mirror_fake_remote_using_pad=true` and
`debug.edgelink.mirror_fake_remote_call_state=offhook`, the call-state dry-run logs
`state=2 usingPad=true audioAllowed=false` and then blocks `onCallStart` before audio startup.
The next probe adds `debug.edgelink.mirror_fake_remote_audio_params=true` so the blocked
`onCallStart` also reports the official PHONERELAY endpoint fields it was about to use. Verified on
device with the debug trigger `com.edgelink.app.DEBUG_PROBE_MILINK`: the fake Pad attaches, the
official ECDH parser reports `keyReady=true sharedKeyBytes=32`, and blocked `onCallStart` logs
`strings=12:m:<blank>,13:n:127.0.0.1 ints=11:l:320,14:o:7102,15:p:7102,16:q:0 byteArrays=17:r:32b`.
From `MirrorCallService.G`, those fields map to local p2p IP `m`, peer p2p IP `n`, audio frame size
`l`, local port `o`, peer port `p`, and shared key `r`.
The follow-up endpoint override keeps the same audio guard but can replace `m/o/n/p` with explicit
phone/Mac values before `onCallStart` is blocked, giving us a safe way to validate the real relay
addresses before allowing `MirrorControlAudioSource`/`MirrorControlAudioSink` to start.
This has been verified with Mac `10.5.50.154` and phone route source `10.5.51.78`: the probe logs
`mirror fake pad audio endpoint override localIp=10.5.51.78 localPort=7102 peerIp=10.5.50.154 peerPort=7102`,
then blocked `onCallStart` reports
`strings=12:m:10.5.51.78,13:n:10.5.50.154 ints=11:l:320,14:o:7102,15:p:7102,16:q:0 byteArrays=17:r:32b`.

The decompiled official `Mirror.apk` confirms the Pad call path. `MirrorCallService.onCallStart`
sets call/mic state, sends the official call event, then starts `MirrorControlAudioSource` through
`X()`. For Pad-like opposite terminals, the phone source later reports its port through display-info
event `110001`; Mirror forwards that as SimpleEvent `31`, and the peer's handler calls `W(port)` to
start `MirrorControlAudioSink`. In other words, spoofing a Mi Pad is the correct door for phone-call
relay, but the spoof still has to provide enough session state, endpoint fields, and RTSP/audio
handshake for the native source/sink to stay up.

The first PHONERELAY wire checks are now verified:

- With `audio_start=both`, endpoint override, and `audio_sink_arg=7102`, Mirror invokes both
  `startAudioSource` and `startAudioSink` while the broader `onCallStart` side effects remain
  blocked by the guard.
- The phone sink connects to the Mac-side peer endpoint `10.5.50.154:7102`.
- A Mac TCP client can connect to the phone source at `10.5.51.78:7102` and receive the official
  `OPTIONS * RTSP/1.0` greeting with `Require: org.wfa.wfd1.0`.
- A temporary Mac RTSP listener on port `7103` receives the phone sink connection, and the phone
  replies `RTSP/1.0 200 OK` to Mac's `OPTIONS`, then sends its own `OPTIONS`.

On macOS, `MiLinkPhoneRelayProbe` is a disabled-by-default listener for this protocol step. It binds
TCP and UDP on port `7102`, logs incoming connections/datagrams to diagnostics with byte count,
fingerprint, and a short hex prefix, parses RTSP messages, answers RTSP requests with `200 OK`, and
sends the minimal `OPTIONS` greeting needed by Xiaomi's PHONERELAY stack. For source-side probing,
hidden defaults can also make the Mac connect out to the phone source:

```text
defaults write com.edgelink.mac phoneRelayProbeEnabled -bool true
defaults write com.edgelink.mac phoneRelayProbePeerHost 10.5.51.78
defaults write com.edgelink.mac phoneRelayProbePeerPort -int 7102
```

The Mac probe now also binds the downlink RTP/RTCP UDP ports `19000-19001` and the source-side
RTCP port `19003`. Port `19002` is reserved for the Mac source RTP sender and is only bound while
that sender is active. The verified phone-source path is:

- Phone sends WFD RTSP `OPTIONS`/`GET_PARAMETER`/`SET_PARAMETER`.
- Mac replies with minimal audio-only WFD parameters and advertises `client_port=19000-19001`.
- Phone accepts Mac `SETUP`/`PLAY` and reports `server_port=26466-26467`.
- Mac receives RTP on UDP `19000` with static RTP payload type `33`.
- RTP payload is MPEG-TS. Each RTP packet payload is a multiple of 188-byte TS packets.
- TS demux identifies one AAC stream at PID `0x1100`.

For an immediate Mac playback path, the probe starts `/opt/homebrew/bin/ffplay` when RTP/MPEG-TS
arrives and writes the TS payload to `ffplay` stdin. This can be disabled with:

```text
defaults write com.edgelink.mac phoneRelayProbePlaybackEnabled -bool false
```

For debugging, the probe also writes a bounded TS capture to `/private/tmp/edgelink-phonerelay.ts`
up to 8 MB by default. This can be disabled with:

```text
defaults write com.edgelink.mac phoneRelayProbeCaptureEnabled -bool false
```

The fake `offhook` dry-run starts the official source encoder but does not provide a real telephony
audio source. In that state, `ffprobe` sees the AAC PID but cannot infer sample rate/channel, and
`ffmpeg` cannot decode useful PCM. A real call is still required to verify whether the phone-source
AAC frames become fully decodable. The downlink phone-to-Mac transport is now wired through RTSP,
RTP, MPEG-TS, and `ffplay`.

For the uplink phone-sink path, Mac now advertises `wfd_presentation_URL` with the Mac's reachable
IPv4 address instead of `localhost`, because the phone has to connect back to that RTSP URL. If the
automatic interface pick is wrong, override it with:

```text
defaults write com.edgelink.mac phoneRelayProbeSourceHost <mac-ip>
```

The verified phone-sink path is slightly different from the earlier WFD assumption. The phone sink
answers Mac `GET_PARAMETER` with `wfd_client_rtp_ports`, for example
`RTP/AVP/UDP;unicast 15550 0 mode=play`. After advertising `wfd_presentation_URL`, the Mac records
that port, sends source-side `SETUP`/`PLAY`, and then starts an experimental AAC/MPEG-TS RTP source
from local UDP `19002` to the phone sink port. On the current Xiaomi EU build the phone replies
`405 Method Not Allowed` to those source-side `SETUP`/`PLAY` requests, but still creates
`MiPlay_RTPSink`, connects back to Mac UDP `19002`, and decodes the incoming AAC stream. Do not treat
those 405 responses as fatal until we find the cleaner official trigger. Source RTP is intentionally
off by default while real-call behavior is still being verified:

```text
defaults write com.edgelink.mac phoneRelayProbeSourceRTPEnabled -bool true
```

The source audio mode defaults to generated silence. For a real Mac-microphone uplink probe, set:

```text
defaults write com.edgelink.mac phoneRelayProbeSourceAudioMode microphone
```

In microphone mode, EdgeLinkMac captures the Mac input through AVAudioEngine, converts it to
48 kHz mono signed 16-bit PCM, pipes that into `ffmpeg`, muxes AAC-LC into MPEG-TS, and packetizes
that TS as RTP payload type `33`. Leave source RTP disabled for normal call-control testing. With it
disabled, the phone mic remains the real phone mic path and the Mac only answers the RTSP negotiation.

For the least-bad real-call standby setup, do not leave the dry-run in `offhook`. Set:

```text
adb -s <device> shell su -c setprop debug.edgelink.mirror_fake_remote_call_state idle
```

Then restart Mirror and trigger the debug receiver explicitly:

```text
adb -s <device> shell am force-stop com.xiaomi.mirror
adb -s <device> shell am broadcast \
  -n com.edgelink.app/com.edgelink.app.DebugMiLinkProbeReceiver \
  -a com.edgelink.app.DEBUG_PROBE_MILINK \
  --receiver-foreground
```

In this state, the verified log is `mirror fake pad key data status keyReady=true sharedKeyBytes=32`
followed by `mirror fake pad call state probe invoking state=0 usingPad=true audioAllowed=false`,
with no `ffplay` process yet. The Mac remains bound on `7102` and `19000-19001`; the first real
off-hook call should trigger the source/sink start and create the `ffplay` process from real call
frames instead of from fake silent frames.

This keeps the experiment bounded: the Mac observes and participates in the RTSP/RTP setup, while
real call control still stays on EdgeLink's own `phone.action` path until the full bidirectional
audio stream contract is identified.

EdgeLink's first phone-control path is separate from Mirror audio relay:

- Mac sends `phone.action` with `action = dial | answer | hangup`.
- Android executes the action through the Shizuku root UserService.
- Android replies with `phone.action.result`.

The Shizuku command policy only allows these exact phone commands:

- `am start -a android.intent.action.CALL -d tel:<digits-or-leading-plus>`
- `input keyevent KEYCODE_HEADSETHOOK`
- `input keyevent KEYCODE_ENDCALL`

This gives EdgeLink a working call-control surface while the Mirror remote-device/session/audio
endpoint is still being filled in. Full call audio relay should stay on the official pad flow, but
the fake Pad has to provide enough real session/message-channel state for the PHONERELAY native
audio source/sink to connect.

The first repeat-call failure was a Mac UI routing issue, not a Telecom rejection. After the
successful outgoing call, later clicks sent `action=answer`, which maps to `KEYCODE_HEADSETHOOK`,
so InCallUI was never asked to dial again. The menu bar UI now keeps the last dialed number, exposes
a separate `重撥` action that sends `dial`, and labels the headset-hook path as `接聽來電`.

### Public Cast Service Binder

MiLink also exposes a public cast SDK binder:

- Service action: `com.milink.sdk.cast.v2.client.public`
- Package: `com.milink.service`
- Implementation: `com.milink.client.ClientV2PublicService`
- Binder descriptor: `com.milink.sdk.cast.v2.IMiLinkCastServiceV2`

The first safe probe binds to the service and reads simple state transactions only:

- `27`: `isAgreePrivacy()`
- `32`: `isAuthDeviceConnecting()`
- `30`: `isVerifyCodeInputShown()`

This verifies the high-level cast SDK IPC path without starting discovery, opening UI, or sending
media/cast commands.

`ClientV2PublicService` still calls `BaseClientService.b()`, which rejects non-whitelisted caller
UIDs with `Uid <uid> is not allowed to call MiLinkCast.` EdgeLink's module hooks that check only in
the MiLink main process and only for caller packages containing `com.edgelink.app`.

### MiShare / Lyra endpoint status

EdgeLinkMac now publishes an experimental `_lyra-mdns._udp.local.` endpoint named `721572C3` with
an official-shaped `AppData` TXT record. Android system NSD can see and resolve this endpoint from
the phone:

- service: `721572C3`
- host: `10.0.0.153`
- port: `5353`
- TXT: `AppData=AkEOchVyw2HyAAUZPxcOBwoDAbTeAQEgIwAjArFFAgtNYWNCb29rIFBybw==`

This proves the Bonjour/mDNS layer is reachable from the phone. It does not prove Xiaomi MiShare /
Lyra accepts EdgeLink as a trusted business endpoint. The phone's MiShare binder still reports the
official cached Mac device `1780C740` with service id `00270525`, and the private MiShare log does
not emit `onDeviceFound()` for `721572C3`.

Treat Xiaomi screen/mirror/file-transfer routes as diagnostics until EdgeLink has a self-contained
Lyra service registration path. The Mac UI should not use the official HyperConnect cached device id
as the primary "view phone screen" path; doing so can leave the user stuck at "Xiaomi service
starting" while no EdgeLink-owned session exists. The primary screen route is EdgeLink's own secure
screen session until the Xiaomi endpoint is verified end-to-end.

The next boundary is MiConnectService's Networking API, not Bonjour. MiShare's Lyra helper registers
`BusinessServiceInfo(serviceName = miLyraShare, service id = 00270525)` through
`com.xiaomi.mi_connect_service/com.xiaomi.continuity.networking.service.NetworkingService`; the
parcel payload is `serviceName`, `packageName`, and `serviceData`. Current MiShare code builds a
9-byte `serviceData` value for `miLyraShare`.

EdgeLink has a raw Binder diagnostic client for this service:

- `edgelink://xiaomi-networking-probe`
  - sends `xiaomi.mi_connect.networkingProbe`
  - reads local trusted-device info, trusted-device list, and service info for `1780C740` and
    `721572C3`
- `edgelink://xiaomi-networking-register`
  - sends `xiaomi.mi_connect.registerLyraService`
  - additionally calls `addServiceInfo(miLyraShare)` with default data `000000001200000103`

For Mirror diagnostics, the phone-side Mirror app has been observed registering
`BusinessServiceInfo(serviceName = cast|synergy, packageName = com.xiaomi.mirror,
serviceData = 0CDDFFFC)`. The debug command therefore accepts
`profile=mirrorCast` or `profile=mirrorSynergy`, and an explicit `servicePackageName` override when
we need to test that exact Mirror-shaped metadata. The default package remains `com.edgelink.app`
so spoofing `com.xiaomi.mirror` is always visible in the command data.

The Xposed module only relaxes `PermissionChecker.checkPermissions(...)` inside
`com.xiaomi.mi_connect_service`, and only when the Binder caller resolves to `com.edgelink.app`.
This keeps the probe bounded: it verifies whether EdgeLink can talk to MiConnectService's metadata
layer without making the official Xiaomi Mac app part of the main flow.
