#!/usr/bin/env bash
# x:summary=Lists the system generations
# x:aliases=gen generation generations
# x:root=false
set -euo pipefail

X_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$X_ROOT/install/helpers/xgen.sh"

if ! xgen_supported; then
    echo "x gen: generations are not supported on this system (no btrfs)"
    exit 0
fi

xgen_list
