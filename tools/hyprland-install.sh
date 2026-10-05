#!/usr/bin/env bash
set -euo pipefail

# Non-interactive Hyprland/equisdots desktop setup for X Linux.
#
# The desktop stack moved to the equisdots org (hyprland, shell, palettes,
# theme-sync, davincix, timex, login) and its official installer is
# equisdots/dots. This tool is the X-specific non-interactive orchestrator:
#
#   OFFLINE (default on an installed system): the whole equisdots snapshot
#     ships inside x-scripts at $X_HYPR_CONFIG/equisdots (regenerated with
#     packaging/vendor-config.sh) and is placed exactly like `dots install`
#     does (configs, shell, palettes, engines, wrappers, login theme, PAM).
#   ONLINE fallback (dev checkout / snapshot absent): clones equisdots/dots to
#     the cache and runs `dots install` (the official placement).
#
# NVIDIA is owned by the X hardware phase (hardware/nvidia.sh). This tool only
# falls back to the upstream equisdots NVIDIA setup (hyprland/install.sh
# --nvidia-only) when an NVIDIA GPU is present and no driver is installed, so
# the full `dots system` phase (and its nvidia-dkms choice) never runs here.
# Nothing in the equisdots org is modified: repos are used read-only.
#
# Runs as the TARGET USER (never as root): root operations go through sudo.
#
# Env:
#   X_HYPR_CONFIG     packaged config tree (default: /usr/share/x/config)
#   X_HYPR_SOURCE     snapshot root override (tests/dev; $X_HYPR_SOURCE/equisdots)
#   X_HYPR_REF        branch/commit of the equisdots/dots fallback (default: main)
#   X_HYPR_BASE       equisdots data dir (default: ~/.local/share/equisdots)
#   X_HYPR_DRYRUN     1 = resolve the source and print the plan only
#   X_HYPR_OFFLINE    1 = force offline mode (never clone; error if no snapshot)
#   X_HYPR_KEEP_SRC   1 = keep the temporary equisdots/dots clone

source "$(dirname "${BASH_SOURCE[0]}")/../install/helpers/common.sh"

if [[ "$(id -u)" -eq 0 ]]; then
    error "hyprland setup must run as the target user, not root"
fi

X_HYPR_REF="${X_HYPR_REF:-main}"
X_HYPR_CONFIG="${X_HYPR_CONFIG:-/usr/share/x/config}"
BASE="${X_HYPR_BASE:-${XDG_DATA_HOME:-$HOME/.local/share}/equisdots}"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/x"
CONFIG_DIR="$HOME/.config"
HYPR="$CONFIG_DIR/hypr"
QS="$HYPR/scripts/quickshell"
BIN="$HOME/.local/bin"
UPSTREAM_URL="https://github.com/equisdots/dots.git"

root() { sudo "$@"; }

mkdir -p "$CACHE"

# --- resolve the payload source (offline snapshot first) -------------------
PAYLOAD="${X_HYPR_SOURCE:-$X_HYPR_CONFIG}"
MODE=""
CFG=""
SRC=""
DOTS_BIN=""

if [[ -d "$PAYLOAD/equisdots/hyprland" ]]; then
    CFG="$PAYLOAD"
    MODE="offline"
    log "offline payload found in packaged tree: $CFG/equisdots"
elif [[ "${X_HYPR_OFFLINE:-0}" == "1" ]]; then
    error "offline mode requested but no equisdots snapshot at $PAYLOAD/equisdots"
else
    MODE="online"
    SRC="$(mktemp -d "$CACHE/equisdots-dots.XXXXXX")"
    [[ "${X_HYPR_KEEP_SRC:-0}" != "1" ]] && trap 'rm -rf "$SRC"' EXIT
    log "cloning $UPSTREAM_URL (branch $X_HYPR_REF)"
    git clone -q --depth 1 --branch "$X_HYPR_REF" "$UPSTREAM_URL" "$SRC/dots"
    DOTS_BIN="$SRC/dots/dots"
fi

# Payload paths per mode. The offline tree mirrors the ~/.local/share/equisdots
# layout of `dots install` (equisdots/<repo>).
if [[ "$MODE" == "offline" ]]; then
    HYPR_SRC="$CFG/equisdots/hyprland"
    LOGIN_SRC="$CFG/equisdots/login"
    XWWW_SRC="$CFG/equisdots/dots/scripts/install-xwww.sh"
    KITTY_SRC="$CFG/kitty"
    STARSHIP_SRC="$CFG/starship"
    NVIM_SRC="$CFG/nvim"
else
    HYPR_SRC="$BASE/hyprland"
    LOGIN_SRC="$BASE/login"
    XWWW_SRC="$BASE/dots/scripts/install-xwww.sh"
    KITTY_SRC=""
    STARSHIP_SRC=""
    NVIM_SRC=""
fi

if [[ "${X_HYPR_DRYRUN:-0}" == "1" ]]; then
    if [[ "$MODE" == "offline" ]]; then
        log "dry-run: install deps + deploy the equisdots snapshot from $CFG (offline) + login/PAM/services"
    else
        log "dry-run: clone equisdots/dots + install deps + deploy the payload + login/PAM/services"
    fi
    exit 0
fi

# --- build jobs vs RAM -------------------------------------------------------
# AUR source builds (quickshell-git/swayosd-git/...) can exceed 4 GB with one
# job per core. Limit the jobs on low-RAM machines so the install does not get
# OOM-killed halfway. 8 GB guests still OOMed with one job per core, so the
# -j2 band covers up to 10 GB.
if [[ -r /proc/meminfo ]]; then
    MEM_MB="$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)"
    if (( MEM_MB < 6000 )); then
        export MAKEFLAGS="-j1"
        export CARGO_BUILD_JOBS=1
        log "low RAM (${MEM_MB} MB): limiting AUR build jobs to 1"
    elif (( MEM_MB < 10000 )); then
        export MAKEFLAGS="-j2"
        export CARGO_BUILD_JOBS=2
        log "low RAM (${MEM_MB} MB): limiting AUR build jobs to 2"
    fi
fi

# --- package split: official (repos) vs AUR ---------------------------------
OFFICIAL=(
    hyprland hypridle hyprpolkitagent xdg-desktop-portal-hyprland
    xdg-desktop-portal-gtk xdg-desktop-portal-wlr qt5-wayland qt6-wayland
    qt5ct qt6ct polkit-kde-agent xorg-xwayland
    rofi rofi-emoji jq imagemagick librsvg
    kitty starship shader-slang
    dunst grim slurp wl-clipboard cliphist brightnessctl ddcutil pamixer
    playerctl hyprpicker libnotify iproute2 pciutils rust pavucontrol
    networkmanager sddm pipewire pipewire-alsa pipewire-pulse wireplumber
    network-manager-applet blueman bluez bluez-utils xdg-utils xdg-user-dirs
    wget curl rsync git base-devel gnome-keyring seahorse kwallet5 libsecret
    noto-fonts noto-fonts-emoji noto-fonts-cjk adw-gtk-theme papirus-icon-theme
    nautilus gvfs gvfs-mtp cava zbar fd ripgrep socat inotify-tools acpi iw
    lm_sensors bc python python-websockets qt6-websockets ffmpeg fastfetch
    satty yq wmctrl power-profiles-daemon easyeffects lsp-plugins
    gpu-screen-recorder qt5-quickcontrols qt5-quickcontrols2
    qt5-graphicaleffects unzip
)

AUR=(
    quickshell-git swayosd-git bibata-cursor-theme mpvpaper
    networkmanager-dmenu-git
)

# The config targets quickshell-git/swayosd-git; drop the official releases
# first so the AUR versions can be installed without conflicts. (The upstream
# list also names rofi-wayland, which no longer exists: the official rofi 2.x
# is Wayland-capable and is what this tool installs.)
root pacman -R --noconfirm quickshell swayosd 2>/dev/null || true

echo "== official packages"
root pacman -S --needed --noconfirm "${OFFICIAL[@]}" || warn "some official packages failed"

if (( ${#AUR[@]} )); then
    HELPER=""
    has_cmd yay && HELPER="yay"
    has_cmd paru && HELPER="paru"

    if [[ -z "$HELPER" ]]; then
        echo "== installing yay (as user)"
        root pacman -S --needed --noconfirm base-devel >/dev/null 2>&1 || true
        YAY_TMP="$(mktemp -d "$CACHE/yay.XXXXXX")"
        git clone -q https://aur.archlinux.org/yay.git "$YAY_TMP/yay"
        (cd "$YAY_TMP/yay" && makepkg -si --noconfirm) || warn "yay build failed"
        rm -rf "$YAY_TMP"
        has_cmd yay && HELPER="yay"
    fi

    if [[ -n "$HELPER" ]]; then
        for p in "${AUR[@]}"; do
            echo "== aur: $p ($HELPER)"
            "$HELPER" -S --needed --noconfirm "$p" || warn "aur package $p failed"
        done
    else
        warn "no AUR helper available; AUR packages skipped"
    fi
fi

# --- user payload: mirror `dots install` (offline) or delegate to dots -----
# Every deploy step is best-effort: a failure is warned and the run continues
# so the user-level commands (~/.local/bin) always end up available.
sync_tree() { # src dst [extra rsync args...] : src/. -> dst/ , no-op if src missing
    local src="$1" dst="$2"; shift 2
    [[ -d "$src" ]] || return 0
    mkdir -p "$dst" 2>/dev/null || true
    if has_cmd rsync; then
        rsync -a "$@" "$src/" "$dst/" || warn "sync failed: $src -> $dst"
    else
        cp -a "$src/." "$dst/" || warn "copy failed: $src -> $dst"
    fi
    return 0
}

# Stage a vendored repo into BASE unless a managed (git) clone already exists.
stage_repo() { # name
    local name="$1"
    local src="$CFG/equisdots/$name" dst="$BASE/$name"
    [[ -d "$src" ]] || return 0
    if [[ -d "$dst/.git" ]]; then
        log "payload: keeping the managed clone of $name"
        return 0
    fi
    sync_tree "$src" "$dst" --exclude '.git*' --exclude 'docs/'
}

# engine/meta wrappers in ~/.local/bin (same contract as `dots install`).
# Written right after staging so the commands survive a later deploy failure.
write_wrappers() {
    mkdir -p "$BIN" 2>/dev/null || return 0
    cat > "$BIN/theme-sync" <<WRAP
#!/usr/bin/env bash
# equisdots · theme-sync wrapper (engine lives in its own repo)
exec "$BASE/theme-sync/theme-sync.sh" "\$@"
WRAP
    cat > "$BIN/davincix" <<WRAP
#!/usr/bin/env bash
# equisdots · davincix wrapper (kernel lives in its own repo)
exec "$BASE/davincix/davincix.sh" "\$@"
WRAP
    cat > "$BIN/dots" <<WRAP
#!/usr/bin/env bash
# equisdots · dots wrapper (meta installer lives in its own repo)
exec "$BASE/dots/dots" "\$@"
WRAP
    cat > "$BIN/timex" <<WRAP
#!/usr/bin/env bash
# equisdots · timex wrapper (engine lives in its own repo)
exec "$BASE/timex/core/timex.sh" "\$@"
WRAP
    chmod +x "$BIN/theme-sync" "$BIN/davincix" "$BIN/dots" "$BIN/timex" 2>/dev/null || true
}

offline_payload() {
    log "payload: staging the equisdots snapshot into $BASE"
    mkdir -p "$BASE" 2>/dev/null || true
    local r
    for r in dots hyprland shell palettes theme-sync davincix timex login; do
        stage_repo "$r"
    done
    write_wrappers
    find "$BASE/timex" -name '*.sh' -exec chmod +x {} + 2>/dev/null || true

    # hyprland: config + app configs + scripts (mirrors dots sync_repo)
    log "hyprland: config -> $HYPR"
    sync_tree "$HYPR_SRC/config/hypr" "$HYPR" --exclude 'docs/' --exclude '.git*'
    local c
    for c in rofi dunst cava; do
        sync_tree "$HYPR_SRC/config/$c" "$CONFIG_DIR/$c" --exclude '.git*'
    done
    mkdir -p "$HYPR/scripts" 2>/dev/null || true
    sync_tree "$HYPR_SRC/scripts" "$HYPR/scripts" --exclude '.git*'
    chmod +x "$HYPR/scripts"/*.sh 2>/dev/null || true

    # Purge legacy artifacts from the pre-equisdots layout.
    rm -rf "$HYPR/scripts/themesync"
    rm -f "$HYPR/scripts/theme-sync.sh" "$HYPR/scripts/sddm-colors.sh" \
          "$HYPR/sddm-colors.sh" "$HYPR/sddm-colors.qml"

    # Monthly dotfiles check (systemd --user timer, user-level).
    if [[ -x "$HYPR/scripts/dotfiles-update.sh" ]] && has_cmd systemctl; then
        bash "$HYPR/scripts/dotfiles-update.sh" --install-timer >/dev/null 2>&1 || true
    fi

    # shell: Quickshell UI -> quickshell/ (palettes are a frozen contract and
    # survive under dock/; rsync --delete purges stale shell files when present).
    log "shell: quickshell -> $QS"
    sync_tree "$BASE/shell" "$QS" --delete --exclude '.git*' --exclude 'docs/' --exclude 'dock/'
    find "$QS" -name '*.sh' -exec chmod +x {} + 2>/dev/null || true

    # palettes -> quickshell/dock/palettes (the old index.json is regenerated
    # from the palettes repo, which is now the owner of the ordered list).
    log "palettes -> $QS/dock/palettes"
    mkdir -p "$QS/dock/palettes" 2>/dev/null || true
    rm -f "$QS/dock/palettes/index.json"
    cp -f "$BASE/palettes"/*.json "$QS/dock/palettes/" 2>/dev/null || true
    sync_tree "$BASE/timex/ui" "$QS/ui/timex" --delete --exclude '.git*' --exclude 'docs/'

    # settings.json is ALWAYS default_settings.json + the user's values.
    if [[ ! -f "$HYPR/settings.json" && -f "$HYPR/default_settings.json" ]]; then
        cp "$HYPR/default_settings.json" "$HYPR/settings.json" 2>/dev/null || true
        log "settings.json seeded from default_settings.json"
    fi
    if [[ -f "$HYPR/settings.json" && -f "$HYPR/default_settings.json" ]] \
       && has_cmd jq; then
        local tmp
        tmp="$(mktemp)"
        if jq --slurpfile def "$HYPR/default_settings.json" '
            (if (has("dock") and (has("bar") | not)) then .bar = .dock else . end)
            | del(.dock, .serpbar, .openGuideAtStartup, .topbarHelpIcon, .monitors)
            | $def[0] * .
        ' "$HYPR/settings.json" > "$tmp" 2>/dev/null; then
            mv "$tmp" "$HYPR/settings.json"
        else
            rm -f "$tmp"
            warn "settings.json could not be migrated (left untouched)"
        fi
    fi
}

# kitty custom shaders: the vendored snapshot ships shaders/ next to the
# config (which already wires custom_shaders/cursor_trail). Ensure the keys are
# present (idempotent) and warn when the shader compiler is missing, since kitty
# disables custom_shaders silently in that case.
ensure_kitty_shader_config() {
    local conf="$CONFIG_DIR/kitty/kitty.conf" added=0
    [[ -f "$conf" ]] || return 0
    if ! grep -qE '^[[:space:]]*custom_shaders[[:space:]]' "$conf"; then
        printf '\ncustom_shaders x-trail\n' >> "$conf"
        added=1
    fi
    if ! grep -qE '^[[:space:]]*cursor_trail[[:space:]]' "$conf"; then
        printf 'cursor_trail 12\n' >> "$conf"
        added=1
    fi
    if ! grep -qE '^[[:space:]]*cursor_trail_start_threshold[[:space:]]' "$conf"; then
        printf 'cursor_trail_start_threshold 0\n' >> "$conf"
        added=1
    fi
    [[ "$added" -eq 1 ]] && log "kitty shaders: enabled the neon trail in kitty.conf"
    if [[ -d "$CONFIG_DIR/kitty/shaders" ]] && ! has_cmd slangc; then
        warn "kitty shaders: slangc missing (shader-slang); kitty will ignore custom_shaders"
    fi
    return 0
}

if [[ "$MODE" == "offline" ]]; then
    offline_payload
else
    log "payload: running the official installer (equisdots/dots install)"
    bash "$DOTS_BIN" install || warn "dots install finished with warnings"
fi

# --- xwww wallpaper daemon (davincix needs it) ------------------------------
# The standalone installer lives in equisdots/dots; it downloads the
# checksum-verified release (source build as fallback) into /usr/local/bin.
if ! has_cmd xwww-daemon; then
    if [[ -x "$XWWW_SRC" ]]; then
        echo "== xwww (wallpaper daemon)"
        bash "$XWWW_SRC" || warn "xwww installation failed (wallpaper daemon)"
    else
        warn "xwww installer not found; install it later with: dots system"
    fi
fi

# --- app configs from the snapshot (kitty/starship/nvim) --------------------
if [[ -n "$KITTY_SRC" && -d "$KITTY_SRC" ]]; then
    echo "== kitty config (offline)"
    sync_tree "$KITTY_SRC" "$CONFIG_DIR/kitty" --exclude '.git*'
    ensure_kitty_shader_config
fi
if [[ -n "$STARSHIP_SRC" && -d "$STARSHIP_SRC" ]]; then
    echo "== starship config (offline)"
    # Canonical root expected by theme-sync (~/.config/equisdots/starship).
    sync_tree "$STARSHIP_SRC" "$CONFIG_DIR/equisdots/starship" --exclude '.git*'
fi
if [[ -n "$NVIM_SRC" && -d "$NVIM_SRC" ]]; then
    echo "== nvim config (offline)"
    sync_tree "$NVIM_SRC" "$CONFIG_DIR/nvim" --exclude '.git*' --exclude '.github/'
fi

# Palette artifacts for the freshly deployed app configs (offline snapshot).
if [[ "$MODE" == "offline" && -x "$BASE/theme-sync/theme-sync.sh" ]] \
   && has_cmd python3 && has_cmd jq; then
    echo "== theme-sync (palette artifacts)"
    bash "$BASE/theme-sync/theme-sync.sh" || warn "theme-sync finished with warnings"
fi

mkdir -p "$HOME/Pictures/Screenshots" "$HOME/Pictures/Wallpapers" "$HYPR/wallpapers"

# --- version state ----------------------------------------------------------
if [[ -f "$HYPR_SRC/updates.json" ]] && has_cmd jq; then
    V="$(jq -r '.version // empty' "$HYPR_SRC/updates.json" 2>/dev/null || true)"
fi
V="${V:-x-1}"
mkdir -p "$HOME/.local/state"
printf 'LOCAL_VERSION="%s"\n' "$V" > "$HOME/.local/state/equisdots-version"

# --- fonts -----------------------------------------------------------------
FONT="$HOME/.local/share/fonts/HackNerdFont-Regular.ttf"
if [[ ! -f "$FONT" ]]; then
    echo "== font"
    mkdir -p "$HOME/.local/share/fonts"
    wget -q -O "$FONT" \
        "https://raw.githubusercontent.com/xscriptor-colors/terminal/main/assets/fonts/HackNerdFont/HackNerdFont-Regular.ttf" \
        || warn "font download failed"
    fc-cache -f >/dev/null 2>&1 || true
fi
root bash -c "cp '$FONT' /usr/share/fonts/ 2>/dev/null; fc-cache -f >/dev/null 2>&1 || true" || true

# --- SDDM login theme (equisdots/login) -------------------------------------
echo "== sddm login theme"
if [[ -x "$LOGIN_SRC/install.sh" ]]; then
    bash "$LOGIN_SRC/install.sh" || warn "login theme installation failed"
elif [[ "$MODE" == "online" ]]; then
    log "login repo not found; cloning equisdots/login..."
    mkdir -p "$BASE"
    if git clone -q --depth 1 https://github.com/equisdots/login "$BASE/login" 2>/dev/null; then
        bash "$BASE/login/install.sh" || warn "login theme installation failed"
    else
        warn "could not clone equisdots/login; skipping the SDDM theme"
    fi
fi

# --- PAM: quickshell lock screen --------------------------------------------
echo "== PAM (quickshell lock)"
PAM_SRC="$HYPR_SRC/config/pam.d/quickshell"
if [[ -f /etc/pam.d/quickshell ]] && grep -q "system-auth" /etc/pam.d/quickshell 2>/dev/null; then
    log "PAM service 'quickshell' already configured"
elif [[ -f "$PAM_SRC" ]]; then
    [[ -f /etc/pam.d/quickshell ]] && root cp /etc/pam.d/quickshell /etc/pam.d/quickshell.backup || true
    root tee /etc/pam.d/quickshell < "$PAM_SRC" >/dev/null || true
fi

# --- services ---------------------------------------------------------------
echo "== services"
root systemctl enable NetworkManager.service 2>/dev/null || true
root systemctl enable sddm.service 2>/dev/null || true
root systemctl enable power-profiles-daemon.service 2>/dev/null || true
root systemctl enable swayosd-libinput-backend.service 2>/dev/null || true
root systemctl enable bluetooth.service 2>/dev/null || true
root systemctl --global enable pipewire pipewire-pulse wireplumber 2>/dev/null || true
systemctl --user enable easyeffects.service 2>/dev/null || true

# --- NVIDIA fallback --------------------------------------------------------
# The X hardware phase owns the driver setup. Only when a GPU is present and
# no driver got installed, delegate to the upstream equisdots NVIDIA setup
# (read-only: it is the repo's own installer). When the driver is already
# there, complete the equisdots GPU-mode feature (envycontrol + sudoers rule)
# only if it is missing.
if has_cmd lspci && lspci 2>/dev/null | grep -qiE 'vga.*nvidia|3d.*nvidia'; then
    if ! root pacman -Qq nvidia nvidia-dkms nvidia-open nvidia-open-dkms >/dev/null 2>&1; then
        warn "NVIDIA GPU without a driver: falling back to the equisdots NVIDIA setup"
        bash "$HYPR_SRC/install.sh" --nvidia-only -y || warn "NVIDIA fallback failed; run: sudo bash $HYPR_SRC/install.sh --nvidia-only"
    elif ! has_cmd envycontrol; then
        GPU_HELPER=""
        has_cmd yay && GPU_HELPER="yay"
        has_cmd paru && GPU_HELPER="paru"
        if [[ -n "$GPU_HELPER" ]]; then
            log "NVIDIA: installing envycontrol (gpu-mode.sh)"
            "$GPU_HELPER" -S --needed --noconfirm envycontrol || warn "envycontrol installation failed"
            if has_cmd envycontrol; then
                root tee /etc/sudoers.d/99-gpu-mode >/dev/null <<'EOF'
%wheel ALL=(ALL) NOPASSWD: /usr/bin/envycontrol -s *
EOF
                root chmod 440 /etc/sudoers.d/99-gpu-mode || true
            fi
        else
            warn "NVIDIA: envycontrol missing and no AUR helper; gpu-mode.sh will not switch modes"
        fi
    fi
fi

# --- ~/.local/bin on PATH ---------------------------------------------------
# The dots/timex/davincix/theme-sync wrappers live in ~/.local/bin; make them
# reachable from interactive shells and TTY logins even when the desktop did
# not start (so the stack can be repaired with: dots install / x setup --user).
ensure_local_bin_path() {
    local line='export PATH="$HOME/.local/bin:$PATH"' rc added=0
    for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile"; do
        [[ -f "$rc" ]] || continue
        if ! grep -q '\.local/bin' "$rc"; then
            printf '\n# equisdots: local bin\n%s\n' "$line" >> "$rc"
            log "PATH: ~/.local/bin added to $rc"
            added=1
        fi
    done
    if [[ "$added" -eq 0 && ! -f "$HOME/.profile" ]]; then
        printf '# equisdots: local bin\n%s\n' "$line" > "$HOME/.profile"
        log "PATH: created ~/.profile with ~/.local/bin"
    fi
}
ensure_local_bin_path

# zsh: the full profile ships grml-zsh-config, whose own /etc/skel/.zshrc was
# seeded at useradd time, so the X seed never lands. Append the starship init
# line idempotently (preserves grml's setup; no-op without starship).
ensure_zsh_starship_init() {
    local rc="$HOME/.zshrc"
    [[ -f "$rc" ]] || return 0
    if grep -qF "starship init zsh" "$rc" 2>/dev/null; then
        return 0
    fi
    {
        printf '\n# x: starship prompt\n'
        printf 'command -v starship >/dev/null 2>&1 && eval "$(starship init zsh)"\n'
    } >> "$rc"
    log "starship: init line added to $rc"
}
ensure_zsh_starship_init

echo "hyprland setup complete. Reboot and select Hyprland in SDDM."
log "user-level commands available: dots, theme-sync, davincix, timex (~/.local/bin)"
log "recovery from a TTY: x setup --user (re-deploy) / dots install (payload update)"
