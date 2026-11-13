#!/usr/bin/env bash
# x:summary=Installs an official Arch kernel (+headers) and records a generation
# x:args=<kernel>... [--no-headers] [--yes]
# x:root=true
set -euo pipefail

X_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$X_ROOT/install/helpers/xkernel.sh"
source "$X_ROOT/install/helpers/xgen.sh"
source "$X_ROOT/install/helpers/pkg.sh"

generation() { # reason label
    local reason="$1" label="$2"
    [[ "${X_GEN_SKIP:-0}" == "1" ]] && return 0
    xgen_supported || return 0
    xgen_new "$reason" "$label" >/dev/null || xgen_warn "generation ($reason) failed"
}

HEADERS=1
YES=0
names=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-headers) HEADERS=0; shift ;;
        --yes|-y)     YES=1; shift ;;
        -h|--help)
            echo "usage: x kernel install <kernel>... [--no-headers] [--yes]"
            echo "  kernels: $(xkernel_known | tr '\n' ' ')"
            echo "  installs the kernel (+ matching headers) through xpm or pacman;"
            echo "  the kernel preset, module deps and initramfs are refreshed and"
            echo "  one generation is recorded."
            exit 0
            ;;
        -*) echo "x kernel install: unknown option '$1'" >&2; exit 1 ;;
        *) names+=("$1"); shift ;;
    esac
done

[[ "${#names[@]}" -gt 0 ]] || { echo "x kernel install: a kernel name is required" >&2; exit 1; }

pkgs=()
for k in "${names[@]}"; do
    xkernel_validate "$k" || exit 1
    if xkernel_release_of_pkgbase "$k" >/dev/null; then
        echo "x kernel: '$k' is already installed (release $(xkernel_release_of_pkgbase "$k"))"
    fi
    pkgs+=("$k")
    if [[ "$HEADERS" -eq 1 ]]; then
        if x_pkg_available_pkg "$k-headers"; then
            pkgs+=("$k-headers")
        else
            echo "x kernel: warning: '$k-headers' not available; installing without headers" >&2
        fi
    fi
done

# --yes is kept for CLI compatibility: the helper transactions are always
# non-interactive (--no-confirm/--noconfirm).
X_GEN_SKIP=1 X_PKG_NO_ALPM_HOOKS=1 x_pkg_install "${pkgs[@]}"
if [[ "${X_PKG_LAST_BACKEND:-}" == "xpm" ]]; then
    x_pkg_sync_mirror || true
fi

for k in "${names[@]}"; do
    x_pkg_ensure_mkinitcpio_preset "$k" || true
done
x_pkg_kernel_finalize || true

echo
for k in "${names[@]}"; do
    echo "x kernel: installed $k ($(xkernel_release_of_pkgbase "$k" || echo unknown))"
done

generation "kernel-install" "kernel: ${names[*]}"
echo "x kernel: boot entries refreshed by the generation hooks (see: x gen list)"
echo "x kernel: reboot and pick the new entry, or keep booting the current kernel"
