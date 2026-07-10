#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE="$ROOT/assets/branding/edgelink-logo.svg"
ANDROID_DRAWABLE="$ROOT/android/app/src/main/res/drawable"
MAC_ASSETS="$ROOT/mac/Sources/App/Resources/Assets.xcassets"
MAC_APPICON="$MAC_ASSETS/AppIcon.appiconset"
MAC_MENUBAR="$MAC_ASSETS/MenuBarIcon.imageset/MenuBarIcon.svg"
PREVIEW="$ROOT/assets/branding/preview"

for tool in sips xmllint python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing required tool: $tool" >&2
    exit 1
  fi
done

if [ "$(xmllint --xpath 'string(/*[local-name()="svg"]/@viewBox)' "$SOURCE")" != "0 0 108 108" ]; then
  echo "The canonical SVG must use viewBox 0 0 108 108" >&2
  exit 1
fi

svg_attr() {
  element_id=$1
  attribute=$2
  xmllint --xpath "string(//*[local-name()='path'][@id='$element_id']/@$attribute)" "$SOURCE"
}

background_path=$(svg_attr background d)
background_color=$(svg_attr background fill)
left_path=$(svg_attr left-frame d)
left_color=$(svg_attr left-frame fill)
right_path=$(svg_attr right-frame d)
right_color=$(svg_attr right-frame fill)
capsule_path=$(svg_attr link-capsule d)
capsule_color=$(svg_attr link-capsule fill)

mkdir -p "$ANDROID_DRAWABLE" "$MAC_APPICON" "$(dirname "$MAC_MENUBAR")" "$PREVIEW"

render_png() {
  size=$1
  output=$2
  sips -s format png -z "$size" "$size" "$SOURCE" --out "$output" >/dev/null
}

for size in 16 32 64 128 256 512 1024; do
  render_png "$size" "$MAC_APPICON/AppIcon-$size.png"
done
render_png 16 "$PREVIEW/edgelink-logo-16.png"
render_png 32 "$PREVIEW/edgelink-logo-32.png"

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/edgelink-icons.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT INT TERM

foreground_svg="$tmp_dir/foreground.svg"
foreground_png="$tmp_dir/foreground-1080.png"
{
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
  printf '%s\n' '<svg xmlns="http://www.w3.org/2000/svg" width="108" height="108" viewBox="0 0 108 108">'
  printf '  <path fill="%s" fill-rule="evenodd" d="%s" />\n' "$left_color" "$left_path"
  printf '  <path fill="%s" fill-rule="evenodd" d="%s" />\n' "$right_color" "$right_path"
  printf '  <path fill="%s" d="%s" />\n' "$capsule_color" "$capsule_path"
  printf '%s\n' '</svg>'
} > "$foreground_svg"
sips -s format png -z 1080 1080 "$foreground_svg" --out "$foreground_png" >/dev/null

python3 - "$foreground_png" "$MAC_APPICON/AppIcon-1024.png" <<'PY'
import math
import sys
from PIL import Image

foreground = Image.open(sys.argv[1]).convert("RGBA")
center = foreground.width / 2
safe_radius = foreground.width * 33 / 108
furthest = 0.0
for y in range(foreground.height):
    for x in range(foreground.width):
        if foreground.getpixel((x, y))[3] > 8:
            radius = math.hypot(x + 0.5 - center, y + 0.5 - center)
            furthest = max(furthest, radius)
            if radius > safe_radius + 1:
                raise SystemExit(
                    f"Android foreground exceeds the 66 dp safe circle at ({x}, {y})"
                )

app_icon = Image.open(sys.argv[2]).convert("RGBA")
if any(app_icon.getpixel(point)[3] != 0 for point in ((0, 0), (1023, 0), (0, 1023), (1023, 1023))):
    raise SystemExit("macOS AppIcon corners must remain transparent")
bounds = app_icon.getchannel("A").getbbox()
if bounds is None or any(abs(actual - expected) > 2 for actual, expected in zip(bounds, (100, 100, 924, 924))):
    raise SystemExit(f"macOS AppIcon bounds are {bounds}, expected approximately (100, 100, 924, 924)")

print(f"Android safe-circle check: max radius {furthest / foreground.width * 108:.2f} dp <= 33 dp")
print(f"macOS AppIcon opaque bounds: {bounds}")
PY

{
  printf '%s\n' '<?xml version="1.0" encoding="utf-8"?>'
  printf '%s\n' '<vector xmlns:android="http://schemas.android.com/apk/res/android"'
  printf '%s\n' '  android:width="108dp"'
  printf '%s\n' '  android:height="108dp"'
  printf '%s\n' '  android:viewportWidth="108"'
  printf '%s\n' '  android:viewportHeight="108">'
  printf '  <path android:fillColor="%s" android:pathData="%s" />\n' "$background_color" "$background_path"
  printf '  <path android:fillColor="%s" android:fillType="evenOdd" android:pathData="%s" />\n' "$left_color" "$left_path"
  printf '  <path android:fillColor="%s" android:fillType="evenOdd" android:pathData="%s" />\n' "$right_color" "$right_path"
  printf '  <path android:fillColor="%s" android:pathData="%s" />\n' "$capsule_color" "$capsule_path"
  printf '%s\n' '</vector>'
} > "$ANDROID_DRAWABLE/ic_edgelink_logo.xml"

{
  printf '%s\n' '<?xml version="1.0" encoding="utf-8"?>'
  printf '%s\n' '<vector xmlns:android="http://schemas.android.com/apk/res/android"'
  printf '%s\n' '  android:width="108dp"'
  printf '%s\n' '  android:height="108dp"'
  printf '%s\n' '  android:viewportWidth="108"'
  printf '%s\n' '  android:viewportHeight="108">'
  printf '  <path android:fillColor="%s" android:fillType="evenOdd" android:pathData="%s" />\n' "$left_color" "$left_path"
  printf '  <path android:fillColor="%s" android:fillType="evenOdd" android:pathData="%s" />\n' "$right_color" "$right_path"
  printf '  <path android:fillColor="%s" android:pathData="%s" />\n' "$capsule_color" "$capsule_path"
  printf '%s\n' '</vector>'
} > "$ANDROID_DRAWABLE/ic_launcher_foreground.xml"

{
  printf '%s\n' '<?xml version="1.0" encoding="utf-8"?>'
  printf '%s\n' '<vector xmlns:android="http://schemas.android.com/apk/res/android"'
  printf '%s\n' '  android:width="108dp"'
  printf '%s\n' '  android:height="108dp"'
  printf '%s\n' '  android:viewportWidth="108"'
  printf '%s\n' '  android:viewportHeight="108">'
  printf '  <path android:fillColor="#FF000000" android:fillType="evenOdd" android:pathData="%s" />\n' "$left_path"
  printf '  <path android:fillColor="#FF000000" android:fillType="evenOdd" android:pathData="%s" />\n' "$right_path"
  printf '  <path android:fillColor="#FF000000" android:pathData="%s" />\n' "$capsule_path"
  printf '%s\n' '</vector>'
} > "$ANDROID_DRAWABLE/ic_launcher_monochrome.xml"

{
  printf '%s\n' '<?xml version="1.0" encoding="utf-8"?>'
  printf '%s\n' '<vector xmlns:android="http://schemas.android.com/apk/res/android"'
  printf '%s\n' '  android:width="24dp"'
  printf '%s\n' '  android:height="24dp"'
  printf '%s\n' '  android:viewportWidth="108"'
  printf '%s\n' '  android:viewportHeight="108">'
  printf '%s\n' '  <group android:pivotX="54" android:pivotY="54" android:scaleX="1.32" android:scaleY="1.32">'
  printf '    <path android:fillColor="#FFFFFFFF" android:fillType="evenOdd" android:pathData="%s" />\n' "$left_path"
  printf '    <path android:fillColor="#FFFFFFFF" android:fillType="evenOdd" android:pathData="%s" />\n' "$right_path"
  printf '    <path android:fillColor="#FFFFFFFF" android:pathData="%s" />\n' "$capsule_path"
  printf '%s\n' '  </group>'
  printf '%s\n' '</vector>'
} > "$ANDROID_DRAWABLE/ic_stat_edgelink.xml"

{
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
  printf '%s\n' '<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 108 108">'
  printf '%s\n' '  <g transform="translate(54 54) scale(1.32) translate(-54 -54)">'
  printf '    <path fill="#000" fill-rule="evenodd" d="%s" />\n' "$left_path"
  printf '    <path fill="#000" fill-rule="evenodd" d="%s" />\n' "$right_path"
  printf '    <path fill="#000" d="%s" />\n' "$capsule_path"
  printf '%s\n' '  </g>'
  printf '%s\n' '</svg>'
} > "$MAC_MENUBAR"

xmllint --noout \
  "$SOURCE" \
  "$ANDROID_DRAWABLE/ic_edgelink_logo.xml" \
  "$ANDROID_DRAWABLE/ic_launcher_foreground.xml" \
  "$ANDROID_DRAWABLE/ic_launcher_monochrome.xml" \
  "$ANDROID_DRAWABLE/ic_stat_edgelink.xml" \
  "$MAC_MENUBAR"

echo "Generated EdgeLink icons from $SOURCE"
