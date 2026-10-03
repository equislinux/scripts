#!/usr/bin/env bash
# x:summary=Applies a system.toml declaration (system parts need root)
# x:args=<system.toml> [--dry-run]
# x:root=false
set -euo pipefail

X_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$X_ROOT/install/helpers/common.sh"
source "$X_ROOT/install/helpers/xgen.sh"
source "$X_ROOT/install/helpers/xgen-system.sh"

FILE=""
DRY=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY=1; shift ;;
        -h|--help)
            echo "usage: x gen apply <system.toml> [--dry-run]"
            echo "  appplies hostname/timezone/locale, packages, services and theme;"
            echo "  removals only with packages.prune = true. Records a generation."
            exit 0
            ;;
        -*)
            echo "x gen apply: unknown option '$1'" >&2
            exit 1
            ;;
        *)
            if [[ -n "$FILE" ]]; then
                echo "x gen apply: only one file is accepted" >&2
                exit 1
            fi
            FILE="$1"
            shift
            ;;
    esac
done

[[ -n "$FILE" ]] || { echo "usage: x gen apply <system.toml> [--dry-run]" >&2; exit 1; }
xgen_system_apply "$FILE" "$DRY"
