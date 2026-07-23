# EdgeLink Agent Notes

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
