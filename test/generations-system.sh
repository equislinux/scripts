#!/usr/bin/env bash
set -euo pipefail

# system.toml declarative layer tests: parser, plan and dry-run apply.
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export X_GEN_BACKEND=dir
export X_GEN_ROOT="$TMP/root"
export X_GEN_STATE="$TMP/state"
export X_GEN_DIR="$X_GEN_STATE/generations"
export X_GEN_CURRENT="$X_GEN_STATE/current"
export X_GEN_SNAPSHOTS="$TMP/snapshots"
export X_GEN_BOOT=off
export X_GEN_SYSTEM_PACKAGES="$TMP/installed.tsv"
export X_GEN_SYSTEM_SERVICES="$TMP/services.txt"
export X_STATE_DIR="$TMP/user-state"
export X_BIN="$SRC/bin"

FAIL=0

check() {
    local desc="$1"
    shift
    if "$@"; then
        printf 'ok - %s\n' "$desc"
    else
        printf 'FAIL - %s\n' "$desc"
        FAIL=1
    fi
}

source "$SRC/install/helpers/xgen.sh"
source "$SRC/install/helpers/xgen-system.sh"

mkdir -p "$X_GEN_ROOT/etc" "$X_STATE_DIR"
printf 'old-host\n' > "$X_GEN_ROOT/etc/hostname"
printf 'LANG=en_US.UTF-8\n' > "$X_GEN_ROOT/etc/locale.conf"
ln -sf /usr/share/zoneinfo/UTC "$X_GEN_ROOT/etc/localtime"
printf 'foo 1.0-1\nbar 2.0-1\n' > "$X_GEN_SYSTEM_PACKAGES"
printf 'sshd.service\n' > "$X_GEN_SYSTEM_SERVICES"

cat > "$TMP/system.toml" <<'EOF'
# Declarative example
[system]
hostname = "new-host"
timezone = "Europe/Madrid"
locale = "es_ES.UTF-8"

[packages]
explicit = [
    "kitty",
    "foo",
]

[services]
enable = ["sshd.service", "NetworkManager"]

[theme]
name = "x-dark"
EOF

cat > "$TMP/prune.toml" <<'EOF'
[packages]
explicit = ["kitty", "foo"]
prune = true
EOF

echo "== parser =="
check "scalar parsed" test "$(xsystem_get "$TMP/system.toml" system hostname)" = "new-host"
check "multiline array parsed" test "$(xsystem_get "$TMP/system.toml" packages explicit | tr '\n' ' ')" = "kitty foo "
check "boolean parsed" test "$(xsystem_get "$TMP/prune.toml" packages prune)" = "true"

echo "== plan =="
PLAN="$(xgen_system_plan "$TMP/system.toml")"
check "hostname action" grep -q 'set hostname: old-host -> new-host' <<< "$PLAN"
check "timezone action" grep -q 'set timezone: UTC -> Europe/Madrid' <<< "$PLAN"
check "locale action" grep -q 'set locale: en_US.UTF-8 -> es_ES.UTF-8' <<< "$PLAN"
check "install missing package" grep -q 'install package: kitty' <<< "$PLAN"
check "does not ask to remove without prune" bash -c "! grep -q 'remove package' <<< \"\$1\"" _ "$PLAN"
check "reports extras without prune" grep -q 'outside the declaration' <<< "$PLAN"
check "service enable action" grep -q 'enable service: NetworkManager' <<< "$PLAN"
check "already enabled service skipped" bash -c "! grep -q 'enable service: sshd.service' <<< \"\$1\"" _ "$PLAN"
check "theme action" grep -q 'set theme: none -> x-dark' <<< "$PLAN"

PLAN2="$(xgen_system_plan "$TMP/prune.toml")"
check "prune asks to remove extras" grep -q 'remove package: bar' <<< "$PLAN2"

echo "== apply dry-run =="
OUT="$(xgen_system_apply "$TMP/system.toml" 1)"
check "dry-run announces no execution" grep -q 'dry-run, nothing executed' <<< "$OUT"
check "dry-run leaves the hostname untouched" test "$(cat "$X_GEN_ROOT/etc/hostname")" = "old-host"
X_DRY_RUN=1 bash "$SRC/bin/x-gen-apply.sh" "$TMP/system.toml" >/dev/null
check "X_DRY_RUN is honored" test "$(cat "$X_GEN_ROOT/etc/hostname")" = "old-host"

echo "== CLI =="
OUT="$(bash "$SRC/bin/x-gen-plan.sh" "$TMP/system.toml")"
check "dispatcher-style plan works" grep -q 'plan for' <<< "$OUT"

if [[ "$FAIL" -eq 0 ]]; then
    echo "generations-system: OK"
else
    echo "generations-system: failures detected"
    exit 1
fi
