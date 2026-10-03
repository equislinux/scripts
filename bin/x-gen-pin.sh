#!/usr/bin/env bash
# x:summary=Marks a generation so it is never pruned
# x:args=<id> [--unpin]
# x:root=false
set -euo pipefail

X_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$X_ROOT/install/helpers/xgen.sh"

ID=""
UNPIN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --unpin) UNPIN=1; shift ;;
        -h|--help)
            echo "usage: x gen pin <id> [--unpin]"
            exit 0
            ;;
        -*)
            echo "x gen pin: unknown option '$1'" >&2
            exit 1
            ;;
        *)
            if [[ -n "$ID" ]]; then
                echo "x gen pin: only one generation id is accepted" >&2
                exit 1
            fi
            ID="$1"
            shift
            ;;
    esac
done

[[ -n "$ID" ]] || { echo "usage: x gen pin <id> [--unpin]" >&2; exit 1; }
xgen_pin "$ID" "$UNPIN"
