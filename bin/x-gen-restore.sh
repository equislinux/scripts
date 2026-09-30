#!/usr/bin/env bash
# x:summary=Restores a path from a generation snapshot
# x:args=<path> [--from ID] [--dest PATH]
# x:root=false
set -euo pipefail

X_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$X_ROOT/install/helpers/xgen.sh"

usage() {
    echo "usage: x gen restore <path> [--from ID] [--dest PATH]"
    echo "  <path>        absolute path in the live tree (e.g. /etc/sddm.conf)"
    echo "  --from ID     generation to restore from (default: current)"
    echo "  --dest PATH   write elsewhere instead of in place (testing/rescue)"
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
            echo "x gen restore: unknown option '$1'" >&2
            usage >&2
            exit 1
            ;;
        *)
            if [[ -n "$PATH_ARG" ]]; then
                echo "x gen restore: only one path is accepted" >&2
                exit 1
            fi
            PATH_ARG="$1"
            shift
            ;;
    esac
done

[[ -n "$PATH_ARG" ]] || { usage >&2; exit 1; }
if [[ -z "$FROM" ]]; then
    FROM="$(xgen_current)"
fi
[[ -n "$FROM" ]] || xgen_die "no current generation; pass --from ID"

xgen_restore "$FROM" "$PATH_ARG" "$DEST"
