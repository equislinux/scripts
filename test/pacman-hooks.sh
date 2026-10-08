#!/usr/bin/env bash
set -euo pipefail

# Pacman hook wrapper tests, without root (dir backend + fake state).
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export X_GEN_BACKEND=dir
export X_GEN_ROOT="$TMP/root"
export X_GEN_STATE="$TMP/state"
export X_GEN_DIR="$X_GEN_STATE/generations"
export X_GEN_CURRENT="$X_GEN_STATE/current"
export X_GEN_SNAPSHOTS="$TMP/snapshots"
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
printf 'hook-host\n' > "$X_GEN_ROOT/etc/hostname"
printf 'v1\n' > "$X_GEN_ROOT/etc/app.conf"

echo "== guards =="
X_GEN_CLI="$SRC/bin/x" bash "$SRC/hooks/pacman-gen.sh" post
check "no current generation -> no-op" test ! -d "$X_GEN_DIR/0001"

export X_GEN_LIVE_SUBVOL=/fake/0001
xgen_new install first >/dev/null
unset X_GEN_LIVE_SUBVOL

NEXT="$(xgen_id_next)"
X_GEN_SKIP=1 X_GEN_CLI="$SRC/bin/x" bash "$SRC/hooks/pacman-gen.sh" post
check "X_GEN_SKIP disables the wrapper" test "$(xgen_id_next)" = "$NEXT"

echo "== wrapper =="
X_GEN_CLI="$SRC/bin/x" bash "$SRC/hooks/pacman-gen.sh" post
check "post records a pacman generation" grep -q '"reason": "pacman"' "$X_GEN_DIR/0002/manifest.json"
X_GEN_CLI="$SRC/bin/x" bash "$SRC/hooks/pacman-gen.sh" pre
check "pre records a safety generation" grep -q '"reason": "pacman-pre"' "$X_GEN_DIR/0003/manifest.json"
check "wrapper records through the CLI" test "$(xgen_current)" = "0001"

echo "== hook files =="
check "pre hook exists" test -f "$SRC/etc/pacman.d/hooks/10-x-gen-pre.hook"
check "post hook exists" test -f "$SRC/etc/pacman.d/hooks/95-x-gen-post.hook"
check "pre hook runs PreTransaction" grep -q 'When = PreTransaction' "$SRC/etc/pacman.d/hooks/10-x-gen-pre.hook"
check "post hook runs PostTransaction" grep -q 'When = PostTransaction' "$SRC/etc/pacman.d/hooks/95-x-gen-post.hook"
check "post hook sorts after mkinitcpio (kernel files exist when capturing)" \
    test "$(printf '90-mkinitcpio-install.hook\n95-x-gen-post.hook\n' | LC_ALL=C sort | tail -1)" = "95-x-gen-post.hook"
check "hooks call the wrapper" grep -q '/usr/share/x/hooks/pacman-gen.sh pre' "$SRC/etc/pacman.d/hooks/10-x-gen-pre.hook"
check "x update disables the hook (manages its own generations)" grep -q 'X_GEN_SKIP=1 pacman' "$SRC/bin/x-update.sh"
check "PKGBUILD ships hooks/" grep -q 'hooks;' "$SRC/packaging/PKGBUILD"

if [[ "$FAIL" -eq 0 ]]; then
    echo "pacman-hooks: OK"
else
    echo "pacman-hooks: failures detected"
    exit 1
fi
