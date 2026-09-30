#!/usr/bin/env bash
set -euo pipefail

# Home generation tests (dotfile copies, no root, no btrfs).
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export X_HGEN_HOME="$TMP/home"
export X_HGEN_STATE="$TMP/state"
export X_TS=20260101000000

FAIL=0

check() {
    local desc="$1"
    shift
    if "$@"; then
        printf 'ok - %s\n' "$desc"
    else
        printf 'FAIL - %s\n' "$desc"
        FAIL=1
    fi
}

source "$SRC/install/helpers/xgen-home.sh"

mkdir -p "$X_HGEN_HOME/.config/app" "$X_HGEN_HOME/.config/BraveSoftware/Cache"
printf 'v1\n' > "$X_HGEN_HOME/.config/app/app.conf"
printf 'alias\n' > "$X_HGEN_HOME/.bashrc"
printf 'junk\n' > "$X_HGEN_HOME/.config/BraveSoftware/Cache/junk"

echo "== new =="
ID="$(hgen_new first)"
check "first home generation is 0001" test "$ID" = "0001"
check "manifest exists" test -f "$X_HGEN_STATE/0001/manifest.json"
check "dotfile captured" test -f "$X_HGEN_STATE/0001/files/.config/app/app.conf"
check "excluded cache not captured" test ! -e "$X_HGEN_STATE/0001/files/.config/BraveSoftware/Cache/junk"
check "current points at 0001" test "$(hgen_current)" = "0001"

echo "== drift and second =="
printf 'v2\n' > "$X_HGEN_HOME/.config/app/app.conf"
STATUS="$(hgen_status)"
check "status reports drift" grep -q '^drift:' <<< "$STATUS"
ID2="$(hgen_new second)"
check "second home generation is 0002" test "$ID2" = "0002"
check "current points at 0002" test "$(hgen_current)" = "0002"

echo "== diff =="
DIFF="$(hgen_diff 0001 0002)"
check "diff shows the changed file" grep -q '~ .config/app/app.conf' <<< "$DIFF"

echo "== restore =="
hgen_restore .config/app/app.conf 0001
check "restore brings v1 back" test "$(cat "$X_HGEN_HOME/.config/app/app.conf")" = "v1"
check "restore keeps a backup" test -f "$X_HGEN_HOME/.config/app/app.conf.bak.$X_TS"
hgen_restore "$X_HGEN_HOME/.bashrc" 0001 "$TMP/out-bashrc"
check "absolute path restore with --dest" grep -q alias "$TMP/out-bashrc"
if ( hgen_restore ../escape 0001 ) >/dev/null 2>&1; then
    check "path escape rejected" false
else
    check "path escape rejected" true
fi

echo "== prune =="
hgen_prune 1 1 >/dev/null
check "dry-run keeps 0001" test -d "$X_HGEN_STATE/0001"
hgen_prune 1 0 >/dev/null
check "prune removes the old generation" test ! -d "$X_HGEN_STATE/0001"
check "current generation kept" test -d "$X_HGEN_STATE/0002"

echo "== CLI =="
OUT="$(bash "$SRC/bin/x" home)"
check "x home lists" grep -q '0002' <<< "$OUT"
bash "$SRC/bin/x" home new --label cli >/dev/null
check "x home new records" test -d "$X_HGEN_STATE/0003"
bash "$SRC/bin/x" home restore .bashrc --from 0002 --dest "$TMP/cli-bashrc" >/dev/null
check "x home restore works" grep -q alias "$TMP/cli-bashrc"
OUT="$(bash "$SRC/bin/x" home status)"
check "x home status works" grep -q '^current:    0003' <<< "$OUT"

if [[ "$FAIL" -eq 0 ]]; then
    echo "home-gens: OK"
else
    echo "home-gens: failures detected"
    exit 1
fi
