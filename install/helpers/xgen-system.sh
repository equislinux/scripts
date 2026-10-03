#!/usr/bin/env bash

# xgen-system — declarative system layer (`system.toml`).
#
# `x gen plan <file>`   prints the actions needed to match the declaration.
# `x gen apply <file>`  executes them (system parts need root/sudo) and records
#                       a generation when generations are available.
#
# Supported schema (TOML subset):
#   [system]    hostname = "x" | timezone = "UTC" | locale = "en_US.UTF-8"
#   [packages]  explicit = ["kitty", "neovim"] | prune = true
#   [services]  enable = ["NetworkManager"]
#   [theme]     name = "x-dark"
#
# Removals never happen unless the corresponding `prune = true` is set.
# Requires xgen.sh to be sourced first.

XSYSTEM_ROOT="${X_GEN_ROOT:-/}"

# --- TOML subset parser -----------------------------------------------------

# Prints a scalar value or one array item per line.
xsystem_get() {
    local file="$1" section="$2" key="$3"
    [[ -f "$file" ]] || return 0
    awk -v want_sec="$section" -v want_key="$key" '
        function trim(s) { gsub(/^[ \t]+/, "", s); gsub(/[ \t]+$/, "", s); return s }
        function emit_array(s,   n, a, i, item) {
            gsub(/[][]/, "", s)
            n = split(s, a, ",")
            for (i = 1; i <= n; i++) {
                item = trim(a[i]); gsub(/^"|"$/, "", item)
                if (item != "") print item
            }
        }
        BEGIN { sec = ""; buf = ""; collecting = 0 }
        {
            line = $0
            sub(/#.*/, "", line)
            if (collecting) {
                buf = buf " " line
                if (index(line, "]")) { emit_array(buf); collecting = 0; buf = "" }
                next
            }
            if (line ~ /^[ \t]*\[/) {
                sec = trim(line); gsub(/[][]/, "", sec); sec = trim(sec)
                next
            }
            if (sec != want_sec) next
            eq = index(line, "=")
            if (eq == 0) next
            k = trim(substr(line, 1, eq - 1))
            if (k != want_key) next
            v = trim(substr(line, eq + 1))
            if (substr(v, 1, 1) == "[") {
                if (index(v, "]")) emit_array(v); else { collecting = 1; buf = v }
            } else {
                gsub(/^"|"$/, "", v)
                print v
            }
        }
    ' "$file"
}

# --- helpers ----------------------------------------------------------------

if ! declare -F run_privileged >/dev/null 2>&1; then
    run_privileged() {
        if [[ "${X_DRY_RUN:-0}" == "1" ]]; then
            echo "  (dry-run) $*"
            return 0
        fi
        if [[ "$(id -u)" -eq 0 ]]; then
            "$@"
        elif command -v sudo >/dev/null 2>&1; then
            sudo "$@"
        else
            xgen_die "cannot elevate privileges (sudo missing)"
        fi
    }
fi

if ! declare -F run_as_user >/dev/null 2>&1; then
    run_as_user() {
        if [[ "$(id -u)" -eq 0 && -n "${SUDO_USER:-}" ]]; then
            runuser -u "$SUDO_USER" -- "$@"
        else
            "$@"
        fi
    }
fi

xsystem_names_file() { # capture-file -> distinct first column
    cut -d' ' -f1 "$1" | LC_ALL=C sort -u
}

xsystem_current_packages() { # tmp file
    if [[ -n "${X_GEN_SYSTEM_PACKAGES:-}" && -f "$X_GEN_SYSTEM_PACKAGES" ]]; then
        cp -f "$X_GEN_SYSTEM_PACKAGES" "$1"
    else
        xgen_capture_packages "$1" >/dev/null
    fi
}

xsystem_current_services() { # tmp file
    if [[ -n "${X_GEN_SYSTEM_SERVICES:-}" && -f "$X_GEN_SYSTEM_SERVICES" ]]; then
        cp -f "$X_GEN_SYSTEM_SERVICES" "$1"
    else
        xgen_capture_services "$1"
    fi
}

xsystem_current_hostname() {
    head -1 "$XSYSTEM_ROOT/etc/hostname" 2>/dev/null || true
}

xsystem_current_timezone() {
    local t=""
    if [[ -L "$XSYSTEM_ROOT/etc/localtime" ]]; then
        t="$(readlink "$XSYSTEM_ROOT/etc/localtime" 2>/dev/null || true)"
        t="${t##*/zoneinfo/}"
    fi
    printf '%s\n' "$t"
}

xsystem_current_locale() {
    sed -n 's/^LANG=//p' "$XSYSTEM_ROOT/etc/locale.conf" 2>/dev/null | head -1 || true
}

xsystem_current_theme() {
    cat "${X_STATE_DIR:-$HOME/.local/state/x}/theme" 2>/dev/null || true
}

# --- plan -------------------------------------------------------------------

xgen_system_plan() {
    local file="$1"
    [[ -f "$file" ]] || xgen_die "system file not found: $file"
    echo "plan for $file:"

    local want got
    want="$(xsystem_get "$file" system hostname)"
    if [[ -n "$want" ]]; then
        got="$(xsystem_current_hostname)"
        [[ "$got" == "$want" ]] || echo "  set hostname: ${got:-none} -> $want"
    fi

    want="$(xsystem_get "$file" system timezone)"
    if [[ -n "$want" ]]; then
        got="$(xsystem_current_timezone)"
        [[ "$got" == "$want" ]] || echo "  set timezone: ${got:-none} -> $want"
    fi

    want="$(xsystem_get "$file" system locale)"
    if [[ -n "$want" ]]; then
        got="$(xsystem_current_locale)"
        [[ "$got" == "$want" ]] || echo "  set locale: ${got:-none} -> $want"
    fi

    local desired tmp names prune name extra
    desired="$(xsystem_get "$file" packages explicit)"
    if [[ -n "$desired" ]]; then
        tmp="$(mktemp)"
        xsystem_current_packages "$tmp"
        names="$(mktemp)"
        xsystem_names_file "$tmp" > "$names"
        while IFS= read -r name; do
            [[ -n "$name" ]] || continue
            grep -qxF "$name" "$names" || echo "  install package: $name"
        done <<< "$desired"
        prune="$(xsystem_get "$file" packages prune)"
        if [[ "$prune" == "true" ]]; then
            while IFS= read -r name; do
                [[ -n "$name" ]] || continue
                grep -qxF "$name" <<< "$desired" || echo "  remove package: $name"
            done < "$names"
        else
            extra=0
            while IFS= read -r name; do
                [[ -n "$name" ]] || continue
                grep -qxF "$name" <<< "$desired" || extra=$((extra + 1))
            done < "$names"
            if (( extra > 0 )); then
                echo "  info: $extra installed package(s) outside the declaration (kept; set packages.prune=true to remove)"
            fi
        fi
        rm -f "$tmp" "$names"
    fi

    desired="$(xsystem_get "$file" services enable)"
    if [[ -n "$desired" ]]; then
        tmp="$(mktemp)"
        xsystem_current_services "$tmp"
        while IFS= read -r name; do
            [[ -n "$name" ]] || continue
            grep -qxF "$name" "$tmp" || echo "  enable service: $name"
        done <<< "$desired"
        rm -f "$tmp"
    fi

    want="$(xsystem_get "$file" theme name)"
    if [[ -n "$want" ]]; then
        got="$(xsystem_current_theme)"
        [[ "$got" == "$want" ]] || echo "  set theme: ${got:-none} -> $want"
    fi

    echo "plan: nothing applied"
}

# --- apply ------------------------------------------------------------------

xgen_system_apply() {
    local file="$1" dry="${2:-0}"
    [[ -f "$file" ]] || xgen_die "system file not found: $file"
    xgen_system_plan "$file"

    if [[ "$dry" == "1" || "${X_DRY_RUN:-0}" == "1" ]]; then
        echo "apply: dry-run, nothing executed"
        return 0
    fi

    local want got tmp names name
    want="$(xsystem_get "$file" system hostname)"
    if [[ -n "$want" && "$want" != "$(xsystem_current_hostname)" ]]; then
        [[ "$want" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$ ]] || xgen_die "invalid hostname: $want"
        if command -v hostnamectl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
            run_privileged hostnamectl set-hostname "$want"
        else
            printf '%s\n' "$want" | run_privileged tee /etc/hostname >/dev/null
        fi
        echo "  hostname -> $want"
    fi

    want="$(xsystem_get "$file" system timezone)"
    if [[ -n "$want" && "$want" != "$(xsystem_current_timezone)" ]]; then
        [[ "$want" =~ ^[A-Za-z0-9_+./-]+$ ]] || xgen_die "invalid timezone: $want"
        run_privileged ln -sf "/usr/share/zoneinfo/$want" /etc/localtime
        echo "  timezone -> $want"
    fi

    want="$(xsystem_get "$file" system locale)"
    if [[ -n "$want" && "$want" != "$(xsystem_current_locale)" ]]; then
        [[ "$want" =~ ^[A-Za-z0-9_.@-]+$ ]] || xgen_die "invalid locale: $want"
        if command -v localectl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
            run_privileged localectl set-locale "LANG=$want"
        else
            printf 'LANG=%s\n' "$want" | run_privileged tee /etc/locale.conf >/dev/null
        fi
        run_privileged locale-gen >/dev/null 2>&1 || true
        echo "  locale -> $want"
    fi

    local desired
    desired="$(xsystem_get "$file" packages explicit)"
    if [[ -n "$desired" ]]; then
        tmp="$(mktemp)"
        names="$(mktemp)"
        xsystem_current_packages "$tmp"
        xsystem_names_file "$tmp" > "$names"
        local -a missing=() extras=()
        while IFS= read -r name; do
            [[ -n "$name" ]] || continue
            grep -qxF "$name" "$names" || missing+=("$name")
        done <<< "$desired"
        if [[ "$(xsystem_get "$file" packages prune)" == "true" ]]; then
            while IFS= read -r name; do
                [[ -n "$name" ]] || continue
                grep -qxF "$name" <<< "$desired" || extras+=("$name")
            done < "$names"
        fi
        if (( ${#missing[@]} > 0 )); then
            run_privileged pacman -S --needed --noconfirm "${missing[@]}"
            echo "  installed: ${missing[*]}"
        fi
        if (( ${#extras[@]} > 0 )); then
            run_privileged pacman -Rns --noconfirm "${extras[@]}"
            echo "  removed: ${extras[*]}"
        fi
        rm -f "$tmp" "$names"
    fi

    desired="$(xsystem_get "$file" services enable)"
    if [[ -n "$desired" ]]; then
        tmp="$(mktemp)"
        xsystem_current_services "$tmp"
        while IFS= read -r name; do
            [[ -n "$name" ]] || continue
            if ! grep -qxF "$name" "$tmp"; then
                run_privileged systemctl enable "$name" >/dev/null 2>&1 || true
                echo "  enabled service: $name"
            fi
        done <<< "$desired"
        rm -f "$tmp"
    fi

    want="$(xsystem_get "$file" theme name)"
    if [[ -n "$want" && "$want" != "$(xsystem_current_theme)" ]]; then
        if [[ -n "${X_BIN:-}" && -x "$X_BIN/x-theme-set.sh" ]]; then
            run_as_user bash "$X_BIN/x-theme-set.sh" "$want"
            echo "  theme -> $want"
        else
            xgen_warn "theme '$want' not applied (x-theme-set.sh not found)"
        fi
    fi

    xgen_maybe_new "apply" "system.toml" || true
    echo "apply: done"
}
