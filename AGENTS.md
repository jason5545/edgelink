# EdgeLink Agent Notes

- When building the macOS app for local install, use Apple Development Team ID `MW4GWYGX56`.
- Keep `mac/project.yml` as the source of truth for Xcode signing settings, then run `xcodegen generate` from `mac/` after editing it.
- Install the built app into `/Applications` with `ditto`, not Finder drag/drop:
  `ditto /private/tmp/edgelink-derived-data/Build/Products/Debug/EdgeLinkMac.app /Applications/EdgeLinkMac.app`
