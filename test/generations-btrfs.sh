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
CHECKMNT=""
CHECKMNT2=""
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
    for m in "$CHECKMNT2" "$CHECKMNT"; do
        [[ -n "$m" && -d "$m" ]] || continue
        mountpoint -q "$m" && umount "$m"
        rmdir "$m" 2>/dev/null
    done
    mountpoint -q "$TOP/@/home" && umount "$TOP/@/home"
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
btrfs subvolume create "$TOP/@home" >/dev/null
btrfs subvolume create "$TOP/@snapshots" >/dev/null
btrfs subvolume create "$TOP/@xstate" >/dev/null
mkdir -p "$TOP/@/.snapshots" "$TOP/@/home"
mount -o "subvol=@snapshots" "$LOOP" "$TOP/@/.snapshots"
mount -o "subvol=@home" "$LOOP" "$TOP/@/home"

export X_GEN_BACKEND=btrfs
export X_GEN_ROOT="$TOP/@"
export X_GEN_STATE="$TOP/@xstate"
export X_GEN_DIR="$X_GEN_STATE/generations"
export X_GEN_CURRENT="$X_GEN_STATE/current"
export X_GEN_SNAPSHOTS="$TOP/@/.snapshots"
# X_GEN_SUBVOL_PREFIX is deliberately NOT exported: the engine must derive
# /@snapshots from the mount itself.
export X_GEN_BOOT=on
export X_GEN_BOOT_DIR="$X_GEN_ROOT/boot"
export X_GEN_CMDLINE="root=UUID=fake rw rootflags=subvol=/@"
export X_TS=20260101000000

# Fake installed system (with a fake ESP and a home with data).
mkdir -p "$X_GEN_ROOT/etc/default" "$X_GEN_ROOT/boot/loader/entries" \
         "$X_GEN_ROOT/boot/grub" "$X_GEN_ROOT/usr/lib/modules/6.9.0-x"
printf 'btrfs-host\n' > "$X_GEN_ROOT/etc/hostname"
printf 'v1\n' > "$X_GEN_ROOT/etc/app.conf"
printf 'UUID=fake / btrfs rw,noatime,subvolid=256,subvol=/@ 0 0\n' > "$X_GEN_ROOT/etc/fstab"
printf 'GRUB_CMDLINE_LINUX="root=UUID=fake rw rootflags=subvol=/@"\n' > "$X_GEN_ROOT/etc/default/grub"
printf 'kernel\n' > "$X_GEN_ROOT/boot/vmlinuz-linux"
printf 'initrd\n' > "$X_GEN_ROOT/boot/initramfs-linux.img"
printf 'default x.conf\ntimeout 5\n' > "$X_GEN_ROOT/boot/loader/loader.conf"
printf 'keep me\n' > "$X_GEN_ROOT/home/keep.txt"

source "$SRC/install/helpers/xgen.sh"

check "subvol prefix is derived from the mount" test "$(xgen_subvol_prefix)" = "/@snapshots"

echo "== first generation (installer-like, live subvol /@) =="
export X_GEN_LIVE_SUBVOL=/@
ID="$(xgen_new install first)"
unset X_GEN_LIVE_SUBVOL
check "first generation is 0001" test "$ID" = "0001"
check "snapshot 0001 is a btrfs subvolume" btrfs subvolume show "$X_GEN_SNAPSHOTS/0001"
check "manifest records /@ as root subvolume" grep -q '"root_subvol": "/@"' "$X_GEN_DIR/0001/manifest.json"
check "systemd-boot entry written" test -f "$X_GEN_BOOT_DIR/loader/entries/x-gen-0001.conf"
check "running generation boots the live kernel" grep -q 'rootflags=subvol=/@' "$X_GEN_BOOT_DIR/loader/entries/x-gen-0001.conf"
check "rescue entry written" test -f "$X_GEN_BOOT_DIR/loader/entries/x-rescue.conf"
check "grub entry written" grep -q -- '--id x-gen-0001' "$X_GEN_BOOT_DIR/grub/custom.cfg"

export X_GEN_RUNNING=0001
echo "== second generation (bootable, self-consistent snapshot) =="
printf 'v2\n' > "$X_GEN_ROOT/etc/app.conf"
ID2="$(xgen_new upgrade)"
check "second generation is 0002" test "$ID2" = "0002"
check "snapshot 0002 is a btrfs subvolume" btrfs subvolume show "$X_GEN_SNAPSHOTS/0002"
check "snapshot 0002 is writable (bootable restore point)" \
    test "$(btrfs property get "$X_GEN_SNAPSHOTS/0002" ro)" = "ro=false"
check "manifest records the derived /@snapshots/0002" grep -q '"root_subvol": "/@snapshots/0002"' "$X_GEN_DIR/0002/manifest.json"
check "entry 0002 uses the derived subvol" grep -q 'rootflags=subvol=/@snapshots/0002' "$X_GEN_BOOT_DIR/loader/entries/x-gen-0002.conf"
check "frozen kernel copied to the ESP" test -f "$X_GEN_BOOT_DIR/x/gen-0002/vmlinuz-linux"

CHECKMNT="$(mktemp -d)"
mount -o "ro,subvol=/@snapshots/0002" "$LOOP" "$CHECKMNT"
check "snapshot 0002 fstab points at itself" grep -q 'subvol=/@snapshots/0002' "$CHECKMNT/etc/fstab"
check "snapshot 0002 fstab drops the old subvolid" grep -q 'subvolid=' "$CHECKMNT/etc/fstab"
check "snapshot 0002 captures v2" test "$(cat "$CHECKMNT/etc/app.conf")" = "v2"
umount "$CHECKMNT"
rmdir "$CHECKMNT"
CHECKMNT=""

echo "== rollback =="
X_GEN_RUNNING=0001 xgen_rollback 0002
check "safety generation created" test -d "$X_GEN_DIR/0003"
check "default pointer updated" test "$(xgen_current)" = "0002"
check "pending marker written" test "$(xgen_pending)" = "0002"
check "target pinned" test -f "$X_GEN_DIR/0002/pinned"
check "loader default follows the rollback" grep -q '^default x-gen-0002.conf' "$X_GEN_BOOT_DIR/loader/loader.conf"
check "home data untouched by rollback" test "$(cat "$X_GEN_ROOT/home/keep.txt")" = "keep me"

echo "== granular restore from the snapshot =="
printf 'v3\n' > "$X_GEN_ROOT/etc/app.conf"
xgen_restore 0002 /etc/app.conf "$X_GEN_ROOT/etc/app.conf"
check "restore brings v2 back" test "$(cat "$X_GEN_ROOT/etc/app.conf")" = "v2"
check "restore keeps a backup of v3" test -f "$X_GEN_ROOT/etc/app.conf.bak.$X_TS"

echo "== data export / import (btrfs send/receive) =="
xgen_export 0002 "$TMP/gen-0002.tar.gz" 1 >/dev/null
check "data bundle written" test -f "$TMP/gen-0002.tar.gz"
btrfs subvolume delete "$X_GEN_SNAPSHOTS/0002" >/dev/null
rm -rf "$X_GEN_DIR/0002"
check "snapshot 0002 destroyed for the import test" test ! -e "$X_GEN_SNAPSHOTS/0002"
xgen_import "$TMP/gen-0002.tar.gz" >/dev/null
check "import restores the metadata" test -f "$X_GEN_DIR/0002/manifest.json"
check "import restores the snapshot subvolume" btrfs subvolume show "$X_GEN_SNAPSHOTS/0002"
check "imported snapshot is writable again" \
    test "$(btrfs property get "$X_GEN_SNAPSHOTS/0002" ro)" = "ro=false"

CHECKMNT2="$(mktemp -d)"
mount -o "ro,subvol=/@snapshots/0002" "$LOOP" "$CHECKMNT2"
check "imported snapshot carries v2" test "$(cat "$CHECKMNT2/etc/app.conf")" = "v2"
umount "$CHECKMNT2"
rmdir "$CHECKMNT2"
CHECKMNT2=""

echo "== btrfs quotas =="
xgen_quota_init "1G" >/dev/null
check "quota init succeeds" btrfs qgroup show -eF "$X_GEN_SNAPSHOTS"
QOUT="$(xgen_quota_status)"
check "quota status shows the snapshots path" grep -q "$X_GEN_SNAPSHOTS" <<< "$QOUT"
check "quota status shows the exclusive limit" grep -qE '1\.00GiB|1073741824' <<< "$QOUT"
if ( xgen_quota_init "bogus" ) >/dev/null 2>&1; then
    check "invalid quota limit fails" false
else
    check "invalid quota limit fails" true
fi

if [[ "$FAIL" -eq 0 ]]; then
    echo "generations-btrfs: OK"
else
    echo "generations-btrfs: failures detected"
    exit 1
fi
