#!/usr/bin/env bash
# x:summary=Imports a generation bundle
# x:args=<file> [--force]
# x:root=false
set -euo pipefail

X_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$X_ROOT/install/helpers/xgen.sh"

FILE=""
FORCE=0
ALLOW_METADATA=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force) FORCE=1; shift ;;
        --allow-metadata-only) ALLOW_METADATA=1; shift ;;
        -h|--help)
            echo "usage: x gen import <file> [--force] [--allow-metadata-only]"
            echo "  --force                  replace the generation if it already exists"
            echo "  --allow-metadata-only    keep the metadata if the btrfs snapshot cannot be imported"
            exit 0
            ;;
        -*)
            echo "x gen import: unknown option '$1'" >&2
            exit 1
            ;;
        *)
            if [[ -n "$FILE" ]]; then
                echo "x gen import: only one bundle is accepted" >&2
                exit 1
            fi
            FILE="$1"
            shift
            ;;
    esac
done

[[ -n "$FILE" ]] || { echo "usage: x gen import <file> [--force] [--allow-metadata-only]" >&2; exit 1; }
xgen_import "$FILE" "$FORCE" "$ALLOW_METADATA"
