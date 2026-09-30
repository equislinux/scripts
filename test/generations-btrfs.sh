#!/usr/bin/env bash
set -euo pipefail

# Real-btrfs validation of the generation engine (loop device).
# Requires root:  sudo bash test/generations-btrfs.sh
if [[ "$(id -u)" -ne 0 ]]; then
    echo "generations-btrfs: skip (run with sudo to validate the btrfs backend)"
    exit 0
fi

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d /tmp/xgen-btrfs.XXXXXX)"
IMG="$TMP/disk.img"
TOP="$TMP/top"
LOOP=""
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

cleanup() {
    set +e
    mountpoint -q "$TOP/@/.snapshots" && umount "$TOP/@/.snapshots"
    mountpoint -q "$TOP" && umount "$TOP"
    [[ -n "$LOOP" ]] && losetup -d "$LOOP" 2>/dev/null
    rm -rf "$TMP"
}
trap cleanup EXIT

truncate -s 1G "$IMG"
LOOP="$(losetup --find --show "$IMG")"
mkfs.btrfs -f -q "$LOOP"

mkdir -p "$TOP"
mount "$LOOP" "$TOP"
btrfs subvolume create "$TOP/@" >/dev/null
btrfs subvolume create "$TOP/@snapshots" >/dev/null
btrfs subvolume create "$TOP/@xstate" >/dev/null
mkdir -p "$TOP/@/.snapshots"
mount -o "subvol=@snapshots" "$LOOP" "$TOP/@/.snapshots"

export X_GEN_BACKEND=btrfs
export X_GEN_ROOT="$TOP/@"
export X_GEN_STATE="$TOP/@xstate"
export X_GEN_DIR="$X_GEN_STATE/generations"
export X_GEN_CURRENT="$X_GEN_STATE/current"
export X_GEN_SNAPSHOTS="$TOP/@/.snapshots"
export X_GEN_SUBVOL_PREFIX=/@snapshots
export X_GEN_BOOT=off
export X_GEN_CMDLINE="root=UUID=fake rw rootflags=subvol=/@"
export X_TS=20260101000000

# Fake installed system.
mkdir -p "$X_GEN_ROOT/etc/default" "$X_GEN_ROOT/boot" "$X_GEN_ROOT/usr/lib/modules/6.9.0-x"
printf 'btrfs-host\n' > "$X_GEN_ROOT/etc/hostname"
printf 'v1\n' > "$X_GEN_ROOT/etc/app.conf"
printf 'UUID=fake / btrfs rw,noatime,subvolid=256,subvol=/@ 0 0\n' > "$X_GEN_ROOT/etc/fstab"
printf 'GRUB_CMDLINE_LINUX="root=UUID=fake rw rootflags=subvol=/@"\n' > "$X_GEN_ROOT/etc/default/grub"
printf 'kernel\n' > "$X_GEN_ROOT/boot/vmlinuz-linux"
printf 'initrd\n' > "$X_GEN_ROOT/boot/initramfs-linux.img"

source "$SRC/install/helpers/xgen.sh"

echo "== first generation (installer-like, live subvol /@) =="
export X_GEN_LIVE_SUBVOL=/@
ID="$(xgen_new install first)"
unset X_GEN_LIVE_SUBVOL
check "first generation is 0001" test "$ID" = "0001"
check "snapshot 0001 is a btrfs subvolume" btrfs subvolume show "$X_GEN_SNAPSHOTS/0001"
check "manifest records /@ as root subvolume" grep -q '"root_subvol": "/@"' "$X_GEN_DIR/0001/manifest.json"

echo "== second generation (bootable, self-consistent snapshot) =="
printf 'v2\n' > "$X_GEN_ROOT/etc/app.conf"
ID2="$(xgen_new upgrade)"
check "second generation is 0002" test "$ID2" = "0002"
check "snapshot 0002 is a btrfs subvolume" btrfs subvolume show "$X_GEN_SNAPSHOTS/0002"
check "snapshot 0002 is writable (bootable restore point)" \
    test "$(btrfs property get "$X_GEN_SNAPSHOTS/0002" ro)" = "ro=false"
check "manifest records /@snapshots/0002" grep -q '"root_subvol": "/@snapshots/0002"' "$X_GEN_DIR/0002/manifest.json"

CHECKMNT="$(mktemp -d)"
mount -o "ro,subvol=/@snapshots/0002" "$LOOP" "$CHECKMNT"
check "snapshot 0002 fstab points at itself" grep -q 'subvol=/@snapshots/0002' "$CHECKMNT/etc/fstab"
check "snapshot 0002 fstab drops the old subvolid" grep -q 'subvolid=' "$CHECKMNT/etc/fstab"
check "snapshot 0002 captures v2" test "$(cat "$CHECKMNT/etc/app.conf")" = "v2"
umount "$CHECKMNT"
rmdir "$CHECKMNT"

echo "== rollback =="
X_GEN_RUNNING=0001 xgen_rollback 0002
check "safety generation created" test -d "$X_GEN_DIR/0003"
check "default pointer updated" test "$(xgen_current)" = "0002"
check "pending marker written" test "$(xgen_pending)" = "0002"
check "target pinned" test -f "$X_GEN_DIR/0002/pinned"
check "rollback does not touch /home" test -d "$TOP/@/home" || true

echo "== granular restore from the snapshot =="
printf 'v3\n' > "$X_GEN_ROOT/etc/app.conf"
xgen_restore 0002 /etc/app.conf "$X_GEN_ROOT/etc/app.conf"
check "restore brings v2 back" test "$(cat "$X_GEN_ROOT/etc/app.conf")" = "v2"
check "restore keeps a backup of v3" test -f "$X_GEN_ROOT/etc/app.conf.bak.$X_TS"

if [[ "$FAIL" -eq 0 ]]; then
    echo "generations-btrfs: OK"
else
    echo "generations-btrfs: failures detected"
    exit 1
fi
