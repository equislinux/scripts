#!/usr/bin/env bash
set -euo pipefail

# Non-interactive niri/equisdots desktop setup for X Linux.
#
# Uses the official equisdots niri meta installer (`dotsniri`) in online mode:
# it clones niri-meta and every owned/shared repo, installs the niri stack
# packages, deploys the shared Quickshell shell + niri overlays, plugins, app
# configs, user units and the niri session entry. X only orchestrates the
# install and the SDDM login theme; nothing under the equisdots org is modified.
#
# Runs as the TARGET USER (never as root): privileged steps go through sudo,
# using the temporary passwordless sudoers file created by the text installer.
#
# Env:
#   X_NIRI_REF          niri-meta branch/ref (default: main)
#   X_NIRI_CACHE_DIR    clone cache (default: $XDG_CACHE_HOME/x)
#   X_NIRI_DRYRUN       1 = print the plan only
#   X_NIRI_SKIP_LOGIN   1 = do not install the SDDM theme / enable sddm

source "$(dirname "${BASH_SOURCE[0]}")/../install/helpers/common.sh"

if [[ "$(id -u)" -eq 0 ]]; then
    error "niri setup must run as the target user, not root"
fi

X_NIRI_REF="${X_NIRI_REF:-main}"
CACHE="${X_NIRI_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/x}"
SRC="$CACHE/niri-meta"
UPSTREAM="https://github.com/equisdots/niri-meta.git"

if [[ "${X_NIRI_DRYRUN:-0}" == "1" ]]; then
    log "dry-run: clone/update $UPSTREAM ($X_NIRI_REF) in $SRC"
    log "dry-run: run dotsniri setup -y (packages, deploy, plugins, app configs, session entry)"
    log "dry-run: dotsniri desktop niri; install the X SDDM theme; enable sddm"
    exit 0
fi

mkdir -p "$CACHE"

if [[ -d "$SRC/.git" ]]; then
    log "updating niri-meta ($X_NIRI_REF)"
    git -C "$SRC" fetch -q --depth 1 origin "$X_NIRI_REF"
    git -C "$SRC" reset -q --hard FETCH_HEAD
else
    log "cloning niri-meta ($X_NIRI_REF)"
    rm -rf "$SRC"
    git clone -q --depth 1 --branch "$X_NIRI_REF" "$UPSTREAM" "$SRC"
fi

[[ -x "$SRC/bin/dotsniri" ]] || error "niri-meta checkout is incomplete: $SRC/bin/dotsniri missing"

log "installing the equisdots niri stack (this needs network and may take a while)"
"$SRC/bin/dotsniri" setup -y

# Keep niri as the default session for a fresh install. dotsniri already does
# this on a fresh state; this is idempotent and fixes a previously chosen
# session when the user explicitly selected niri in the X installer.
"$SRC/bin/dotsniri" desktop niri || warn "could not set niri as the default desktop"

if [[ "${X_NIRI_SKIP_LOGIN:-0}" != "1" ]]; then
    LOGIN_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/equisdots/login"
    if [[ -x "$LOGIN_DIR/install.sh" ]]; then
        log "installing the X/equisdots SDDM login theme"
        sudo "$LOGIN_DIR/install.sh"
    else
        warn "login theme not found at $LOGIN_DIR; SDDM will use its default theme"
    fi
    sudo systemctl enable sddm.service >/dev/null 2>&1 || warn "could not enable sddm"
fi

log "niri setup finished; select the Niri session at the login screen"
