#!/usr/bin/env bash
set -euo pipefail

# Package backend helper tests: xpm selection, pacman fallback and the exact
# argument construction, without touching the real package databases.

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

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

BIN="$TMP/bin"
LOG="$TMP/calls.log"
mkdir -p "$BIN" "$TMP/xpmdb/local" "$TMP/pacmandb" "$TMP/mkinitcpio.d"
: > "$LOG"
export PKG_TEST_LOG="$LOG"

cat > "$BIN/xpm" <<'EOF'
#!/usr/bin/env bash
{
    printf 'xpm'
    printf ' %s' "$@"
    printf '\n'
} >> "$PKG_TEST_LOG"
case "${1:-}" in
    query)
        case "${2:-}" in
            "")     printf 'foo 1.2.3-1\nfoobar 9.9-1\nbar 2.0-1\n' ;;
            foo)    printf 'foo 1.2.3-1\nfoobar 9.9-1\n' ;;
            foobar) printf 'foobar 9.9-1\n' ;;
            bar)    printf 'bar 2.0-1\n' ;;
            *)      exit 1 ;;
        esac
        ;;
esac
exit 0
EOF

cat > "$BIN/pacman" <<'EOF'
#!/usr/bin/env bash
{
    printf 'pacman'
    printf ' %s' "$@"
    printf '\n'
} >> "$PKG_TEST_LOG"
case "${1:-}" in
    -Q)
        case "${2:-}" in
            "")  printf 'foo 1.2.3-1\nbar 2.0-1\n' ;;
            foo) printf 'foo 1.2.3-1\n' ;;
            bar) printf 'bar 2.0-1\n' ;;
            *)   exit 1 ;;
        esac
        ;;
    -Qo)
        path="${!#}"
        printf '%s is owned by foo 1.2.3-1\n' "$path"
        ;;
esac
exit 0
EOF

cat > "$BIN/mkinitcpio" <<'EOF'
#!/usr/bin/env bash
{ printf 'mkinitcpio'; printf ' %s' "$@"; printf '\n'; } >> "$PKG_TEST_LOG"
exit 0
EOF

cat > "$BIN/depmod" <<'EOF'
#!/usr/bin/env bash
{ printf 'depmod'; printf ' %s' "$@"; printf '\n'; } >> "$PKG_TEST_LOG"
exit 0
EOF

chmod +x "$BIN"/*
export PATH="$BIN:$PATH"
export X_PKG_XPM_DB="$TMP/xpmdb"
export X_PKG_PACMAN_DB="$TMP/pacmandb"
unset X_PKG_BACKEND X_PKG_LAST_BACKEND X_GEN_SKIP

run_privileged() {
    { printf 'priv'; printf ' %s' "$@"; printf '\n'; } >> "$PKG_TEST_LOG"
    "$@"
}

source "$SRC/install/helpers/pkg.sh"

echo "== selection =="
check "initialized xpm is preferred" test "$(x_pkg_backend)" = "xpm"
check "xpm availability sees the local database" x_pkg_available_xpm
check "forced pacman backend" test "$(X_PKG_BACKEND=pacman x_pkg_backend)" = "pacman"
check "forced xpm backend works before its database exists" \
    test "$(X_PKG_BACKEND=xpm X_PKG_XPM_DB="$TMP/missing" x_pkg_backend)" = "xpm"
check "xpm binary without a local database falls back to pacman" \
    test "$(X_PKG_XPM_DB="$TMP/missing" x_pkg_backend)" = "pacman"

INFO="$(bash "$SRC/bin/x-info.sh")"
check "x info counts packages from xpm" grep -q 'packages: 3' <<< "$INFO"
INFO="$(X_PKG_XPM_DB="$TMP/missing" bash "$SRC/bin/x-info.sh")"
check "x info falls back to the pacman count" grep -q 'packages: 2' <<< "$INFO"

echo "== install/remove/upgrade =="
: > "$LOG"
x_pkg_install foo bar
check "xpm install gets --needed and --no-confirm" \
    grep -qx 'xpm install --needed --no-confirm foo bar' "$LOG"
check "xpm install does not call pacman" bash -c "! grep -q '^pacman ' \"\$1\"" _ "$LOG"

: > "$LOG"
x_pkg_install foo
check "last backend is recorded" test "$X_PKG_LAST_BACKEND" = "xpm"

: > "$LOG"
x_pkg_remove foo
check "xpm remove is non-interactive" \
    grep -qx 'xpm remove --no-confirm foo' "$LOG"
: > "$LOG"
x_pkg_remove --recursive --nosave foo bar
check "xpm remove supports recursive + nosave" \
    grep -qx 'xpm remove --no-confirm --recursive --nosave foo bar' "$LOG"

: > "$LOG"
x_pkg_upgrade
check "xpm upgrade is non-interactive" grep -qx 'xpm upgrade --no-confirm' "$LOG"

: > "$LOG"
X_PKG_XPM_DB="$TMP/missing" x_pkg_install foo
check "pacman install fallback" grep -qx 'pacman -S --needed --noconfirm foo' "$LOG"
: > "$LOG"
X_PKG_XPM_DB="$TMP/missing" x_pkg_remove foo
check "pacman remove fallback keeps -R semantics by default" \
    grep -qx 'pacman -R --noconfirm foo' "$LOG"
: > "$LOG"
X_PKG_XPM_DB="$TMP/missing" x_pkg_remove --recursive --nosave foo
check "pacman remove fallback keeps -Rns" grep -qx 'pacman -Rns --noconfirm foo' "$LOG"
: > "$LOG"
X_PKG_XPM_DB="$TMP/missing" x_pkg_upgrade
check "pacman upgrade fallback" grep -qx 'pacman -Syu --noconfirm' "$LOG"

echo "== query/owner/sync =="
check "xpm query is filtered to the exact package name" \
    test "$(x_pkg_query foo)" = "foo 1.2.3-1"
check "xpm query does not match a substring package" \
    test "$(x_pkg_query foobar)" = "foobar 9.9-1"
check "installed check accepts an installed package" x_pkg_installed foo
if x_pkg_installed nope >/dev/null 2>&1; then
    check "installed check rejects a missing package" false
else
    check "installed check rejects a missing package" true
fi
: > "$LOG"
check "owner falls back to pacman -Qo under xpm" \
    test "$(x_pkg_owner /usr/bin/foo)" = "foo"
check "owner query used pacman" grep -q '^pacman -Qo -- /usr/bin/foo' "$LOG"
check "sync package availability uses xpm info" x_pkg_available_pkg foo

: > "$LOG"
x_pkg_sync
check "xpm sync is used" grep -qx 'xpm sync' "$LOG"
X_PKG_XPM_DB="$TMP/missing" x_pkg_sync >/dev/null
check "pacman -Sy fallback" grep -qx 'pacman -Sy' "$LOG"

: > "$LOG"
x_pkg_sync_mirror
check "mirror runs after xpm operations" \
    grep -qx "xpm sync-pacman-db --pacman-db $TMP/pacmandb" "$LOG"
: > "$LOG"
X_PKG_PACMAN_DB="$TMP/missing" x_pkg_sync_mirror
check "mirror is skipped without a pacman database" test ! -s "$LOG"

echo "== generation guard =="
: > "$LOG"
X_GEN_SKIP=1 x_pkg_install foo
check "X_GEN_SKIP is forwarded through the privilege wrapper" \
    grep -q '^priv env X_GEN_SKIP=1 xpm install' "$LOG"

echo "== kernel helpers =="
printf 'ALL_kver="/boot/vmlinuz-%%PKGBASE%%"\ndefault_image="/boot/initramfs-%%PKGBASE%%.img"\n' \
    > "$TMP/hook.preset"
X_PKG_MKINITCPIO_DIR="$TMP/mkinitcpio.d" X_PKG_MKINITCPIO_TEMPLATE="$TMP/hook.preset" \
    x_pkg_ensure_mkinitcpio_preset linux
PRESET="$TMP/mkinitcpio.d/linux.preset"
check "preset is created from the vendor template" test -f "$PRESET"
check "preset substitutes the pkgbase" grep -q 'vmlinuz-linux' "$PRESET"
check "preset leaves no placeholder" bash -c "! grep -q '%PKGBASE%' \"\$1\"" _ "$PRESET"
: > "$LOG"
X_PKG_MKINITCPIO_DIR="$TMP/mkinitcpio.d" X_PKG_MKINITCPIO_TEMPLATE="$TMP/hook.preset" \
    x_pkg_ensure_mkinitcpio_preset linux
check "existing preset is not rewritten" test ! -s "$LOG"
: > "$LOG"
x_pkg_kernel_finalize
check "finalize runs depmod" grep -q '^depmod -a' "$LOG"
check "finalize runs mkinitcpio -P" grep -q '^mkinitcpio -P' "$LOG"
X_PKG_MKINITCPIO_DIR="$TMP/mkinitcpio.d" x_pkg_remove_mkinitcpio_preset linux
check "preset removal deletes the file" test ! -e "$PRESET"

if [[ "$FAIL" -eq 0 ]]; then
    echo "pkg-helper: OK"
else
    echo "pkg-helper: failures detected"
    exit 1
fi
