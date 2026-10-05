#!/usr/bin/env bash
# x:summary=Installs Xscriptor AI agents/skills/commands for OpenCode
# x:args=[--bundle x|dev|full] [--env NAME]... [--project|--dest DIR] [--source DIR] [--ref REF] [--dry-run] [--list]
# x:aliases=agent agents agent-install
# x:root=false
set -euo pipefail

X_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$X_ROOT/install/helpers/common.sh"
source "$X_ROOT/install/helpers/agents.sh"

BUNDLE="x"
DEST=""
SOURCE="${X_AGENT_SOURCE:-}"
REF=""
DRYRUN=0
LIST=0
ENVS=()

usage() {
    cat <<'EOF'
usage: x agent install [options]

Installs the Xscriptor AI bundle (agents, skills, commands) for OpenCode.

Options:
  --bundle x|dev|full   x (default): X environment packs (archiso + hyprland);
                        dev: x + senior agents and skills;
                        full: everything (all agents + skills + commands + packs)
  --env NAME            Add an environment pack (repeatable; default: archiso hyprland)
  --project             Install into ./.opencode instead of ~/.config/opencode
  --dest DIR            Explicit destination directory
  --source DIR          Local xscriptor-ai workspace (offline)
  --ref REF             Git ref to download (default: main)
  --dry-run             Print the plan without copying anything
  --list                List the items the bundle would install
  -h, --help            Show this help

Environment:
  X_AGENT_SOURCE, XSCRIPTOR_AI_DIR, X_AGENT_REF, X_AGENT_CACHE, X_AGENT_ENVS
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bundle) BUNDLE="$2"; shift 2 ;;
        --env) ENVS+=("$2"); shift 2 ;;
        --project) DEST="$(pwd)/.opencode"; shift ;;
        --dest) DEST="$2"; shift 2 ;;
        --source) SOURCE="$2"; shift 2 ;;
        --ref) REF="$2"; shift 2 ;;
        --dry-run) DRYRUN=1; shift ;;
        --list) LIST=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) error "unknown option: $1 (see x agent install --help)" ;;
    esac
done

if [[ -n "$REF" ]]; then X_AGENT_REF="$REF"; fi
if [[ -n "$SOURCE" ]]; then X_AGENT_SOURCE="$SOURCE"; fi
if [[ "${#ENVS[@]}" -gt 0 ]]; then X_AGENT_ENVS=("${ENVS[@]}"); fi
if [[ "$DRYRUN" == "1" || "$LIST" == "1" ]]; then X_AGENT_DRYRUN=1; fi

if [[ -z "$DEST" ]]; then
    DEST="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
fi

log "resolving xscriptor-ai sources"
BASE="$(x_agent_resolve)"
log "source: $BASE"

if [[ "$DRYRUN" == "1" ]]; then
    RUN_OUT="$(mktemp)"
    trap 'rm -f "$RUN_OUT"' EXIT
    x_agent_install "$BASE" "$BUNDLE" "$DEST" > "$RUN_OUT"
    cat "$RUN_OUT"
    COUNT="$(grep -c '^    - ' "$RUN_OUT" || true)"
    if [[ "$LIST" == "1" ]]; then
        echo "x agent: $COUNT item(s) in the '$BUNDLE' bundle"
    else
        echo "x agent: dry-run: '$BUNDLE' bundle -> $DEST ($COUNT item(s))"
    fi
    exit 0
fi

MANIFEST="$(x_agent_install "$BASE" "$BUNDLE" "$DEST")"
COUNT="$(grep -vc '^#' "$MANIFEST" || true)"

echo "x agent: installed $COUNT item(s) from the '$BUNDLE' bundle"
echo "         destination: $DEST"
echo "         manifest:    $MANIFEST"
echo "         restart opencode to load the new agents/skills/commands"
