#!/usr/bin/env bash
# x:summary=Restores a path or a package from a generation snapshot
# x:args=<path> | --pkg <name> [--from ID] [--dest PATH]
# x:root=false
set -euo pipefail

X_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$X_ROOT/install/helpers/xgen.sh"

usage() {
    echo "usage: x gen restore <path> [--from ID] [--dest PATH]"
    echo "       x gen restore --pkg <name> [--from ID] [--dest ROOT]"
    echo "  <path>        absolute path in the live tree (e.g. /etc/sddm.conf)"
    echo "  --pkg <name>  restore every file owned by a package (pacman/xpm db)"
    echo "  --from ID     generation to restore from (default: current)"
    echo "  --dest PATH   write elsewhere instead of in place (testing/rescue)"
}

PATH_ARG=""
PKG=""
FROM=""
DEST=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pkg)  PKG="${2:?--pkg needs a package name}"; shift 2 ;;
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

if [[ -z "$FROM" ]]; then
    FROM="$(xgen_current)"
fi
[[ -n "$FROM" ]] || xgen_die "no current generation; pass --from ID"

if [[ -n "$PKG" ]]; then
    [[ -z "$PATH_ARG" ]] || { echo "x gen restore: --pkg does not take a path" >&2; exit 1; }
    xgen_restore_pkg "$PKG" "$FROM" "$DEST"
    exit 0
fi

[[ -n "$PATH_ARG" ]] || { usage >&2; exit 1; }
xgen_restore "$FROM" "$PATH_ARG" "$DEST"
