#!/usr/bin/env bash
# x:summary=Shows the actions to match a system.toml declaration
# x:args=<system.toml>
# x:root=false
set -euo pipefail

X_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$X_ROOT/install/helpers/common.sh"
source "$X_ROOT/install/helpers/xgen.sh"
source "$X_ROOT/install/helpers/xgen-system.sh"

if [[ $# -ne 1 || "$1" == -* ]]; then
    echo "usage: x gen plan <system.toml>" >&2
    exit 1
fi

xgen_system_plan "$1"
