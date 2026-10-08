#!/usr/bin/env bash
# Kernel helpers for the x CLI: validation, inspection and removal safety.
# Overridable for tests:
#   X_KERNEL_MODULES_DIR, X_KERNEL_BOOT_DIR, X_KERNEL_KNOWN,
#   X_KERNEL_RUNNING_RELEASE

xkernel_modules_dir() { printf '%s\n' "${X_KERNEL_MODULES_DIR:-/usr/lib/modules}"; }
xkernel_boot_dir() { printf '%s\n' "${X_KERNEL_BOOT_DIR:-/boot}"; }

xkernel_known() {
    printf '%s\n' "${X_KERNEL_KNOWN:-linux linux-lts linux-zen linux-hardened linux-rt linux-rt-lts}"
}

xkernel_is_known() {
    local k="${1:-}" c
    for c in $(xkernel_known); do
        [[ "$k" == "$c" ]] && return 0
    done
    return 1
}

xkernel_validate() {
    local k="${1:-}"
    if [[ -z "$k" ]]; then
        echo "x kernel: a kernel name is required" >&2
        return 1
    fi
    if ! xkernel_is_known "$k"; then
        echo "x kernel: unsupported kernel '$k' (supported: $(xkernel_known | tr '\n' ' '))" >&2
        return 1
    fi
}

xkernel_release_of_pkgbase() {
    local k="$1" m
    for m in "$(xkernel_modules_dir)"/*/; do
        [[ -d "$m" ]] || continue
        [[ "$(cat "$m/pkgbase" 2>/dev/null)" == "$k" ]] || continue
        basename "$m"
        return 0
    done
    return 1
}

xkernel_installed_pkgbases() {
    local m
    for m in "$(xkernel_modules_dir)"/*/; do
        [[ -d "$m" ]] || continue
        cat "$m/pkgbase" 2>/dev/null || true
    done | LC_ALL=C sort -u
}

xkernel_running_pkgbase() {
    local rel="${X_KERNEL_RUNNING_RELEASE:-$(uname -r 2>/dev/null || true)}"
    cat "$(xkernel_modules_dir)/$rel/pkgbase" 2>/dev/null || true
}

xkernel_pkg_installed() { pacman -Qq "$1" >/dev/null 2>&1; }

xkernel_boot_style() {
    local b
    b="$(xkernel_boot_dir)"
    if [[ -d "$b/loader/entries" ]]; then
        printf 'systemd-boot\n'
    elif [[ -f "$b/grub/grub.cfg" ]]; then
        printf 'grub\n'
    else
        printf 'unknown\n'
    fi
}

# Returns 0 when the kernel can be removed; otherwise prints the reason.
xkernel_check_removable() {
    local k="${1:-}" running count
    xkernel_validate "$k" || return 1
    if ! xkernel_release_of_pkgbase "$k" >/dev/null; then
        echo "x kernel: '$k' is not installed" >&2
        return 1
    fi
    running="$(xkernel_running_pkgbase)"
    if [[ -n "$running" && "$k" == "$running" ]]; then
        echo "x kernel: cannot remove the running kernel '$k'; reboot into another kernel first" >&2
        return 1
    fi
    count="$(xkernel_installed_pkgbases | wc -l)"
    if (( count < 2 )); then
        echo "x kernel: cannot remove '$k': it is the only installed kernel" >&2
        return 1
    fi
    return 0
}
