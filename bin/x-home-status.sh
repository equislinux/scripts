#!/usr/bin/env bash
# x:summary=Shows the current home generation and dotfile drift
# x:root=false
set -euo pipefail

X_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$X_ROOT/install/helpers/xgen-home.sh"

case "${1:-}" in
    --json) hgen_status_json ;;
    "")     hgen_status ;;
    *)
        echo "usage: x home status [--json]" >&2
        exit 1
        ;;
esac
