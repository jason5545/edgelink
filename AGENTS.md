# EdgeLink Agent Notes

- When building the macOS app for local install, use Apple Development Team ID `MW4GWYGX56`.
- Keep `mac/project.yml` as the source of truth for Xcode signing settings, then run `xcodegen generate` from `mac/` after editing it.
- Install the built app into `/Applications` with `ditto`, not Finder drag/drop:
  `ditto /private/tmp/edgelink-derived-data/Build/Products/Debug/EdgeLinkMac.app /Applications/EdgeLinkMac.app`
- Repeated Keychain password prompts usually mean the identity item was created by an old ad-hoc/DerivedData build. Do not delete it, because that changes the device ID and breaks pairing. Launch the stable `/Applications` build once and let `KeychainIdentityStore` migrate the item to the current signed app.
