#!/usr/bin/env bash
set -euo pipefail

# Boot-entry and rollback tests without root (dir backend, fake ESP).
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export X_GEN_BACKEND=dir
export X_GEN_ROOT="$TMP/root"
export X_GEN_STATE="$TMP/state"
export X_GEN_DIR="$X_GEN_STATE/generations"
export X_GEN_CURRENT="$X_GEN_STATE/current"
export X_GEN_SNAPSHOTS="$TMP/snapshots"
export X_GEN_BOOT=on
export X_GEN_BOOT_DIR="$TMP/root/boot"
export X_GEN_BOOT_KEEP=2
export X_GEN_CMDLINE="root=UUID=test rw rootflags=subvol=/@"
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

# Fake root tree + fake ESP with both systemd-boot and GRUB layouts.
mkdir -p "$X_GEN_ROOT/etc" "$X_GEN_ROOT/usr/lib/modules/6.9.0-test" \
         "$X_GEN_BOOT_DIR/loader/entries" "$X_GEN_BOOT_DIR/grub"
printf 'boot-host\n' > "$X_GEN_ROOT/etc/hostname"
printf 'v1\n' > "$X_GEN_ROOT/etc/app.conf"
printf 'kernel\n' > "$X_GEN_BOOT_DIR/vmlinuz-linux"
printf 'initrd\n' > "$X_GEN_BOOT_DIR/initramfs-linux.img"
printf 'default x.conf\ntimeout 5\n' > "$X_GEN_BOOT_DIR/loader/loader.conf"
printf 'stock\n' > "$X_GEN_BOOT_DIR/loader/entries/x.conf"

SB="$X_GEN_BOOT_DIR/loader/entries"
GRUB="$X_GEN_BOOT_DIR/grub"

echo "== first generation (installer-like) =="
export X_GEN_LIVE_SUBVOL=/@
ID="$(xgen_new install first)"
unset X_GEN_LIVE_SUBVOL
check "first generation is 0001" test "$ID" = "0001"
check "systemd-boot entry written" test -f "$SB/x-gen-0001.conf"
check "running generation boots the stock kernel" grep -q '^linux   /vmlinuz-linux' "$SB/x-gen-0001.conf"
check "entry carries its subvolume" grep -q 'rootflags=subvol=/@' "$SB/x-gen-0001.conf"
check "loader default points at 0001" grep -q '^default x-gen-0001.conf' "$X_GEN_BOOT_DIR/loader/loader.conf"
check "x.conf mirrors the default entry" grep -q 'gen 0001' "$X_GEN_BOOT_DIR/loader/entries/x.conf"
check "grub entry written" grep -q 'menuentry "X Linux (gen 0001, install)" --id x-gen-0001' "$GRUB/custom.cfg"
check "grub default points at 0001" grep -q '^set default=x-gen-0001' "$GRUB/custom.cfg"
check "rescue entry written" test -f "$SB/x-rescue.conf"
check "rescue entry targets rescue mode" grep -q 'systemd.unit=rescue.target' "$SB/x-rescue.conf"
check "grub rescue entry written" grep -q -- '--id x-rescue' "$GRUB/custom.cfg"

echo "== frozen generations =="
export X_GEN_RUNNING=0001
printf 'v2\n' > "$X_GEN_ROOT/etc/app.conf"
ID2="$(xgen_new upgrade)"
check "second generation is 0002" test "$ID2" = "0002"
check "frozen generation uses its archived kernel" grep -q '^linux   /x/gen-0002/vmlinuz-linux' "$SB/x-gen-0002.conf"
check "archived kernel copied to the ESP" test -f "$X_GEN_BOOT_DIR/x/gen-0002/vmlinuz-linux"
check "default keeps following the running generation" grep -q '^default x-gen-0001.conf' "$X_GEN_BOOT_DIR/loader/loader.conf"

export X_GEN_RUNNING=0002
xgen_new upgrade >/dev/null
export X_GEN_RUNNING=0003
xgen_new upgrade >/dev/null

echo "== ESP retention =="
check "newest entry kept" test -f "$SB/x-gen-0004.conf"
check "pruned entry removed from the ESP" test ! -f "$SB/x-gen-0002.conf"
check "pruned kernel copy removed" test ! -d "$X_GEN_BOOT_DIR/x/gen-0002"
check "pruned generation keeps its archive snapshot" test -d "$X_GEN_SNAPSHOTS/0002"
check "pruned generation keeps its metadata" test -f "$X_GEN_DIR/0002/manifest.json"
check "default entry is kept" test -f "$SB/x-gen-0001.conf"

echo "== rollback =="
export X_GEN_RUNNING=0004
xgen_rollback 0002
check "safety generation created" test -d "$X_GEN_DIR/0005"
check "entry recreated for the rollback target" test -f "$SB/x-gen-0002.conf"
check "loader default points at the target" grep -q '^default x-gen-0002.conf' "$X_GEN_BOOT_DIR/loader/loader.conf"
check "grub default points at the target" grep -q '^set default=x-gen-0002' "$GRUB/custom.cfg"
check "default pointer updated" test "$(xgen_current)" = "0002"
check "pending marker written" test "$(xgen_pending)" = "0002"
check "target pinned" test -f "$X_GEN_DIR/0002/pinned"
STATUS="$(xgen_status)"
check "status reports the pending rollback" grep -q '^pending:    rollback to 0002 on reboot' <<< "$STATUS"
check "status still reports the running generation" grep -q '^running:    0004' <<< "$STATUS"

export X_GEN_RUNNING=0002
xgen_rollback 0002 --no-safety
check "selecting the running generation clears pending" test ! -f "$X_GEN_STATE/pending"
check "default pointer stays on 0002" test "$(xgen_current)" = "0002"

echo "== pin and prune =="
xgen_pin 0003
check "pin marker written" test -f "$X_GEN_DIR/0003/pinned"
xgen_pin 0003 --unpin
check "unpin removes the marker" test ! -f "$X_GEN_DIR/0003/pinned"
xgen_pin 0003

DRY="$(xgen_prune 1 1)"
check "dry-run lists a removable generation" grep -q 'would remove generation 0001' <<< "$DRY"
check "dry-run removes nothing" test -d "$X_GEN_DIR/0001"
xgen_prune 1 0 >/dev/null
check "prune removes the stale generation" test ! -d "$X_GEN_DIR/0001"
check "prune removes its snapshot" test ! -d "$X_GEN_SNAPSHOTS/0001"
check "prune removes its ESP entry" test ! -f "$SB/x-gen-0001.conf"
check "prune removes the other stale generation" test ! -d "$X_GEN_DIR/0004"
check "pinned generation survives" test -d "$X_GEN_DIR/0003"
check "running/default generation survives" test -d "$X_GEN_DIR/0002"
check "newest generation survives" test -d "$X_GEN_DIR/0005"

echo "== CLI =="
OUT="$(X_GEN_RUNNING=0002 bash "$SRC/bin/x" gen status)"
check "x gen status via dispatcher" grep -q '^running:    0002' <<< "$OUT"
X_GEN_RUNNING=0002 bash "$SRC/bin/x" gen boot >/dev/null
check "x gen boot syncs entries" test -f "$SB/x-gen-0002.conf"
OUT="$(X_GEN_BOOT=off bash "$SRC/bin/x" gen boot)"
check "boot can be disabled" grep -q 'not managed' <<< "$OUT"

if [[ "$FAIL" -eq 0 ]]; then
    echo "generations-boot: OK"
else
    echo "generations-boot: failures detected"
    exit 1
fi
