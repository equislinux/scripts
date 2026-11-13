#!/usr/bin/env bash
# x:summary=Removes an installed kernel (refuses the running or last one)
# x:args=<kernel> [--yes]
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

# Removes a stale /boot file only when no other package owns it.
remove_kernel_file() { # pkgbase file
    local pkgbase="$1" file="$2" owner
    [[ -e "$file" || -L "$file" ]] || return 0
    owner="$(x_pkg_owner "$file" 2>/dev/null || true)"
    if [[ -n "$owner" && "$owner" != "$pkgbase" && "$owner" != "$pkgbase-headers" ]]; then
        xgen_warn "keeping $file (owned by $owner)"
        return 0
    fi
    if ! x_pkg_run rm -f "$file"; then
        xgen_warn "could not remove $file"
    fi
    return 0
}

YES=0
name=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes|-y) YES=1; shift ;;
        -h|--help)
            echo "usage: x kernel remove <kernel> [--yes]"
            echo "  the running kernel and the last installed kernel are protected;"
            echo "  snapshots that archived the kernel remain bootable (rollback)."
            exit 0
            ;;
        -*) echo "x kernel remove: unknown option '$1'" >&2; exit 1 ;;
        *) name="$1"; shift ;;
    esac
done

[[ -n "$name" ]] || { echo "x kernel remove: a kernel name is required" >&2; exit 1; }
xkernel_check_removable "$name" || exit 1

pkgs=("$name")
if x_pkg_installed "$name-headers"; then
    pkgs+=("$name-headers")
fi

# --yes is kept for CLI compatibility: the helper transactions are always
# non-interactive. Match the previous `pacman -R` behavior (keep deps and
# configuration files).
X_GEN_SKIP=1 X_PKG_NO_ALPM_HOOKS=1 x_pkg_remove "${pkgs[@]}"
if [[ "${X_PKG_LAST_BACKEND:-}" == "xpm" ]]; then
    x_pkg_sync_mirror || true
fi

x_pkg_remove_mkinitcpio_preset "$name" || true
boot_dir="$(xkernel_boot_dir)"
remove_kernel_file "$name" "$boot_dir/vmlinuz-$name"
remove_kernel_file "$name" "$boot_dir/initramfs-$name.img"
remove_kernel_file "$name" "$boot_dir/initramfs-$name-fallback.img"
x_pkg_mkinitcpio || true

generation "kernel-remove" "kernel: $name"

echo
echo "x kernel: removed $name (and its headers when present)"
echo "x kernel: older snapshots that archived $name stay bootable via rollback"
echo "x kernel: boot entries and remaining kernels refreshed (see: x gen list)"
