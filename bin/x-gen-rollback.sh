#!/usr/bin/env bash
# x:summary=Selects a generation as the default boot (rollback)
# x:args=<id> [--no-safety]
# x:root=false
set -euo pipefail

X_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$X_ROOT/install/helpers/xgen.sh"

usage() {
    echo "usage: x gen rollback <id> [--no-safety]"
    echo "  <id>          generation to boot by default (see 'x gen list')"
    echo "  --no-safety   do not create a pre-rollback safety generation"
    echo
    echo "The switch applies on the next reboot; the system rolls back to the"
    echo "selected generation's snapshot (user data in /home is untouched)."
}

TARGET=""
NO_SAFETY=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-safety) NO_SAFETY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        -*)
            echo "x gen rollback: unknown option '$1'" >&2
            usage >&2
            exit 1
            ;;
        *)
            if [[ -n "$TARGET" ]]; then
                echo "x gen rollback: only one generation id is accepted" >&2
                exit 1
            fi
            TARGET="$1"
            shift
            ;;
    esac
done

[[ -n "$TARGET" ]] || { usage >&2; exit 1; }

xgen_rollback "$TARGET" "$NO_SAFETY"
