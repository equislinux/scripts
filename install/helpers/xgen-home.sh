#!/usr/bin/env bash

# Home generations: versioned copies of a user's dotfiles. System generations
# cover the root subvolume; `/home` deliberately stays out of them, so this
# layer versions the user configuration with plain file copies (no root, no
# btrfs, works on WSL).
#
# Environment:
#   X_HGEN_STATE     store root   (default ${XDG_DATA_HOME:-~/.local/share}/x/home-gens)
#   X_HGEN_HOME      home to capture (default $HOME)
#   X_HGEN_INCLUDE   space-separated relative paths (default dotfiles + .config)
#   X_HGEN_EXCLUDE   directory names skipped anywhere in the tree
#                    (default: Cache CachedData GPUCache logs)
#   X_HGEN_KEEP      generations kept by prune (default 10)

X_HGEN_STATE="${X_HGEN_STATE:-${XDG_DATA_HOME:-$HOME/.local/share}/x/home-gens}"
X_HGEN_HOME="${X_HGEN_HOME:-$HOME}"
X_HGEN_INCLUDE="${X_HGEN_INCLUDE:-.bashrc .bash_profile .profile .zshrc .zshenv .gitconfig .config}"
X_HGEN_EXCLUDE="${X_HGEN_EXCLUDE:-Cache CachedData GPUCache logs}"
X_HGEN_KEEP="${X_HGEN_KEEP:-10}"

hgen_log() {
    printf '\033[1;36m[x gen home]\033[0m %s\n' "$*"
}

hgen_warn() {
    printf '\033[1;33m[x gen home!]\033[0m %s\n' "$*" >&2
}

hgen_die() {
    printf '\033[1;31m[x gen home!!]\033[0m %s\n' "$*" >&2
    exit 1
}

hgen_gen_dir() {
    printf '%s/%s\n' "$X_HGEN_STATE" "$1"
}

hgen_manifest_path() {
    printf '%s/manifest.json\n' "$(hgen_gen_dir "$1")"
}

hgen_current() {
    [[ -f "$X_HGEN_STATE/current" ]] || return 0
    head -1 "$X_HGEN_STATE/current" 2>/dev/null || true
}

hgen_current_set() {
    mkdir -p "$X_HGEN_STATE"
    printf '%s\n' "$1" > "$X_HGEN_STATE/current.tmp"
    mv "$X_HGEN_STATE/current.tmp" "$X_HGEN_STATE/current"
}

hgen_ids() {
    local dir
    for dir in "$X_HGEN_STATE"/[0-9]*; do
        [[ -d "$dir" ]] || continue
        basename "$dir"
    done | LC_ALL=C sort -n
}

hgen_id_next() {
    local d id max=0
    for d in "$X_HGEN_STATE"/*; do
        [[ -e "$d" ]] || continue
        id="$(basename "$d")"
        [[ "$id" =~ ^[0-9]{4,}$ ]] || continue
        (( 10#$id > max )) && max=$((10#$id))
    done
    printf '%04d\n' "$((max + 1))"
}

hgen_field() {
    local id="$1" field="$2" f
    f="$(hgen_manifest_path "$id")"
    [[ -f "$f" ]] || return 0
    sed -n "s/.*\"$field\":[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$f" | head -1
}

hgen_json_str() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\r\n'
}

hgen_path_excluded() {
    local rel="$1" comp pat
    local -a comps
    IFS='/' read -r -a comps <<< "$rel"
    for comp in "${comps[@]}"; do
        for pat in $X_HGEN_EXCLUDE; do
            if [[ "$comp" == "$pat" ]]; then
                return 0
            fi
        done
    done
    return 1
}

# Live `<relpath>\t<sha256>` listing of the included files.
hgen_listing() {
    local tmp rel f
    tmp="$(mktemp)"
    for rel in $X_HGEN_INCLUDE; do
        [[ -e "$X_HGEN_HOME/$rel" ]] || continue
        if [[ -d "$X_HGEN_HOME/$rel" ]]; then
            while IFS= read -r f; do
                [[ -n "$f" ]] || continue
                hgen_path_excluded "$rel/$f" && continue
                printf '%s\t%s\n' "$rel/$f" "$(sha256sum "$X_HGEN_HOME/$rel/$f" | cut -d' ' -f1)"
            done < <(cd "$X_HGEN_HOME/$rel" && find . -type f | sed 's|^\./||' | LC_ALL=C sort)
        else
            printf '%s\t%s\n' "$rel" "$(sha256sum "$X_HGEN_HOME/$rel" | cut -d' ' -f1)"
        fi
    done | LC_ALL=C sort > "$tmp"
    cat "$tmp"
    rm -f "$tmp"
}

# Copies an include path, skipping excluded directories, without leaving temp
# files in the home.
hgen_copy_include() {
    local rel="$1" dest="$2" from to
    if [[ ! -d "$X_HGEN_HOME/$rel" ]]; then
        mkdir -p "$dest/$(dirname "$rel")"
        cp -a "$X_HGEN_HOME/$rel" "$dest/$rel"
        return 0
    fi
    while IFS= read -r from; do
        [[ -n "$from" ]] || continue
        hgen_path_excluded "$rel/$from" && continue
        to="$dest/$rel/$from"
        if [[ -d "$X_HGEN_HOME/$rel/$from" ]]; then
            mkdir -p "$to"
        else
            mkdir -p "$(dirname "$to")"
            cp -a "$X_HGEN_HOME/$rel/$from" "$to"
        fi
    done < <(cd "$X_HGEN_HOME/$rel" && find . -mindepth 1 | sed 's|^\./||' | LC_ALL=C sort)
}

hgen_new() {
    local label="${1:-}"
    [[ -d "$X_HGEN_HOME" ]] || hgen_die "home not found: $X_HGEN_HOME"
    local id dir parent rel count hash created
    id="$(hgen_id_next)"
    dir="$(hgen_gen_dir "$id")"
    [[ -e "$dir" ]] && hgen_die "home generation $id already exists"
    mkdir -p "$dir/files"
    count=0
    for rel in $X_HGEN_INCLUDE; do
        [[ -e "$X_HGEN_HOME/$rel" ]] || continue
        hgen_copy_include "$rel" "$dir/files"
        count=$((count + 1))
    done
    hgen_listing > "$dir/files.sha256"
    hash="$(sha256sum "$dir/files.sha256" | cut -d' ' -f1)"
    parent="$(hgen_current)"
    created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    {
        printf '{\n'
        printf '  "schema": 1,\n'
        printf '  "id": "%s",\n' "$id"
        if [[ -n "$parent" ]]; then
            printf '  "parent": "%s",\n' "$parent"
        else
            printf '  "parent": null,\n'
        fi
        printf '  "label": "%s",\n' "$(hgen_json_str "$label")"
        printf '  "created": "%s",\n' "$created"
        printf '  "home": "%s",\n' "$(hgen_json_str "$X_HGEN_HOME")"
        printf '  "include": "%s",\n' "$(hgen_json_str "$X_HGEN_INCLUDE")"
        printf '  "paths": %s,\n' "$count"
        printf '  "sha256": "%s"\n' "$hash"
        printf '}\n'
    } > "$dir/manifest.json"
    hgen_current_set "$id"
    printf '%s\n' "$id"
}

hgen_list() {
    local dir id created label cur found=0
    cur="$(hgen_current)"
    printf '%-6s %-20s %s\n' "ID" "CREATED" "LABEL"
    for dir in "$X_HGEN_STATE"/[0-9]*; do
        [[ -d "$dir" ]] || continue
        id="$(basename "$dir")"
        created="$(hgen_field "$id" created)"
        label="$(hgen_field "$id" label)"
        if [[ "$id" == "$cur" ]]; then
            id="$id *"
        fi
        printf '%-6s %-20s %s\n' "$id" "${created:-?}" "$label"
        found=1
    done
    [[ "$found" -eq 1 ]] || printf 'no home generations\n'
}

hgen_status() {
    local cur dir then_hash now_hash
    cur="$(hgen_current)"
    printf 'store:      %s\n' "$X_HGEN_STATE"
    printf 'home:       %s\n' "$X_HGEN_HOME"
    if [[ -z "$cur" ]]; then
        printf 'current:    none\n'
        return 0
    fi
    dir="$(hgen_gen_dir "$cur")"
    printf 'current:    %s\n' "$cur"
    printf 'created:    %s\n' "$(hgen_field "$cur" created)"
    printf 'label:      %s\n' "$(hgen_field "$cur" label)"
    printf 'paths:      %s\n' "$(hgen_field "$cur" paths)"
    then_hash="$(sed -n 's/.*"sha256": *"\([^"]*\)".*/\1/p' "$dir/manifest.json" 2>/dev/null | head -1)"
    now_hash="$(hgen_listing | sha256sum | cut -d' ' -f1)"
    if [[ -n "$then_hash" && "$then_hash" != "$now_hash" ]]; then
        printf 'drift:      dotfiles changed since generation %s (x gen home new)\n' "$cur"
    fi
}

hgen_diff() {
    local a="$1" b="$2"
    [[ -f "$(hgen_manifest_path "$a")" && -f "$(hgen_manifest_path "$b")" ]] \
        || hgen_die "usage: x gen home diff <id-a> <id-b>"
    printf 'home generation %s -> %s\n\n' "$a" "$b"
    local la="$X_HGEN_STATE/$a/files.sha256" lb="$X_HGEN_STATE/$b/files.sha256"
    [[ -f "$la" && -f "$lb" ]] || hgen_die "generations have no file listing"
    local d
    d="$(awk '
        NR == FNR { av[$1] = $2; next }
        { bv[$1] = $2 }
        END {
            for (f in bv) if (!(f in av)) printf "added\t%s\n", f
            for (f in av) if (!(f in bv)) printf "removed\t%s\n", f
            for (f in av) if ((f in bv) && av[f] != bv[f]) printf "changed\t%s\n", f
        }' "$la" "$lb" | LC_ALL=C sort)"
    if [[ -z "$d" ]]; then
        printf '  (no changes)\n'
        return 0
    fi
    local kind f
    while IFS=$'\t' read -r kind f; do
        [[ -n "$kind" ]] || continue
        case "$kind" in
            added)   printf '  + %s\n' "$f" ;;
            removed) printf '  - %s\n' "$f" ;;
            changed) printf '  ~ %s\n' "$f" ;;
        esac
    done <<< "$d"
}

hgen_backup_if_differs() {
    local from="$1" to="$2" ts="${X_TS:-$(date +%Y%m%d%H%M%S)}"
    if [[ -e "$to" ]] && ! cmp -s "$from" "$to"; then
        mv "$to" "$to.bak.$ts"
    fi
}

hgen_restore_tree() {
    local src="$1" dest="$2" rel from to
    mkdir -p "$dest"
    while IFS= read -r rel; do
        [[ -n "$rel" ]] || continue
        from="$src/$rel"
        to="$dest/$rel"
        if [[ -d "$from" ]]; then
            mkdir -p "$to"
            continue
        fi
        hgen_backup_if_differs "$from" "$to"
        if [[ ! -e "$to" ]]; then
            mkdir -p "$(dirname "$to")"
            cp -a "$from" "$to"
        fi
    done < <(cd "$src" && find . -mindepth 1 | LC_ALL=C sort)
}

hgen_restore() {
    local path="$1" id="${2:-}" dest="${3:-}"
    [[ -n "$path" ]] || hgen_die "usage: x gen home restore <path> [--from ID]"
    case "$path" in
        "$X_HGEN_HOME"/*) path="${path#"$X_HGEN_HOME"/}" ;;
        /*) hgen_die "path must be relative to the home or under it: $path" ;;
    esac
    case "$path" in
        ..|../*|*/../*|*/..) hgen_die "path escapes the home: $path" ;;
    esac
    if [[ -z "$id" ]]; then
        id="$(hgen_current)"
    fi
    [[ -n "$id" ]] || hgen_die "no home generation; pass --from ID"
    local src
    src="$(hgen_gen_dir "$id")/files/${path#/}"
    [[ -e "$src" ]] || hgen_die "$path not found in home generation $id"
    if [[ -z "$dest" ]]; then
        dest="$X_HGEN_HOME/${path#/}"
    fi
    if [[ -d "$src" ]]; then
        hgen_restore_tree "$src" "$dest"
    else
        mkdir -p "$(dirname "$dest")"
        hgen_backup_if_differs "$src" "$dest"
        if [[ ! -e "$dest" ]]; then
            cp -a "$src" "$dest"
        fi
    fi
    hgen_log "restored $path from home generation $id"
}

hgen_prune() {
    local keep_n="${1:-${X_HGEN_KEEP:-10}}" dry="${2:-0}"
    [[ "$keep_n" =~ ^[0-9]+$ ]] || hgen_die "keep must be a number"
    local ids=() id cur total first_keep i removed=0
    while IFS= read -r id; do
        [[ -n "$id" ]] && ids+=("$id")
    done < <(hgen_ids)
    total="${#ids[@]}"
    [[ "$total" -gt 0 ]] || { hgen_log "no home generations to prune"; return 0; }
    first_keep=$((total - keep_n))
    (( first_keep < 0 )) && first_keep=0
    cur="$(hgen_current)"
    for (( i = 0; i < total; i++ )); do
        id="${ids[i]}"
        if (( i >= first_keep )); then
            continue
        fi
        if [[ "$id" == "$cur" ]]; then
            continue
        fi
        if [[ -f "$(hgen_gen_dir "$id")/pinned" ]]; then
            continue
        fi
        if [[ "$dry" == "1" ]]; then
            printf 'would remove home generation %s\n' "$id"
        else
            rm -rf "$(hgen_gen_dir "$id")"
            printf 'removed home generation %s\n' "$id"
        fi
        removed=$((removed + 1))
    done
    if [[ "$dry" == "1" ]]; then
        hgen_log "dry-run: $removed home generation(s) would be removed (keep=$keep_n)"
    else
        hgen_log "$removed home generation(s) removed (keep=$keep_n, current kept)"
    fi
}
