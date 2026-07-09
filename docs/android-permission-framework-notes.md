# Android Permission Framework Notes

Source inspected locally only:

- Device: Xiaomi `25102PCBEG`
- Android release / SDK: `16` / `36`
- Build fingerprint: `POCO/myron_global/myron:16/BP2A.250605.031.A3/OS3.0.6.0.WPMTWXM:user/release-keys`
- Pulled framework/APK files under ignored path: `captures/android-framework-25102PCBEG/`
- Decompiled local files:
  - `services.jar`
  - `service-permission.jar`
  - `framework-permission-s.jar`
  - `GooglePermissionController.apk`
  - `MiuiPermissionControllerOverlay.apk`

No public AOSP or web sources are used for these notes.

## Bottom Line

There is no normal-app, no-root, silent grant path through `PackageManager` or the exported
PermissionController UI.

The only real non-root path that can programmatically grant runtime permissions is Device Policy:

- EdgeLink is provisioned as Device Owner or Profile Owner, then calls
  `DevicePolicyManager.setPermissionGrantState(...)`.
- Or an existing Device/Profile Owner delegates `delegation-permission-grant` to EdgeLink.

This works for runtime permissions only. It does not silently enable special app access such as
Accessibility, Notification Listener, MediaProjection consent, overlay settings, or
`WRITE_SECURE_SETTINGS`.

## PermissionController

The device uses:

```text
package: com.google.android.permissioncontroller
original-package: com.android.permissioncontroller
```

Important exported UI:

- `GrantPermissionsActivity`
  - accepts `android.content.pm.action.REQUEST_PERMISSIONS`
  - accepts `android.content.pm.action.REQUEST_PERMISSIONS_FOR_OTHER`
  - still creates the user-facing runtime permission dialog
- `RequestRoleActivity`
  - accepts `android.app.role.action.REQUEST_ROLE`
  - accepts default SMS / default dialer compatibility intents

Important service:

- `PermissionControllerServiceImpl`
  - exported with `android.permission.PermissionControllerService`
  - used by the framework as the system PermissionController service
  - not a public bypass for EdgeLink

The runtime grant binder path is still guarded in `PermissionManagerServiceImpl` by
`android.permission.GRANT_RUNTIME_PERMISSIONS` or `android.permission.REVOKE_RUNTIME_PERMISSIONS`.
A normal EdgeLink install cannot hold those permissions.

## Device Policy Path

The local framework shows the Device Policy runtime grant path:

```text
DevicePolicyManagerService.setPermissionGrantState(...)
  -> PolicyEnforcerCallbacks.setPermissionGrantState(...)
  -> PermissionControllerManager.setRuntimePermissionGrantStateByDeviceAdmin(...)
  -> PermissionControllerServiceImpl.onSetRuntimePermissionGrantStateByDeviceAdmin(...)
```

`PermissionControllerServiceImpl` then:

- finds the admin package and target package
- expands split permissions
- checks that the target permission is grantable by admin policy
- grants/revokes the runtime permission group
- marks policy-fixed state as needed

Authorization is enforced before this reaches PermissionController:

- default Device Owner
- Profile Owner
- financed Device Owner for its limited case
- package delegated with `delegation-permission-grant`

Practical EdgeLink integration:

1. Add an optional Device Admin receiver and metadata XML.
2. Add a managed/provisioned mode in Android code.
3. If EdgeLink is Device Owner/Profile Owner, call `setPermissionGrantState` for:
   - `POST_NOTIFICATIONS`
   - `READ_SMS`
   - `RECEIVE_SMS`
   - `SEND_SMS`
4. Keep the current settings handoff flow for:
   - Accessibility service
   - Notification Listener
   - MediaProjection consent
   - overlay permission
   - `WRITE_SETTINGS`
   - `WRITE_SECURE_SETTINGS`

Provisioning from adb is no-root but not zero-touch:

```text
adb shell dpm set-device-owner com.edgelink.app/.EdgeLinkDeviceAdminReceiver
```

This normally requires a fresh/unprovisioned device or a compatible managed setup.

## SMS Role Path

The local `roles.xml` defines `android.app.role.SMS` as a requestable role. If granted, it grants a
large set of role-managed permissions and app-ops, including SMS, phone, contacts, storage,
microphone, camera, notifications, and SMS write app-op.

This is not silent. It goes through `RequestRoleActivity`.

EdgeLink is not currently role-qualified for SMS. The local role definition requires:

- receiver for `android.provider.Telephony.SMS_DELIVER` with `android.permission.BROADCAST_SMS`
- receiver for `android.provider.Telephony.WAP_PUSH_DELIVER` with
  `android.permission.BROADCAST_WAP_PUSH`
- service for `android.intent.action.RESPOND_VIA_MESSAGE` with
  `android.permission.SEND_RESPOND_VIA_MESSAGE`
- activity for `android.intent.action.SENDTO` with `smsto:`

Current EdgeLink only declares `SMS_RECEIVED`, so SMS role would require product work, not just a
permission request change. It also makes EdgeLink the user's default SMS app.

## Xiaomi-Specific Findings

`MiuiPermissionControllerOverlay.apk` is only a static resource overlay targeting
`com.google.android.permissioncontroller`. It changes UI resources/styles and does not expose a
permission grant API.

`MediaProjectionManagerService` has a Xiaomi-specific bypass for `com.milink.service` stopping
behavior. That is package-specific and not reusable by EdgeLink without Xiaomi privileges/signature.

Local follow-up test on the same Xiaomi device:

- The bypass is a direct string check in `MediaProjectionManagerService`:
  `if ("com.milink.service".equals(this.mProjectionGrant.packageName))`.
- `miui-services.jar` provides `MediaProjectionManagerServiceStubImpl`, but it has no editable
  package whitelist. It hard-codes only MIUI cases such as `com.miui.carlink`,
  `com.miui.screenrecorder`, and `com.google.android.googlequicksearchbox`.
- `miui-framework.jar` provides `MiuiScreenProjectionStubImpl`, but that is Xiaomi screen-projection
  window/UI state and blacklist handling. Its settings keys such as `cast_mode_package` and
  `screen_project_in_screening` do not feed the framework `com.milink.service` bypass.
- `device_config` media-projection flags are readable, but shell cannot add arbitrary new flags on
  this user build.
- `cmd appops set com.edgelink.app PROJECT_MEDIA allow` does work from adb shell, and binder
  `media_projection.hasProjectionPermission(uid, package)` changes from `0` to `1`. This is an
  adb/shell provisioning grant for the media-projection app-op, not the Xiaomi `com.milink.service`
  stop-bypass exception.

Practical read: without root/system image patching, EdgeLink cannot add itself to the MiLink
MediaProjection exception. The closest no-root developer/provisioning lever is the shell app-op:

```text
adb shell cmd appops set com.edgelink.app PROJECT_MEDIA allow
```

That can reduce MediaProjection consent friction on a development/provisioned device, but an
ordinary EdgeLink app cannot set it for itself.

DPC follow-up:

- `dpm list-owners` reported `no owners` on the test device.
- EdgeLink cannot currently be set as active admin/profile owner because it does not declare a
  `DeviceAdminReceiver`.
- Even after adding DPC support, `DevicePolicyManager.setPermissionGrantState(...)` only accepts
  runtime permissions. The framework path checks `isRuntimePermission(permission)` before grant.
- `PROJECT_MEDIA` is app-op `OP_PROJECT_MEDIA`, checked by MediaProjection through app-ops, not a
  runtime permission.
- DPC has screen-capture policy controls such as disabling capture, but no public Device Policy API
  to set `PROJECT_MEDIA` to `allow` for itself.

## EdgeLink Repo Touchpoints

Current Android app state:

- `android/app/src/main/AndroidManifest.xml`
  - declares runtime SMS and notification permissions
  - declares Accessibility and Notification Listener services
  - declares special permissions `SYSTEM_ALERT_WINDOW`, `WRITE_SETTINGS`, `WRITE_SECURE_SETTINGS`
- `android/app/src/main/kotlin/com/edgelink/app/MainActivity.kt`
  - runtime prompt flow via `ActivityResultContracts.RequestPermission`
  - SMS runtime prompt via `RequestMultiplePermissions`
- `android/app/src/main/kotlin/com/edgelink/app/EdgeLinkController.kt`
  - opens Notification Listener settings
  - opens Accessibility settings
  - opens write-settings / overlay settings
- `android/app/src/main/kotlin/com/edgelink/app/AndroidSmsSync.kt`
  - checks `READ_SMS` / `RECEIVE_SMS` / `SEND_SMS`

Recommended sequence:

1. Add optional DPC support first if the goal is real automatic runtime grants.
2. Keep it explicitly opt-in, because Device Owner/Profile Owner changes the device management
   model.
3. Consider SMS role only if EdgeLink is meant to become a real default SMS app.
4. Do not chase PermissionController exported activities or Xiaomi overlay resources as hidden
   grant hooks.
