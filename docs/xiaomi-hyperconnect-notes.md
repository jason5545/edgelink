# Xiaomi HyperConnect Notes

Source inspected locally:

- `/Applications/小米互联服务.app`
- Copied to ignored repo path: `captures/xiaomi-hyperconnect/小米互联服务.app`
- Bundle ID: `com.xiaomi.hyperConnect`
- Version: `3.0.300` / build `285`
- URL scheme: `hyperConnect`

## Useful For EdgeLink

### MI/POCO Device Profile

EdgeLink should treat Xiaomi, Redmi, and POCO Android devices as one capability family. The
Android app can detect this from `Build.MANUFACTURER`, `Build.BRAND`, and `Build.MODEL`, then pass
that profile to the Mac during pairing or registration metadata.

This should not be a scattered set of manufacturer checks. Prefer one local profile helper on
Android, then one capability flag on the Mac side.

### Official File Transfer Handoff

The bundled Share Extension builds:

```text
hyperConnect://transfer?filePaths=%@
```

It copies shared files into the Xiaomi app group when possible, serializes selected paths, percent
encodes them, and opens the URL. The extension activation rule accepts file URLs, images, and movies,
up to 999 attachments.

Practical EdgeLink use:

- On Mac, detect whether `hyperConnect://` is registered.
- If the paired Android device profile is Xiaomi/Redmi/POCO, offer a "Send with Xiaomi HyperConnect"
  action for local files.
- Generate a URL with `filePaths` as a percent-encoded JSON array of file paths, then hand it to
  `NSWorkspace`.
- Let Xiaomi's app handle target-device selection and transfer.

This is the cleanest integration point found so far because it uses the app's public URL entry
instead of trying to speak Xiaomi's private transport.

### Discovery Strategy Clues

Xiaomi's networking policies use a mix of:

- BLE advertising/discovery
- mDNS advertising/discovery
- Wi-Fi LAN
- Wi-Fi Aware
- restricted WLAN
- remote/cloud fallback

EdgeLink currently has only `_edgelink._tcp` as the LAN service type. For MI/POCO devices, this
suggests we should keep relay fallback visible and not assume LAN discovery will be stable under all
screen/network states. If we add richer LAN pairing later, Xiaomi-style policy windows are a useful
model: short high-intensity discovery after startup/network change, then low-power background mode.

### Existing Screen Share Guard

EdgeLink already has Xiaomi-specific screen-share protection handling:

- `disable_screen_share_protections_for_apps_and_notifications`
- `screen_project_private_on`

Keep this guarded behind `WRITE_SECURE_SETTINGS`. It is still a valid MI/POCO optimization and should
belong under the same device profile if more Xiaomi-specific behavior is added.

## Not Worth Using Directly

### Private Xiaomi SDKs

The app bundles private frameworks such as:

- `micontinuity_sdk`
- `dist_clipboard`
- `miexpress`
- `dmsdk`
- `lyra_rpc`
- `dist_hw_srv`
- `distribute_camera_sdk`

They expose useful concepts, but they are not a stable integration surface for EdgeLink.

The certificates/configs show Xiaomi-owned Android package and signing checks, including
`com.xiaomi.bluetooth`, `com.xiaomi.smarthome`, and Xiaomi release signatures. EdgeLink should not
impersonate these services or link these frameworks.

### Universal Clipboard

The app has a `topic.name:universalClipboard` path, but it rides on Xiaomi's trusted-device/service
layer. EdgeLink should keep its own clipboard sync instead of trying to attach to Xiaomi's topic.

### Virtual Camera / Mirror

The app ships a CMIO System Extension:

- `com.xiaomi.hyperConnect.MiCamera`
- Mach service: `DG75VEYT9V.group.com.xiaomi.hyperConnect`

It also contains WFD/MiPlay mirror strings and distributed camera RPC methods. This is too heavy for
EdgeLink to reuse directly. A reasonable product move is to detect the official Xiaomi app and point
MI/POCO users to it for phone-as-camera or official mirroring, while EdgeLink keeps its own screen
viewer path.

## Suggested Implementation Shape

1. Add an Android `DeviceProfile` helper:
   - `isXiaomiFamily = manufacturer/brand/model contains xiaomi, redmi, or poco`
   - include normalized brand/model fields for diagnostics.

2. Add optional peer capability metadata:
   - Pairing/register metadata can advertise `deviceFamily: "xiaomi"` or capabilities like
     `officialHyperConnectLikelyAvailable`.

3. Add a small Mac bridge:
   - `XiaomiHyperConnectBridge.isInstalled`
   - `XiaomiHyperConnectBridge.openTransfer(fileURLs:)`
   - keep it isolated from EdgeLink's core protocol.

4. Show Xiaomi-specific affordances only when both are true:
   - paired Android profile is Xiaomi/Redmi/POCO
   - Mac has the `hyperConnect` URL scheme registered.

5. Keep fallback behavior unchanged:
   - EdgeLink relay, screen viewer, SMS, notification, clipboard sync should continue to work without
     the Xiaomi app.
