#!/usr/bin/env bash
set -euo pipefail

# Validation entry point: headless suite always; btrfs suite with root/sudo.
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "== headless suite (smoke: dispatch, helpers, generations) =="
bash "$SRC/test/smoke.sh"

if [[ "$(id -u)" -eq 0 ]]; then
    echo
    echo "== btrfs suite (real loop device) =="
    bash "$SRC/test/generations-btrfs.sh"
elif sudo -n true 2>/dev/null; then
    echo
    echo "== btrfs suite (real loop device, via sudo) =="
    sudo -n bash "$SRC/test/generations-btrfs.sh"
else
    echo
    echo "generations-btrfs: skipped (run: sudo bash $SRC/test/generations-btrfs.sh)"
fi
