#!/usr/bin/env bash
# x:summary=Shows running/default generations, pending rollback and drift
# x:root=false
set -euo pipefail

X_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$X_ROOT/install/helpers/xgen.sh"

case "${1:-}" in
    --json) xgen_status_json ;;
    "")     xgen_status ;;
    *)
        echo "usage: x gen status [--json]" >&2
        exit 1
        ;;
esac
