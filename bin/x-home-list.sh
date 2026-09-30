#!/usr/bin/env bash
# x:summary=Lists the user's home generations (dotfiles)
# x:aliases=home
# x:root=false
set -euo pipefail

X_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$X_ROOT/install/helpers/xgen-home.sh"

hgen_list
