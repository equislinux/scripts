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
mkdir -p "$X_GEN_ROOT/home/user/.local/state/x/migrations"
: > "$X_GEN_ROOT/home/user/.local/state/x/migrations/20260101000000-alpha"

echo "== creation =="
ID="$(xgen_new test first)"
check "first generation is 0001" test "$ID" = "0001"
check "manifest exists" test -f "$X_GEN_DIR/0001/manifest.json"
check "snapshot exists" test -f "$X_GEN_SNAPSHOTS/0001/etc/app.conf"
check "current points at 0001" test "$(xgen_current)" = "0001"
check "manifest records the cmdline" grep -q 'rootflags=subvol=@' "$X_GEN_DIR/0001/manifest.json"
check "manifest records the kernel release" grep -q '6.9.0-test' "$X_GEN_DIR/0001/manifest.json"
check "kernel archived in metadata" test -f "$X_GEN_DIR/0001/boot/vmlinuz-linux"
check "manifest records the root subvolume" grep -q '"root_subvol": "/fake/0001"' "$X_GEN_DIR/0001/manifest.json"
check "manifest records migrations" grep -q '"migrations": {"count": 1}' "$X_GEN_DIR/0001/manifest.json"
check "migrations capture lists the marker" grep -q 'user	20260101000000-alpha' "$X_GEN_DIR/0001/migrations.txt"

# From here on, generation 0001 is the running one.
export X_GEN_RUNNING=0001

echo "== status =="
STATUS="$(xgen_status)"
check "status shows the running generation" grep -q '^running:    0001' <<< "$STATUS"
check "status shows the default generation" grep -q '^default:    0001' <<< "$STATUS"
JSON="$(xgen_status_json)"
check "status json reports the backend" grep -q '"backend":"dir"' <<< "$JSON"
check "status json reports the running generation" grep -q '"running":"0001"' <<< "$JSON"
check "status json reports no pending rollback" grep -q '"pending":null' <<< "$JSON"
printf 'v2\n' > "$X_GEN_ROOT/etc/app.conf"
STATUS="$(xgen_status)"
check "status reports /etc drift" grep -q '^drift:' <<< "$STATUS"

echo "== second generation =="
: > "$X_GEN_ROOT/home/user/.local/state/x/migrations/20260102000000-beta"
ID2="$(xgen_new test second)"
check "second generation is 0002" test "$ID2" = "0002"
check "second records parent 0001" grep -q '"parent": "0001"' "$X_GEN_DIR/0002/manifest.json"
check "records do not steal the default boot" test "$(xgen_current)" = "0001"

echo "== verify =="
check "verify matches the generation" xgen_verify 0002
: > "$X_GEN_ROOT/home/user/.local/state/x/migrations/20260103000000-gamma"
VERIFY_OUT="$(xgen_verify 0002 2>&1 || true)"
check "verify reports the migration drift" grep -q '+ user 20260103000000-gamma' <<< "$VERIFY_OUT"
if xgen_verify 0002 >/dev/null 2>&1; then
    check "verify exits non-zero on drift" false
else
    check "verify exits non-zero on drift" true
fi

echo "== list =="
LIST="$(xgen_list)"
check "list shows 0001" grep -q '^0001 ' <<< "$LIST"
check "list marks the default one" grep -q '^0001 \*' <<< "$LIST"
check "list marks the running one" grep -q '^0001 \*r' <<< "$LIST"

echo "== diff =="
printf 'kitty 1.0-1\nfoo 2.0-1\n' > "$X_GEN_DIR/0001/packages.tsv"
printf 'kitty 1.1-1\nbar 3.0-1\n' > "$X_GEN_DIR/0002/packages.tsv"
printf 'svc-a.service\n' > "$X_GEN_DIR/0001/services.txt"
printf 'svc-a.service\nsvc-b.service\n' > "$X_GEN_DIR/0002/services.txt"
DIFF="$(xgen_diff 0001 0002)"
check "diff shows the updated package" grep -q '~ kitty 1.0-1 -> 1.1-1' <<< "$DIFF"
check "diff shows the added package" grep -q '+ bar 3.0-1' <<< "$DIFF"
check "diff shows the removed package" grep -q -- '- foo 2.0-1' <<< "$DIFF"
check "diff shows the added service" grep -q '+ svc-b.service' <<< "$DIFF"
check "diff shows the added migration" grep -q '+ user 20260102000000-beta' <<< "$DIFF"
check "diff shows the /etc hash change" grep -q '^/etc:' <<< "$DIFF"

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

echo "== restore --pkg =="
mkdir -p "$X_GEN_SNAPSHOTS/0001/var/lib/pacman/local/foo-2.0-1" \
         "$X_GEN_SNAPSHOTS/0001/usr/share/foo" \
         "$X_GEN_ROOT/usr/share/foo"
printf '%%FILES%%\nusr/share/foo/\nusr/share/foo/app.conf\n' \
    > "$X_GEN_SNAPSHOTS/0001/var/lib/pacman/local/foo-2.0-1/files"
printf 'pkg-snapshot\n' > "$X_GEN_SNAPSHOTS/0001/usr/share/foo/app.conf"
printf 'pkg-live\n' > "$X_GEN_ROOT/usr/share/foo/app.conf"
xgen_restore_pkg foo 0001 "$X_GEN_ROOT"
check "package restore brings the snapshot file back" \
    test "$(cat "$X_GEN_ROOT/usr/share/foo/app.conf")" = "pkg-snapshot"
check "package restore keeps a backup" \
    test -f "$X_GEN_ROOT/usr/share/foo/app.conf.bak.$X_TS"
if ( xgen_restore_pkg nope 0001 "$X_GEN_ROOT" ) >/dev/null 2>&1; then
    check "restore of an unknown package fails" false
else
    check "restore of an unknown package fails" true
fi

echo "== CLI =="
OUT="$(bash "$SRC/bin/x" gen list)"
check "x gen lists generations" grep -q '0001' <<< "$OUT"
bash "$SRC/bin/x" gen new --reason test --label third >/dev/null
check "x gen new records the next id" test -d "$X_GEN_DIR/0003"

UNSUP="$(X_GEN_BACKEND=off bash "$SRC/bin/x" gen list)"
check "off backend reports unsupported" grep -q 'not supported' <<< "$UNSUP"

echo "== prune by age =="
sed -i 's/"created": ".*"/"created": "2000-01-01T00:00:00Z"/' "$X_GEN_DIR/0002/manifest.json"
DRY="$(xgen_prune 0 1 7)"
check "dry-run lists the old generation" grep -q 'would remove generation 0002' <<< "$DRY"
if grep -q 'would remove generation 0003' <<< "$DRY"; then
    check "dry-run keeps the fresh generation" false
else
    check "dry-run keeps the fresh generation" true
fi
xgen_prune 0 0 7 >/dev/null
check "old generation removed" test ! -d "$X_GEN_DIR/0002"
check "fresh generation kept by age" test -d "$X_GEN_DIR/0003"
check "running generation kept" test -d "$X_GEN_DIR/0001"

if [[ "$FAIL" -eq 0 ]]; then
    echo "generations: OK"
else
    echo "generations: failures detected"
    exit 1
fi
