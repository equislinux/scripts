#!/usr/bin/env bash
# x:summary=Removes old generations (keeps pinned, running and default)
# x:args=[--keep N] [--dry-run]
# x:root=false
set -euo pipefail

X_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$X_ROOT/install/helpers/xgen.sh"

KEEP="${X_GEN_KEEP:-5}"
DRY=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep) KEEP="${2:?--keep needs a number}"; shift 2 ;;
        --dry-run) DRY=1; shift ;;
        -h|--help)
            echo "usage: x gen prune [--keep N] [--dry-run]"
            echo "  --keep N    newest generations to keep (default $KEEP)"
            echo "  --dry-run   only list what would be removed"
            echo
            echo "Pinned, running and default generations are always kept."
            exit 0
            ;;
        *)
            echo "x gen prune: unknown argument '$1' (see 'x gen prune --help')" >&2
            exit 1
            ;;
    esac
done

xgen_prune "$KEEP" "$DRY"
