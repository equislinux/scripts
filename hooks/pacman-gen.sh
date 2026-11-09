#!/usr/bin/env bash
# Records an x generation around package-manager transactions. Installed by
# x-scripts and referenced from /usr/share/libalpm/hooks/{10-x-gen-pre,95-x-gen-post}.hook.
#
# Usage: pacman-gen.sh pre|post
#
# The ALPM hook mechanism is shared by pacman and xpm, so the generation
# reason records which one ran the transaction (`pacman`/`xpm`, or
# `<manager>-pre` for the safety generation).
#
# Guards:
#   - X_GEN_SKIP=1 disables it (x update manages its own generations).
#   - No current generation means the system is not initialized yet
#     (installer/pacstrap), so it is a no-op.
#   - Non-btrfs systems are a no-op.
#
# X_GEN_CLI points at the x CLI (tests); X_PAYLOAD_DIR overrides the payload
# root (defaults to the parent of this script's directory).
# X_GEN_PKG_MANAGER overrides package-manager detection (tests/future tools).
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

# Identify the package manager that invoked the hook. xpm exports
# XPM_ALPM_HOOK; pacman exports no marker, so inspect the parent process.
# Fall back to pacman for manual/test invocations, preserving the historical
# behavior.
pkg_manager() {
    if [[ -n "${X_GEN_PKG_MANAGER:-}" ]]; then
        printf '%s\n' "$X_GEN_PKG_MANAGER"
        return 0
    fi
    if [[ -n "${XPM_ALPM_HOOK:-}" ]]; then
        printf 'xpm\n'
        return 0
    fi
    local parent=""
    if [[ -r "/proc/$PPID/comm" ]]; then
        IFS= read -r parent < "/proc/$PPID/comm" || true
    fi
    case "${parent##*/}" in
        xpm|pacman) printf '%s\n' "${parent##*/}" ;;
        *) printf 'pacman\n' ;;
    esac
}

manager="$(pkg_manager)"
cli="${X_GEN_CLI:-/usr/bin/x}"

case "$phase" in
    pre)  exec bash "$cli" gen new --reason "$manager-pre" --label safety ;;
    post) exec bash "$cli" gen new --reason "$manager" ;;
    *)
        echo "pacman-gen.sh: unknown phase '$phase' (use pre or post)" >&2
        exit 2
        ;;
esac
