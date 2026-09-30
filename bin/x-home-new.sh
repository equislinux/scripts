#!/usr/bin/env bash
# x:summary=Records a home generation (copy of the user dotfiles)
# x:args=[--label L]
# x:root=false
set -euo pipefail

X_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$X_ROOT/install/helpers/xgen-home.sh"

LABEL=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --label) LABEL="${2:?--label needs a value}"; shift 2 ;;
        -h|--help)
            echo "usage: x home new [--label L]"
            exit 0
            ;;
        *)
            echo "x home new: unknown argument '$1'" >&2
            exit 1
            ;;
    esac
done

id="$(hgen_new "$LABEL")"
hgen_log "home generation $id recorded${LABEL:+ (label: $LABEL)}"
