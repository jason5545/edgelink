#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  tools/extract-xiaomi-hyperconnect.sh [APP_PATH]

Environment:
  OUT_ROOT   Output root. Default: captures/xiaomi-hyperconnect
  COPY_RAW   Copy the full .app bundle into raw/. Default: 1
  SAVE_RAW_STRINGS
             Save unfiltered per-binary strings.raw.txt. Default: 0

The script finds com.xiaomi.hyperConnect in /Applications when APP_PATH is omitted.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out_root="${OUT_ROOT:-$repo_root/captures/xiaomi-hyperconnect}"
copy_raw="${COPY_RAW:-1}"
save_raw_strings="${SAVE_RAW_STRINGS:-0}"

plist_value() {
  local plist="$1"
  local key="$2"
  /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true
}

find_app() {
  local candidate
  while IFS= read -r -d '' candidate; do
    [[ -f "$candidate/Contents/Info.plist" ]] || continue
    if [[ "$(plist_value "$candidate/Contents/Info.plist" CFBundleIdentifier)" == "com.xiaomi.hyperConnect" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done < <(find /Applications -maxdepth 1 -name '*.app' -print0)
  return 1
}

app_path="${1:-${APP_PATH:-}}"
if [[ -z "$app_path" ]]; then
  app_path="$(find_app)" || {
    echo "Could not find com.xiaomi.hyperConnect under /Applications" >&2
    exit 1
  }
fi

if [[ ! -d "$app_path" || ! -f "$app_path/Contents/Info.plist" ]]; then
  echo "Not an app bundle: $app_path" >&2
  exit 1
fi

info_plist="$app_path/Contents/Info.plist"
bundle_id="$(plist_value "$info_plist" CFBundleIdentifier)"
short_version="$(plist_value "$info_plist" CFBundleShortVersionString)"
build_version="$(plist_value "$info_plist" CFBundleVersion)"
if [[ "$bundle_id" != "com.xiaomi.hyperConnect" ]]; then
  echo "Unexpected bundle id '$bundle_id' for $app_path" >&2
  exit 1
fi

artifact_name="${short_version:-unknown}-${build_version:-unknown}"
dest="$out_root/$artifact_name"
if [[ -e "$dest" ]]; then
  dest="$out_root/$artifact_name-$(date +%Y%m%d-%H%M%S)"
fi

mkdir -p "$dest"
raw_dir="$dest/raw"
index_dir="$dest/index"
mkdir -p "$raw_dir" "$index_dir"

app_name="$(basename "$app_path")"
raw_app="$raw_dir/$app_name"
if [[ "$copy_raw" != "0" ]]; then
  ditto "$app_path" "$raw_app"
else
  raw_app="$app_path"
fi

run_text() {
  local out="$1"
  shift
  mkdir -p "$(dirname "$out")"
  {
    printf '$'
    printf ' %q' "$@"
    printf '\n\n'
    "$@" </dev/null
    local status=$?
    printf '\n[exit %d]\n' "$status"
  } >"$out" 2>&1 || true
}

safe_name() {
  printf '%s' "$1" | sed 's#[/[:space:]]#_#g; s#[^[:alnum:]_.@+=,-]#_#g'
}

relative_to_app() {
  local path="$1"
  printf '%s' "${path#"$raw_app"/}"
}

is_interesting_binary() {
  local rel="$1"
  case "$rel" in
    Contents/MacOS/*) return 0 ;;
    Contents/PlugIns/*) return 0 ;;
    Contents/Library/SystemExtensions/*) return 0 ;;
    *HC*.framework/*) return 0 ;;
    *Mi*.framework/*) return 0 ;;
    *mi*.framework/*) return 0 ;;
    *dist*.framework/*) return 0 ;;
    *dmsdk.framework/*) return 0 ;;
    *lyra_rpc.framework/*) return 0 ;;
    *miexpress.framework/*) return 0 ;;
    *OneTrack_mac.framework/*) return 0 ;;
    *PermissionManager.framework/*) return 0 ;;
  esac
  return 1
}

interesting_pattern='xiaomi|hyperconnect|hyperConnect|lyra|milink|mi_connect|mico|micontinuity|miexpress|dmsdk|mirror|camera|clipboard|handoff|nearby|share|transfer|rtsp|wfd|miplay|mdns|bonjour|ble|bluetooth|wifi|aware|token|cert|sign|signature|aes|rsa|ecdh|secret|keychain|appgroup|url|scheme|topic|service|rpc|continuity'

cat >"$dest/README.md" <<EOF
# Xiaomi HyperConnect Extraction

- Source app: \`$app_path\`
- Raw snapshot: \`raw/$app_name\`
- Bundle ID: \`$bundle_id\`
- Version: \`$short_version\`
- Build: \`$build_version\`
- Generated: \`$(date -u +%Y-%m-%dT%H:%M:%SZ)\`

Use \`index/\` first. The raw app is present only so the package does not have to be copied from
\`/Applications\` again.

## Useful Entry Points

- \`index/metadata/\`: Info.plist, signatures, entitlements, provisioning profiles, file lists.
- \`index/resources/\`: copied plist/json/strings resources plus JSON-converted plist output.
- \`index/macho/\`: per-binary Mach-O info, linked libraries, imports, symbols, class dumps, Swift dumps,
  and filtered strings.
- \`index/search/interesting-strings.txt\`: cross-binary filtered strings for quick protocol/resource
  searches.

Raw per-binary strings are not saved by default. Re-run with \`SAVE_RAW_STRINGS=1\` if a full strings
dump is needed for every binary.
EOF

metadata_dir="$index_dir/metadata"
resources_dir="$index_dir/resources"
macho_dir="$index_dir/macho"
search_dir="$index_dir/search"
mkdir -p "$metadata_dir" "$resources_dir/raw" "$resources_dir/json" "$macho_dir" "$search_dir"

run_text "$metadata_dir/app-info.plist.txt" plutil -p "$raw_app/Contents/Info.plist"
plutil -convert json -o "$metadata_dir/app-info.json" "$raw_app/Contents/Info.plist" 2>"$metadata_dir/app-info-json.stderr" || true
run_text "$metadata_dir/codesign-main.txt" codesign -dv --verbose=4 "$raw_app"
run_text "$metadata_dir/entitlements-main.xml" codesign -d --entitlements :- "$raw_app"
run_text "$metadata_dir/spctl-main.txt" spctl --assess --type execute --verbose=4 "$raw_app"
run_text "$metadata_dir/file-tree.txt" find "$raw_app" -print
run_text "$metadata_dir/file-manifest.sha256" sh -c 'cd "$1" && find . -type f -print0 | sort -z | xargs -0 shasum -a 256' sh "$raw_app"
run_text "$metadata_dir/disk-usage.txt" du -sh "$raw_app"

if [[ -f "$raw_app/Contents/embedded.provisionprofile" ]]; then
  run_text "$metadata_dir/embedded-provisionprofile.plist" security cms -D -i "$raw_app/Contents/embedded.provisionprofile"
fi

if [[ -f "$raw_app/Contents/PlugIns/ShareExtension.appex/Contents/Info.plist" ]]; then
  run_text "$metadata_dir/share-extension-info.plist.txt" plutil -p "$raw_app/Contents/PlugIns/ShareExtension.appex/Contents/Info.plist"
  plutil -convert json -o "$metadata_dir/share-extension-info.json" "$raw_app/Contents/PlugIns/ShareExtension.appex/Contents/Info.plist" 2>"$metadata_dir/share-extension-info-json.stderr" || true
  run_text "$metadata_dir/codesign-share-extension.txt" codesign -dv --verbose=4 "$raw_app/Contents/PlugIns/ShareExtension.appex"
  run_text "$metadata_dir/entitlements-share-extension.xml" codesign -d --entitlements :- "$raw_app/Contents/PlugIns/ShareExtension.appex"
  if [[ -f "$raw_app/Contents/PlugIns/ShareExtension.appex/Contents/embedded.provisionprofile" ]]; then
    run_text "$metadata_dir/share-extension-provisionprofile.plist" security cms -D -i "$raw_app/Contents/PlugIns/ShareExtension.appex/Contents/embedded.provisionprofile"
  fi
fi

if [[ -f "$raw_app/Contents/Library/SystemExtensions/com.xiaomi.hyperConnect.MiCamera.systemextension/Contents/Info.plist" ]]; then
  sys_ext="$raw_app/Contents/Library/SystemExtensions/com.xiaomi.hyperConnect.MiCamera.systemextension"
  run_text "$metadata_dir/micamera-systemextension-info.plist.txt" plutil -p "$sys_ext/Contents/Info.plist"
  plutil -convert json -o "$metadata_dir/micamera-systemextension-info.json" "$sys_ext/Contents/Info.plist" 2>"$metadata_dir/micamera-systemextension-info-json.stderr" || true
  run_text "$metadata_dir/codesign-micamera-systemextension.txt" codesign -dv --verbose=4 "$sys_ext"
  run_text "$metadata_dir/entitlements-micamera-systemextension.xml" codesign -d --entitlements :- "$sys_ext"
  if [[ -f "$sys_ext/Contents/embedded.provisionprofile" ]]; then
    run_text "$metadata_dir/micamera-systemextension-provisionprofile.plist" security cms -D -i "$sys_ext/Contents/embedded.provisionprofile"
  fi
fi

{
  printf 'name\tpath\tidentifier\tversion\tbuild\n'
  while IFS= read -r -d '' plist; do
    name="$(basename "$(dirname "$(dirname "$plist")")")"
    id="$(plist_value "$plist" CFBundleIdentifier)"
    ver="$(plist_value "$plist" CFBundleShortVersionString)"
    bld="$(plist_value "$plist" CFBundleVersion)"
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$(relative_to_app "$plist")" "$id" "$ver" "$bld"
  done < <(find "$raw_app/Contents" -name Info.plist -print0 | sort -z)
} >"$metadata_dir/bundles.tsv"

{
  printf 'name\tpath\tidentifier\tversion\tbuild\n'
  while IFS= read -r -d '' framework; do
    plist="$framework/Resources/Info.plist"
    [[ -f "$plist" ]] || plist="$framework/Versions/A/Resources/Info.plist"
    id=""
    ver=""
    bld=""
    if [[ -f "$plist" ]]; then
      id="$(plist_value "$plist" CFBundleIdentifier)"
      ver="$(plist_value "$plist" CFBundleShortVersionString)"
      bld="$(plist_value "$plist" CFBundleVersion)"
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$(basename "$framework")" "$(relative_to_app "$framework")" "$id" "$ver" "$bld"
  done < <(find "$raw_app/Contents/Frameworks" -maxdepth 1 -name '*.framework' -print0 | sort -z)
} >"$metadata_dir/frameworks.tsv"

while IFS= read -r -d '' resource; do
  rel="$(relative_to_app "$resource")"
  mkdir -p "$resources_dir/raw/$(dirname "$rel")" "$resources_dir/json/$(dirname "$rel")"
  cp -p "$resource" "$resources_dir/raw/$rel" 2>/dev/null || true
  case "$resource" in
    *.plist|*.strings|*.stringsdict)
      plutil -convert json -o "$resources_dir/json/$rel.json" "$resource" 2>"$resources_dir/json/$rel.stderr" || true
      ;;
    *.json)
      cp -p "$resource" "$resources_dir/json/$rel" 2>/dev/null || true
      plutil -lint "$resource" >"$resources_dir/json/$rel.lint" 2>&1 || true
      ;;
  esac
done < <(find "$raw_app/Contents" -type f \( -name '*.plist' -o -name '*.json' -o -name '*.strings' -o -name '*.stringsdict' \) -print0)

if [[ -f "$raw_app/Contents/Resources/Assets.car" ]]; then
  run_text "$metadata_dir/assets-car-info.json" assetutil --info "$raw_app/Contents/Resources/Assets.car"
fi

binaries_tsv="$metadata_dir/macho-binaries.tsv"
printf 'safe_name\trelative_path\tfile_type\tsha256\n' >"$binaries_tsv"
all_interesting_strings="$search_dir/interesting-strings.txt"
: >"$all_interesting_strings"

while IFS= read -r -d '' binary; do
  if ! file "$binary" | grep -q 'Mach-O'; then
    continue
  fi
  rel="$(relative_to_app "$binary")"
  safe="$(safe_name "$rel")"
  bin_dir="$macho_dir/$safe"
  mkdir -p "$bin_dir"
  file_type="$(file -b "$binary" | sed -n '1p' | tr '\t' ' ' | sed 's/[[:space:]][[:space:]]*/ /g; s/[[:space:]]$//')"
  sha="$(shasum -a 256 "$binary" | awk '{print $1}')"
  printf '%s\t%s\t%s\t%s\n' "$safe" "$rel" "$file_type" "$sha" >>"$binaries_tsv"

  run_text "$bin_dir/file.txt" file "$binary"
  run_text "$bin_dir/lipo-info.txt" lipo -info "$binary"
  run_text "$bin_dir/dwarfdump-uuid.txt" dwarfdump --uuid "$binary"
  run_text "$bin_dir/vtool-build.txt" vtool -show-build "$binary"
  run_text "$bin_dir/otool-libraries.txt" otool -L "$binary"
  run_text "$bin_dir/rabin-info.json" rabin2 -I -j "$binary"
  run_text "$bin_dir/rabin-libraries.txt" rabin2 -l "$binary"
  run_text "$bin_dir/rabin-imports.txt" rabin2 -i "$binary"
  run_text "$bin_dir/rabin-classes.txt" rabin2 -c "$binary"
  run_text "$bin_dir/rabin-classes-header.txt" rabin2 -cc "$binary"
  run_text "$bin_dir/rabin-sections.txt" rabin2 -S "$binary"
  run_text "$bin_dir/rabin-symbols.txt" rabin2 -s "$binary"
  run_text "$bin_dir/nm-external-symbols.txt" nm -gjU "$binary"
  run_text "$bin_dir/nm-external-symbols-demangled.txt" sh -c 'nm -gjU "$1" | xcrun swift-demangle' sh "$binary"
  if [[ "$save_raw_strings" == "1" ]]; then
    run_text "$bin_dir/strings.raw.txt" strings -a "$binary"
    rg -i "$interesting_pattern" "$bin_dir/strings.raw.txt" >"$bin_dir/strings.interesting.txt" || true
  else
    {
      printf '$ strings -a %q | rg -i %q\n\n' "$binary" "$interesting_pattern"
      strings -a "$binary" | rg -i "$interesting_pattern" || true
      printf '\n[exit 0]\n'
    } >"$bin_dir/strings.interesting.txt"
  fi
  {
    printf '\n===== %s =====\n' "$rel"
    cat "$bin_dir/strings.interesting.txt"
  } >>"$all_interesting_strings"

  if is_interesting_binary "$rel"; then
    run_text "$bin_dir/otool-load-commands.txt" otool -l "$binary"
    run_text "$bin_dir/otool-objc.txt" otool -ov "$binary"
    if rg -q 'objc class|objc protocol|objc method' "$bin_dir/rabin-classes.txt"; then
      mkdir -p "$bin_dir/objc-headers"
      run_text "$bin_dir/ipsw-class-dump.txt" ipsw class-dump --arch arm64 "$binary"
      run_text "$bin_dir/ipsw-class-dump-headers.log" ipsw class-dump --arch arm64 --headers --output "$bin_dir/objc-headers" "$binary"
    fi
    if rg -q 'swift class|swift protocol|swift property' "$bin_dir/rabin-classes.txt"; then
      mkdir -p "$bin_dir/swift-headers"
      run_text "$bin_dir/ipsw-swift-dump.txt" ipsw swift-dump --arch arm64 --extra "$binary"
      run_text "$bin_dir/ipsw-swift-dump-demangled.txt" ipsw swift-dump --arch arm64 --extra --demangle "$binary"
      run_text "$bin_dir/ipsw-swift-dump-headers.log" ipsw swift-dump --arch arm64 --headers --output "$bin_dir/swift-headers" "$binary"
    fi
  fi
done < <(find "$raw_app/Contents" -type f -print0 | sort -z)

{
  echo "# Extraction Summary"
  echo
  echo "- Artifact: \`$dest\`"
  echo "- Bundle: \`$bundle_id\`"
  echo "- Version/build: \`$short_version / $build_version\`"
  echo "- Mach-O binaries: \`$(($(wc -l < "$binaries_tsv") - 1))\`"
  echo "- Frameworks: \`$(($(wc -l < "$metadata_dir/frameworks.tsv") - 1))\`"
  echo
  echo "## Fast Files"
  echo
  echo "- \`index/metadata/bundles.tsv\`"
  echo "- \`index/metadata/frameworks.tsv\`"
  echo "- \`index/metadata/macho-binaries.tsv\`"
  echo "- \`index/search/interesting-strings.txt\`"
} >"$index_dir/SUMMARY.md"

echo "$dest"
