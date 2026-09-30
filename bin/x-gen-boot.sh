#!/usr/bin/env bash
# x:summary=Regenerates the per-generation boot entries
# x:root=false
set -euo pipefail

X_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$X_ROOT/install/helpers/xgen.sh"

if ! xgen_boot_enabled; then
    echo "x gen boot: boot entries are not managed here (X_GEN_BOOT=$X_GEN_BOOT, dir=$X_GEN_BOOT_DIR)"
    exit 0
fi

xgen_boot_sync
xgen_log "boot entries synced in $X_GEN_BOOT_DIR"
