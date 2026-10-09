#!/usr/bin/env bash
set -euo pipefail

# Generation export/import tests without root (dir backend).
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

A="$TMP/a"
B="$TMP/b"
C="$TMP/c"

export X_GEN_BACKEND=dir
export X_GEN_ROOT="$A/root"
export X_GEN_STATE="$A/state"
export X_GEN_DIR="$X_GEN_STATE/generations"
export X_GEN_CURRENT="$X_GEN_STATE/current"
export X_GEN_SNAPSHOTS="$A/snapshots"
export X_GEN_BOOT=off
export X_GEN_CMDLINE="root=UUID=test rw"
export X_TS=20260101000000

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

mkdir -p "$X_GEN_ROOT/etc" "$X_GEN_ROOT/usr/lib/modules/6.9.0-test"
printf 'export-host\n' > "$X_GEN_ROOT/etc/hostname"
printf 'v1\n' > "$X_GEN_ROOT/etc/app.conf"

export X_GEN_LIVE_SUBVOL=/fake/0001
xgen_new install first >/dev/null
unset X_GEN_LIVE_SUBVOL

echo "== export =="
xgen_export 0001 "$TMP/meta.tar.gz" 0 >/dev/null
check "metadata bundle written" test -f "$TMP/meta.tar.gz"
check "bundle carries the manifest" bash -c "tar -tzf '$TMP/meta.tar.gz' | grep -q './manifest.json'"
check "metadata bundle has no snapshot data" bash -c "! tar -tzf '$TMP/meta.tar.gz' | grep -q './snapshot'"
check "bundle carries the checksum manifest" bash -c "tar -tzf '$TMP/meta.tar.gz' | grep -q './BUNDLE.sha256'"
xgen_export 0001 "$TMP/full.tar.gz" 1 >/dev/null
check "full bundle carries the snapshot" bash -c "tar -tzf '$TMP/full.tar.gz' | grep -q './snapshot/'"

echo "== import =="
env X_GEN_BACKEND=dir X_GEN_BOOT=off X_GEN_CMDLINE="$X_GEN_CMDLINE" \
    X_GEN_ROOT="$B/root" X_GEN_STATE="$B/state" X_GEN_DIR="$B/state/generations" \
    X_GEN_CURRENT="$B/state/current" X_GEN_SNAPSHOTS="$B/snapshots" \
    bash "$SRC/bin/x-gen-import.sh" "$TMP/meta.tar.gz" >/dev/null
check "metadata import lands in the target state" test -f "$B/state/generations/0001/manifest.json"
check "metadata import has no snapshot" test ! -e "$B/snapshots/0001"

env X_GEN_BACKEND=dir X_GEN_BOOT=off X_GEN_CMDLINE="$X_GEN_CMDLINE" \
    X_GEN_ROOT="$C/root" X_GEN_STATE="$C/state" X_GEN_DIR="$C/state/generations" \
    X_GEN_CURRENT="$C/state/current" X_GEN_SNAPSHOTS="$C/snapshots" \
    bash "$SRC/bin/x-gen-import.sh" "$TMP/full.tar.gz" >/dev/null
check "full import lands the snapshot" test -f "$C/snapshots/0001/etc/app.conf"
check "full import lands the manifest" test -f "$C/state/generations/0001/manifest.json"

echo "== restore from the imported generation =="
env X_GEN_BACKEND=dir X_GEN_BOOT=off \
    X_GEN_ROOT="$C/root" X_GEN_STATE="$C/state" X_GEN_DIR="$C/state/generations" \
    X_GEN_CURRENT="$C/state/current" X_GEN_SNAPSHOTS="$C/snapshots" \
    bash "$SRC/bin/x" gen restore /etc/app.conf --from 0001 --dest "$TMP/out/app.conf" >/dev/null
check "restore works from the imported generation" test "$(cat "$TMP/out/app.conf")" = "v1"

echo "== duplicates =="
if env X_GEN_BACKEND=dir X_GEN_BOOT=off \
    X_GEN_ROOT="$C/root" X_GEN_STATE="$C/state" X_GEN_DIR="$C/state/generations" \
    X_GEN_CURRENT="$C/state/current" X_GEN_SNAPSHOTS="$C/snapshots" \
    bash "$SRC/bin/x-gen-import.sh" "$TMP/full.tar.gz" >/dev/null 2>&1; then
    check "duplicate import fails" false
else
    check "duplicate import fails" true
fi
env X_GEN_BACKEND=dir X_GEN_BOOT=off X_GEN_CMDLINE="$X_GEN_CMDLINE" \
    X_GEN_ROOT="$C/root" X_GEN_STATE="$C/state" X_GEN_DIR="$C/state/generations" \
    X_GEN_CURRENT="$C/state/current" X_GEN_SNAPSHOTS="$C/snapshots" \
    bash "$SRC/bin/x-gen-import.sh" "$TMP/full.tar.gz" --force >/dev/null
check "duplicate import with --force replaces" test -f "$C/snapshots/0001/etc/app.conf"

echo "== integrity =="
D="$TMP/d"
mkdir -p "$TMP/tamper"
tar -xzf "$TMP/meta.tar.gz" -C "$TMP/tamper"
printf 'tampered\n' >> "$TMP/tamper/manifest.json"
tar -czf "$TMP/tampered.tar.gz" -C "$TMP/tamper" .
if OUT="$(env X_GEN_BACKEND=dir X_GEN_BOOT=off \
    X_GEN_ROOT="$D/root" X_GEN_STATE="$D/state" X_GEN_DIR="$D/state/generations" \
    X_GEN_CURRENT="$D/state/current" X_GEN_SNAPSHOTS="$D/snapshots" \
    bash "$SRC/bin/x-gen-import.sh" "$TMP/tampered.tar.gz" 2>&1)"; then
    check "tampered bundle is rejected" false
else
    check "tampered bundle is rejected" true
fi
check "rejection mentions the checksum" grep -q 'checksum' <<< "$OUT"

echo "== data policy and signing =="
mkdir -p "$TMP/datab"
tar -xzf "$TMP/meta.tar.gz" -C "$TMP/datab"
printf 'raw-btrfs-stream\n' > "$TMP/datab/snapshot.btrfs"
rm -f "$TMP/datab/BUNDLE.sha256"
tmpf="$TMP/datab.sums"
(cd "$TMP/datab" && find . -type f ! -name BUNDLE.sha256 -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum) > "$tmpf"
mv "$tmpf" "$TMP/datab/BUNDLE.sha256"
tar -czf "$TMP/datab.tar.gz" -C "$TMP/datab" .
E="$TMP/e"
if env X_GEN_BACKEND=dir X_GEN_BOOT=off \
    X_GEN_ROOT="$E/root" X_GEN_STATE="$E/state" X_GEN_DIR="$E/state/generations" \
    X_GEN_CURRENT="$E/state/current" X_GEN_SNAPSHOTS="$E/snapshots" \
    bash "$SRC/bin/x-gen-import.sh" "$TMP/datab.tar.gz" >/dev/null 2>&1; then
    check "btrfs data on the dir backend fails by default" false
else
    check "btrfs data on the dir backend fails by default" true
fi
env X_GEN_BACKEND=dir X_GEN_BOOT=off \
    X_GEN_ROOT="$E/root" X_GEN_STATE="$E/state" X_GEN_DIR="$E/state/generations" \
    X_GEN_CURRENT="$E/state/current" X_GEN_SNAPSHOTS="$E/snapshots" \
    bash "$SRC/bin/x-gen-import.sh" "$TMP/datab.tar.gz" --allow-metadata-only >/dev/null 2>&1
check "--allow-metadata-only imports the metadata" test -f "$E/state/generations/0001/manifest.json"

if X_GEN_SIGN_KEY= bash "$SRC/bin/x-gen-export.sh" 0001 --out "$TMP/unsigned.tar.gz" --sign >/dev/null 2>&1; then
    check "--sign without a key fails" false
else
    check "--sign without a key fails" true
fi

echo "== encryption =="
if command -v gpg >/dev/null 2>&1; then
    export GNUPGHOME="$TMP/gnupg"
    mkdir -m 700 -p "$GNUPGHOME"
    gpg --batch --pinentry-mode loopback --passphrase '' \
        --quick-generate-key "x test <x@test.invalid>" default default never >/dev/null 2>&1
    TEST_KEY="$(gpg --batch --with-colons --list-keys x@test.invalid 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')"
    check "test gpg key generated" test -n "$TEST_KEY"

    import_into() {
        local dir="$1" bundle="$2" pass="${3:-}"
        mkdir -p "$dir"
        if [[ -n "$pass" ]]; then
            env X_GEN_BACKEND=dir X_GEN_BOOT=off X_GEN_CMDLINE="$X_GEN_CMDLINE" X_GEN_PASSPHRASE="$pass" \
                X_GEN_ROOT="$dir/root" X_GEN_STATE="$dir/state" X_GEN_DIR="$dir/state/generations" \
                X_GEN_CURRENT="$dir/state/current" X_GEN_SNAPSHOTS="$dir/snapshots" \
                bash "$SRC/bin/x-gen-import.sh" "$bundle" >/dev/null 2>&1
        else
            env X_GEN_BACKEND=dir X_GEN_BOOT=off X_GEN_CMDLINE="$X_GEN_CMDLINE" \
                X_GEN_ROOT="$dir/root" X_GEN_STATE="$dir/state" X_GEN_DIR="$dir/state/generations" \
                X_GEN_CURRENT="$dir/state/current" X_GEN_SNAPSHOTS="$dir/snapshots" \
                bash "$SRC/bin/x-gen-import.sh" "$bundle" >/dev/null 2>&1
        fi
    }

    X_GEN_PASSPHRASE=s3cret xgen_export 0001 "$TMP/enc.tar.zst.gpg" 0 0 sym >/dev/null
    check "symmetric bundle written" test -f "$TMP/enc.tar.zst.gpg"
    check "bundle is an OpenPGP stream" xgen_is_gpg_file "$TMP/enc.tar.zst.gpg"
    check "no plaintext bundle beside it" test ! -e "$TMP/enc.tar.zst"

    check "symmetric round-trip imports" import_into "$TMP/f" "$TMP/enc.tar.zst.gpg" s3cret
    check "symmetric import lands the manifest" test -f "$TMP/f/state/generations/0001/manifest.json"

    if import_into "$TMP/g" "$TMP/enc.tar.zst.gpg" wrong >/dev/null 2>&1; then
        check "wrong passphrase is rejected" false
    else
        check "wrong passphrase is rejected" true
    fi
    check "failed decrypt leaves no generation" test ! -e "$TMP/g/state/generations/0001"

    cp "$TMP/enc.tar.zst.gpg" "$TMP/renamed.bin"
    check "renamed encrypted bundle detected by magic" import_into "$TMP/h" "$TMP/renamed.bin" s3cret
    check "renamed bundle imports" test -f "$TMP/h/state/generations/0001/manifest.json"

    xgen_export 0001 "$TMP/recip.tar.zst.gpg" 0 0 recip "$TEST_KEY" >/dev/null
    check "recipient bundle written" test -f "$TMP/recip.tar.zst.gpg"
    check "recipient round-trip imports" import_into "$TMP/i" "$TMP/recip.tar.zst.gpg"
    check "recipient import lands the manifest" test -f "$TMP/i/state/generations/0001/manifest.json"

    X_GEN_SIGN_KEY="$TEST_KEY" xgen_export 0001 "$TMP/signed.tar.zst.gpg" 0 1 recip "$TEST_KEY" >/dev/null
    check "sign+encrypt bundle written" test -f "$TMP/signed.tar.zst.gpg"
    check "sign+encrypt round-trip imports" import_into "$TMP/j" "$TMP/signed.tar.zst.gpg"
    check "sign+encrypt import lands the manifest" test -f "$TMP/j/state/generations/0001/manifest.json"

    cp "$TMP/enc.tar.zst.gpg" "$TMP/tampered.gpg"
    sz="$(stat -c %s "$TMP/tampered.gpg")"
    printf '\xff' | dd of="$TMP/tampered.gpg" bs=1 seek=$((sz - 1)) conv=notrunc status=none
    if import_into "$TMP/k" "$TMP/tampered.gpg" s3cret >/dev/null 2>&1; then
        check "tampered ciphertext is rejected" false
    else
        check "tampered ciphertext is rejected" true
    fi
else
    echo "gpg not available; skipping encryption tests"
fi

if [[ "$FAIL" -eq 0 ]]; then
    echo "generations-export: OK"
else
    echo "generations-export: failures detected"
    exit 1
fi
