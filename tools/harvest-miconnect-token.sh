#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  tools/harvest-miconnect-token.sh [--apply]

Pulls the Xiaomi account's miconnect service token from the attached phone
(adb root) and prints or applies the UserDefaults injection EdgeLink reads
via MijiaAccountTokenStore:

  xiaomiMijiaCUserId          (extras.encrypted_user_id)
  xiaomiMijiaServiceToken     (authtokens miconnect, part 1)
  xiaomiMijiaSSecurity        (authtokens miconnect, part 2)
  xiaomiMijiaAccountNumericId (accounts.name for com.xiaomi)

Without --apply the script only prints the `defaults write` commands.
With --apply it writes them into com.edgelink.mac and imports the token
into the EdgeLink Keychain on next app launch enrollment.

Token lifetime is limited (weeks); re-run when enrollment starts failing
with 401/token errors. The enrolled cert itself lasts ~6 months.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

APPLY=0
if [[ "${1:-}" == "--apply" ]]; then
  APPLY=1
fi

command -v adb >/dev/null || { echo "adb not found" >&2; exit 1; }
adb get-state >/dev/null 2>&1 || { echo "no adb device" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

adb shell "su -c 'cp /data/system_ce/0/accounts_ce.db /data/local/tmp/accounts_ce.harvest.db && chmod 644 /data/local/tmp/accounts_ce.harvest.db'" >/dev/null
adb pull /data/local/tmp/accounts_ce.harvest.db "$TMP/accounts.db" >/dev/null
adb shell "su -c 'rm -f /data/local/tmp/accounts_ce.harvest.db'" >/dev/null 2>&1 || true

RAW_TOKEN="$(sqlite3 "$TMP/accounts.db" "select authtoken from authtokens where type='miconnect' limit 1;")"
C_USER_ID="$(sqlite3 "$TMP/accounts.db" "select value from extras where key='encrypted_user_id' limit 1;")"
NUMERIC_ID="$(sqlite3 "$TMP/accounts.db" "select name from accounts where type='com.xiaomi' limit 1;")"

SERVICE_TOKEN="${RAW_TOKEN%%,*}"
SSECURITY="${RAW_TOKEN#*,}"

if [[ -z "$SERVICE_TOKEN" || -z "$SSECURITY" || "$SERVICE_TOKEN" == "$SSECURITY" || -z "$C_USER_ID" || -z "$NUMERIC_ID" ]]; then
  echo "harvest failed: token/cUserId/numericId incomplete" >&2
  exit 1
fi

NOW="$(date +%s)"

if [[ "$APPLY" == "1" ]]; then
  defaults write com.edgelink.mac xiaomiMijiaCUserId "$C_USER_ID"
  defaults write com.edgelink.mac xiaomiMijiaServiceToken "$SERVICE_TOKEN"
  defaults write com.edgelink.mac xiaomiMijiaSSecurity "$SSECURITY"
  defaults write com.edgelink.mac xiaomiMijiaAccountNumericId "$NUMERIC_ID"
  defaults write com.edgelink.mac xiaomiMijiaTokenFetchedAt -float "$NOW"
  echo "applied: cUserId=$C_USER_ID numericId=$NUMERIC_ID serviceToken=${#SERVICE_TOKEN}chars ssecurity=${#SSECURITY}chars"
else
  cat <<CMDS
defaults write com.edgelink.mac xiaomiMijiaCUserId "$C_USER_ID"
defaults write com.edgelink.mac xiaomiMijiaServiceToken "$SERVICE_TOKEN"
defaults write com.edgelink.mac xiaomiMijiaSSecurity "$SSECURITY"
defaults write com.edgelink.mac xiaomiMijiaAccountNumericId "$NUMERIC_ID"
defaults write com.edgelink.mac xiaomiMijiaTokenFetchedAt -float "$NOW"
CMDS
fi
