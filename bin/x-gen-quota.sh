#!/usr/bin/env bash
# x:summary=Manages the btrfs quota for snapshots (space limit)
# x:args=init [--limit SIZE] | status
# x:root=false
set -euo pipefail

X_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$X_ROOT/install/helpers/xgen.sh"

usage() {
    echo "usage: x gen quota init [--limit SIZE]"
    echo "       x gen quota status"
    echo
    echo "  init     enables btrfs quotas and sets an exclusive limit on the"
    echo "           snapshots subvolume (SIZE like 50G; default X_GEN_QGROUP)"
    echo "  status   shows usage and the qgroup table"
}

ACTION="${1:-status}"
shift || true

case "$ACTION" in
    init)
        LIMIT=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --limit) LIMIT="${2:?--limit needs a size}"; shift 2 ;;
                *) echo "x gen quota init: unknown option '$1'" >&2; exit 1 ;;
            esac
        done
        xgen_quota_init "$LIMIT"
        ;;
    status)
        xgen_quota_status
        ;;
    -h|--help)
        usage
        ;;
    *)
        echo "x gen quota: unknown subcommand '$ACTION'" >&2
        usage >&2
        exit 1
        ;;
esac
