#!/usr/bin/env bash

# pkg — package backend selection for x-scripts.
#
# xpm is preferred when it is installed and has an initialized local database;
# otherwise the historical pacman commands are used. Query-only fallbacks stay
# on pacman where xpm has no equivalent yet (for example `-Qo`).
#
# Environment:
#   X_PKG_BACKEND     auto|xpm|pacman  (default auto: xpm when initialized)
#   X_PKG_XPM_DB      xpm database root (default /var/lib/xpm). An existing
#                     <root>/local means xpm owns installs and is preferred.
#   X_PKG_PACMAN_DB   pacman database root (default /var/lib/pacman)
#   X_GEN_SKIP=1      forwarded through sudo so x update/kernel commands can
#                     record their own generation around a transaction
#
# X_PKG_BACKEND=xpm forces xpm even before its local database exists (useful
# for a migration); X_PKG_BACKEND=pacman keeps legacy behavior. Functions are
# source-safe and do not change the caller's shell options.

x_pkg_have_cmd() { command -v "$1" >/dev/null 2>&1; }

x_pkg_xpm_db() { printf '%s\n' "${X_PKG_XPM_DB:-/var/lib/xpm}"; }
x_pkg_pacman_db() { printf '%s\n' "${X_PKG_PACMAN_DB:-/var/lib/pacman}"; }

x_pkg_warn() {
    if declare -F xgen_warn >/dev/null 2>&1; then
        xgen_warn "$*"
    else
        printf '\033[1;33m[x pkg!]\033[0m %s\n' "$*" >&2
    fi
}

x_pkg_die() {
    if declare -F xgen_die >/dev/null 2>&1; then
        xgen_die "$*"
    fi
    printf '\033[1;31m[x pkg!!]\033[0m %s\n' "$*" >&2
    exit 1
}

# True when xpm exists and is initialized (or explicitly forced).
x_pkg_available_xpm() {
    case "${X_PKG_BACKEND:-auto}" in
        pacman) return 1 ;;
        xpm)    x_pkg_have_cmd xpm; return $? ;;
    esac
    x_pkg_have_cmd xpm || return 1
    [[ -d "$(x_pkg_xpm_db)/local" ]]
}

x_pkg_available_pacman() { x_pkg_have_cmd pacman; }

# Prints xpm, pacman or none.
x_pkg_backend() {
    if x_pkg_available_xpm; then
        printf 'xpm\n'
    elif x_pkg_available_pacman; then
        printf 'pacman\n'
    else
        printf 'none\n'
    fi
}

# Runs a transactional command as root. Prefer a caller-provided
# run_privileged (installer/xgen context), then sudo, then the current user.
x_pkg_run() {
    (( $# > 0 )) || return 1
    local -a cmd=()
    # sudo generally resets the environment: pass the generation guard as an
    # explicit env argument so pacman/xpm hooks honor it under sudo too.
    if [[ -n "${X_GEN_SKIP:-}" ]]; then
        cmd=(env "X_GEN_SKIP=$X_GEN_SKIP")
    fi
    cmd+=("$@")
    if declare -F run_privileged >/dev/null 2>&1; then
        run_privileged "${cmd[@]}"
    elif [[ "${X_DRY_RUN:-0}" == "1" ]]; then
        printf '  (dry-run) %s\n' "${cmd[*]}"
    elif [[ "$(id -u)" -eq 0 ]]; then
        "${cmd[@]}"
    elif x_pkg_have_cmd sudo; then
        sudo "${cmd[@]}"
    else
        x_pkg_die "cannot elevate privileges for: $*"
    fi
}

x_pkg_install() {
    (( $# > 0 )) || x_pkg_die "x_pkg_install: package name required"
    local backend
    backend="$(x_pkg_backend)"
    case "$backend" in
        xpm)
            local -a flags=()
            [[ "${X_PKG_NO_ALPM_HOOKS:-0}" == "1" ]] && flags+=(--no-alpm-hooks)
            x_pkg_run xpm "${flags[@]}" install --needed --no-confirm "$@"
            ;;
        pacman) x_pkg_run pacman -S --needed --noconfirm "$@" ;;
        *)      x_pkg_die "no package manager (xpm/pacman) found" ;;
    esac
    X_PKG_LAST_BACKEND="$backend"
}

# x_pkg_remove [--recursive] [--nosave] <pkg>...
# Defaults match `pacman -R` (keep dependencies and configuration files).
x_pkg_remove() {
    local recursive=0 nosave=0 pflag="-R"
    local -a pkgs=() xflags=()
    while (( $# > 0 )); do
        case "$1" in
            -r|--recursive) recursive=1; shift ;;
            -n|--nosave)    nosave=1; shift ;;
            --)             shift; break ;;
            -*)             x_pkg_die "x_pkg_remove: unknown option '$1'" ;;
            *)              pkgs+=("$1"); shift ;;
        esac
    done
    pkgs+=("$@")
    (( ${#pkgs[@]} > 0 )) || x_pkg_die "x_pkg_remove: package name required"
    if (( recursive )); then
        xflags+=(--recursive)
    fi
    if (( nosave )); then
        xflags+=(--nosave)
    fi
    # Keep the conventional pacman cluster (-Rns for recursive + nosave).
    if (( nosave )); then pflag+="n"; fi
    if (( recursive )); then pflag+="s"; fi

    local backend
    backend="$(x_pkg_backend)"
    case "$backend" in
        xpm)
            local -a prefix=()
            [[ "${X_PKG_NO_ALPM_HOOKS:-0}" == "1" ]] && prefix+=(--no-alpm-hooks)
            x_pkg_run xpm "${prefix[@]}" remove --no-confirm "${xflags[@]}" "${pkgs[@]}"
            ;;
        pacman) x_pkg_run pacman "$pflag" --noconfirm "${pkgs[@]}" ;;
        *)      x_pkg_die "no package manager (xpm/pacman) found" ;;
    esac
    X_PKG_LAST_BACKEND="$backend"
}

x_pkg_upgrade() {
    local backend
    backend="$(x_pkg_backend)"
    case "$backend" in
        xpm)    x_pkg_run xpm upgrade --no-confirm ;;
        pacman) x_pkg_run pacman -Syu --noconfirm ;;
        *)      x_pkg_die "no package manager (xpm/pacman) found" ;;
    esac
    X_PKG_LAST_BACKEND="$backend"
}

# Exact local-database query: prints "<name> <version>" and returns non-zero
# when the package is not installed. xpm query is substring-based, so its
# output is filtered by exact name.
x_pkg_query() {
    local pkg="${1:-}" backend
    [[ -n "$pkg" ]] || return 1
    backend="$(x_pkg_backend)"
    case "$backend" in
        xpm)
            local line
            line="$(xpm query "$pkg" 2>/dev/null \
                | awk -v want="$pkg" '$1 == want { print $1 " " $2; exit }')" || true
            [[ -n "$line" ]] || return 1
            printf '%s\n' "$line"
            ;;
        pacman)
            pacman -Q "$pkg" 2>/dev/null || return 1
            ;;
        *)
            return 1
            ;;
    esac
}

x_pkg_installed() { x_pkg_query "${1:-}" >/dev/null 2>&1; }

# True when the package can be resolved from the active sync database.
x_pkg_available_pkg() {
    local pkg="${1:-}"
    [[ -n "$pkg" ]] || return 1
    if x_pkg_available_xpm; then
        xpm info "$pkg" >/dev/null 2>&1
    elif x_pkg_available_pacman; then
        pacman -Si "$pkg" >/dev/null 2>&1
    else
        return 1
    fi
}

# xpm has no `-Qo` yet. Do not silently fall back to pacman: in the xpm
# backend ownership is unknown, and callers must handle that.
x_pkg_owner() {
    local path="${1:-}" out owner
    [[ -n "$path" ]] || return 1
    [[ "$(x_pkg_backend)" == "pacman" ]] || return 1
    out="$(pacman -Qo -- "$path" 2>/dev/null)" || return 1
    owner="$(printf '%s\n' "$out" | sed -n 's/.* is owned by \([^ ]*\).*/\1/p' | head -1)"
    [[ -n "$owner" ]] || return 1
    printf '%s\n' "$owner"
}

x_pkg_sync() {
    local backend
    backend="$(x_pkg_backend)"
    case "$backend" in
        xpm)    x_pkg_run xpm sync ;;
        pacman) x_pkg_run pacman -Sy ;;
        *)      x_pkg_die "no package manager (xpm/pacman) found" ;;
    esac
    X_PKG_LAST_BACKEND="$backend"
}

# Native xpm mode does not mirror transactions into pacman's database.
# Keep this as a compatibility no-op so existing callers stay valid.
x_pkg_sync_mirror() { return 0; }

x_pkg_depmod() {
    x_pkg_have_cmd depmod || return 0
    if ! x_pkg_run depmod -a; then
        x_pkg_warn "depmod -a failed; module dependencies may be stale"
    fi
    return 0
}

x_pkg_mkinitcpio() {
    x_pkg_have_cmd mkinitcpio || return 0
    if ! x_pkg_run mkinitcpio -P; then
        x_pkg_warn "mkinitcpio -P failed; initramfs images may be stale"
    fi
    return 0
}

# Post-transaction kernel finalization for the xpm backend, where ALPM Path
# triggers do not run yet.
x_pkg_kernel_finalize() {
    x_pkg_depmod
    x_pkg_mkinitcpio
    return 0
}

# Ensures the kernel package's mkinitcpio preset exists, using the vendor
# template with the standard %PKGBASE% substitution. No-op without mkinitcpio.
x_pkg_ensure_mkinitcpio_preset() {
    local pkgbase="${1:-}" dir template preset tmp
    [[ -n "$pkgbase" ]] || return 1
    x_pkg_have_cmd mkinitcpio || return 0
    dir="${X_PKG_MKINITCPIO_DIR:-/etc/mkinitcpio.d}"
    template="${X_PKG_MKINITCPIO_TEMPLATE:-/usr/share/mkinitcpio/hook.preset}"
    preset="$dir/$pkgbase.preset"
    [[ -f "$preset" ]] && return 0
    if [[ ! -f "$template" ]]; then
        x_pkg_warn "mkinitcpio preset template missing: $template"
        return 0
    fi
    tmp="$(mktemp)" || return 1
    if ! sed "s/%PKGBASE%/$pkgbase/g" "$template" > "$tmp"; then
        rm -f "$tmp"
        x_pkg_warn "could not render the mkinitcpio preset for $pkgbase"
        return 0
    fi
    if ! x_pkg_run install -Dm644 "$tmp" "$preset"; then
        x_pkg_warn "could not install the mkinitcpio preset for $pkgbase"
    fi
    rm -f "$tmp"
    return 0
}

x_pkg_remove_mkinitcpio_preset() {
    local pkgbase="${1:-}" dir preset
    [[ -n "$pkgbase" ]] || return 1
    dir="${X_PKG_MKINITCPIO_DIR:-/etc/mkinitcpio.d}"
    preset="$dir/$pkgbase.preset"
    [[ -f "$preset" ]] || return 0
    if ! x_pkg_run rm -f "$preset"; then
        x_pkg_warn "could not remove the stale mkinitcpio preset $preset"
    fi
    return 0
}
