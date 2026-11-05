#!/usr/bin/env bash
# System-wide Nerd Font used by the SDDM theme and equisdots.
# This payload is fetched from the signed x-scripts package so it can evolve
# without rebuilding the ISO. Failures are non-fatal for the installer.
set -euo pipefail

FONT_URL="${X_FONT_URL:-https://raw.githubusercontent.com/xscriptor-colors/terminal/main/assets/fonts/HackNerdFont/HackNerdFont-Regular.ttf}"
FONT_DIR=/usr/share/fonts/HackNerdFont
FONT_FILE="$FONT_DIR/HackNerdFont-Regular.ttf"

if [[ ! -f "$FONT_FILE" ]]; then
    tmp="$(mktemp)"
    trap 'rm -f "$tmp"' EXIT
    curl -fsSL --retry 2 --connect-timeout 10 "$FONT_URL" -o "$tmp"
    install -d -m 0755 "$FONT_DIR"
    install -m 0644 "$tmp" "$FONT_FILE"
fi
if command -v fc-cache >/dev/null 2>&1; then
    fc-cache -f >/dev/null 2>&1 || true
fi
