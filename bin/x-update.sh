#!/usr/bin/env bash
# x:summary=Updates the system and runs migrations
# x:aliases=update upgrade up
# x:root=false
set -euo pipefail

X_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
X_BIN="${X_BIN:-$X_ROOT/bin}"
source "$X_ROOT/install/helpers/xgen.sh"

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

if command -v pacman >/dev/null 2>&1; then
    echo "x update: syncing repos and updating"
    # X_GEN_SKIP=1 makes the pacman hook (etc/pacman.d/hooks/20-x-gen-post)
    # skip: x update records its own pre/post generations around the update.
    if ! run_privileged env X_GEN_SKIP=1 pacman -Syu --noconfirm; then
        xgen_warn "pacman failed; the pre-update generation was kept for recovery"
        exit 1
    fi
else
    echo "x update: pacman not present (skip)"
fi

if [[ "$(id -u)" -eq 0 && -n "${SUDO_USER:-}" ]]; then
    runuser -u "$SUDO_USER" -- bash "$X_BIN/x-migrate.sh"
else
    bash "$X_BIN/x-migrate.sh"
fi

generation "update" ""

echo "x update: done"
