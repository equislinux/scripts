#!/usr/bin/env bash
# x:summary=Shows running/default generations, pending rollback and drift
# x:root=false
set -euo pipefail

X_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$X_ROOT/install/helpers/xgen.sh"

xgen_status
