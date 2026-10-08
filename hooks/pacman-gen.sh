#!/usr/bin/env bash
# Records an x generation around pacman transactions. Installed by x-scripts
# and referenced from /usr/share/libalpm/hooks/{10-x-gen-pre,95-x-gen-post}.hook.
#
# Usage: pacman-gen.sh pre|post
#
# Guards:
#   - X_GEN_SKIP=1 disables it (x update manages its own generations).
#   - No current generation means the system is not initialized yet
#     (installer/pacstrap), so it is a no-op.
#   - Non-btrfs systems are a no-op.
#
# X_GEN_CLI points at the x CLI (tests); X_PAYLOAD_DIR overrides the payload
# root (defaults to the parent of this script's directory).
set -euo pipefail

phase="${1:-post}"

if [[ "${X_GEN_SKIP:-0}" == "1" ]]; then
    exit 0
fi

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
X_PAYLOAD="${X_PAYLOAD_DIR:-$SELF_DIR/..}"
source "$X_PAYLOAD/install/helpers/xgen.sh"

if [[ -z "$(xgen_current)" ]]; then
    exit 0
fi
xgen_supported || exit 0

cli="${X_GEN_CLI:-/usr/bin/x}"

case "$phase" in
    pre)  exec bash "$cli" gen new --reason pacman-pre --label safety ;;
    post) exec bash "$cli" gen new --reason pacman ;;
    *)
        echo "pacman-gen.sh: unknown phase '$phase' (use pre or post)" >&2
        exit 2
        ;;
esac
