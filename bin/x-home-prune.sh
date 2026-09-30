#!/usr/bin/env bash
# x:summary=Removes old home generations (keeps current and pinned)
# x:args=[--keep N] [--dry-run]
# x:root=false
set -euo pipefail

X_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$X_ROOT/install/helpers/xgen-home.sh"

KEEP="${X_HGEN_KEEP:-10}"
DRY=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep) KEEP="${2:?--keep needs a number}"; shift 2 ;;
        --dry-run) DRY=1; shift ;;
        -h|--help)
            echo "usage: x home prune [--keep N] [--dry-run]"
            exit 0
            ;;
        *)
            echo "x home prune: unknown argument '$1'" >&2
            exit 1
            ;;
    esac
done

hgen_prune "$KEEP" "$DRY"
