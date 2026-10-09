#!/usr/bin/env bash
# x:summary=Exports a generation as a portable signed/encrypted bundle
# x:args=<id> [--out FILE] [--with-data] [--sign] [--encrypt | --encrypt-to KEY]
# x:root=false
set -euo pipefail

X_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$X_ROOT/install/helpers/xgen.sh"

ID=""
OUT=""
DATA=0
SIGN=0
ENC="none"
RECIPIENTS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --out) OUT="${2:?--out needs a path}"; shift 2 ;;
        --with-data) DATA=1; shift ;;
        --sign) SIGN=1; shift ;;
        --encrypt)
            if [[ "$ENC" == "recip" ]]; then
                echo "x gen export: --encrypt and --encrypt-to are mutually exclusive" >&2
                exit 1
            fi
            ENC="sym"
            shift
            ;;
        --encrypt-to)
            if [[ "$ENC" == "sym" ]]; then
                echo "x gen export: --encrypt and --encrypt-to are mutually exclusive" >&2
                exit 1
            fi
            RECIPIENTS+=("${2:?--encrypt-to needs a key}")
            ENC="recip"
            shift 2
            ;;
        -h|--help)
            echo "usage: x gen export <id> [--out FILE] [--with-data] [--sign]"
            echo "                      [--encrypt | --encrypt-to KEY]..."
            echo "  --out FILE        output bundle (default: x-gen-<id>-<date>.tar.zst[.gpg])"
            echo "  --with-data       include the snapshot (btrfs send / tree copy; root on btrfs)"
            echo "  --sign            sign with X_GEN_SIGN_KEY (detached .sig; embedded when encrypting)"
            echo "  --encrypt         symmetric AES256; passphrase via pinentry, or X_GEN_PASSPHRASE"
            echo "                    (automation only; never passed through argv)"
            echo "  --encrypt-to KEY  encrypt to a gpg key (repeatable). Signing becomes embedded"
            echo "                    (sign-then-encrypt), verified on import when the key is present."
            exit 0
            ;;
        -*)
            echo "x gen export: unknown option '$1'" >&2
            exit 1
            ;;
        *)
            if [[ -n "$ID" ]]; then
                echo "x gen export: only one generation id is accepted" >&2
                exit 1
            fi
            ID="$1"
            shift
            ;;
    esac
done

[[ -n "$ID" ]] || { echo "usage: x gen export <id> [--out FILE] [--with-data] [--sign] [--encrypt | --encrypt-to KEY]" >&2; exit 1; }
xgen_export "$ID" "$OUT" "$DATA" "$SIGN" "$ENC" "${RECIPIENTS[@]}"
