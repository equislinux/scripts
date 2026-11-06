#!/usr/bin/env bash
set -euo pipefail

# System provisioning entry (root). Orchestrates the phases
# config -> hardware -> login -> post-install.
source "$(dirname "${BASH_SOURCE[0]}")/helpers/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/helpers/xgen.sh"

x_require_root

X_INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "$X_INSTALL_DIR/config.sh"
bash "$X_INSTALL_DIR/hardware.sh"
bash "$X_INSTALL_DIR/login.sh"
bash "$X_INSTALL_DIR/post-install.sh"

# Remote payloads are optional and must never block provisioning.
bash "$X_INSTALL_DIR/remote-payloads.sh" ||     warn "remote payloads runner failed; continuing"

xgen_maybe_new "setup" ""

log "system provisioned"
