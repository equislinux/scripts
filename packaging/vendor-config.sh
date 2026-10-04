#!/usr/bin/env bash
set -euo pipefail

# Vendors a snapshot of the desktop configs that ship inside the x-scripts
# package, so a complete Hyprland desktop can be provisioned OFFLINE after
# install (no cloning of external repos at setup time).
#
# The desktop stack lives in the equisdots org; its official installer is
# equisdots/dots. The app configs (kitty/starship/nvim) still come from the
# sibling xscriptor-colors ecosystem. All sources are used READ-ONLY and
# remain the source of truth. This script only produces a copy at
# packaging/.vendor/x-config which packaging/PKGBUILD ships to
# /usr/share/x/config and tools/hyprland-install.sh deploys from when present.
#
# Vendored layout (packaging/.vendor/x-config):
#   equisdots/{dots,hyprland,shell,palettes,theme-sync,davincix,timex,login}
#       <- equisdots org (branch main)
#   kitty/     <- xscriptor-colors/terminal (emulators/kitty only)
#                 includes shaders/ (x-glow.slang + x-trail.pipeline)
#   starship/  <- xscriptor-colors/terminal (prompts/starship only)
#   nvim/      <- xscriptor-colors/nvim
#
# Reproducibility: the resolved commits are recorded in
# packaging/vendor-config.lock. On the next run every repo is checked out at its
# pinned commit (when reachable), so rebuilding the package from the same lock
# produces the same snapshot. The lock is rewritten when it changes, so a
# maintainer commits it together with the updated snapshot.
#
# NVIDIA: nothing is excluded from the snapshot anymore. The X hardware phase
# owns the driver setup (hardware/nvidia.sh); tools/hyprland-install.sh only
# falls back to the upstream equisdots NVIDIA setup (hyprland/install.sh
# --nvidia-only) when a GPU is present without a driver, so the vendored
# snapshot must stay complete.
#
# Usage: packaging/vendor-config.sh [REPO_ROOT]
#   REPO_ROOT defaults to the repo root (parent of packaging/).
#   Refuses to run as root. Requires network access.
#
# Env:
#   X_VENDOR_BRANCH=ref  branch to clone (default: main)
#   X_VENDOR_NO_LOCK=1   ignore the lock (resolve branch tips) and rewrite it
#   X_VENDOR_LOCK=path   lock file override (default: packaging/vendor-config.lock)

source "$(dirname "${BASH_SOURCE[0]}")/../install/helpers/common.sh"

REPO_ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

if [[ "$(id -u)" -eq 0 ]]; then
    error "vendor-config must not run as root"
fi

PACKAGING="$REPO_ROOT/packaging"
STAGE="$PACKAGING/.vendor/stage"
XCFG="$PACKAGING/.vendor/x-config"
BRANCH="${X_VENDOR_BRANCH:-main}"
LOCK="${X_VENDOR_LOCK:-$PACKAGING/vendor-config.lock}"

has_cmd git || error "git is required"

# --- pinned revisions (packaging/vendor-config.lock) ------------------------
declare -A LOCK_REV=()
if [[ -f "$LOCK" && "${X_VENDOR_NO_LOCK:-0}" != "1" ]]; then
    while read -r _key _url _sha _rest; do
        [[ -z "${_key:-}" || "$_key" == \#* ]] && continue
        [[ -n "${_sha:-}" ]] && LOCK_REV["$_key"]="$_sha"
    done < "$LOCK"
    log "lock: $LOCK (${#LOCK_REV[@]} pinned repo(s))"
else
    log "lock: none (resolving the $BRANCH tip; a new lock will be written)"
fi

declare -A FULL_SHA=()
CLONE_REV=""

clone_src() { # name url ; sets CLONE_REV (short) and FULL_SHA[name]
    local name="$1" url="$2" pinned=""
    if [[ -d "$STAGE/$name" ]]; then
        rm -rf "$STAGE/$name"
    fi
    git clone -q --depth 1 --branch "$BRANCH" "$url" "$STAGE/$name"

    pinned="${LOCK_REV[$name]:-}"
    if [[ -n "$pinned" ]]; then
        if [[ "$(git -C "$STAGE/$name" rev-parse HEAD)" != "$pinned" ]]; then
            # GitHub serves arbitrary commits: fetch the pinned one directly.
            if git -C "$STAGE/$name" fetch -q --depth 1 origin "$pinned" 2>/dev/null \
               && git -C "$STAGE/$name" checkout -q FETCH_HEAD 2>/dev/null; then
                log "pin $name -> $pinned"
            else
                warn "$name: pinned commit $pinned is not fetchable; using $BRANCH tip"
            fi
        fi
    fi

    CLONE_REV="$(git -C "$STAGE/$name" rev-parse --short HEAD)"
    FULL_SHA["$name"]="$(git -C "$STAGE/$name" rev-parse HEAD)"
    rm -rf "$STAGE/$name/.git" "$STAGE/$name/.github"
}

mkdir -p "$STAGE"
rm -rf "$XCFG"

EQ_REPOS=(dots hyprland shell palettes theme-sync davincix timex login)
declare -A EQ_REV=()
declare -A SRC_URL=()

log "cloning the equisdots desktop stack (branch $BRANCH) into $STAGE"
for r in "${EQ_REPOS[@]}"; do
    SRC_URL["equisdots-$r"]="https://github.com/equisdots/$r.git"
    clone_src "equisdots-$r" "${SRC_URL[equisdots-$r]}"
    EQ_REV[$r]="$CLONE_REV"
done

log "cloning the xscriptor-colors app configs (branch $BRANCH)"
SRC_URL[terminal]="https://github.com/xscriptor-colors/terminal.git"
SRC_URL[nvim]="https://github.com/xscriptor-colors/nvim.git"
clone_src terminal "${SRC_URL[terminal]}"; TERM_REV="$CLONE_REV"
clone_src nvim "${SRC_URL[nvim]}";     NVIM_REV="$CLONE_REV"

# --- write/refresh the lock -------------------------------------------------
LOCK_ORDER=()
for r in "${EQ_REPOS[@]}"; do LOCK_ORDER+=("equisdots-$r"); done
LOCK_ORDER+=(terminal nvim)

LOCK_TMP="$(mktemp)"
{
    printf '# x — vendored desktop sources (generated by packaging/vendor-config.sh)\n'
    printf '# Re-running the script checks these exact commits out (branch: %s).\n' "$BRANCH"
    for key in "${LOCK_ORDER[@]}"; do
        printf '%s %s %s\n' "$key" "${SRC_URL[$key]}" "${FULL_SHA[$key]}"
    done
} > "$LOCK_TMP"

if [[ -f "$LOCK" ]] && cmp -s "$LOCK_TMP" "$LOCK"; then
    rm -f "$LOCK_TMP"
    log "lock unchanged: $LOCK"
else
    mv "$LOCK_TMP" "$LOCK"
    log "lock updated: $LOCK (commit it with the snapshot)"
fi

echo "== normalizing into $XCFG"

install_dir() { # src dst : copy the contents of src into dst (if src is a dir)
    if [[ -d "$1" ]]; then
        mkdir -p "$2"
        cp -a "$1/." "$2/"
    fi
}

# equisdots: every repo keeps its name under equisdots/ so the offline
# deployment mirrors the ~/.local/share/equisdots layout of `dots install`.
for r in "${EQ_REPOS[@]}"; do
    install_dir "$STAGE/equisdots-$r" "$XCFG/equisdots/$r"
done

# xscriptor-colors/terminal: kitty emulator config + starship prompt only.
# emulators/kitty/config becomes kitty.conf; themes/*.conf land under themes/.
mkdir -p "$XCFG/kitty/themes"
if [[ -f "$STAGE/terminal/emulators/kitty/config" ]]; then
    cp -a "$STAGE/terminal/emulators/kitty/config" "$XCFG/kitty/kitty.conf"
fi
install_dir "$STAGE/terminal/emulators/kitty/themes" "$XCFG/kitty/themes"

# Custom shaders (neon cursor trail). The shipped kitty.conf wires
# custom_shaders/cursor_trail*; the compiled pair must travel offline too.
install_dir "$STAGE/terminal/emulators/kitty/shaders" "$XCFG/kitty/shaders"

# prompts/starship: canonical template + per-palette themes (theme-sync
# regenerates them from the palettes).
mkdir -p "$XCFG/starship"
install_dir "$STAGE/terminal/prompts/starship" "$XCFG/starship"

# xscriptor-colors/nvim: whole config tree (what upstream clones to ~/.config/nvim).
install_dir "$STAGE/nvim" "$XCFG/nvim"

rm -rf "$STAGE"

echo "== verify: no .git/.github and the key stack files are present"
if [[ -n "$(find "$XCFG" \( -name .git -o -name .github \) -print -quit)" ]]; then
    error "vendored tree still contains .git/.github"
fi
for f in \
    equisdots/dots/dots \
    equisdots/dots/scripts/install-xwww.sh \
    equisdots/hyprland/config/hypr/hyprland.lua \
    equisdots/hyprland/config/pam.d/quickshell \
    equisdots/shell/Shell.qml \
    equisdots/palettes/x.json \
    equisdots/theme-sync/theme-sync.sh \
    equisdots/davincix/davincix.sh \
    equisdots/timex/core/timex.sh \
    equisdots/login/install.sh \
    kitty/kitty.conf \
    kitty/shaders/x-glow.slang \
    kitty/shaders/x-trail.pipeline \
    starship/starship.toml \
    nvim/init.lua \
; do
    [[ -e "$XCFG/$f" ]] || error "vendored tree is missing $f"
done

echo
echo "vendored config snapshot ready: $XCFG"
printf 'sources (branch %s, pinned in %s):\n' "$BRANCH" "$(basename "$LOCK")"
for r in "${EQ_REPOS[@]}"; do
    printf '  equisdots/%-10s @%s\n' "$r" "${EQ_REV[$r]}"
done
printf '  xscriptor-colors/terminal @%s\n' "$TERM_REV"
printf '  xscriptor-colors/nvim     @%s\n' "$NVIM_REV"
for d in equisdots kitty starship nvim; do
    printf '  %-10s %4s file(s)\n' "$d" "$(find "$XCFG/$d" -type f 2>/dev/null | wc -l | tr -d ' ')"
done
echo "regenerate the package snapshot with: packaging/vendor-config.sh"
