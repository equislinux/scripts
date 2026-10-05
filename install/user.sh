#!/usr/bin/env bash
set -euo pipefail

# User provisioning entry (runs as the target user, or as
# root: in that case it delegates to install/user-seed.sh via runuser).
source "$(dirname "${BASH_SOURCE[0]}")/helpers/common.sh"

TARGET_USER="$(x_target_user)"
TARGET_HOME="$(x_target_home)"
[[ -n "$TARGET_HOME" ]] || error "could not resolve the home of $TARGET_USER"

log "user: $TARGET_USER ($TARGET_HOME)"

if [[ "$(id -u)" -eq 0 ]]; then
    env X_SKEL_DIR="${X_SKEL_DIR:-/etc/skel}" X_CONFIG_SEED="$X_ROOT/config" \
        runuser -u "$TARGET_USER" -- bash "$X_ROOT/install/user-seed.sh"
else
    X_SKEL_DIR="${X_SKEL_DIR:-/etc/skel}" X_CONFIG_SEED="$X_ROOT/config" \
        bash "$X_ROOT/install/user-seed.sh"
fi

if [[ "${X_NODE:-0}" == "1" ]]; then
    log "user: installing node toolchain (fnm)"
    run_as_user bash "$X_ROOT/tools/node.sh"
fi

if [[ "${X_HYPRLAND:-1}" == "1" ]]; then
    log "user: installing the Hyprland/equisdots desktop"
    run_as_user bash "$X_ROOT/tools/hyprland-install.sh"
fi

log "user provisioned"
log "optional: 'x agent install' provisions the Xscriptor AI agents/skills for OpenCode"
