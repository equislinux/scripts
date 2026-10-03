#!/usr/bin/env bash
# x:summary=Shows the differences between two generations
# x:args=<id-a> <id-b>
# x:root=false
set -euo pipefail

X_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$X_ROOT/install/helpers/xgen.sh"

if [[ $# -eq 2 && "$1" != -* ]]; then
    xgen_diff "$1" "$2"
    exit 0
fi

echo "usage: x gen diff <id-a> <id-b>" >&2
exit 1
