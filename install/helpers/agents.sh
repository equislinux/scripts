#!/usr/bin/env bash
# Shared helpers for `x agent ...`: install Xscriptor AI agents, skills and
# commands for OpenCode from the xscriptor-ai repositories.
#
# Source resolution (first match wins):
#   1. X_AGENT_SOURCE       -> a workspace dir with agents/, skills/, environments/
#   2. XSCRIPTOR_AI_DIR     -> same shape as above
#   3. sibling checkout     -> <parent of this repo>/xscriptor-ai
#   4. download             -> codeload tarballs of agents/skills/environments
#                              at X_AGENT_REF (default: main), cached under
#                              ~/.cache/x/agents/<ref>/
#
# Destinations follow the OpenCode layout:
#   <dest>/agents/*.md
#   <dest>/skills/<name>/SKILL.md (+ references/)
#   <dest>/commands/*.md
#
# Every install records the copied relative paths in a manifest under
# ~/.local/state/x/agents/ so `x agent status|remove` can work without
# touching unrelated user files.

X_AGENT_REPOS=(agents skills environments)
X_AGENT_REF="${X_AGENT_REF:-main}"
X_AGENT_CACHE="${X_AGENT_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/x/agents}"
X_AGENT_DEFAULT_ENVS=(archiso hyprland)

x_agent_state_dir() {
    printf '%s' "${X_AGENT_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/x/agents}"
}

# Manifest path for a destination directory (stable, filesystem-safe name).
x_agent_manifest() {
    local dest="$1" key
    key="$(printf '%s' "$dest" | tr '/ ' '__')"
    printf '%s/%s.tsv' "$(x_agent_state_dir)" "$key"
}

# Local workspace source, if available.
x_agent_source_dir() {
    local base=""
    if [[ -n "${X_AGENT_SOURCE:-}" && -d "${X_AGENT_SOURCE}" ]]; then
        base="${X_AGENT_SOURCE}"
    elif [[ -n "${XSCRIPTOR_AI_DIR:-}" && -d "${XSCRIPTOR_AI_DIR}" ]]; then
        base="${XSCRIPTOR_AI_DIR}"
    else
        local sibling
        sibling="$(dirname "$X_ROOT")/xscriptor-ai"
        [[ -d "$sibling" ]] && base="$sibling"
    fi

    [[ -n "$base" ]] || return 1

    # Accept either a workspace (with agents/ + skills/ + environments/) or a
    # single repo root (e.g. the agents repo itself).
    if [[ -d "$base/agents" || -d "$base/environments" || -d "$base/skills" ]]; then
        printf '%s' "$base"
        return 0
    fi
    return 1
}

# Download the three repos into the cache and echo the base dir.
x_agent_download() {
    local base="$X_AGENT_CACHE/$X_AGENT_REF" repo dst url
    mkdir -p "$X_AGENT_CACHE"
    for repo in "${X_AGENT_REPOS[@]}"; do
        dst="$base/$repo"
        if [[ -f "$dst/.x-downloaded" ]]; then
            continue
        fi
        rm -rf "$dst"
        mkdir -p "$dst"
        url="https://codeload.github.com/xscriptor-ai/$repo/tar.gz/refs/heads/$X_AGENT_REF"
        log "downloading xscriptor-ai/$repo@$X_AGENT_REF"
        if has_cmd curl && has_cmd tar; then
            curl -fsSL "$url" | tar -xz -C "$dst" --strip-components=1
        elif has_cmd git; then
            rm -rf "$dst"
            git clone --depth 1 --branch "$X_AGENT_REF" \
                "https://github.com/xscriptor-ai/$repo.git" "$dst"
        else
            error "need curl+tar or git to download xscriptor-ai/$repo"
        fi
        : > "$dst/.x-downloaded"
    done
    printf '%s' "$base"
}

# Resolve a usable source base (local first, download otherwise).
x_agent_resolve() {
    x_agent_source_dir || x_agent_download
}

# Print every directory containing a SKILL.md under the given root.
x_agent_find_skills() {
    find "$1" -name SKILL.md -not -path '*/node_modules/*' -printf '%h\n' 2>/dev/null | sort -u
}

# Copy one item (file or directory) and record it in the manifest.
x_agent_emit() {
    local src="$1" rel="$2" manifest="$3" dest="$4"
    if [[ "${X_AGENT_DRYRUN:-0}" == "1" ]]; then
        printf '    - %s\n' "$rel"
        return 0
    fi
    mkdir -p "$dest/$(dirname "$rel")"
    if [[ -d "$src" ]]; then
        rm -rf "${dest:?}/$rel"
        cp -a "$src" "$dest/$(dirname "$rel")/"
    else
        cp -f "$src" "$dest/$rel"
    fi
    printf '%s\n' "$rel" >> "$manifest"
}

x_agent_add_agents_from() {
    local dir="$1" dest="$2" manifest="$3" f
    [[ -d "$dir" ]] || return 0
    while IFS= read -r f; do
        x_agent_emit "$f" "agents/$(basename "$f")" "$manifest" "$dest"
    done < <(find "$dir" -type f -name '*.md' ! -name 'README.md' | sort)
}

x_agent_add_skills_from() {
    local root="$1" dest="$2" manifest="$3" dir name
    [[ -d "$root" ]] || return 0
    while IFS= read -r dir; do
        name="$(basename "$dir")"
        x_agent_emit "$dir" "skills/$name" "$manifest" "$dest"
    done < <(x_agent_find_skills "$root")
}

x_agent_add_commands_from() {
    local dir="$1" dest="$2" manifest="$3" f
    [[ -d "$dir" ]] || return 0
    while IFS= read -r f; do
        x_agent_emit "$f" "commands/$(basename "$f")" "$manifest" "$dest"
    done < <(find "$dir" -maxdepth 1 -type f -name '*.md' ! -name 'README.md' | sort)
}

# Environment packs: <base>/environments/<env>/{agents,skills,commands}
x_agent_add_env() {
    local base="$1" env="$2" dest="$3" manifest="$4" root="$base/environments/$env"
    [[ -d "$root" ]] || return 1
    x_agent_add_agents_from "$root/agents" "$dest" "$manifest"
    x_agent_add_skills_from "$root/skills" "$dest" "$manifest"
    x_agent_add_commands_from "$root/commands" "$dest" "$manifest"
    return 0
}

x_agent_add_envs() {
    local base="$1" dest="$2" manifest="$3" env
    local -a envs
    if declare -p X_AGENT_ENVS >/dev/null 2>&1; then
        envs=("${X_AGENT_ENVS[@]}")
    else
        envs=("${X_AGENT_DEFAULT_ENVS[@]}")
    fi
    if [[ "${#envs[@]}" -eq 0 ]]; then
        envs=("${X_AGENT_DEFAULT_ENVS[@]}")
    fi
    for env in "${envs[@]}"; do
        x_agent_add_env "$base" "$env" "$dest" "$manifest" || warn "environment not found: $env"
    done
}

# Install a bundle into dest. Echoes the manifest path.
x_agent_install() {
    local base="$1" bundle="$2" dest="$3"
    local manifest
    manifest="$(x_agent_manifest "$dest")"
    if [[ "${X_AGENT_DRYRUN:-0}" != "1" ]]; then
        mkdir -p "$dest"
        mkdir -p "$(dirname "$manifest")"
        printf '# dest: %s\n' "$dest" > "$manifest"
    fi

    case "$bundle" in
        x)
            x_agent_add_envs "$base" "$dest" "$manifest"
            ;;
        dev)
            x_agent_add_envs "$base" "$dest" "$manifest"
            x_agent_add_agents_from "$base/agents/senior/agents" "$dest" "$manifest"
            x_agent_add_skills_from "$base/skills/senior" "$dest" "$manifest"
            ;;
        full)
            x_agent_add_envs "$base" "$dest" "$manifest"
            x_agent_add_agents_from "$base/agents/agents" "$dest" "$manifest"
            x_agent_add_agents_from "$base/agents/senior/agents" "$dest" "$manifest"
            x_agent_add_skills_from "$base/skills" "$dest" "$manifest"
            x_agent_add_commands_from "$base/skills/commands" "$dest" "$manifest"
            ;;
        *)
            error "unknown bundle: $bundle (use x|dev|full)"
            ;;
    esac

    if [[ "${X_AGENT_DRYRUN:-0}" != "1" ]]; then
        printf '%s' "$manifest"
    fi
}
