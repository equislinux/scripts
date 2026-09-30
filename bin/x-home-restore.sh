#!/usr/bin/env bash
# x:summary=Restores a dotfile path from a home generation
# x:args=<path> [--from ID] [--dest PATH]
# x:root=false
set -euo pipefail

X_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$X_ROOT/install/helpers/xgen-home.sh"

usage() {
    echo "usage: x home restore <path> [--from ID] [--dest PATH]"
    echo "  <path>        path relative to the home (or absolute under it)"
    echo "  --from ID     home generation (default: current)"
    echo "  --dest PATH   write elsewhere (default: the live path)"
}

PATH_ARG=""
FROM=""
DEST=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --from) FROM="${2:?--from needs a generation id}"; shift 2 ;;
        --dest) DEST="${2:?--dest needs a path}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*)
            echo "x home restore: unknown option '$1'" >&2
            usage >&2
            exit 1
            ;;
        *)
            if [[ -n "$PATH_ARG" ]]; then
                echo "x home restore: only one path is accepted" >&2
                exit 1
            fi
            PATH_ARG="$1"
            shift
            ;;
    esac
done

[[ -n "$PATH_ARG" ]] || { usage >&2; exit 1; }
hgen_restore "$PATH_ARG" "$FROM" "$DEST"
