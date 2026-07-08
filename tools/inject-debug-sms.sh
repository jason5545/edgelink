#!/usr/bin/env bash
set -euo pipefail

adb_bin="${ADB:-adb}"
address="${1:-123720}"
if (($# > 0)); then
  shift
fi

if (($# > 0)); then
  text="$*"
else
  text="EdgeLink local SMS test $(date '+%Y-%m-%d %H:%M:%S')"
fi

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

"$adb_bin" shell "am broadcast \
  --receiver-foreground \
  -a com.edgelink.app.DEBUG_INJECT_SMS \
  -n com.edgelink.app/.DebugSmsReceiver \
  --es address $(shell_quote "$address") \
  --es text $(shell_quote "$text")"
