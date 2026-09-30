#!/usr/bin/env bash
# x:summary=Shows the current home generation and dotfile drift
# x:root=false
set -euo pipefail

X_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$X_ROOT/install/helpers/xgen-home.sh"

hgen_status
