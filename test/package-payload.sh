#!/usr/bin/env bash
set -euo pipefail

# Asserts that the built x-scripts package (packaging/*.pkg.tar.zst) matches the
# branch, and that the copy bundled in the x repo is exactly that package.
# Skips silently when nothing has been built (or the x repo is absent).

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

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

pkgver="$(sed -n 's/^pkgver=//p' "$SRC/packaging/PKGBUILD" | head -1)"
pkgrel="$(sed -n 's/^pkgrel=//p' "$SRC/packaging/PKGBUILD" | head -1)"
expected="x-scripts-${pkgver}-${pkgrel}-any.pkg.tar.zst"

shopt -s nullglob
built=("$SRC"/packaging/x-scripts-*.pkg.tar.zst)
bundled=("$SRC"/../x/airootfs/root/x-installer/packages/x-scripts-*.pkg.tar.zst)
shopt -u nullglob

if [[ "${#built[@]}" -eq 0 && "${#bundled[@]}" -eq 0 ]]; then
    echo "package-payload: skip (no built package and no bundled payload)"
    exit 0
fi

echo "== built package =="
if [[ "${#built[@]}" -eq 0 ]]; then
    check "built package exists" false
else
    pkg="$(ls -1t "$SRC"/packaging/x-scripts-*.pkg.tar.zst | head -1)"
    check "built package is current (expected $expected)" \
        test "$(basename "$pkg")" = "$expected"
    listing="$(tar -tf "$pkg")"
    for f in \
        usr/share/x/install/helpers/xgen.sh \
        usr/share/x/install/helpers/xgen-home.sh \
        usr/share/x/install/helpers/xgen-system.sh \
        usr/share/x/bin/x-gen-new.sh \
        usr/share/x/bin/x-gen-boot.sh \
        usr/share/x/bin/x-home-new.sh \
        usr/share/x/hooks/pacman-gen.sh \
        usr/share/x/etc/pacman.d/hooks/10-x-gen-pre.hook \
        usr/share/x/etc/pacman.d/hooks/20-x-gen-post.hook
    do
        check "payload contains $f" grep -qxF "$f" <<< "$listing"
    done
    tar -xOf "$pkg" usr/share/x/install/helpers/xgen.sh > "$TMP/xgen.sh"
    check "xgen.sh matches the branch" cmp -s "$TMP/xgen.sh" "$SRC/install/helpers/xgen.sh"
    tar -xOf "$pkg" usr/share/x/install/helpers/xgen-home.sh > "$TMP/xgen-home.sh"
    check "xgen-home.sh matches the branch" cmp -s "$TMP/xgen-home.sh" "$SRC/install/helpers/xgen-home.sh"
    tar -xOf "$pkg" usr/share/x/install/helpers/xgen-system.sh > "$TMP/xgen-system.sh"
    check "xgen-system.sh matches the branch" cmp -s "$TMP/xgen-system.sh" "$SRC/install/helpers/xgen-system.sh"
fi

echo "== bundled payload (x repo) =="
if [[ "${#bundled[@]}" -eq 0 ]]; then
    echo "package-payload: bundled payload not present (x repo absent?)"
else
    check "exactly one bundled payload (install.sh picks the first glob)" \
        test "${#bundled[@]}" -eq 1
    check "bundled payload is $expected" test "$(basename "${bundled[0]}")" = "$expected"
    if [[ "${#built[@]}" -gt 0 ]]; then
        check "bundled payload equals the built package" cmp -s "${bundled[0]}" "$pkg"
    fi
fi

if [[ "$FAIL" -eq 0 ]]; then
    echo "package-payload: OK"
else
    echo "package-payload: failures detected"
    exit 1
fi
