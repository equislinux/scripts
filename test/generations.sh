#!/usr/bin/env bash
set -euo pipefail

# Generations tests without root (dir backend, fake root tree).
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export X_GEN_BACKEND=dir
export X_GEN_ROOT="$TMP/root"
export X_GEN_STATE="$TMP/state"
export X_GEN_DIR="$X_GEN_STATE/generations"
export X_GEN_CURRENT="$X_GEN_STATE/current"
export X_GEN_SNAPSHOTS="$TMP/snapshots"
export X_GEN_CMDLINE="root=UUID=test rw rootflags=subvol=@"
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

# Fake root tree with the pieces the manifest inspects.
mkdir -p "$X_GEN_ROOT/etc" "$X_GEN_ROOT/home/user/.config" \
         "$X_GEN_ROOT/usr/lib/modules/6.9.0-test" "$X_GEN_ROOT/boot"
printf 'testhost\n' > "$X_GEN_ROOT/etc/hostname"
printf 'v1\n' > "$X_GEN_ROOT/etc/app.conf"
printf 'kernel\n' > "$X_GEN_ROOT/boot/vmlinuz-linux"
printf 'initrd\n' > "$X_GEN_ROOT/boot/initramfs-linux.img"

echo "== creation =="
ID="$(xgen_new test first)"
check "first generation is 0001" test "$ID" = "0001"
check "manifest exists" test -f "$X_GEN_DIR/0001/manifest.json"
check "snapshot exists" test -f "$X_GEN_SNAPSHOTS/0001/etc/app.conf"
check "current points at 0001" test "$(xgen_current)" = "0001"
check "manifest records the cmdline" grep -q 'rootflags=subvol=@' "$X_GEN_DIR/0001/manifest.json"
check "manifest records the kernel release" grep -q '6.9.0-test' "$X_GEN_DIR/0001/manifest.json"
check "kernel archived in metadata" test -f "$X_GEN_DIR/0001/boot/vmlinuz-linux"

echo "== status =="
STATUS="$(xgen_status)"
check "status shows the current generation" grep -q '^current:    0001' <<< "$STATUS"
printf 'v2\n' > "$X_GEN_ROOT/etc/app.conf"
STATUS="$(xgen_status)"
check "status reports /etc drift" grep -q '^drift:' <<< "$STATUS"

echo "== second generation =="
ID2="$(xgen_new test second)"
check "second generation is 0002" test "$ID2" = "0002"
check "second records parent 0001" grep -q '"parent": "0001"' "$X_GEN_DIR/0002/manifest.json"

echo "== list =="
LIST="$(xgen_list)"
check "list shows 0001" grep -q '^0001 ' <<< "$LIST"
check "list marks the current one" grep -q '^0002 \*' <<< "$LIST"

echo "== restore =="
xgen_restore 0001 /etc/app.conf "$X_GEN_ROOT/etc/app.conf"
check "restore brings the old content back" test "$(cat "$X_GEN_ROOT/etc/app.conf")" = "v1"
check "restore keeps a backup of the replaced file" test -f "$X_GEN_ROOT/etc/app.conf.bak.$X_TS"

bash "$SRC/bin/x" gen restore /etc/app.conf --from 0001 --dest "$TMP/out/app.conf" >/dev/null
check "dispatcher restore with --dest" test "$(cat "$TMP/out/app.conf")" = "v1"

if ( xgen_restore 0001 /etc/nope "$TMP/x" ) >/dev/null 2>&1; then
    check "restore of a missing path fails" false
else
    check "restore of a missing path fails" true
fi
if ( xgen_restore 9999 /etc/app.conf "$TMP/x" ) >/dev/null 2>&1; then
    check "restore of an unknown generation fails" false
else
    check "restore of an unknown generation fails" true
fi

echo "== CLI =="
OUT="$(bash "$SRC/bin/x" gen list)"
check "x gen lists generations" grep -q '0001' <<< "$OUT"
bash "$SRC/bin/x" gen new --reason test --label third >/dev/null
check "x gen new creates the next id" test "$(xgen_current)" = "0003"

UNSUP="$(X_GEN_BACKEND=off bash "$SRC/bin/x" gen list)"
check "off backend reports unsupported" grep -q 'not supported' <<< "$UNSUP"

if [[ "$FAIL" -eq 0 ]]; then
    echo "generations: OK"
else
    echo "generations: failures detected"
    exit 1
fi
