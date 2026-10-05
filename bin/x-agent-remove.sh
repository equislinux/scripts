#!/usr/bin/env bash
# x:summary=Removes the installed Xscriptor AI bundle
# x:args=[--dest DIR] [--all] [--dry-run]
# x:aliases=agent-remove
# x:root=false
set -euo pipefail

X_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$X_ROOT/install/helpers/common.sh"
source "$X_ROOT/install/helpers/agents.sh"

DEST=""
ALL=0
DRYRUN=0

usage() {
    cat <<'EOF'
usage: x agent remove [options]

Removes the files recorded in the x agent manifest. Only files installed by
`x agent install` are touched.

Options:
  --dest DIR    Remove the bundle installed at DIR (default: ~/.config/opencode)
  --all         Remove every recorded destination
  --dry-run     Print what would be removed
  -h, --help    Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dest) DEST="$2"; shift 2 ;;
        --all) ALL=1; shift ;;
        --dry-run) DRYRUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) error "unknown option: $1 (see x agent remove --help)" ;;
    esac
done

remove_manifest() {
    local manifest="$1" dest rel removed=0
    dest="$(sed -n 's/^# dest: //p' "$manifest" | head -n1)"
    [[ -n "$dest" ]] || dest="$DEST"
    if [[ -z "$dest" ]]; then
        warn "manifest without destination: $manifest"
        return 0
    fi
    echo "  destination: $dest"
    while IFS= read -r rel; do
        [[ -z "$rel" || "$rel" == \#* ]] && continue
        if [[ "$DRYRUN" == "1" ]]; then
            echo "    - $rel"
        else
            rm -rf "${dest:?}/$rel"
        fi
        removed=$((removed + 1))
    done < "$manifest"

    if [[ "$DRYRUN" != "1" ]]; then
        find "$dest/skills" -mindepth 1 -type d -empty -delete 2>/dev/null || true
        rm -f "$manifest"
    fi
    echo "    removed $removed file(s)"
}

shopt -s nullglob
if [[ "$ALL" == "1" ]]; then
    MANIFESTS=("$(x_agent_state_dir)"/*.tsv)
    [[ "${#MANIFESTS[@]}" -gt 0 ]] || { echo "x agent: nothing to remove"; exit 0; }
    for manifest in "${MANIFESTS[@]}"; do
        remove_manifest "$manifest"
    done
    exit 0
fi

if [[ -z "$DEST" ]]; then
    DEST="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
fi
MANIFEST="$(x_agent_manifest "$DEST")"
if [[ ! -f "$MANIFEST" ]]; then
    echo "x agent: no install recorded for $DEST"
    exit 0
fi
remove_manifest "$MANIFEST"
