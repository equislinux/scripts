#!/usr/bin/env bash
# x:summary=Updates the system and runs migrations
# x:aliases=update upgrade up
# x:root=false
set -euo pipefail

X_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
X_BIN="${X_BIN:-$X_ROOT/bin}"
source "$X_ROOT/install/helpers/xgen.sh"
source "$X_ROOT/install/helpers/pkg.sh"

generation() { # reason label
    local reason="$1" label="$2"
    [[ "${X_GEN_SKIP:-0}" == "1" ]] && return 0
    xgen_supported || return 0
    if [[ "$(id -u)" -eq 0 ]]; then
        xgen_new "$reason" "$label" >/dev/null || xgen_warn "generation ($reason) failed"
    elif command -v sudo >/dev/null 2>&1; then
        sudo bash "$X_BIN/x-gen-new.sh" --reason "$reason" --label "$label" >/dev/null \
            || xgen_warn "generation ($reason) skipped (sudo failed)"
    else
        xgen_warn "generation ($reason) skipped (needs root)"
    fi
}

home_generation() { # label
    local label="$1"
    if [[ "${X_HGEN_SKIP:-0}" == "1" ]]; then
        return 0
    fi
    if [[ "$(id -u)" -eq 0 && -n "${SUDO_USER:-}" ]]; then
        runuser -u "$SUDO_USER" -- bash "$X_BIN/x-home-new.sh" --label "$label" >/dev/null 2>&1 || true
    elif [[ "$(id -u)" -ne 0 ]]; then
        bash "$X_BIN/x-home-new.sh" --label "$label" >/dev/null 2>&1 || true
    fi
    return 0
}

run_privileged() {
    if [[ "$(id -u)" -eq 0 ]]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        return 1
    fi
}

generation "pre-update" "safety"
home_generation "pre-update"

# Self-heal legacy repo URLs (org renames): the [x] server moved from
# xlnux.github.io to equislinux.github.io. Runs before the transaction so
# systems installed with the old URL can still fetch updates once.
repo_url_selfheal() { # file label
    local file="$1" label="$2"
    [[ -f "$file" ]] || return 0
    if grep -q "xlnux\.github\.io" "$file" 2>/dev/null; then
        if run_privileged sed -i 's#xlnux\.github\.io#equislinux.github.io#g' "$file"; then
            echo "x update: migrated the $label repo URL to equislinux.github.io"
        else
            xgen_warn "could not migrate the $label repo URL in $file"
        fi
    fi
}

backend="$(x_pkg_backend)"
if [[ "$backend" != "none" ]]; then
    echo "x update: syncing repos and updating with $backend"
    repo_url_selfheal /etc/pacman.conf "[x]"
    repo_url_selfheal /etc/xpm.conf "xpm"
    # X_GEN_SKIP=1 makes the ALPM hooks skip: x update records its own pre/post
    # generations around the update.
    if ! X_GEN_SKIP=1 x_pkg_upgrade; then
        xgen_warn "$backend failed; the pre-update generation was kept for recovery"
        exit 1
    fi
    if [[ "${X_PKG_LAST_BACKEND:-}" == "xpm" ]]; then
        x_pkg_sync_mirror || true
        x_pkg_kernel_finalize || true
    fi
else
    echo "x update: no package manager (xpm/pacman) present (skip)"
fi

if [[ "$(id -u)" -eq 0 && -n "${SUDO_USER:-}" ]]; then
    runuser -u "$SUDO_USER" -- bash "$X_BIN/x-migrate.sh"
else
    bash "$X_BIN/x-migrate.sh"
fi

generation "update" ""

echo "x update: done"
