# Xiaomi HyperConnect Local Extraction

This directory records the repeatable extraction flow for Xiaomi HyperConnect on macOS.
The actual app snapshot and generated indexes are local research artifacts under
`captures/xiaomi-hyperconnect/`, which is intentionally git-ignored.

Current local artifact:

```text
captures/xiaomi-hyperconnect/3.0.300-285
```

Source app:

```text
/Applications/小米互联服务.app
```

Captured version:

```text
CFBundleIdentifier: com.xiaomi.hyperConnect
CFBundleShortVersionString: 3.0.300
CFBundleVersion: 285
```

## Rebuild

```bash
tools/extract-xiaomi-hyperconnect.sh
```

The script auto-discovers `com.xiaomi.hyperConnect` under `/Applications`, copies the full `.app`
bundle into `captures/xiaomi-hyperconnect/<version>-<build>/raw/`, then writes searchable indexes to
`captures/xiaomi-hyperconnect/<version>-<build>/index/`.

Useful options:

```bash
COPY_RAW=0 tools/extract-xiaomi-hyperconnect.sh /path/to/小米互联服务.app
SAVE_RAW_STRINGS=1 tools/extract-xiaomi-hyperconnect.sh
OUT_ROOT=/tmp/xiaomi-hyperconnect tools/extract-xiaomi-hyperconnect.sh
```

## Start Here

```text
index/SUMMARY.md
index/metadata/app-info.json
index/metadata/bundles.tsv
index/metadata/frameworks.tsv
index/metadata/macho-binaries.tsv
index/search/interesting-strings.txt
```

For binary-specific work, open:

```text
index/macho/<safe-binary-name>/
```

Each Mach-O directory contains the available mix of:

```text
file.txt
lipo-info.txt
dwarfdump-uuid.txt
vtool-build.txt
otool-libraries.txt
rabin-info.json
rabin-libraries.txt
rabin-imports.txt
rabin-classes.txt
rabin-classes-header.txt
rabin-sections.txt
rabin-symbols.txt
nm-external-symbols.txt
nm-external-symbols-demangled.txt
strings.interesting.txt
objc-headers/
swift-headers/
```

## Notes

- `radare2` and `ipsw` were installed with Homebrew for this workflow.
- The script avoids interactive `ipsw macho info`; on this app it can prompt for architecture and
  consume the parent `find` stream.
- `spctl --assess` may return a non-zero status for the copied app snapshot. Treat that as a
  Gatekeeper assessment result, not as extraction failure.
- Keep copied Xiaomi binaries and generated reverse-engineering output out of product code. Use these
  artifacts as research references only.
