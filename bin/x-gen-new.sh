#!/usr/bin/env bash
# x:summary=Creates a generation (immutable snapshot + manifest)
# x:args=[--reason R] [--label L]
# x:root=false
set -euo pipefail

X_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$X_ROOT/install/helpers/xgen.sh"

REASON="${X_GEN_REASON:-manual}"
LABEL="${X_GEN_LABEL:-}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --reason) REASON="${2:?--reason needs a value}"; shift 2 ;;
        --label)  LABEL="${2:?--label needs a value}"; shift 2 ;;
        -h|--help)
            echo "usage: x gen new [--reason R] [--label L]"
            echo "  --reason  why the generation is created (default: manual)"
            echo "  --label   free-form label shown by 'x gen list'"
            exit 0
            ;;
        *)
            echo "x gen new: unknown argument '$1' (see 'x gen new --help')" >&2
            exit 1
            ;;
    esac
done

id="$(xgen_new "$REASON" "$LABEL")"
xgen_log "generation $id created (reason: $REASON${LABEL:+, label: $LABEL})"
