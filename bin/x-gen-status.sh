#!/usr/bin/env bash
# x:summary=Shows the current generation and config drift
# x:root=false
set -euo pipefail

X_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$X_ROOT/install/helpers/xgen.sh"

xgen_status
