#!/usr/bin/env bash
# Optional remote payloads fetched from a signed manifest.
# This runner is intentionally conservative: every problem is a warning and
# setup continues. Payload scripts are responsible for being idempotent.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers/common.sh"

MANIFEST_URL="${X_PAYLOAD_MANIFEST_URL:-https://raw.githubusercontent.com/equislinux/scripts/main/payloads/manifest.list}"
SIGNATURE_URL="${X_PAYLOAD_SIGNATURE_URL:-${MANIFEST_URL}.sig}"
STATE_DIR="${X_PAYLOAD_STATE_DIR:-/var/lib/x/payloads}"
FORCE="${X_PAYLOADS_FORCE:-0}"

if [[ "${X_REMOTE_PAYLOADS:-1}" == "0" ]]; then
    log "remote payloads: disabled"
    exit 0
fi

for command in curl gpg sha256sum timeout; do
    if ! command -v "$command" >/dev/null 2>&1; then
        warn "remote payloads: '$command' unavailable; skipping"
        exit 0
    fi
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
manifest="$tmp/manifest.list"
signature="$tmp/manifest.list.sig"

if ! curl -fsSL --retry 2 --connect-timeout 10 --max-time 60 \
    "$MANIFEST_URL" -o "$manifest" ||
   ! curl -fsSL --retry 2 --connect-timeout 10 --max-time 60 \
    "$SIGNATURE_URL" -o "$signature"; then
    warn "remote payloads: signed manifest unavailable; skipping"
    exit 0
fi

verify_manifest() {
    if gpg --homedir /etc/pacman.d/gnupg --batch --verify \
        "$signature" "$manifest" >/dev/null 2>&1; then
        return 0
    fi

    # Fallback for a target whose pacman keyring has not imported the [x] key
    # yet. The public key is installed by the ISO installer.
    if [[ -f /etc/pacman.d/x-repo.pub ]]; then
        local home="$tmp/gnupg"
        mkdir -m 700 -p "$home"
        if gpg --homedir "$home" --batch --import \
            /etc/pacman.d/x-repo.pub >/dev/null 2>&1 &&
           gpg --homedir "$home" --batch --verify \
            "$signature" "$manifest" >/dev/null 2>&1; then
            return 0
        fi
    fi
    return 1
}

if ! verify_manifest; then
    warn "remote payloads: manifest signature is invalid; skipping"
    exit 0
fi

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

mkdir -p "$STATE_DIR"
entries=0
applied=0

while IFS='|' read -r raw_name raw_url raw_sha raw_optional; do
    name="$(trim "$raw_name")"
    url="$(trim "$raw_url")"
    sha="$(trim "$raw_sha")"
    optional="$(trim "$raw_optional")"

    [[ -n "$name" ]] || continue
    if [[ "$name" == \#* ]]; then
        continue
    fi
    if [[ ! "$name" =~ ^[A-Za-z0-9._-]+$ ]]; then
        warn "remote payloads: invalid name '$name'; skipping"
        continue
    fi
    if [[ ! "$url" =~ ^https:// ]]; then
        warn "remote payloads: '$name' has a non-https URL; skipping"
        continue
    fi
    if [[ ! "$sha" =~ ^[0-9a-fA-F]{64}$ ]]; then
        warn "remote payloads: '$name' has an invalid SHA-256; skipping"
        continue
    fi
    entries=$((entries + 1))

    state="$STATE_DIR/$name.sha256"
    if [[ "$FORCE" != "1" && -f "$state" && "$(cat "$state")" == "$sha" ]]; then
        log "remote payloads: '$name' already applied"
        continue
    fi

    script="$tmp/$name.sh"
    if ! curl -fsSL --retry 2 --connect-timeout 10 --max-time 120 \
        "$url" -o "$script"; then
        warn "remote payloads: could not download '$name'; skipping"
        continue
    fi
    if ! printf '%s  %s\n' "$sha" "$script" | sha256sum -c - >/dev/null 2>&1; then
        warn "remote payloads: checksum mismatch for '$name'; skipping"
        continue
    fi

    log "remote payloads: running '$name' (optional=$optional)"
    if timeout "${X_PAYLOAD_TIMEOUT:-600}" bash "$script"; then
        printf '%s\n' "$sha" > "$state"
        applied=$((applied + 1))
    else
        warn "remote payloads: '$name' failed; setup continues"
    fi
done < "$manifest"

log "remote payloads: $entries entry/entries, $applied applied"
exit 0
