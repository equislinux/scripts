#!/usr/bin/env bash
set -euo pipefail

# Generation export/import tests without root (dir backend).
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

A="$TMP/a"
B="$TMP/b"
C="$TMP/c"

export X_GEN_BACKEND=dir
export X_GEN_ROOT="$A/root"
export X_GEN_STATE="$A/state"
export X_GEN_DIR="$X_GEN_STATE/generations"
export X_GEN_CURRENT="$X_GEN_STATE/current"
export X_GEN_SNAPSHOTS="$A/snapshots"
export X_GEN_BOOT=off
export X_GEN_CMDLINE="root=UUID=test rw"
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

source "$SRC/install/helpers/xgen.sh"

mkdir -p "$X_GEN_ROOT/etc" "$X_GEN_ROOT/usr/lib/modules/6.9.0-test"
printf 'export-host\n' > "$X_GEN_ROOT/etc/hostname"
printf 'v1\n' > "$X_GEN_ROOT/etc/app.conf"

export X_GEN_LIVE_SUBVOL=/fake/0001
xgen_new install first >/dev/null
unset X_GEN_LIVE_SUBVOL

echo "== export =="
xgen_export 0001 "$TMP/meta.tar.gz" 0 >/dev/null
check "metadata bundle written" test -f "$TMP/meta.tar.gz"
check "bundle carries the manifest" bash -c "tar -tzf '$TMP/meta.tar.gz' | grep -q './manifest.json'"
check "metadata bundle has no snapshot data" bash -c "! tar -tzf '$TMP/meta.tar.gz' | grep -q './snapshot'"
xgen_export 0001 "$TMP/full.tar.gz" 1 >/dev/null
check "full bundle carries the snapshot" bash -c "tar -tzf '$TMP/full.tar.gz' | grep -q './snapshot/'"

echo "== import =="
env X_GEN_BACKEND=dir X_GEN_BOOT=off X_GEN_CMDLINE="$X_GEN_CMDLINE" \
    X_GEN_ROOT="$B/root" X_GEN_STATE="$B/state" X_GEN_DIR="$B/state/generations" \
    X_GEN_CURRENT="$B/state/current" X_GEN_SNAPSHOTS="$B/snapshots" \
    bash "$SRC/bin/x-gen-import.sh" "$TMP/meta.tar.gz" >/dev/null
check "metadata import lands in the target state" test -f "$B/state/generations/0001/manifest.json"
check "metadata import has no snapshot" test ! -e "$B/snapshots/0001"

env X_GEN_BACKEND=dir X_GEN_BOOT=off X_GEN_CMDLINE="$X_GEN_CMDLINE" \
    X_GEN_ROOT="$C/root" X_GEN_STATE="$C/state" X_GEN_DIR="$C/state/generations" \
    X_GEN_CURRENT="$C/state/current" X_GEN_SNAPSHOTS="$C/snapshots" \
    bash "$SRC/bin/x-gen-import.sh" "$TMP/full.tar.gz" >/dev/null
check "full import lands the snapshot" test -f "$C/snapshots/0001/etc/app.conf"
check "full import lands the manifest" test -f "$C/state/generations/0001/manifest.json"

echo "== restore from the imported generation =="
env X_GEN_BACKEND=dir X_GEN_BOOT=off \
    X_GEN_ROOT="$C/root" X_GEN_STATE="$C/state" X_GEN_DIR="$C/state/generations" \
    X_GEN_CURRENT="$C/state/current" X_GEN_SNAPSHOTS="$C/snapshots" \
    bash "$SRC/bin/x" gen restore /etc/app.conf --from 0001 --dest "$TMP/out/app.conf" >/dev/null
check "restore works from the imported generation" test "$(cat "$TMP/out/app.conf")" = "v1"

echo "== duplicates =="
if env X_GEN_BACKEND=dir X_GEN_BOOT=off \
    X_GEN_ROOT="$C/root" X_GEN_STATE="$C/state" X_GEN_DIR="$C/state/generations" \
    X_GEN_CURRENT="$C/state/current" X_GEN_SNAPSHOTS="$C/snapshots" \
    bash "$SRC/bin/x-gen-import.sh" "$TMP/full.tar.gz" >/dev/null 2>&1; then
    check "duplicate import fails" false
else
    check "duplicate import fails" true
fi
env X_GEN_BACKEND=dir X_GEN_BOOT=off X_GEN_CMDLINE="$X_GEN_CMDLINE" \
    X_GEN_ROOT="$C/root" X_GEN_STATE="$C/state" X_GEN_DIR="$C/state/generations" \
    X_GEN_CURRENT="$C/state/current" X_GEN_SNAPSHOTS="$C/snapshots" \
    bash "$SRC/bin/x-gen-import.sh" "$TMP/full.tar.gz" --force >/dev/null
check "duplicate import with --force replaces" test -f "$C/snapshots/0001/etc/app.conf"

if [[ "$FAIL" -eq 0 ]]; then
    echo "generations-export: OK"
else
    echo "generations-export: failures detected"
    exit 1
fi
