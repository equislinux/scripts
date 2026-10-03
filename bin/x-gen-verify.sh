#!/usr/bin/env bash
# x:summary=Verifies the live system against a generation
# x:args=[id]
# x:root=false
set -euo pipefail

X_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$X_ROOT/install/helpers/xgen.sh"

if [[ $# -gt 1 || "${1:-}" == -* ]]; then
    echo "usage: x gen verify [id]" >&2
    exit 1
fi

xgen_verify "${1:-}"
