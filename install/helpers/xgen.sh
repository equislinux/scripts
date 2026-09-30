#!/usr/bin/env bash

# xgen — generation engine: bootable snapshots of the root tree + manifest.
#
# A generation is a snapshot of X_GEN_ROOT plus a directory of metadata
# (manifest.json, packages.tsv, services.txt, boot/, snapshot.uuid, pinned).
# The current generation is tracked in X_GEN_CURRENT; X_GEN_BOOT_DIR (the ESP
# on installed systems) gets one boot entry per kept generation.
#
# Design and CLI: docs/en/generations.md.
#
# Environment:
#   X_GEN_STATE       state root          (default /var/lib/x, a subvol on installs)
#   X_GEN_DIR         generations dir     (default $X_GEN_STATE/generations)
#   X_GEN_CURRENT     default-boot id     (default $X_GEN_STATE/current)
#   X_GEN_SNAPSHOTS   snapshots dir       (default /.snapshots)
#   X_GEN_SUBVOL_PREFIX  in-fs path of the snapshots dir (default X_GEN_SNAPSHOTS)
#   X_GEN_ROOT        tree to snapshot    (default /)
#   X_GEN_BACKEND     auto|btrfs|dir|off  (default auto)
#   X_GEN_CMDLINE     kernel cmdline      (default /proc/cmdline)
#   X_GEN_BOOT        auto|on|off         (default auto: on with btrfs)
#   X_GEN_BOOT_DIR    boot/ESP dir        (default /boot)
#   X_GEN_BOOT_KEEP   entries to keep     (default 3)
#   X_GEN_LIVE_SUBVOL subvol of the live generation (set by the installer: /@)
#   X_GEN_RUNNING     running generation id (tests; default: from /proc/cmdline)
#   X_GEN_SKIP        1 disables automatic generations in hooks
#
# The `dir` backend copies X_GEN_ROOT into the snapshots dir. It exists for
# tests and for degraded (non-btrfs) environments; it refuses to copy `/`.

X_GEN_STATE="${X_GEN_STATE:-/var/lib/x}"
X_GEN_DIR="${X_GEN_DIR:-$X_GEN_STATE/generations}"
X_GEN_CURRENT="${X_GEN_CURRENT:-$X_GEN_STATE/current}"
X_GEN_SNAPSHOTS="${X_GEN_SNAPSHOTS:-/.snapshots}"
X_GEN_SUBVOL_PREFIX="${X_GEN_SUBVOL_PREFIX:-$X_GEN_SNAPSHOTS}"
X_GEN_ROOT="${X_GEN_ROOT:-/}"
X_GEN_BACKEND="${X_GEN_BACKEND:-auto}"
X_GEN_BOOT="${X_GEN_BOOT:-auto}"
X_GEN_BOOT_DIR="${X_GEN_BOOT_DIR:-/boot}"
X_GEN_BOOT_KEEP="${X_GEN_BOOT_KEEP:-3}"

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

xgen_gen_ids() {
    local dir
    for dir in "$X_GEN_DIR"/[0-9]*; do
        [[ -d "$dir" ]] || continue
        basename "$dir"
    done | LC_ALL=C sort -n
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

xgen_pending_file() {
    printf '%s/pending\n' "$X_GEN_STATE"
}

xgen_pending() {
    [[ -f "$(xgen_pending_file)" ]] || return 0
    head -1 "$(xgen_pending_file)" 2>/dev/null || true
}

xgen_pending_set() {
    mkdir -p "$X_GEN_STATE"
    printf '%s\n' "$1" > "$(xgen_pending_file).tmp"
    mv "$(xgen_pending_file).tmp" "$(xgen_pending_file)"
}

xgen_pending_clear() {
    rm -f "$(xgen_pending_file)"
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
    local id="$1" parent="$2" reason="$3" label="$4" pkg_backend="${5:-none}" root_subvol="${6:-}"
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
        printf '  "schema": 2,\n'
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
        printf '  "root_subvol": "%s",\n' "$(xgen_json_str "$root_subvol")"
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
            # Writable snapshot: it is a bootable restore point, not an archive
            # copy (see docs/en/generations.md). No -r on purpose.
            btrfs subvolume snapshot "$X_GEN_ROOT" "$snap" >/dev/null || return 1
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

xgen_snapshot_subvolid() {
    local id="$1"
    btrfs subvolume show "$(xgen_snapshot_path "$id")" 2>/dev/null \
        | sed -n 's/^[[:space:]]*Subvolume ID:[[:space:]]*//p' | head -1
}

# Makes a snapshot self-consistent: its /etc/fstab must point at itself, not
# at the live subvolume it was forked from.
xgen_patch_snapshot_fstab() {
    local id="$1" dev mnt fstab subid subpath
    [[ "$(xgen_backend)" == "btrfs" ]] || return 0
    dev="$(xgen_root_device)"
    [[ -n "$dev" ]] || return 1
    subid="$(xgen_snapshot_subvolid "$id")"
    subpath="$X_GEN_SUBVOL_PREFIX/$id"
    [[ -n "$subid" ]] || return 1
    mnt="$(mktemp -d)"
    mount -o "subvol=$subpath" "$dev" "$mnt" || { rmdir "$mnt" 2>/dev/null || true; return 1; }
    fstab="$mnt/etc/fstab"
    if [[ -f "$fstab" ]]; then
        awk -v subid="$subid" -v subpath="$subpath" '
            $2 == "/" && $3 == "btrfs" {
                n = split($4, a, ",")
                out = ""
                for (i = 1; i <= n; i++) {
                    if (a[i] ~ /^subvol(id)?=/) continue
                    out = (out == "" ? a[i] : out "," a[i])
                }
                $4 = out ",subvolid=" subid ",subvol=" subpath
            }
            { print }
        ' "$fstab" > "$fstab.xgen" && mv "$fstab.xgen" "$fstab"
    fi
    if [[ -f "$mnt/etc/default/grub" ]]; then
        sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"$(xgen_cmdline_for_gen "$id")\"|" \
            "$mnt/etc/default/grub" 2>/dev/null || true
    fi
    umount "$mnt" 2>/dev/null || xgen_warn "could not unmount $mnt"
    rmdir "$mnt" 2>/dev/null || true
    return 0
}

xgen_release_mount() {
    local mnt="$1"
    [[ -n "$mnt" ]] || return 0
    umount "$mnt" 2>/dev/null || xgen_warn "could not unmount $mnt (left at $mnt)"
    rmdir "$mnt" 2>/dev/null || true
}

# --- boot entries -----------------------------------------------------------

xgen_default_subvol() {
    local id="$1"
    if [[ -n "${X_GEN_LIVE_SUBVOL:-}" ]]; then
        printf '%s\n' "$X_GEN_LIVE_SUBVOL"
        return 0
    fi
    case "$(xgen_backend)" in
        btrfs) printf '%s/%s\n' "$X_GEN_SUBVOL_PREFIX" "$id" ;;
        *)     printf '/fake/%s\n' "$id" ;;
    esac
}

xgen_cmdline_for_gen() {
    local id="$1" base subvol
    subvol="$(xgen_manifest_field "$id" root_subvol)"
    [[ -n "$subvol" ]] || subvol="$(xgen_default_subvol "$id")"
    base="$(xgen_manifest_field "$id" cmdline)"
    base="$(printf '%s' "$base" | sed 's/[[:space:]]*rootflags=[^[:space:]]*//g')"
    base="${base## }"
    base="${base%% }"
    [[ " $base " == *" rw "* ]] || base="${base:+$base }rw"
    printf '%s rootflags=subvol=%s\n' "$base" "$subvol"
}

xgen_running_id() {
    if [[ -n "${X_GEN_RUNNING:-}" ]]; then
        printf '%s\n' "$X_GEN_RUNNING"
        return 0
    fi
    local cmdline subvol id
    cmdline="$(cat /proc/cmdline 2>/dev/null || true)"
    subvol="$(printf '%s' "$cmdline" | tr ' ' '\n' | sed -n 's/^rootflags=//p' \
        | tr ',' '\n' | sed -n 's/^subvol=//p' | head -1)"
    [[ -n "$subvol" ]] || return 0
    for id in $(xgen_gen_ids); do
        if [[ "$(xgen_manifest_field "$id" root_subvol)" == "$subvol" ]]; then
            printf '%s\n' "$id"
            return 0
        fi
    done
    return 0
}

xgen_boot_enabled() {
    case "$X_GEN_BOOT" in
        off) return 1 ;;
        on)  return 0 ;;
    esac
    [[ "$(xgen_backend)" == "btrfs" && -d "$X_GEN_BOOT_DIR" ]]
}

xgen_pick_kernel() {
    local f
    f="$(find "$(xgen_gen_dir "$1")/boot" -maxdepth 1 -name 'vmlinuz-*' -type f 2>/dev/null | LC_ALL=C sort | head -1)" || f=""
    if [[ -n "$f" ]]; then
        printf '%s\n' "$f"
    fi
    return 0
}

xgen_pick_initrd() {
    local f
    f="$(find "$(xgen_gen_dir "$1")/boot" -maxdepth 1 -name 'initramfs-*.img' -type f 2>/dev/null | LC_ALL=C sort | head -1)" || f=""
    if [[ -n "$f" ]]; then
        printf '%s\n' "$f"
    fi
    return 0
}

xgen_boot_sync() {
    local force="${1:-}"
    xgen_boot_enabled || return 0
    local bootdir="$X_GEN_BOOT_DIR"
    local sb_dir="$bootdir/loader/entries" grub_dir="$bootdir/grub"
    local have_sb=0 have_grub=0
    [[ -d "$sb_dir" ]] && have_sb=1
    [[ -d "$grub_dir" ]] && have_grub=1
    if [[ "$have_sb" -eq 0 && "$have_grub" -eq 0 ]]; then
        xgen_warn "no systemd-boot or GRUB layout in $bootdir; skipping entries"
        return 0
    fi

    local running cur id
    running="$(xgen_running_id)"
    cur="$(xgen_current)"
    [[ -n "$cur" ]] || cur="$running"
    [[ -n "$cur" ]] || return 0

    local keep_ids=()
    while IFS= read -r id; do
        [[ -n "$id" ]] && keep_ids+=("$id")
    done < <(xgen_gen_ids)
    local total="${#keep_ids[@]}"
    [[ "$total" -gt 0 ]] || return 0

    local first_keep=$((total - X_GEN_BOOT_KEEP))
    (( first_keep < 0 )) && first_keep=0

    local -A keep=()
    keep[$cur]=1
    if [[ -n "$running" ]]; then
        keep[$running]=1
    fi
    if [[ -n "$force" ]]; then
        keep[$force]=1
    fi
    local i
    for (( i = 0; i < total; i++ )); do
        id="${keep_ids[i]}"
        if (( i >= first_keep )); then
            keep[$id]=1
        fi
        if [[ -f "$(xgen_gen_dir "$id")/pinned" ]]; then
            keep[$id]=1
        fi
    done

    # The running generation mutates in place: refresh its kernel archive
    # from the live boot dir so a later rollback boots matching modules.
    if [[ -n "$running" && -d "$(xgen_gen_dir "$running")" ]]; then
        xgen_capture_kernel "$running" 2>/dev/null || true
    fi

    mkdir -p "$bootdir/x"
    local entries="" lin initrd cmd title kfile ifile dest
    for id in "${keep_ids[@]}"; do
        [[ -n "${keep[$id]:-}" ]] || continue
        if [[ "$id" == "$running" ]]; then
            lin="/vmlinuz-linux"
            initrd="/initramfs-linux.img"
        else
            kfile="$(xgen_pick_kernel "$id")"
            ifile="$(xgen_pick_initrd "$id")"
            if [[ -z "$kfile" || -z "$ifile" ]]; then
                xgen_warn "generation $id has no archived kernel; entry skipped"
                continue
            fi
            dest="$bootdir/x/gen-$id"
            mkdir -p "$dest"
            cp -a "$kfile" "$dest/${kfile##*/}"
            cp -a "$ifile" "$dest/${ifile##*/}"
            lin="/x/gen-$id/${kfile##*/}"
            initrd="/x/gen-$id/${ifile##*/}"
        fi
        cmd="$(xgen_cmdline_for_gen "$id")"
        title="X Linux (gen $id, $(xgen_manifest_field "$id" reason))"
        title="${title//\"/\'}"
        if [[ "$have_sb" -eq 1 ]]; then
            {
                printf 'title   %s\n' "$title"
                printf 'linux   %s\n' "$lin"
                printf 'initrd  %s\n' "$initrd"
                printf 'options %s\n' "$cmd"
            } > "$sb_dir/x-gen-$id.conf"
        fi
        if [[ "$have_grub" -eq 1 ]]; then
            entries="$entries
menuentry \"$title\" --id x-gen-$id {
    linux $lin $cmd
    initrd $initrd
}"
        fi
    done

    # Prune ESP copies/entries outside the keep set.
    local d
    for d in "$bootdir"/x/gen-*; do
        [[ -d "$d" ]] || continue
        id="${d##*/gen-}"
        if [[ -z "${keep[$id]:-}" ]]; then
            rm -rf "$d"
            rm -f "$sb_dir/x-gen-$id.conf"
        fi
    done

    # Defaults: prefer the current generation, else the newest entry.
    local def="$cur"
    if [[ "$have_sb" -eq 1 && ! -f "$sb_dir/x-gen-$def.conf" ]]; then
        for id in "${keep_ids[@]}"; do
            if [[ -f "$sb_dir/x-gen-$id.conf" ]]; then
                def="$id"
            fi
        done
    fi
    if [[ "$have_sb" -eq 1 && -f "$sb_dir/x-gen-$def.conf" ]]; then
        if [[ -f "$bootdir/loader/loader.conf" ]]; then
            sed -i "s|^default .*|default x-gen-$def.conf|" "$bootdir/loader/loader.conf"
            if ! grep -q '^default ' "$bootdir/loader/loader.conf"; then
                printf 'default x-gen-%s.conf\n' "$def" >> "$bootdir/loader/loader.conf"
            fi
        else
            printf 'default x-gen-%s.conf\ntimeout 5\nconsole-mode max\n' "$def" > "$bootdir/loader/loader.conf"
        fi
        cp -f "$sb_dir/x-gen-$def.conf" "$sb_dir/x.conf"
    fi
    if [[ "$have_grub" -eq 1 ]]; then
        {
            printf 'set default=x-gen-%s\n' "$def"
            printf '%s\n' "$entries"
        } > "$grub_dir/custom.cfg"
    fi
    return 0
}

# --- generation lifecycle ---------------------------------------------------

xgen_new() {
    local reason="${1:-manual}" label="${2:-}"
    local backend id dir pkg_backend parent oldcur root_subvol running
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
    oldcur="$(xgen_current)"
    parent="$(xgen_running_id)"
    [[ -n "$parent" ]] || parent="$oldcur"
    root_subvol="$(xgen_default_subvol "$id")"
    xgen_write_manifest "$id" "$parent" "$reason" "$label" "$pkg_backend" "$root_subvol"
    xgen_snapshot_create "$id" || xgen_die "snapshot failed for generation $id"
    if [[ "$backend" == "btrfs" && "$root_subvol" == "$(xgen_snapshot_path "$id")" ]]; then
        xgen_patch_snapshot_fstab "$id" || xgen_warn "could not patch the snapshot fstab"
    fi
    if [[ -z "$oldcur" ]]; then
        xgen_current_set "$id"
    fi
    running="$(xgen_running_id)"
    if [[ -z "$running" && -z "$oldcur" ]]; then
        export X_GEN_RUNNING="$id"
    fi
    xgen_boot_sync
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

xgen_rollback() {
    local target="${1:-}" no_safety="${2:-0}"
    local backend running
    [[ -n "$target" ]] || xgen_die "usage: x gen rollback <id> [--no-safety]"
    backend="$(xgen_backend)"
    [[ "$backend" != "off" ]] || xgen_die "generations are not supported on this system"
    if [[ "$backend" == "btrfs" && "$(id -u)" -ne 0 ]]; then
        xgen_die "rollback requires root"
    fi
    [[ -f "$(xgen_manifest_path "$target")" ]] || xgen_die "generation $target not found"

    if [[ "$no_safety" != "1" && "$no_safety" != "--no-safety" ]]; then
        xgen_new "pre-rollback" "safety" >/dev/null || xgen_die "safety generation failed"
    fi
    running="$(xgen_running_id)"
    touch "$(xgen_gen_dir "$target")/pinned"
    xgen_current_set "$target"
    xgen_boot_sync "$target"
    if [[ "$running" == "$target" ]]; then
        xgen_pending_clear
        xgen_log "generation $target is already running"
    else
        xgen_pending_set "$target"
        xgen_log "generation $target selected as default; reboot to apply"
    fi
    return 0
}

# --- inspection -------------------------------------------------------------

xgen_diff() {
    local a="$1" b="$2"
    [[ -n "$a" && -n "$b" ]] || xgen_die "usage: x gen diff <id-a> <id-b>"
    [[ -f "$(xgen_manifest_path "$a")" ]] || xgen_die "generation $a not found"
    [[ -f "$(xgen_manifest_path "$b")" ]] || xgen_die "generation $b not found"

    printf 'generation %s -> %s\n\n' "$a" "$b"

    local pa="$X_GEN_DIR/$a/packages.tsv" pb="$X_GEN_DIR/$b/packages.tsv"
    local diffs=""
    if [[ -f "$pa" && -f "$pb" ]]; then
        diffs="$(awk '
            NR == FNR { av[$1] = $2; next }
            { bv[$1] = $2 }
            END {
                for (n in bv) if (!(n in av)) printf "added\t%s\t%s\n", n, bv[n]
                for (n in av) if (!(n in bv)) printf "removed\t%s\t%s\n", n, av[n]
                for (n in av) if ((n in bv) && av[n] != bv[n]) printf "updated\t%s\t%s\t%s\n", n, av[n], bv[n]
            }' "$pa" "$pb" | LC_ALL=C sort)"
    fi
    printf 'packages:\n'
    if [[ -z "$diffs" ]]; then
        printf '  (no changes)\n'
    else
        while IFS=$'\t' read -r kind n v1 v2; do
            case "$kind" in
                added)   printf '  + %s %s\n' "$n" "$v1" ;;
                removed) printf '  - %s %s\n' "$n" "$v1" ;;
                updated) printf '  ~ %s %s -> %s\n' "$n" "$v1" "$v2" ;;
            esac
        done <<< "$diffs"
    fi
    printf '\n'

    local sa="$X_GEN_DIR/$a/services.txt" sb="$X_GEN_DIR/$b/services.txt"
    printf 'services:\n'
    if [[ -f "$sa" && -f "$sb" ]]; then
        local sadded="" sremoved=""
        sadded="$(comm -13 "$sa" "$sb" 2>/dev/null || true)"
        sremoved="$(comm -23 "$sa" "$sb" 2>/dev/null || true)"
        if [[ -z "$sadded$sremoved" ]]; then
            printf '  (no changes)\n'
        else
            local s
            for s in $sadded; do printf '  + %s\n' "$s"; done
            for s in $sremoved; do printf '  - %s\n' "$s"; done
        fi
    else
        printf '  (not captured)\n'
    fi
    printf '\n'

    local ka kb ha hb
    ka="$(xgen_manifest_field "$a" release)"
    kb="$(xgen_manifest_field "$b" release)"
    printf 'kernel:     %s -> %s\n' "${ka:-?}" "${kb:-?}"
    ha="$(xgen_manifest_field "$a" etc_sha256)"
    hb="$(xgen_manifest_field "$b" etc_sha256)"
    printf '/etc:       %s -> %s\n' "${ha:-?}" "${hb:-?}"
    printf 'root:       %s -> %s\n' \
        "$(xgen_manifest_field "$a" root_subvol)" "$(xgen_manifest_field "$b" root_subvol)"
}

# --- pin and prune ----------------------------------------------------------

xgen_pin() {
    local id="$1" unpin="${2:-0}"
    [[ -n "$id" ]] || xgen_die "usage: x gen pin <id> [--unpin]"
    [[ -f "$(xgen_manifest_path "$id")" ]] || xgen_die "generation $id not found"
    if [[ "$unpin" == "1" || "$unpin" == "--unpin" ]]; then
        rm -f "$(xgen_gen_dir "$id")/pinned"
        xgen_log "generation $id unpinned"
    else
        touch "$(xgen_gen_dir "$id")/pinned"
        xgen_log "generation $id pinned (never pruned)"
    fi
}

xgen_delete_generation() {
    local id="$1" backend snap
    backend="$(xgen_backend)"
    snap="$(xgen_snapshot_path "$id")"
    case "$backend" in
        btrfs)
            [[ "$(id -u)" -eq 0 ]] || xgen_die "prune requires root"
            if [[ -d "$snap" ]]; then
                btrfs subvolume delete "$snap" >/dev/null || return 1
            fi
            ;;
        dir)
            rm -rf "$snap"
            ;;
        *)
            return 1
            ;;
    esac
    rm -rf "$(xgen_gen_dir "$id")"
    return 0
}

# xgen_prune [keep] [dry-run]
xgen_prune() {
    local keep_n="${1:-${X_GEN_KEEP:-5}}" dry="${2:-0}"
    [[ "$keep_n" =~ ^[0-9]+$ ]] || xgen_die "keep must be a number"
    local backend running cur id
    backend="$(xgen_backend)"
    [[ "$backend" != "off" ]] || xgen_die "generations are not supported on this system"
    if [[ "$backend" == "btrfs" && "$dry" != "1" && "$(id -u)" -ne 0 ]]; then
        xgen_die "prune requires root"
    fi

    running="$(xgen_running_id)"
    cur="$(xgen_current)"

    local ids=()
    while IFS= read -r id; do
        [[ -n "$id" ]] && ids+=("$id")
    done < <(xgen_gen_ids)
    local total="${#ids[@]}"
    if [[ "$total" -eq 0 ]]; then
        xgen_log "no generations to prune"
        return 0
    fi

    local first_keep=$((total - keep_n))
    (( first_keep < 0 )) && first_keep=0

    local -A keep=()
    if [[ -n "$running" ]]; then keep[$running]=1; fi
    if [[ -n "$cur" ]]; then keep[$cur]=1; fi
    local i
    for (( i = 0; i < total; i++ )); do
        id="${ids[i]}"
        if (( i >= first_keep )); then keep[$id]=1; fi
        if [[ -f "$(xgen_gen_dir "$id")/pinned" ]]; then keep[$id]=1; fi
    done

    local removed=0
    for id in "${ids[@]}"; do
        [[ -n "${keep[$id]:-}" ]] && continue
        if [[ "$dry" == "1" ]]; then
            printf 'would remove generation %s\n' "$id"
        else
            if xgen_delete_generation "$id"; then
                printf 'removed generation %s\n' "$id"
            else
                xgen_warn "could not remove generation $id"
                continue
            fi
        fi
        removed=$((removed + 1))
    done

    if [[ "$dry" != "1" && "$removed" -gt 0 ]]; then
        xgen_boot_sync
    fi

    local pending
    pending="$(xgen_pending)"
    if [[ -n "$pending" && ! -f "$(xgen_manifest_path "$pending")" ]]; then
        xgen_pending_clear
        xgen_warn "pending rollback target $pending no longer exists; marker cleared"
    fi

    if [[ "$dry" == "1" ]]; then
        xgen_log "dry-run: $removed generation(s) would be removed (keep=$keep_n)"
    else
        xgen_log "$removed generation(s) removed (keep=$keep_n, pinned/running/default kept)"
    fi
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
    local backend cur running pending dir then_hash now_hash
    backend="$(xgen_backend)"
    printf 'backend:    %s\n' "$backend"
    cur="$(xgen_current)"
    running="$(xgen_running_id)"
    pending="$(xgen_pending)"
    printf 'running:    %s\n' "${running:-unknown}"
    printf 'default:    %s\n' "${cur:-none}"
    if [[ -n "$pending" && "$pending" != "$running" ]]; then
        printf 'pending:    rollback to %s on reboot\n' "$pending"
    fi
    if [[ -z "$cur" ]]; then
        xgen_supported || printf 'status:     generations unavailable (no btrfs on %s)\n' "$X_GEN_ROOT"
        return 0
    fi
    # Drift is measured against the running generation when it is known.
    local ref="$cur"
    if [[ -n "$running" && -f "$(xgen_manifest_path "$running")" ]]; then
        ref="$running"
    fi
    dir="$(xgen_gen_dir "$ref")"
    printf 'created:    %s\n' "$(xgen_manifest_field "$ref" created)"
    printf 'reason:     %s\n' "$(xgen_manifest_field "$ref" reason)"
    printf 'label:      %s\n' "$(xgen_manifest_field "$ref" label)"
    printf 'snapshot:   %s\n' "$(xgen_snapshot_path "$ref")"
    then_hash="$(sed -n 's/.*"etc_sha256": *"\([^"]*\)".*/\1/p' "$dir/manifest.json" 2>/dev/null | head -1)"
    now_hash="$(xgen_hash_tree "$X_GEN_ROOT/etc" 2>/dev/null || true)"
    if [[ -n "$then_hash" && "$then_hash" != "n/a" && -n "$now_hash" && "$then_hash" != "$now_hash" ]]; then
        printf 'drift:      /etc changed since generation %s (x gen new)\n' "$ref"
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

# Mounts a snapshot read-only (btrfs only); echoes the mount dir, empty for
# the dir backend. The caller must xgen_release_mount it.
xgen_snapshot_mount() {
    local id="$1" dev mnt
    [[ "$(xgen_backend)" == "btrfs" ]] || return 0
    [[ "$(id -u)" -eq 0 ]] || xgen_die "btrfs restore requires root"
    dev="$(xgen_root_device)"
    [[ -n "$dev" ]] || xgen_die "cannot resolve the device of $X_GEN_ROOT"
    mnt="$(mktemp -d)"
    mount -o "ro,subvol=$X_GEN_SUBVOL_PREFIX/$id" "$dev" "$mnt" || {
        rmdir "$mnt" 2>/dev/null || true
        xgen_die "cannot mount snapshot $id"
    }
    printf '%s\n' "$mnt"
}

xgen_restore() {
    local id="$1" path="$2" dest="${3:-}"
    [[ -n "$id" && -n "$path" ]] || xgen_die "usage: x gen restore <path> [--from ID]"
    [[ -n "$dest" ]] || dest="/${path#/}"

    local snap mnt="" root src
    snap="$(xgen_snapshot_path "$id")"
    [[ -d "$snap" ]] || xgen_die "generation $id not found ($snap)"
    mnt="$(xgen_snapshot_mount "$id")"
    root="${mnt:-$snap}"
    src="$root/${path#/}"

    if [[ ! -e "$src" ]]; then
        xgen_release_mount "$mnt"
        xgen_die "$path not found in generation $id"
    fi

    xgen_restore_from "$src" "$dest"
    xgen_release_mount "$mnt"
    xgen_log "restored $path from generation $id -> $dest"
}

# Restores every file of a package using the file list of the package database
# inside the snapshot (pacman's local db, or xpm's local db).
xgen_restore_pkg() {
    local pkg="$1" id="$2" dest="${3:-}"
    [[ -n "$pkg" && -n "$id" ]] || xgen_die "usage: x gen restore --pkg <name> [--from ID]"
    [[ "$pkg" != */* ]] || xgen_die "invalid package name: $pkg"

    local snap mnt="" root dbdir files count=0 rel src target prefix
    snap="$(xgen_snapshot_path "$id")"
    [[ -d "$snap" ]] || xgen_die "generation $id not found ($snap)"
    mnt="$(xgen_snapshot_mount "$id")"
    root="${mnt:-$snap}"

    dbdir="$(find "$root/var/lib/pacman/local" -maxdepth 1 -mindepth 1 -type d -name "$pkg-[0-9]*" 2>/dev/null | LC_ALL=C sort | head -1)" || dbdir=""
    if [[ -z "$dbdir" && -d "$root/var/lib/xpm/local/$pkg" ]]; then
        dbdir="$root/var/lib/xpm/local/$pkg"
    fi
    if [[ -z "$dbdir" ]]; then
        xgen_release_mount "$mnt"
        xgen_die "package $pkg not found in generation $id"
    fi
    files="$dbdir/files"
    if [[ ! -f "$files" ]]; then
        xgen_release_mount "$mnt"
        xgen_die "no file list for package $pkg in generation $id"
    fi

    prefix="${dest%/}"
    while IFS= read -r rel; do
        [[ "$rel" == %* ]] && continue
        [[ -n "$rel" ]] || continue
        rel="${rel#/}"
        src="$root/$rel"
        target="$prefix/$rel"
        if [[ ! -e "$src" ]]; then
            xgen_warn "missing in snapshot: /$rel"
            continue
        fi
        if [[ -d "$src" ]]; then
            mkdir -p "$target"
        else
            xgen_restore_file "$src" "$target"
        fi
        count=$((count + 1))
    done < "$files"

    xgen_release_mount "$mnt"
    xgen_log "restored $count path(s) from package $pkg (generation $id)"
}
