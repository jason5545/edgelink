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
   - do not require them for EdgeLink's own pairing.

