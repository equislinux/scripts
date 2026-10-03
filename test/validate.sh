#!/usr/bin/env bash
set -euo pipefail

# Validation entry point: headless suite always; btrfs suite with root/sudo.
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "== headless suite (smoke: dispatch, helpers, generations) =="
bash "$SRC/test/smoke.sh"

echo
echo "== package payload =="
bash "$SRC/test/package-payload.sh"

for repo in xpm xpkg; do
    dir="$SRC/../$repo"
    if [[ -d "$dir" && -f "$dir/Cargo.toml" ]] && command -v cargo >/dev/null 2>&1; then
        echo
        echo "== $repo (cargo test --workspace) =="
        ( cd "$dir" && cargo test --workspace -q ) || exit 1
    fi
done

if [[ "$(id -u)" -eq 0 ]]; then
    echo
    echo "== btrfs suite (real loop device) =="
    bash "$SRC/test/generations-btrfs.sh"
elif sudo -n -l /usr/bin/bash "$SRC/test/generations-btrfs.sh" >/dev/null 2>&1; then
    echo
    echo "== btrfs suite (real loop device, via NOPASSWD sudo) =="
    sudo -n /usr/bin/bash "$SRC/test/generations-btrfs.sh"
else
    echo
    echo "generations-btrfs: skipped (run: sudo bash $SRC/test/generations-btrfs.sh)"
fi
