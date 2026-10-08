#!/usr/bin/env bash
set -euo pipefail

# Headless tests for the x kernel helpers (fakes /usr/lib/modules and /boot).

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

source "$SRC/install/helpers/xkernel.sh"

export X_KERNEL_MODULES_DIR="$TMP/modules"
export X_KERNEL_BOOT_DIR="$TMP/boot"
mkdir -p "$X_KERNEL_MODULES_DIR/$(uname -r)" "$X_KERNEL_MODULES_DIR/6.18.55-1-lts" \
         "$X_KERNEL_BOOT_DIR/grub"
printf 'linux\n' > "$X_KERNEL_MODULES_DIR/$(uname -r)/pkgbase"
printf 'linux-lts\n' > "$X_KERNEL_MODULES_DIR/6.18.55-1-lts/pkgbase"
: > "$X_KERNEL_BOOT_DIR/grub/grub.cfg"

check "validate accepts a known kernel" xkernel_validate linux
if xkernel_validate linux-firmware >/dev/null 2>&1; then
    check "validate rejects linux-firmware" false
else
    check "validate rejects linux-firmware" true
fi
if xkernel_validate "" >/dev/null 2>&1; then
    check "validate rejects an empty name" false
else
    check "validate rejects an empty name" true
fi

check "release_of_pkgbase resolves the release" \
    test "$(xkernel_release_of_pkgbase linux-lts)" = "6.18.55-1-lts"
check "running pkgbase comes from the modules dir" \
    test "$(xkernel_running_pkgbase)" = "linux"
check "installed pkgbases are listed once" \
    test "$(xkernel_installed_pkgbases | tr '\n' ' ')" = "linux linux-lts "
check "boot style detects grub" test "$(xkernel_boot_style)" = "grub"

if xkernel_check_removable linux >/dev/null 2>&1; then
    check "refuses removing the running kernel" false
else
    check "refuses removing the running kernel" true
fi
if xkernel_check_removable linux-nonsense >/dev/null 2>&1; then
    check "refuses an unknown kernel" false
else
    check "refuses an unknown kernel" true
fi
check "allows removing a non-running kernel" xkernel_check_removable linux-lts

rm -rf "$X_KERNEL_MODULES_DIR/6.18.55-1-lts"
export X_KERNEL_RUNNING_RELEASE="6.9.9-not-installed"
if xkernel_check_removable linux >/dev/null 2>&1; then
    check "refuses removing the last kernel" false
else
    check "refuses removing the last kernel" true
fi

if [[ "$FAIL" -eq 0 ]]; then
    echo "kernel tests: OK"
else
    echo "kernel tests: failures detected"
    exit 1
fi
