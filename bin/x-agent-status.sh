#!/usr/bin/env bash
# x:summary=Shows the installed Xscriptor AI bundle status
# x:aliases=agent-status
# x:root=false
set -euo pipefail

X_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$X_ROOT/install/helpers/common.sh"
source "$X_ROOT/install/helpers/agents.sh"

STATE="$(x_agent_state_dir)"

echo "x agent status"
if SRC="$(x_agent_source_dir 2>/dev/null)"; then
    echo "  source: $SRC (local)"
else
    echo "  source: download xscriptor-ai@$X_AGENT_REF into $X_AGENT_CACHE (no local workspace)"
fi

shopt -s nullglob
MANIFESTS=("$STATE"/*.tsv)
if [[ "${#MANIFESTS[@]}" -eq 0 ]]; then
    echo "  no installs recorded (run: x agent install)"
    exit 0
fi

for manifest in "${MANIFESTS[@]}"; do
    dest="$(sed -n 's/^# dest: //p' "$manifest" | head -n1)"
    agents="$(grep -c '^agents/' "$manifest" || true)"
    skills="$(grep -c '^skills/' "$manifest" || true)"
    commands="$(grep -c '^commands/' "$manifest" || true)"
    total="$(grep -vc '^#' "$manifest" || true)"
    echo "  destination: ${dest:-unknown}"
    echo "    agents: $agents  skills: $skills  commands: $commands  (total: $total)"
    echo "    manifest: $manifest"
done
