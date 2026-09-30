#!/usr/bin/env bash
# x:summary=Exports a generation as a portable bundle
# x:args=<id> [--out FILE] [--with-data]
# x:root=false
set -euo pipefail

X_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$X_ROOT/install/helpers/xgen.sh"

ID=""
OUT=""
DATA=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --out) OUT="${2:?--out needs a path}"; shift 2 ;;
        --with-data) DATA=1; shift ;;
        -h|--help)
            echo "usage: x gen export <id> [--out FILE] [--with-data]"
            echo "  --out FILE      output bundle (default: x-gen-<id>-<date>.tar.zst)"
            echo "  --with-data     include the snapshot (btrfs send / tree copy; root on btrfs)"
            exit 0
            ;;
        -*)
            echo "x gen export: unknown option '$1'" >&2
            exit 1
            ;;
        *)
            if [[ -n "$ID" ]]; then
                echo "x gen export: only one generation id is accepted" >&2
                exit 1
            fi
            ID="$1"
            shift
            ;;
    esac
done

[[ -n "$ID" ]] || { echo "usage: x gen export <id> [--out FILE] [--with-data]" >&2; exit 1; }
xgen_export "$ID" "$OUT" "$DATA"
