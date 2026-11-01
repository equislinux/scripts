#!/usr/bin/env bash
# x:summary=Shows system and x environment info
# x:aliases=info status doctor
# x:root=false
set -euo pipefail

X_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
X_BIN="${X_BIN:-$X_ROOT/bin}"
source "$X_ROOT/install/helpers/pkg.sh"

version="dev"
if git -C "$X_ROOT" rev-parse --short HEAD >/dev/null 2>&1; then
    version="$(git -C "$X_ROOT" describe --tags --always 2>/dev/null || git -C "$X_ROOT" rev-parse --short HEAD)"
fi

echo "x $(basename "$X_ROOT") $version"
echo "repo: $X_ROOT"
echo "user: $(id -un) ($(id -u))"

pkg_count=""
if x_pkg_available_xpm; then
    if out="$(xpm query 2>/dev/null)"; then
        if [[ -n "$out" ]]; then
            pkg_count="$(printf '%s\n' "$out" | wc -l)"
        else
            pkg_count=0
        fi
    fi
fi
if [[ -z "$pkg_count" ]] && command -v pacman >/dev/null 2>&1; then
    pkg_count="$(pacman -Q 2>/dev/null | wc -l)"
fi
if [[ -n "$pkg_count" ]]; then
    echo "dist: arch (packages: $pkg_count)"
else
    echo "dist: no-pacman"
fi

theme_file="${X_STATE_DIR:-$HOME/.local/state/x}/theme"
if [[ -f "$theme_file" ]]; then
    echo "theme: $(cat "$theme_file")"
fi
