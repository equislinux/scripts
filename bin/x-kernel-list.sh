#!/usr/bin/env bash
# x:summary=Lists kernels (release, running, headers) and boot entries
# x:root=false
set -euo pipefail

X_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$X_ROOT/install/helpers/xkernel.sh"

running="$(xkernel_running_pkgbase)"
printf '%-16s %-24s %s\n' KERNEL RELEASE FLAGS
for k in $(xkernel_known); do
    rel="$(xkernel_release_of_pkgbase "$k" || true)"
    if [[ -z "$rel" ]]; then
        printf '%-16s %-24s %s\n' "$k" "-" "not installed"
        continue
    fi
    flags="installed"
    [[ "$k" == "$running" ]] && flags="$flags running"
    xkernel_pkg_installed "$k-headers" && flags="$flags headers"
    printf '%-16s %-24s %s\n' "$k" "$rel" "$flags"
done
echo
echo "boot entries: $(xkernel_boot_style) (see: x gen boot)"
