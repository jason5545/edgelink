# EdgeLink Agent Notes

## Definition of done

- Every completed change must pass the full test suite before it is considered done:
  `cd mac && xcodebuild -project EdgeLink.xcodeproj -scheme EdgeLinkMacTests -configuration Debug -derivedDataPath /private/tmp/edgelink-test-dd test`
  New test files need `xcodegen generate` (from `mac/`) before the suite picks them up.
- Never deploy (`ditto` into `/Applications`) before the full suite is green; deploy only after all tests pass.

## Common paths & commands

- Phone is USB-connected (`adb devices`, adb root available). EdgeLink Android logs:
  `adb shell "run-as com.edgelink.app tail -60 files/diagnostics.log"`
- Mac app logs: `~/Library/Application Support/EdgeLink/diagnostics.log`
- TeleService relay logs (`RelayLog`, call-relay flow) are in the **radio** buffer:
  `adb logcat -b radio -d`
- Debug probe (kills live mirror sessions — reconnect after):
  `adb shell am broadcast -a com.edgelink.app.DEBUG_PROBE_MILINK -p com.edgelink.app [--es command xiaomi.mi_connect.networkingProbe]`
- Call-relay debug props (all inert when empty): `debug.edgelink.relay_filter_accept_all=1`,
  `debug.edgelink.relay_dial_test=<deviceId>`, `debug.edgelink.relay_inject_device=<deviceId>`
- lyra-debug CLI (pcap/parse/keys): build with
  `xcodebuild -project mac/EdgeLink.xcodeproj -scheme LyraDebug -configuration Debug build`,
  binary under `~/Library/Developer/Xcode/DerivedData/EdgeLink-*/Build/Products/Debug/lyra-debug`
- Phone-side APKs for jadx research: `/system/priv-app/TeleService/TeleService.apk` (call relay),
  `/product/priv-app/Mirror/Mirror.apk` (mirror/call provider); existing decompiles under
  `captures/` (e.g. `captures/xiaomi-mirror-device/jadx/`, `captures/mi-connect-service/jadx/`)
- tcpdump on phone: `adb shell "nohup tcpdump -i wlan0 -s 0 -w /sdcard/x.pcap host <mac-ip> >/dev/null 2>&1 &"`,
  then `adb shell pkill tcpdump` and `adb pull`


- **Xiaomi mirror: dim is NOT the issue — do NOT touch dim/power/Hangup-related code** (`AndroidScreenPowerGuard`, dim/brightness logic, MIUI Hangup/synergy power-key paths). Verified 2026-07-28: video keeps flowing with virtual display at brightness 2.44E-4, DIM, even screen_off (official Hangup behavior); static screen → zero frames is normal encoder behavior, not a stall. These areas were painstakingly tuned; changing them historically causes regressions.
- When building the macOS app for local install, use Apple Development Team ID `MW4GWYGX56`.
- Keep `mac/project.yml` as the source of truth for Xcode signing settings, then run `xcodegen generate` from `mac/` after editing it.
- Install the built app into `/Applications` with `ditto`, not Finder drag/drop:
  `ditto /private/tmp/edgelink-derived-data/Build/Products/Debug/EdgeLinkMac.app /Applications/EdgeLinkMac.app`
- The incoming-call UI lives in the main app (`MacIncomingCallPresenter`). The old Mac Catalyst helper `EdgeLinkCallUI.app` was removed; do not rebuild or reinstall it, and delete any stale `/Applications/EdgeLinkCallUI.app` copy.
- Repeated Keychain password prompts usually mean the identity item was created by an old ad-hoc/DerivedData build. Do not delete it, because that changes the device ID and breaks pairing. Launch the stable `/Applications` build once and let `KeychainIdentityStore` migrate the item to the current signed app.

## Xiaomi HyperConnect research artifact

- For Xiaomi HyperConnect / `/Applications/小米互联服务.app` research, read the existing indexed artifact first:
  `captures/xiaomi-hyperconnect/3.0.300-285/index/`
- Start with:
  `index/SUMMARY.md`,
  `index/metadata/app-info.json`,
  `index/metadata/frameworks.tsv`,
  `index/metadata/macho-binaries.tsv`,
  and `index/search/interesting-strings.txt`.
- For binary-specific details, use `index/macho/<safe-binary-name>/` and its `rabin-*`, `otool-*`,
  `objc-headers/`, and `swift-headers/` outputs.
- Do not re-extract or decompile `/Applications/小米互联服务.app` by default. Only rerun
  `tools/extract-xiaomi-hyperconnect.sh` when the local artifact is missing, the installed app version
  changed, or Jason explicitly asks to refresh the extraction.
- `captures/` is intentionally ignored. Do not commit copied Xiaomi binaries or generated
  reverse-engineering output; keep product code clean-room and use these artifacts only as local
  research references.
- The workflow notes live in `cleanroom/xiaomi-hyperconnect/README.md`.

## macOS notification sender icon

- If EdgeLink notifications show a blank sender icon in Notification Center, inspect LaunchServices before changing `UNNotificationContent`, attachments, `LSUIElement`, request identifiers, or private notification APIs. Notification Center resolves the sender icon through the posting bundle ID's LaunchServices record and IconServices, not from `UNNotificationAttachment`.
- Check every registration for `com.edgelink.mac`, including its `path`, `icons`, and `activityTypes`, with:
  `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -dump`
- The healthy state is one `com.edgelink.mac` registration at `/Applications/EdgeLinkMac.app`, with `Contents/Resources/AppIcon.icns`, `CFBundleIconName = AppIcon`, and `NOTIFICATION#MW4GWYGX56:com.edgelink.mac` attached to that record.
- DerivedData and `/private/tmp/edgelink-*` builds can register additional copies under the same bundle ID. A stale copy without icon resources can become the notification activity record and make every notification show a blank icon. Unregister only the known stale EdgeLink paths with `lsregister -f -u <stale-app-path>`, then register the installed app with `lsregister -f /Applications/EdgeLinkMac.app`.
- After repairing the registrations, restart the current user's `usernoted` and `NotificationCenter` processes so they rebuild their sender-icon state. This does not require changing the notification delivery flow.
- IconServices caches by app identity and version. If the registry is clean but the old blank icon remains, increment `CFBundleVersion`, rebuild, reinstall with `ditto`, and register the `/Applications` copy again.
- Do not launch `EdgeLinkMac.app` directly from DerivedData or `/private/tmp`. Always test the signed `/Applications/EdgeLinkMac.app`. If direct debug launching becomes necessary, give debug builds a different bundle ID suffix.
