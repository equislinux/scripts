#!/usr/bin/env bash

# xgen — generation engine: immutable snapshots of the root tree + manifest.
#
# A generation is a read-only snapshot of X_GEN_ROOT plus a directory of
# metadata (manifest.json, packages.tsv, services.txt, boot/, snapshot.uuid).
# Design and CLI: docs/en/generations.md.
#
# Environment:
#   X_GEN_STATE      state root          (default /var/lib/x)
#   X_GEN_DIR        generations dir     (default $X_GEN_STATE/generations)
#   X_GEN_CURRENT    current-id file     (default $X_GEN_STATE/current)
#   X_GEN_SNAPSHOTS  snapshots dir       (default /.snapshots)
#   X_GEN_ROOT       tree to snapshot    (default /)
#   X_GEN_BACKEND    auto|btrfs|dir|off  (default auto)
#   X_GEN_CMDLINE    kernel cmdline      (default /proc/cmdline)
#   X_GEN_SKIP       1 disables automatic generations in hooks
#
# The `dir` backend copies X_GEN_ROOT into the snapshots dir. It exists for
# tests and for degraded (non-btrfs) environments; it refuses to copy `/`.

X_GEN_STATE="${X_GEN_STATE:-/var/lib/x}"
X_GEN_DIR="${X_GEN_DIR:-$X_GEN_STATE/generations}"
X_GEN_CURRENT="${X_GEN_CURRENT:-$X_GEN_STATE/current}"
X_GEN_SNAPSHOTS="${X_GEN_SNAPSHOTS:-/.snapshots}"
X_GEN_ROOT="${X_GEN_ROOT:-/}"
X_GEN_BACKEND="${X_GEN_BACKEND:-auto}"

xgen_log() {
    printf '\033[1;36m[x gen]\033[0m %s\n' "$*"
}

xgen_warn() {
    printf '\033[1;33m[x gen!]\033[0m %s\n' "$*" >&2
}

xgen_die() {
    printf '\033[1;31m[x gen!!]\033[0m %s\n' "$*" >&2
    exit 1
}

# --- backend ----------------------------------------------------------------

xgen_backend() {
    if [[ "$X_GEN_BACKEND" != "auto" ]]; then
        printf '%s\n' "$X_GEN_BACKEND"
        return 0
    fi
    if command -v btrfs >/dev/null 2>&1 \
        && [[ "$(stat -f -c %T "$X_GEN_ROOT" 2>/dev/null || true)" == "btrfs" ]]; then
        printf 'btrfs\n'
    else
        printf 'off\n'
    fi
}

xgen_supported() {
    [[ "$(xgen_backend)" != "off" ]]
}

# --- ids and paths ----------------------------------------------------------

xgen_gen_dir() {
    printf '%s/%s\n' "$X_GEN_DIR" "$1"
}

xgen_manifest_path() {
    printf '%s/manifest.json\n' "$(xgen_gen_dir "$1")"
}

xgen_snapshot_path() {
    printf '%s/%s\n' "$X_GEN_SNAPSHOTS" "$1"
}

xgen_id_next() {
    local d id max=0
    for d in "$X_GEN_DIR"/* "$X_GEN_SNAPSHOTS"/*; do
        [[ -e "$d" ]] || continue
        id="$(basename "$d")"
        [[ "$id" =~ ^[0-9]{4,}$ ]] || continue
        (( 10#$id > max )) && max=$((10#$id))
    done
    printf '%04d\n' "$((max + 1))"
}

xgen_current() {
    [[ -f "$X_GEN_CURRENT" ]] || return 0
    head -1 "$X_GEN_CURRENT" 2>/dev/null || true
}

xgen_current_set() {
    mkdir -p "$(dirname "$X_GEN_CURRENT")"
    printf '%s\n' "$1" > "$X_GEN_CURRENT.tmp"
    mv "$X_GEN_CURRENT.tmp" "$X_GEN_CURRENT"
}

# --- state capture ----------------------------------------------------------

xgen_json_str() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' | tr -d '\r\n'
}

xgen_hash_tree() {
    local dir="$1"
    [[ -d "$dir" ]] || return 1
    (
        cd "$dir" || exit 1
        find . -xdev -type f \
            ! -name '.pwd.lock' ! -name 'mtab' ! -path './pacman.d/gnupg/*' \
            -print0 2>/dev/null \
            | LC_ALL=C sort -z \
            | xargs -0 -r sha256sum \
            | sha256sum | cut -d' ' -f1
    )
}

xgen_kernel_release() {
    local rel=""
    if [[ -d "$X_GEN_ROOT/usr/lib/modules" ]]; then
        rel="$(find "$X_GEN_ROOT/usr/lib/modules" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null | LC_ALL=C sort -V | tail -1)"
    fi
    [[ -n "$rel" ]] || rel="$(uname -r 2>/dev/null || printf 'unknown')"
    printf '%s\n' "$rel"
}

xgen_cmdline() {
    local s="${X_GEN_CMDLINE:-}"
    if [[ -z "$s" && -r /proc/cmdline ]]; then
        s="$(tr -d '\n' < /proc/cmdline)"
    fi
    printf '%s\n' "$s"
}

xgen_tooling_version() {
    local out=""
    if command -v pacman >/dev/null 2>&1; then
        out="$(pacman -Q x-scripts 2>/dev/null | awk '{print $2}')" || out=""
    fi
    if [[ -z "$out" && -n "${X_ROOT:-}" ]] && command -v git >/dev/null 2>&1; then
        out="$(git -C "$X_ROOT" describe --tags --always 2>/dev/null)" || out=""
    fi
    [[ -n "$out" ]] || out="unknown"
    printf '%s\n' "$out"
}

xgen_capture_packages() {
    local out="$1" backend="none"
    : > "$out"
    if command -v pacman >/dev/null 2>&1; then
        backend="pacman"
        pacman -Q 2>/dev/null | LC_ALL=C sort > "$out" || true
    elif command -v xpm >/dev/null 2>&1; then
        backend="xpm"
        xpm query 2>/dev/null | LC_ALL=C sort > "$out" || true
    fi
    printf '%s\n' "$backend"
}

xgen_capture_services() {
    local out="$1"
    : > "$out"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl list-unit-files --state=enabled --no-legend --no-pager 2>/dev/null \
            | awk '{print $1}' | LC_ALL=C sort > "$out" || true
    fi
}

xgen_capture_kernel() {
    local id="$1" dest f
    dest="$(xgen_gen_dir "$id")/boot"
    mkdir -p "$dest"
    local found=0
    for f in "$X_GEN_ROOT"/boot/vmlinuz-* "$X_GEN_ROOT"/boot/initramfs-*.img; do
        [[ -f "$f" ]] || continue
        cp -a "$f" "$dest/" 2>/dev/null || return 1
        found=1
    done
    [[ "$found" -eq 1 ]]
}

xgen_manifest_field() {
    local id="$1" field="$2" f
    f="$(xgen_manifest_path "$id")"
    [[ -f "$f" ]] || return 0
    sed -n "s/.*\"$field\":[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$f" | head -1
}

xgen_write_manifest() {
    local id="$1" parent="$2" reason="$3" label="$4" pkg_backend="${5:-none}"
    local dir created hostname kernel cmdline etc_hash
    local pkg_count pkg_hash svc_count
    dir="$(xgen_gen_dir "$id")"
    mkdir -p "$dir"
    created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    hostname="$(head -1 "$X_GEN_ROOT/etc/hostname" 2>/dev/null || true)"
    [[ -n "$hostname" ]] || hostname="$(uname -n 2>/dev/null || printf 'unknown')"
    kernel="$(xgen_kernel_release)"
    cmdline="$(xgen_cmdline)"
    etc_hash="$(xgen_hash_tree "$X_GEN_ROOT/etc" 2>/dev/null || printf 'n/a')"
    pkg_count="$(wc -l < "$dir/packages.tsv" 2>/dev/null | tr -d ' ')"
    [[ -n "$pkg_count" ]] || pkg_count=0
    pkg_hash="$(sha256sum "$dir/packages.tsv" 2>/dev/null | cut -d' ' -f1 || true)"
    [[ -n "$pkg_hash" ]] || pkg_hash="n/a"
    svc_count="$(wc -l < "$dir/services.txt" 2>/dev/null | tr -d ' ')"
    [[ -n "$svc_count" ]] || svc_count=0

    {
        printf '{\n'
        printf '  "schema": 1,\n'
        printf '  "id": "%s",\n' "$id"
        if [[ -n "$parent" ]]; then
            printf '  "parent": "%s",\n' "$parent"
        else
            printf '  "parent": null,\n'
        fi
        printf '  "reason": "%s",\n' "$(xgen_json_str "$reason")"
        printf '  "label": "%s",\n' "$(xgen_json_str "$label")"
        printf '  "created": "%s",\n' "$created"
        printf '  "hostname": "%s",\n' "$(xgen_json_str "$hostname")"
        printf '  "backend": "%s",\n' "$(xgen_backend)"
        printf '  "package_backend": "%s",\n' "$pkg_backend"
        printf '  "x_scripts": "%s",\n' "$(xgen_json_str "$(xgen_tooling_version)")"
        printf '  "kernel": {"release": "%s"},\n' "$(xgen_json_str "$kernel")"
        printf '  "cmdline": "%s",\n' "$(xgen_json_str "$cmdline")"
        printf '  "configs": {"etc_sha256": "%s"},\n' "$etc_hash"
        printf '  "packages": {"count": %s, "sha256": "%s"},\n' "$pkg_count" "$pkg_hash"
        printf '  "services": {"count": %s}\n' "$svc_count"
        printf '}\n'
    } > "$dir/manifest.json"
}

# --- snapshots --------------------------------------------------------------

xgen_root_device() {
    findmnt -n -o SOURCE -T "$X_GEN_ROOT" 2>/dev/null | sed 's/\[.*\]$//'
}

xgen_snapshot_create() {
    local id="$1" backend snap
    backend="$(xgen_backend)"
    snap="$(xgen_snapshot_path "$id")"
    case "$backend" in
        btrfs)
            [[ "$(id -u)" -eq 0 ]] || xgen_die "btrfs snapshots require root"
            [[ -d "$X_GEN_SNAPSHOTS" ]] || xgen_die "snapshots dir missing: $X_GEN_SNAPSHOTS"
            btrfs subvolume snapshot -r "$X_GEN_ROOT" "$snap" >/dev/null || return 1
            local uuid
            uuid="$(btrfs subvolume show "$snap" 2>/dev/null | awk -F': *' '/^[[:space:]]*UUID:/{print $2; exit}' || true)"
            if [[ -n "$uuid" ]]; then
                printf '%s\n' "$uuid" > "$(xgen_gen_dir "$id")/snapshot.uuid"
            fi
            ;;
        dir)
            [[ "$X_GEN_ROOT" != "/" ]] || xgen_die "dir backend refuses to copy /"
            mkdir -p "$snap"
            cp -a "$X_GEN_ROOT/." "$snap/"
            ;;
        *)
            xgen_die "generations are not supported here (backend: $backend)"
            ;;
    esac
    return 0
}

xgen_release_mount() {
    local mnt="$1"
    [[ -n "$mnt" ]] || return 0
    umount "$mnt" 2>/dev/null || xgen_warn "could not unmount $mnt (left at $mnt)"
    rmdir "$mnt" 2>/dev/null || true
}

# --- generation lifecycle ---------------------------------------------------

xgen_new() {
    local reason="${1:-manual}" label="${2:-}"
    local backend id dir pkg_backend parent
    backend="$(xgen_backend)"
    [[ "$backend" != "off" ]] || xgen_die "generations are not supported on this system"
    if [[ "$backend" == "btrfs" && "$(id -u)" -ne 0 ]]; then
        xgen_die "generations require root"
    fi

    id="$(xgen_id_next)"
    dir="$(xgen_gen_dir "$id")"
    if [[ -e "$dir" || -e "$(xgen_snapshot_path "$id")" ]]; then
        xgen_die "generation $id already exists"
    fi

    mkdir -p "$dir"
    pkg_backend="$(xgen_capture_packages "$dir/packages.tsv")"
    xgen_capture_services "$dir/services.txt"
    xgen_capture_kernel "$id" || xgen_warn "kernel capture incomplete"
    parent="$(xgen_current)"
    xgen_write_manifest "$id" "$parent" "$reason" "$label" "$pkg_backend"
    xgen_snapshot_create "$id" || xgen_die "snapshot failed for generation $id"
    xgen_current_set "$id"
    printf '%s\n' "$id"
}

xgen_maybe_new() {
    local reason="${1:-auto}" label="${2:-}"
    if [[ "${X_GEN_SKIP:-0}" == "1" ]]; then
        return 0
    fi
    xgen_supported || return 0
    [[ "$(id -u)" -eq 0 ]] || return 0
    xgen_new "$reason" "$label" >/dev/null || xgen_warn "generation ($reason) failed; continuing"
    return 0
}

xgen_list() {
    local dir id label reason created cur found=0
    cur="$(xgen_current)"
    printf '%-6s %-20s %-12s %s\n' "ID" "CREATED" "REASON" "LABEL"
    for dir in "$X_GEN_DIR"/[0-9]*; do
        [[ -d "$dir" ]] || continue
        id="$(basename "$dir")"
        created="$(xgen_manifest_field "$id" created)"
        reason="$(xgen_manifest_field "$id" reason)"
        label="$(xgen_manifest_field "$id" label)"
        if [[ "$id" == "$cur" ]]; then
            id="$id *"
        fi
        printf '%-6s %-20s %-12s %s\n' "$id" "${created:-?}" "${reason:-?}" "$label"
        found=1
    done
    [[ "$found" -eq 1 ]] || printf 'no generations\n'
}

xgen_status() {
    local backend cur dir then_hash now_hash
    backend="$(xgen_backend)"
    printf 'backend:    %s\n' "$backend"
    cur="$(xgen_current)"
    if [[ -z "$cur" ]]; then
        printf 'current:    none\n'
        xgen_supported || printf 'status:     generations unavailable (no btrfs on %s)\n' "$X_GEN_ROOT"
        return 0
    fi
    dir="$(xgen_gen_dir "$cur")"
    printf 'current:    %s\n' "$cur"
    printf 'reason:     %s\n' "$(xgen_manifest_field "$cur" reason)"
    printf 'label:      %s\n' "$(xgen_manifest_field "$cur" label)"
    printf 'created:    %s\n' "$(xgen_manifest_field "$cur" created)"
    printf 'sha256:     %s\n' "$(sed -n 's/.*"etc_sha256": *"\([^"]*\)".*/\1/p' "$dir/manifest.json" 2>/dev/null | head -1)"
    printf 'snapshot:   %s\n' "$(xgen_snapshot_path "$cur")"
    then_hash="$(sed -n 's/.*"etc_sha256": *"\([^"]*\)".*/\1/p' "$dir/manifest.json" 2>/dev/null | head -1)"
    now_hash="$(xgen_hash_tree "$X_GEN_ROOT/etc" 2>/dev/null || true)"
    if [[ -n "$then_hash" && "$then_hash" != "n/a" && "$then_hash" != "$now_hash" ]]; then
        printf 'drift:      /etc changed since generation %s (x gen new)\n' "$cur"
    fi
}

# --- granular restore -------------------------------------------------------

xgen_backup_if_differs() {
    local from="$1" to="$2" ts="${X_TS:-$(date +%Y%m%d%H%M%S)}"
    if [[ -e "$to" ]] && ! cmp -s "$from" "$to"; then
        mv "$to" "$to.bak.$ts"
    fi
}

xgen_restore_file() {
    local from="$1" to="$2"
    mkdir -p "$(dirname "$to")"
    xgen_backup_if_differs "$from" "$to"
    if [[ ! -e "$to" ]]; then
        cp -a "$from" "$to"
    fi
}

xgen_restore_tree() {
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
        xgen_backup_if_differs "$from" "$to"
        if [[ ! -e "$to" ]]; then
            mkdir -p "$(dirname "$to")"
            cp -a "$from" "$to"
        fi
    done < <(cd "$src" && find . -mindepth 1 | LC_ALL=C sort)
}

xgen_restore_from() {
    local src="$1" dest="$2"
    if [[ -d "$src" ]]; then
        xgen_restore_tree "$src" "$dest"
    else
        xgen_restore_file "$src" "$dest"
    fi
}

xgen_restore() {
    local id="$1" path="$2" dest="${3:-}"
    [[ -n "$id" && -n "$path" ]] || xgen_die "usage: x gen restore <path> [--from ID]"
    [[ -n "$dest" ]] || dest="/${path#/}"

    local backend snap mnt="" src
    backend="$(xgen_backend)"
    [[ "$backend" != "off" ]] || xgen_die "generations are not supported on this system"
    snap="$(xgen_snapshot_path "$id")"
    [[ -d "$snap" ]] || xgen_die "generation $id not found ($snap)"

    if [[ "$backend" == "btrfs" ]]; then
        [[ "$(id -u)" -eq 0 ]] || xgen_die "btrfs restore requires root"
        local dev
        dev="$(xgen_root_device)"
        [[ -n "$dev" ]] || xgen_die "cannot resolve the device of $X_GEN_ROOT"
        mnt="$(mktemp -d)"
        mount -o ro,subvol="$X_GEN_SNAPSHOTS/$id" "$dev" "$mnt" || xgen_die "cannot mount snapshot $id"
        src="$mnt/${path#/}"
    else
        src="$snap/${path#/}"
    fi

    if [[ ! -e "$src" ]]; then
        xgen_release_mount "$mnt"
        xgen_die "$path not found in generation $id"
    fi

    xgen_restore_from "$src" "$dest"
    xgen_release_mount "$mnt"
    xgen_log "restored $path from generation $id -> $dest"
}
