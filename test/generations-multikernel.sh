#!/usr/bin/env bash
set -euo pipefail

# Multi-kernel tests: linux + linux-lts entries per generation (dir backend).
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
export X_GEN_BOOT_DIR="$X_GEN_ROOT/boot"
export X_GEN_BOOT_KEEP=3
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

# Fake ESP with two kernels and their modules dirs (pkgbase files).
mkdir -p "$X_GEN_ROOT/etc" "$X_GEN_ROOT/boot/loader/entries" "$X_GEN_ROOT/boot/grub" \
         "$X_GEN_ROOT/usr/lib/modules/6.9.0-test" "$X_GEN_ROOT/usr/lib/modules/6.6.0-test"
printf 'multi-host\n' > "$X_GEN_ROOT/etc/hostname"
printf 'linux\n' > "$X_GEN_ROOT/boot/vmlinuz-linux"
printf 'linux-initrd\n' > "$X_GEN_ROOT/boot/initramfs-linux.img"
printf 'lts\n' > "$X_GEN_ROOT/boot/vmlinuz-linux-lts"
printf 'lts-initrd\n' > "$X_GEN_ROOT/boot/initramfs-linux-lts.img"
printf 'linux\n' > "$X_GEN_ROOT/usr/lib/modules/6.9.0-test/pkgbase"
printf 'linux-lts\n' > "$X_GEN_ROOT/usr/lib/modules/6.6.0-test/pkgbase"

SB="$X_GEN_BOOT_DIR/loader/entries"
GRUB="$X_GEN_BOOT_DIR/grub"

echo "== capture =="
export X_GEN_LIVE_SUBVOL=/fake/0001
ID="$(xgen_new install first)"
unset X_GEN_LIVE_SUBVOL
check "first generation is 0001" test "$ID" = "0001"
check "kernels.tsv captures both kernels" test "$(wc -l < "$X_GEN_DIR/0001/boot/kernels.tsv")" = "2"
check "primary kernel is linux (newest release)" \
    grep -q '^linux	6.9.0-test	vmlinuz-linux	initramfs-linux.img$' "$X_GEN_DIR/0001/boot/kernels.tsv"
check "lts kernel captured" \
    grep -q '^linux-lts	6.6.0-test	vmlinuz-linux-lts	initramfs-linux-lts.img$' "$X_GEN_DIR/0001/boot/kernels.tsv"

echo "== running generation entries (stock ESP kernels) =="
check "primary entry written" test -f "$SB/x-gen-0001.conf"
check "primary entry uses vmlinuz-linux" grep -q '^linux   /vmlinuz-linux$' "$SB/x-gen-0001.conf"
check "lts entry written" test -f "$SB/x-gen-0001-linux-lts.conf"
check "lts entry uses vmlinuz-linux-lts" grep -q '^linux   /vmlinuz-linux-lts$' "$SB/x-gen-0001-linux-lts.conf"
check "lts entry uses its own initramfs" grep -q '^initrd  /initramfs-linux-lts.img$' "$SB/x-gen-0001-linux-lts.conf"
check "rescue entry uses the primary kernel" grep -q '^linux   /vmlinuz-linux$' "$SB/x-rescue.conf"

echo "== frozen generation entries (archived per pkgbase) =="
export X_GEN_RUNNING=0001
ID2="$(xgen_new upgrade)"
check "second generation is 0002" test "$ID2" = "0002"
check "primary archived under linux/" test -f "$X_GEN_BOOT_DIR/x/gen-0002/linux/vmlinuz-linux"
check "lts archived under linux-lts/" test -f "$X_GEN_BOOT_DIR/x/gen-0002/linux-lts/vmlinuz-linux-lts"
check "primary entry points at the archive" grep -q '^linux   /x/gen-0002/linux/vmlinuz-linux$' "$SB/x-gen-0002.conf"
check "lts entry points at the archive" grep -q '^linux   /x/gen-0002/linux-lts/vmlinuz-linux-lts$' "$SB/x-gen-0002-linux-lts.conf"
check "grub has both entries" bash -c "grep -q -- '--id x-gen-0002 ' '$GRUB/custom.cfg' && grep -q -- '--id x-gen-0002-linux-lts' '$GRUB/custom.cfg'"

if [[ "$FAIL" -eq 0 ]]; then
    echo "generations-multikernel: OK"
else
    echo "generations-multikernel: failures detected"
    exit 1
fi
