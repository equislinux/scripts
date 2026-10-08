#!/usr/bin/env bash
# x:summary=Removes an installed kernel (refuses the running or last one)
# x:args=<kernel> [--yes]
# x:root=true
set -euo pipefail

X_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$X_ROOT/install/helpers/xkernel.sh"

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
if xkernel_pkg_installed "$name-headers"; then
    pkgs+=("$name-headers")
fi

opts=()
[[ "$YES" -eq 1 ]] && opts+=(--noconfirm)
pacman -R "${opts[@]}" "${pkgs[@]}"

echo
echo "x kernel: removed $name (and its headers when present)"
echo "x kernel: older snapshots that archived $name stay bootable via rollback"
echo "x kernel: boot entries refreshed by the generation hooks (see: x gen list)"
