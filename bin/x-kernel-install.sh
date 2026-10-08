#!/usr/bin/env bash
# x:summary=Installs an official Arch kernel (+headers) and records a generation
# x:args=<kernel>... [--no-headers] [--yes]
# x:root=true
set -euo pipefail

X_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$X_ROOT/install/helpers/xkernel.sh"
source "$X_ROOT/install/helpers/xgen.sh"

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
            echo "  installs the kernel (+ matching headers) through pacman; the"
            echo "  generation hooks snapshot it automatically."
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
        if pacman -Si "$k-headers" >/dev/null 2>&1; then
            pkgs+=("$k-headers")
        else
            echo "x kernel: warning: '$k-headers' not available; installing without headers" >&2
        fi
    fi
done

opts=(--needed)
[[ "$YES" -eq 1 ]] && opts+=(--noconfirm)
pacman -S "${opts[@]}" "${pkgs[@]}"

echo
for k in "${names[@]}"; do
    echo "x kernel: installed $k ($(xkernel_release_of_pkgbase "$k" || echo unknown))"
done
echo "x kernel: boot entries refreshed by the generation hooks (see: x gen list)"
echo "x kernel: reboot and pick the new entry, or keep booting the current kernel"
