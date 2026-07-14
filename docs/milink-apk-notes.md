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
