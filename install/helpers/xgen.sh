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
#   X_GEN_SUBVOL_PREFIX  in-fs path of the snapshots dir (auto-detected from
#                        the btrfs mount, e.g. /@snapshots; override to force)
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
X_GEN_SUBVOL_PREFIX="${X_GEN_SUBVOL_PREFIX:-}"
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

# The state dir is root-only (0700) on installed systems: give a clear message
# instead of returning an empty list when a read command is run as a user.
xgen_check_state_readable() {
    [[ -d "$X_GEN_DIR" ]] || return 0
    [[ -r "$X_GEN_DIR" ]] && return 0
    [[ "$(id -u)" -eq 0 ]] && return 0
    xgen_die "generation state is root-only ($X_GEN_DIR); re-run with sudo"
}

# True when the relative path stays inside the snapshot (no `..` components).
xgen_is_safe_relpath() {
    local p="${1#/}"
    case "$p" in
        ''|..|../*|*/../*|*/..) return 1 ;;
    esac
    return 0
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
            ! -name '.pwd.lock' ! -name 'mtab' ! -name '.updated' \
            ! -name 'resolv.conf' ! -name 'adjtime' \
            ! -path './pacman.d/gnupg/*' \
            -print0 2>/dev/null \
            | LC_ALL=C sort -z \
            | xargs -0 -r sha256sum \
            | sha256sum | cut -d' ' -f1
    )
}

xgen_kernel_release() {
    local rel="" running
    running="$(uname -r 2>/dev/null || true)"
    # Prefer the running kernel when its modules are present (installed
    # systems); inside a chroot fall back to the newest modules dir.
    if [[ -n "$running" && -d "$X_GEN_ROOT/usr/lib/modules/$running" ]]; then
        rel="$running"
    elif [[ -d "$X_GEN_ROOT/usr/lib/modules" ]]; then
        rel="$(find "$X_GEN_ROOT/usr/lib/modules" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null | LC_ALL=C sort -V | tail -1)"
    fi
    [[ -n "$rel" ]] || rel="${running:-unknown}"
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

# Captures the applied-migration markers of every user home under X_GEN_ROOT
# (`<user>\t<marker>` lines). Markers live in ~/.local/state/x/migrations, so
# they are not part of the root snapshot; the manifest records them.
xgen_capture_migrations() {
    local out="$1" home user m
    : > "$out"
    for home in "$X_GEN_ROOT/root" "$X_GEN_ROOT"/home/*; do
        [[ -d "$home/.local/state/x/migrations" ]] || continue
        if [[ "$home" == "$X_GEN_ROOT/root" ]]; then
            user="root"
        else
            user="$(basename "$home")"
        fi
        while IFS= read -r m; do
            [[ -n "$m" ]] || continue
            printf '%s\t%s\n' "$user" "$m"
        done < <(find "$home/.local/state/x/migrations" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | LC_ALL=C sort)
    done | LC_ALL=C sort > "$out"
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

    # Per-kernel map for multi-kernel support:
    #   pkgbase <TAB> release <TAB> vmlinuz name <TAB> initramfs name
    local ts="$dest/kernels.tsv" mdir rel pkgbase vname iname
    : > "$ts"
    if [[ -d "$X_GEN_ROOT/usr/lib/modules" ]]; then
        for mdir in "$X_GEN_ROOT"/usr/lib/modules/*/; do
            [[ -d "$mdir" ]] || continue
            rel="$(basename "$mdir")"
            pkgbase="$(cat "$mdir/pkgbase" 2>/dev/null || true)"
            [[ -n "$pkgbase" ]] || continue
            vname=""
            iname=""
            [[ -f "$X_GEN_ROOT/boot/vmlinuz-$pkgbase" ]] && vname="vmlinuz-$pkgbase"
            [[ -f "$X_GEN_ROOT/boot/initramfs-$pkgbase.img" ]] && iname="initramfs-$pkgbase.img"
            [[ -n "$vname" && -n "$iname" ]] || continue
            printf '%s\t%s\t%s\t%s\n' "$pkgbase" "$rel" "$vname" "$iname" >> "$ts"
        done
    fi
    [[ -s "$ts" ]] || rm -f "$ts"

    [[ "$found" -eq 1 ]]
}

xgen_gen_kernels() {
    local f
    f="$(xgen_gen_dir "$1")/boot/kernels.tsv"
    [[ -f "$f" ]] && cat "$f"
    return 0
}

# Pairs a vmlinuz with its matching initramfs by name suffix
# (linux -> initramfs-linux.img, linux-lts -> initramfs-linux-lts.img),
# echoing "kernel|initrd". Used for legacy generations without kernels.tsv.
xgen_pick_pair() {
    local dir="$1" k name i
    k="$(find "$dir" -maxdepth 1 -name 'vmlinuz-*' -type f 2>/dev/null | LC_ALL=C sort | head -1)" || k=""
    [[ -n "$k" ]] || return 0
    name="${k##*/vmlinuz-}"
    i="$dir/initramfs-$name.img"
    if [[ ! -f "$i" ]]; then
        i="$(find "$dir" -maxdepth 1 -name 'initramfs-*.img' -type f 2>/dev/null | LC_ALL=C sort | head -1)" || i=""
    fi
    [[ -n "$i" && -f "$i" ]] || return 0
    printf '%s|%s\n' "$k" "$i"
}

xgen_primary_pkgbase() {
    local id="$1" rel pkgbase release
    rel="$(xgen_manifest_field "$id" release)"
    while IFS=$'\t' read -r pkgbase release _ _; do
        [[ -n "$pkgbase" ]] || continue
        if [[ -n "$rel" && "$release" == "$rel" ]]; then
            printf '%s\n' "$pkgbase"
            return 0
        fi
    done < <(xgen_gen_kernels "$id")
    return 0
}

xgen_gen_bootable() {
    local id="$1"
    [[ -s "$(xgen_gen_dir "$id")/boot/kernels.tsv" ]] && return 0
    [[ -n "$(xgen_pick_pair "$(xgen_gen_dir "$id")/boot")" ]]
}

# Rewrites the /etc hash in a manifest (used to re-anchor it to the snapshot).
xgen_manifest_set_hash() {
    local id="$1" hash="$2" f tmp
    f="$(xgen_manifest_path "$id")"
    [[ -f "$f" && -n "$hash" ]] || return 0
    tmp="$f.tmp"
    sed "s|\"etc_sha256\": \"[^\"]*\"|\"etc_sha256\": \"$hash\"|" "$f" > "$tmp" && mv "$tmp" "$f"
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
    local pkg_count pkg_hash svc_count mig_count
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
    mig_count="$(wc -l < "$dir/migrations.txt" 2>/dev/null | tr -d ' ')"
    [[ -n "$mig_count" ]] || mig_count=0

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
        printf '  "services": {"count": %s},\n' "$svc_count"
        printf '  "migrations": {"count": %s}\n' "$mig_count"
        printf '}\n'
    } > "$dir/manifest.json"
}

# --- snapshots --------------------------------------------------------------

xgen_root_device() {
    findmnt -n -o SOURCE -T "$X_GEN_ROOT" 2>/dev/null | sed 's/\[.*\]$//'
}

# In-fs path of the snapshot store, used by mount options and boot entries.
# An explicit X_GEN_SUBVOL_PREFIX wins; otherwise it is derived from the btrfs
# mount (`/@snapshots` on installer layouts); the dir/off backends fall back to
# the mount path itself.
xgen_subvol_prefix() {
    if [[ -n "${X_GEN_SUBVOL_PREFIX:-}" ]]; then
        printf '%s\n' "$X_GEN_SUBVOL_PREFIX"
        return 0
    fi
    if [[ "$(xgen_backend)" == "btrfs" ]]; then
        local fsroot=""
        fsroot="$(findmnt -n -o FSROOT -T "$X_GEN_SNAPSHOTS" 2>/dev/null)" || fsroot=""
        if [[ -n "$fsroot" && "$fsroot" != "/" ]]; then
            printf '%s\n' "$fsroot"
            return 0
        fi
    fi
    printf '%s\n' "$X_GEN_SNAPSHOTS"
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

    # Runtime locks must not be frozen into a bootable generation: the pacman
    # hooks snapshot the tree while a transaction holds /var/lib/pacman/db.lck,
    # and a stale lock inside the booted generation blocks every later pacman
    # run ("unable to lock database"). The snapshot is a separate tree, so
    # deleting it here never touches the running transaction.
    rm -f "$snap/var/lib/pacman/db.lck"
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
    subpath="$(xgen_subvol_prefix)/$id"
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
        btrfs) printf '%s/%s\n' "$(xgen_subvol_prefix)" "$id" ;;
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

    # Bootable kept generations (kernel available); the default is the current
    # one when bootable, else the newest bootable entry.
    local bootable_ids=()
    for id in "${keep_ids[@]}"; do
        [[ -n "${keep[$id]:-}" ]] || continue
        if [[ "$id" == "$running" ]] || xgen_gen_bootable "$id"; then
            bootable_ids+=("$id")
        fi
    done
    local def="" def_lin="" def_initrd="" def_cmd=""
    if [[ "${#bootable_ids[@]}" -gt 0 ]]; then
        def="${bootable_ids[${#bootable_ids[@]}-1]}"
        for id in "${bootable_ids[@]}"; do
            if [[ "$id" == "$cur" ]]; then
                def="$cur"
                break
            fi
        done
    fi

    mkdir -p "$bootdir/x"
    local entries="" cmd title
    for id in "${keep_ids[@]}"; do
        [[ -n "${keep[$id]:-}" ]] || continue

        # Per-kernel rows (multi-kernel): pkgbase|release|vmlinuz|initramfs.
        local rows=() row pkgbase rel vname iname kfile ifile dest subdir
        local primary="" rp
        while IFS=$'\t' read -r pkgbase rel vname iname; do
            [[ -n "$pkgbase" ]] && rows+=("$pkgbase|$rel|$vname|$iname")
        done < <(xgen_gen_kernels "$id")
        if [[ "${#rows[@]}" -eq 0 ]]; then
            # Legacy single-kernel generation (no kernels.tsv): pair the
            # kernel with its initramfs by name suffix.
            local pair=""
            if [[ "$id" == "$running" ]]; then
                pair="$(xgen_pick_pair "$bootdir")"
            else
                pair="$(xgen_pick_pair "$(xgen_gen_dir "$id")/boot")"
            fi
            if [[ -z "$pair" ]]; then
                xgen_warn "generation $id has no archived kernel; entry skipped"
                continue
            fi
            IFS='|' read -r kfile ifile <<< "$pair"
            rows=("default|$(xgen_manifest_field "$id" release)|${kfile##*/}|${ifile##*/}")
        fi
        primary="$(xgen_primary_pkgbase "$id")"
        if [[ -z "$primary" ]]; then
            for rp in "${rows[@]}"; do
                primary="${rp%%|*}"
                break
            done
        fi

        for row in "${rows[@]}"; do
            IFS='|' read -r pkgbase rel vname iname <<< "$row"
            local suffix="" lin initrd
            subdir=""
            [[ "$pkgbase" != "$primary" ]] && suffix="-$pkgbase"
            if [[ "$id" == "$running" ]]; then
                # The running generation boots the live ESP kernels (its root
                # mutates in place); frozen kernels may not match its modules.
                if [[ ! -f "$bootdir/$vname" || ! -f "$bootdir/$iname" ]]; then
                    xgen_warn "generation $id: $pkgbase kernel missing on the ESP; entry skipped"
                    continue
                fi
                lin="/$vname"
                initrd="/$iname"
            else
                [[ "$pkgbase" == "default" ]] || subdir="$pkgbase"
                if [[ ! -f "$(xgen_gen_dir "$id")/boot/$vname" || ! -f "$(xgen_gen_dir "$id")/boot/$iname" ]]; then
                    xgen_warn "generation $id has no archived $pkgbase kernel; entry skipped"
                    continue
                fi
                dest="$bootdir/x/gen-$id${subdir:+/$subdir}"
                mkdir -p "$dest"
                cp -a "$(xgen_gen_dir "$id")/boot/$vname" "$dest/$vname"
                cp -a "$(xgen_gen_dir "$id")/boot/$iname" "$dest/$iname"
                lin="/x/gen-$id${subdir:+/$subdir}/$vname"
                initrd="/x/gen-$id${subdir:+/$subdir}/$iname"
            fi
            cmd="$(xgen_cmdline_for_gen "$id")"
            title="X Linux (gen $id, $(xgen_manifest_field "$id" reason))"
            [[ -z "$suffix" ]] || title="$title [$pkgbase]"
            title="${title//\"/\'}"
            if [[ -n "$def" && "$id" == "$def" && -z "$suffix" ]]; then
                def_lin="$lin"
                def_initrd="$initrd"
                def_cmd="$cmd"
            fi
            if [[ "$have_sb" -eq 1 ]]; then
                {
                    printf 'title   %s\n' "$title"
                    printf 'linux   %s\n' "$lin"
                    printf 'initrd  %s\n' "$initrd"
                    printf 'options %s\n' "$cmd"
                } > "$sb_dir/x-gen-$id$suffix.conf"
            fi
            if [[ "$have_grub" -eq 1 ]]; then
                entries="$entries
menuentry \"$title\" --id x-gen-$id$suffix {
    linux $lin $cmd
    initrd $initrd
}"
            fi
        done
    done

    # Prune ESP copies/entries outside the keep set.
    local d
    for d in "$bootdir"/x/gen-*; do
        [[ -d "$d" ]] || continue
        id="${d##*/gen-}"
        if [[ -z "${keep[$id]:-}" ]]; then
            rm -rf "$d"
            rm -f "$sb_dir/x-gen-$id.conf"
            local e
            for e in "$sb_dir/x-gen-$id-"*.conf; do
                [[ -e "$e" ]] && rm -f "$e"
            done
        fi
    done

    if [[ "$have_sb" -eq 1 && -n "$def" ]]; then
        if [[ -f "$bootdir/loader/loader.conf" ]]; then
            sed -i "s|^default .*|default x-gen-$def.conf|" "$bootdir/loader/loader.conf"
            if ! grep -q '^default ' "$bootdir/loader/loader.conf"; then
                printf 'default x-gen-%s.conf\n' "$def" >> "$bootdir/loader/loader.conf"
            fi
        else
            printf 'default x-gen-%s.conf\ntimeout 5\nconsole-mode max\n' "$def" > "$bootdir/loader/loader.conf"
        fi
        cp -f "$sb_dir/x-gen-$def.conf" "$sb_dir/x.conf"
        if [[ -n "$def_lin" ]]; then
            {
                printf 'title   X Linux (rescue)\n'
                printf 'linux   %s\n' "$def_lin"
                printf 'initrd  %s\n' "$def_initrd"
                printf 'options %s systemd.unit=rescue.target\n' "$def_cmd"
            } > "$sb_dir/x-rescue.conf"
        fi
    fi
    if [[ "$have_grub" -eq 1 ]]; then
        {
            if [[ -n "$def" ]]; then
                printf 'set default=x-gen-%s\n' "$def"
            fi
            printf '%s\n' "$entries"
            if [[ -n "$def_lin" ]]; then
                printf '\nmenuentry "X Linux (rescue)" --id x-rescue {\n'
                printf '    linux %s %s systemd.unit=rescue.target\n' "$def_lin" "$def_cmd"
                printf '    initrd %s\n' "$def_initrd"
                printf '}\n'
            fi
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
    xgen_capture_migrations "$dir/migrations.txt"
    xgen_capture_kernel "$id" || xgen_warn "kernel capture incomplete"
    oldcur="$(xgen_current)"
    parent="$(xgen_running_id)"
    [[ -n "$parent" ]] || parent="$oldcur"
    root_subvol="$(xgen_default_subvol "$id")"
    xgen_write_manifest "$id" "$parent" "$reason" "$label" "$pkg_backend" "$root_subvol"
    xgen_snapshot_create "$id" || xgen_die "snapshot failed for generation $id"
    if [[ "$backend" == "btrfs" && "$root_subvol" == "$(xgen_subvol_prefix)/$id" ]]; then
        xgen_patch_snapshot_fstab "$id" || xgen_warn "could not patch the snapshot fstab"
    fi
    # The /etc hash must describe the snapshot (immutable), not the live tree:
    # hashing before the snapshot raced with boot-time writers (resolv.conf,
    # ssh host keys, ...) and the manifest never matched again.
    local snap_etc
    snap_etc="$(xgen_snapshot_path "$id")/etc"
    if [[ -d "$snap_etc" ]]; then
        xgen_manifest_set_hash "$id" "$(xgen_hash_tree "$snap_etc" 2>/dev/null || true)"
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
    xgen_check_state_readable

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
    xgen_check_state_readable

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

    local ma="$X_GEN_DIR/$a/migrations.txt" mb="$X_GEN_DIR/$b/migrations.txt"
    printf 'migrations:\n'
    if [[ -f "$ma" && -f "$mb" ]]; then
        local madded mremoved mm
        madded="$(comm -13 "$ma" "$mb" 2>/dev/null || true)"
        mremoved="$(comm -23 "$ma" "$mb" 2>/dev/null || true)"
        if [[ -z "$madded$mremoved" ]]; then
            printf '  (no changes)\n'
        else
            while IFS= read -r mm; do
                if [[ -n "$mm" ]]; then
                    printf '  + %s\n' "$(printf '%s' "$mm" | tr '\t' ' ')"
                fi
            done <<< "$madded"
            while IFS= read -r mm; do
                if [[ -n "$mm" ]]; then
                    printf '  - %s\n' "$(printf '%s' "$mm" | tr '\t' ' ')"
                fi
            done <<< "$mremoved"
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

# Compares the live system against a generation's captures. Returns 0 when
# they match and 1 on drift (with a report).
xgen_verify() {
    local id="${1:-$(xgen_current)}" drift=0
    [[ -n "$id" ]] || xgen_die "no generation to verify; pass an id"
    [[ -f "$(xgen_manifest_path "$id")" ]] || xgen_die "generation $id not found"
    xgen_check_state_readable

    printf 'verifying live system against generation %s\n\n' "$id"

    local tmpdir live_pkgs live_svc live_mig
    tmpdir="$(mktemp -d)"
    live_pkgs="$tmpdir/packages.tsv"
    live_svc="$tmpdir/services.txt"
    live_mig="$tmpdir/migrations.txt"
    xgen_capture_packages "$live_pkgs" >/dev/null
    xgen_capture_services "$live_svc"
    xgen_capture_migrations "$live_mig"

    local gen_pkgs="$X_GEN_DIR/$id/packages.tsv"
    printf 'packages:\n'
    if [[ -f "$gen_pkgs" ]]; then
        local pkgs_diff count
        pkgs_diff="$(awk '
            NR == FNR { gv[$1] = $2; next }
            { lv[$1] = $2 }
            END {
                for (n in lv) if (!(n in gv)) printf "added\t%s\t%s\n", n, lv[n]
                for (n in gv) if (!(n in lv)) printf "missing\t%s\t%s\n", n, gv[n]
                for (n in gv) if ((n in lv) && gv[n] != lv[n]) printf "changed\t%s\t%s\t%s\n", n, gv[n], lv[n]
            }' "$gen_pkgs" "$live_pkgs" | LC_ALL=C sort)"
        if [[ -z "$pkgs_diff" ]]; then
            printf '  (match)\n'
        else
            local kind n v1 v2
            while IFS=$'\t' read -r kind n v1 v2; do
                [[ -n "$kind" ]] || continue
                case "$kind" in
                    added)   printf '  + %s %s\n' "$n" "$v1" ;;
                    missing) printf '  - %s %s\n' "$n" "$v1" ;;
                    changed) printf '  ~ %s %s -> %s\n' "$n" "$v1" "$v2" ;;
                esac
            done <<< "$pkgs_diff"
            count="$(printf '%s\n' "$pkgs_diff" | grep -c . || true)"
            drift=$((drift + count))
        fi
    else
        printf '  (not captured)\n'
    fi
    printf '\n'

    local gen_svc="$X_GEN_DIR/$id/services.txt"
    printf 'services:\n'
    if [[ -f "$gen_svc" ]]; then
        local sadded smissing count
        sadded="$(comm -13 "$gen_svc" "$live_svc" 2>/dev/null || true)"
        smissing="$(comm -23 "$gen_svc" "$live_svc" 2>/dev/null || true)"
        if [[ -z "$sadded$smissing" ]]; then
            printf '  (match)\n'
        else
            local s
            while IFS= read -r s; do [[ -n "$s" ]] && printf '  + %s\n' "$s"; done <<< "$sadded"
            while IFS= read -r s; do [[ -n "$s" ]] && printf '  - %s\n' "$s"; done <<< "$smissing"
            count="$(printf '%s\n%s\n' "$sadded" "$smissing" | grep -c . || true)"
            drift=$((drift + count))
        fi
    else
        printf '  (not captured)\n'
    fi
    printf '\n'

    local gen_mig="$X_GEN_DIR/$id/migrations.txt"
    printf 'migrations:\n'
    if [[ -f "$gen_mig" ]]; then
        local madded mmissing count mm
        madded="$(comm -13 "$gen_mig" "$live_mig" 2>/dev/null || true)"
        mmissing="$(comm -23 "$gen_mig" "$live_mig" 2>/dev/null || true)"
        if [[ -z "$madded$mmissing" ]]; then
            printf '  (match)\n'
        else
            while IFS= read -r mm; do
                if [[ -n "$mm" ]]; then
                    printf '  + %s\n' "$(printf '%s' "$mm" | tr '\t' ' ')"
                fi
            done <<< "$madded"
            while IFS= read -r mm; do
                if [[ -n "$mm" ]]; then
                    printf '  - %s\n' "$(printf '%s' "$mm" | tr '\t' ' ')"
                fi
            done <<< "$mmissing"
            count="$(printf '%s\n%s\n' "$madded" "$mmissing" | grep -c . || true)"
            drift=$((drift + count))
        fi
    else
        printf '  (not captured)\n'
    fi
    printf '\n'

    local then_hash now_hash then_kernel now_kernel
    then_hash="$(xgen_manifest_field "$id" etc_sha256)"
    now_hash="$(xgen_hash_tree "$X_GEN_ROOT/etc" 2>/dev/null || true)"
    printf '/etc sha256: %s\n' "$then_hash"
    if [[ -n "$then_hash" && "$then_hash" != "n/a" && -n "$now_hash" && "$then_hash" != "$now_hash" ]]; then
        printf '             live: %s (changed)\n' "$now_hash"
        drift=$((drift + 1))
    fi
    then_kernel="$(xgen_manifest_field "$id" release)"
    now_kernel="$(xgen_kernel_release)"
    printf 'kernel:      %s\n' "$then_kernel"
    if [[ -n "$then_kernel" && "$then_kernel" != "$now_kernel" ]]; then
        printf '             live: %s (changed)\n' "$now_kernel"
        drift=$((drift + 1))
    fi

    rm -rf "$tmpdir"

    if [[ "$drift" -eq 0 ]]; then
        xgen_log "live system matches generation $id"
        return 0
    fi
    xgen_warn "$drift difference(s) against generation $id"
    return 1
}

# --- pin and prune ----------------------------------------------------------

xgen_pin() {
    local id="$1" unpin="${2:-0}"
    [[ -n "$id" ]] || xgen_die "usage: x gen pin <id> [--unpin]"
    [[ -f "$(xgen_manifest_path "$id")" ]] || xgen_die "generation $id not found"
    xgen_check_state_readable
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

# xgen_prune [keep] [dry-run] [older-than-days]
#
# A generation is removed only when it is outside the newest `keep` window,
# older than `older-than-days` (when > 0) and not pinned/running/default.
xgen_prune() {
    local keep_n="${1:-${X_GEN_KEEP:-5}}" dry="${2:-0}" older_days="${3:-0}"
    [[ "$keep_n" =~ ^[0-9]+$ ]] || xgen_die "keep must be a number"
    [[ "$older_days" =~ ^[0-9]+$ ]] || xgen_die "older-than must be a number of days"
    xgen_check_state_readable
    local backend running cur id
    local cutoff=""
    if (( older_days > 0 )); then
        cutoff="$(date -u -d "@$(( $(date +%s) - older_days * 86400 ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
        if [[ -z "$cutoff" ]]; then
            xgen_warn "cannot compute the age cutoff; ignoring --older-than"
        fi
    fi
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
    local i created
    for (( i = 0; i < total; i++ )); do
        id="${ids[i]}"
        if (( i >= first_keep )); then keep[$id]=1; fi
        if [[ -f "$(xgen_gen_dir "$id")/pinned" ]]; then keep[$id]=1; fi
        if [[ -n "$cutoff" ]]; then
            created="$(xgen_manifest_field "$id" created)"
            if [[ -n "$created" && "$created" > "$cutoff" ]]; then
                keep[$id]=1
            fi
        fi
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
    xgen_check_state_readable
    local dir id label reason created cur running markers found=0
    cur="$(xgen_current)"
    running="$(xgen_running_id)"
    printf '%-6s %-20s %-12s %s\n' "ID" "CREATED" "REASON" "LABEL"
    for dir in "$X_GEN_DIR"/[0-9]*; do
        [[ -d "$dir" ]] || continue
        id="$(basename "$dir")"
        created="$(xgen_manifest_field "$id" created)"
        reason="$(xgen_manifest_field "$id" reason)"
        label="$(xgen_manifest_field "$id" label)"
        markers=""
        if [[ "$id" == "$cur" ]]; then
            markers="${markers}*"
        fi
        if [[ "$id" == "$running" ]]; then
            markers="${markers}r"
        fi
        if [[ -f "$(xgen_gen_dir "$id")/pinned" ]]; then
            markers="${markers}p"
        fi
        if [[ -n "$markers" ]]; then
            id="$id $markers"
        fi
        printf '%-6s %-20s %-12s %s\n' "$id" "${created:-?}" "${reason:-?}" "$label"
        found=1
    done
    [[ "$found" -eq 1 ]] || printf 'no generations\n'
}

xgen_status() {
    xgen_check_state_readable
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

    local n_snaps=0 n_entries=0 d
    for d in "$X_GEN_SNAPSHOTS"/[0-9]*; do
        [[ -e "$d" ]] || continue
        n_snaps=$((n_snaps + 1))
    done
    for d in "$X_GEN_BOOT_DIR"/loader/entries/x-gen-*.conf; do
        [[ -e "$d" ]] || continue
        n_entries=$((n_entries + 1))
    done
    if [[ -f "$X_GEN_BOOT_DIR/grub/custom.cfg" ]]; then
        n_entries=$((n_entries + $(grep -c -- '--id x-gen-' "$X_GEN_BOOT_DIR/grub/custom.cfg" 2>/dev/null || true)))
    fi
    printf 'snapshots:  %s in %s\n' "$n_snaps" "$X_GEN_SNAPSHOTS"
    printf 'entries:    %s in %s\n' "$n_entries" "$X_GEN_BOOT_DIR"
    if [[ "$backend" == "btrfs" ]] && command -v btrfs >/dev/null 2>&1; then
        local usage=""
        usage="$(btrfs filesystem du -s "$X_GEN_SNAPSHOTS" 2>/dev/null | tail -1 | awk '{print $1}')" || usage=""
        if [[ -n "$usage" ]]; then
            printf 'usage:      %s in snapshots\n' "$usage"
        fi
    fi
    then_hash="$(sed -n 's/.*"etc_sha256": *"\([^"]*\)".*/\1/p' "$dir/manifest.json" 2>/dev/null | head -1)"
    now_hash="$(xgen_hash_tree "$X_GEN_ROOT/etc" 2>/dev/null || true)"
    if [[ -n "$then_hash" && "$then_hash" != "n/a" && -n "$now_hash" && "$then_hash" != "$now_hash" ]]; then
        printf 'drift:      /etc changed since generation %s (x gen new)\n' "$ref"
    fi
}

# --- btrfs quotas (space limits) --------------------------------------------

# Enables btrfs quotas on the snapshots subvolume and optionally sets an
# exclusive limit (X_GEN_QGROUP or --limit, e.g. 50G). Exclusive limits only
# count the snapshots' own data, which is what a retention budget wants.
xgen_quota_init() {
    local limit="${1:-${X_GEN_QGROUP:-}}"
    [[ "$(xgen_backend)" == "btrfs" ]] || xgen_die "btrfs quotas require the btrfs backend"
    [[ "$(id -u)" -eq 0 ]] || xgen_die "quota init requires root"
    command -v btrfs >/dev/null 2>&1 || xgen_die "btrfs-progs is required"
    [[ -d "$X_GEN_SNAPSHOTS" ]] || xgen_die "snapshots dir missing: $X_GEN_SNAPSHOTS"
    if ! btrfs quota enable "$X_GEN_SNAPSHOTS" >/dev/null 2>&1; then
        xgen_die "could not enable btrfs quotas on $X_GEN_SNAPSHOTS"
    fi
    if [[ -n "$limit" ]]; then
        [[ "$limit" =~ ^[0-9]+([.][0-9]+)?([KMGTP]i?B?)?$ ]] || xgen_die "invalid limit '$limit' (e.g. 50G)"
        btrfs qgroup limit -e "$limit" "$X_GEN_SNAPSHOTS" >/dev/null \
            || xgen_die "could not set the limit on $X_GEN_SNAPSHOTS"
        xgen_log "snapshots limited to $limit (exclusive) in $X_GEN_SNAPSHOTS"
    else
        xgen_log "btrfs quotas enabled in $X_GEN_SNAPSHOTS (set a limit with --limit)"
    fi
}

xgen_quota_status() {
    if [[ "$(xgen_backend)" != "btrfs" ]]; then
        echo "quota:  unavailable (backend: $(xgen_backend))"
        return 0
    fi
    echo "path:   $X_GEN_SNAPSHOTS"
    local usage=""
    usage="$(btrfs filesystem du -s "$X_GEN_SNAPSHOTS" 2>/dev/null | tail -1 | awk '{print $1}')" || usage=""
    [[ -n "$usage" ]] && echo "usage:  $usage"
    if btrfs qgroup show -reF "$X_GEN_SNAPSHOTS" >/dev/null 2>&1; then
        echo "qgroups:"
        btrfs qgroup show -eF "$X_GEN_SNAPSHOTS" 2>/dev/null | sed 's/^/  /'
    else
        echo "qgroups: not enabled (run 'x gen quota init')"
    fi
}

# --- export and import ------------------------------------------------------

# Packs a generation into a portable bundle (metadata always; snapshot data
# with --with-data). The archive is tar.zst when zstd is available, tar.gz
# otherwise.
xgen_gpg_available() { command -v gpg >/dev/null 2>&1; }

# Detects an OpenPGP packet stream by the first byte (0x80-0xCF).
xgen_is_gpg_file() {
    local b
    [[ -f "$1" ]] || return 1
    b="$(od -An -tu1 -N1 "$1" 2>/dev/null | tr -d ' ')"
    [[ -n "$b" ]] || return 1
    (( b >= 128 && b <= 207 ))
}

# Compression of a file by magic bytes: zst, gz or tar.
xgen_compression_of() {
    local magic
    magic="$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n')"
    case "$magic" in
        28b52ffd*) printf 'zst\n' ;;
        1f8b*)     printf 'gz\n' ;;
        *)         printf 'tar\n' ;;
    esac
}

# gpg wrapper: uses X_GEN_PASSPHRASE through a file descriptor (never argv)
# when set; otherwise gpg falls back to its agent/pinentry.
xgen_gpg_run() {
    if [[ -n "${X_GEN_PASSPHRASE:-}" ]]; then
        gpg --batch --yes --pinentry-mode loopback --passphrase-fd 3 "$@" 3<<<"$X_GEN_PASSPHRASE"
    else
        gpg --yes "$@"
    fi
}

xgen_export() {
    local id="$1" out="${2:-}" with_data="${3:-0}" sign="${4:-0}" enc="${5:-none}"
    local n=$(( $# < 5 ? $# : 5 ))
    shift "$n"
    local -a recipients=("$@")
    [[ -n "$id" ]] || xgen_die "usage: x gen export <id> [--out FILE] [--with-data] [--sign] [--encrypt|--encrypt-to KEY]"
    [[ -f "$(xgen_manifest_path "$id")" ]] || xgen_die "generation $id not found"
    case "$enc" in
        none|sym|recip) ;;
        *) xgen_die "invalid encryption mode '$enc'" ;;
    esac
    if [[ "$enc" == "sym" && "${#recipients[@]}" -gt 0 ]]; then
        xgen_die "--encrypt and --encrypt-to are mutually exclusive"
    fi
    if [[ "$enc" == "recip" && "${#recipients[@]}" -eq 0 ]]; then
        xgen_die "--encrypt-to needs at least one key"
    fi
    if [[ "$enc" != "none" ]] && ! xgen_gpg_available; then
        xgen_die "gpg is required to encrypt the bundle"
    fi
    if [[ "$sign" == "1" && "$enc" != "none" && -z "${X_GEN_SIGN_KEY:-}" ]]; then
        xgen_die "X_GEN_SIGN_KEY is not set (required for --sign)"
    fi

    local old_umask
    old_umask="$(umask)"
    umask 077
    xgen_check_state_readable

    local tmpdir
    tmpdir="$(mktemp -d)"
    cp -a "$(xgen_gen_dir "$id")/." "$tmpdir/"
    rm -f "$tmpdir/pinned"

    {
        printf 'schema=1\n'
        printf 'id=%s\n' "$id"
        printf 'hostname=%s\n' "$(xgen_manifest_field "$id" hostname)"
        printf 'created=%s\n' "$(xgen_manifest_field "$id" created)"
        printf 'exported=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'root_subvol=%s\n' "$(xgen_manifest_field "$id" root_subvol)"
        printf 'with_data=%s\n' "$with_data"
    } > "$tmpdir/BUNDLE.txt"

    if [[ "$with_data" == "1" ]]; then
        case "$(xgen_backend)" in
            btrfs)
                [[ "$(id -u)" -eq 0 ]] || { rm -rf "$tmpdir"; xgen_die "btrfs data export requires root"; }
                local ro="$X_GEN_SNAPSHOTS/.export-$id"
                btrfs subvolume delete "$ro" >/dev/null 2>&1 || true
                btrfs subvolume snapshot -r "$(xgen_snapshot_path "$id")" "$ro" >/dev/null \
                    || { rm -rf "$tmpdir"; xgen_die "cannot snapshot $id for export"; }
                if ! btrfs send "$ro" > "$tmpdir/snapshot.btrfs"; then
                    btrfs subvolume delete "$ro" >/dev/null 2>&1 || true
                    rm -rf "$tmpdir"
                    xgen_die "btrfs send failed for generation $id"
                fi
                btrfs subvolume delete "$ro" >/dev/null 2>&1 || true
                ;;
            dir)
                cp -a "$(xgen_snapshot_path "$id")" "$tmpdir/snapshot"
                ;;
        esac
    fi

    # Integrity manifest: sha256 of every bundled file (verified on import).
    local sums
    sums="$(mktemp)"
    (cd "$tmpdir" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum) > "$sums"
    mv "$sums" "$tmpdir/BUNDLE.sha256"

    local use_zstd=0
    if command -v zstd >/dev/null 2>&1; then
        if [[ -z "$out" || "$out" == *.tar.zst || "$out" == *.tar.zst.gpg ]]; then
            use_zstd=1
        fi
    fi

    if [[ -z "$out" ]]; then
        local stamp
        stamp="$(date -u +%Y%m%d)"
        if [[ "$use_zstd" -eq 1 ]]; then
            out="x-gen-$id-$stamp.tar.zst"
        else
            out="x-gen-$id-$stamp.tar.gz"
        fi
    fi
    if [[ "$enc" != "none" && "$out" != *.gpg ]]; then
        out="$out.gpg"
    fi

    if [[ "$enc" == "none" ]]; then
        if [[ "$use_zstd" -eq 1 ]]; then
            tar -C "$tmpdir" -cf - . | zstd -q -3 -o "$out" || { rm -rf "$tmpdir"; xgen_die "export failed"; }
        else
            tar -czf "$out" -C "$tmpdir" . || { rm -rf "$tmpdir"; xgen_die "export failed"; }
        fi
    else
        local -a gopts=(--cipher-algo AES256)
        if [[ "$enc" == "sym" ]]; then
            gopts+=(--symmetric)
        else
            local r
            for r in "${recipients[@]}"; do
                gopts+=(--recipient "$r")
            done
            gopts+=(--encrypt --trust-model always)
        fi
        if [[ "$sign" == "1" ]]; then
            gopts+=(--sign --local-user "$X_GEN_SIGN_KEY")
        fi
        if [[ "$use_zstd" -eq 1 ]]; then
            tar -C "$tmpdir" -cf - . | zstd -q -3 | xgen_gpg_run "${gopts[@]}" --output "$out" \
                || { rm -rf "$tmpdir"; xgen_die "encrypted export failed"; }
        else
            tar -C "$tmpdir" -czf - . | xgen_gpg_run "${gopts[@]}" --output "$out" \
                || { rm -rf "$tmpdir"; xgen_die "encrypted export failed"; }
        fi
        case "$enc" in
            sym)   xgen_log "encrypted bundle (symmetric, AES256): $out" ;;
            recip) xgen_log "encrypted bundle (recipients: ${recipients[*]}): $out" ;;
        esac
        [[ "$sign" == "1" ]] && xgen_log "embedded signature by $X_GEN_SIGN_KEY"
    fi

    if [[ "$sign" == "1" && "$enc" == "none" ]]; then
        local key="${X_GEN_SIGN_KEY:-}"
        if [[ -z "$key" ]]; then
            rm -rf "$tmpdir"
            xgen_die "X_GEN_SIGN_KEY is not set (required for --sign)"
        fi
        xgen_gpg_available || { rm -rf "$tmpdir"; xgen_die "gpg is required for --sign"; }
        gpg --batch --yes --local-user "$key" --detach-sign --output "$out.sig" "$out" \
            || { rm -rf "$tmpdir"; xgen_die "failed to sign $out"; }
        xgen_log "signed bundle: $out.sig"
    fi

    rm -rf "$tmpdir"
    umask "$old_umask"
    xgen_log "generation $id exported to $out"
}

# Imports a bundle created by xgen_export. Data is imported only when present
# in the bundle (btrfs: `btrfs receive`, dir: tree copy).
xgen_import() {
    local file="$1" force="${2:-0}" allow_metadata="${3:-0}"
    [[ -f "$file" ]] || xgen_die "bundle not found: $file"
    xgen_check_state_readable

    local tmpdir work="$file" decrypted=0
    tmpdir="$(mktemp -d)"

    if xgen_is_gpg_file "$file"; then
        xgen_gpg_available || { rm -rf "$tmpdir"; xgen_die "gpg is required to decrypt $file"; }
        work="$(mktemp)"
        decrypted=1
        if ! xgen_gpg_run --decrypt --output "$work" "$file"; then
            rm -f "$work"
            rm -rf "$tmpdir"
            xgen_die "failed to decrypt $file (wrong passphrase/key or corrupt)"
        fi
        xgen_log "bundle decrypted"
    fi

    case "$(xgen_compression_of "$work")" in
        zst)
            command -v zstd >/dev/null 2>&1 || { rm -f "$work"; rm -rf "$tmpdir"; xgen_die "zstd is required for $file"; }
            zstd -q -dc "$work" | tar -C "$tmpdir" -xf - || { rm -f "$work"; rm -rf "$tmpdir"; xgen_die "cannot extract $file"; }
            ;;
        gz)
            tar -xzf "$work" -C "$tmpdir" || { rm -f "$work"; rm -rf "$tmpdir"; xgen_die "cannot extract $file"; }
            ;;
        tar)
            tar -xf "$work" -C "$tmpdir" || { rm -f "$work"; rm -rf "$tmpdir"; xgen_die "cannot extract $file"; }
            ;;
        *)
            rm -f "$work"
            rm -rf "$tmpdir"
            xgen_die "unknown bundle format: $file (expected tar.zst, tar.gz, tar or a gpg-encrypted bundle)"
            ;;
    esac
    if [[ "$decrypted" == "1" ]]; then
        rm -f "$work"
    fi

    if [[ -f "$tmpdir/BUNDLE.sha256" ]]; then
        if ! (cd "$tmpdir" && sha256sum -c --quiet BUNDLE.sha256 >/dev/null 2>&1); then
            rm -rf "$tmpdir"
            xgen_die "bundle checksum verification failed (corrupt or tampered): $file"
        fi
    else
        xgen_warn "bundle has no BUNDLE.sha256; skipping the integrity check"
    fi

    if [[ -f "$file.sig" ]]; then
        if ! gpg --batch --verify "$file.sig" "$file" >/dev/null 2>&1; then
            rm -rf "$tmpdir"
            xgen_die "bundle signature verification failed: $file (import the publisher key first)"
        fi
    elif [[ "$decrypted" == "1" ]]; then
        xgen_log "encrypted bundle (gpg verifies embedded signatures when the signer key is present)"
    else
        xgen_warn "bundle is not signed ($file.sig missing)"
    fi

    local id
    id="$(sed -n 's/.*"id": *"\([^"]*\)".*/\1/p' "$tmpdir/manifest.json" 2>/dev/null | head -1)"
    if [[ -z "$id" ]]; then
        rm -rf "$tmpdir"
        xgen_die "invalid bundle: no generation id in manifest.json"
    fi

    local dir
    dir="$(xgen_gen_dir "$id")"
    if [[ -e "$dir" && "$force" != "1" ]]; then
        rm -rf "$tmpdir"
        xgen_die "generation $id already exists (use --force to replace it)"
    fi

    # Data first: a bundle whose snapshot cannot be imported must fail before
    # any trace of the generation lands in the state.
    if [[ -f "$tmpdir/snapshot.btrfs" ]]; then
        if [[ "$(xgen_backend)" != "btrfs" ]]; then
            if [[ "$allow_metadata" != "1" ]]; then
                rm -rf "$tmpdir"
                xgen_die "bundle contains btrfs data but the backend is not btrfs (use --allow-metadata-only to skip the snapshot)"
            fi
            xgen_warn "btrfs data in the bundle but the backend is not btrfs; snapshot skipped"
        else
            [[ "$(id -u)" -eq 0 ]] || { rm -rf "$tmpdir"; xgen_die "btrfs data import requires root"; }
            mkdir -p "$X_GEN_SNAPSHOTS"
            if btrfs receive "$X_GEN_SNAPSHOTS" < "$tmpdir/snapshot.btrfs" >/dev/null 2>&1; then
                # receive() preserves the sent name (.export-<id>) as a
                # read-only subvolume with received_uuid set; btrfs refuses to
                # flip those to rw (and forcing it breaks incremental send).
                # Fork a fresh writable snapshot for the generation and drop
                # the received one instead.
                if [[ -e "$X_GEN_SNAPSHOTS/$id" ]]; then
                    btrfs subvolume delete "$X_GEN_SNAPSHOTS/$id" >/dev/null 2>&1 || true
                fi
                if [[ -e "$X_GEN_SNAPSHOTS/.export-$id" ]]; then
                    if ! btrfs subvolume snapshot "$X_GEN_SNAPSHOTS/.export-$id" "$X_GEN_SNAPSHOTS/$id" >/dev/null 2>&1; then
                        xgen_warn "could not fork the received snapshot into generation $id"
                    fi
                    btrfs subvolume delete "$X_GEN_SNAPSHOTS/.export-$id" >/dev/null 2>&1 || true
                fi
            else
                if [[ "$allow_metadata" != "1" ]]; then
                    rm -rf "$tmpdir"
                    xgen_die "btrfs receive failed for $file (use --allow-metadata-only to keep the metadata)"
                fi
                xgen_warn "btrfs receive failed; metadata imported without snapshot data"
            fi
        fi
    elif [[ -d "$tmpdir/snapshot" ]]; then
        mkdir -p "$X_GEN_SNAPSHOTS"
        rm -rf "$X_GEN_SNAPSHOTS/$id"
        cp -a "$tmpdir/snapshot" "$X_GEN_SNAPSHOTS/$id"
    fi

    rm -rf "$dir"
    mkdir -p "$dir"
    cp -a "$tmpdir/." "$dir/"
    rm -f "$dir/BUNDLE.txt"
    rm -rf "$tmpdir"
    xgen_log "generation $id imported ('x gen rollback $id' to select it)"
}

# Machine-readable status (single JSON line).
xgen_status_json() {
    local backend cur running pending ref dir then_hash now_hash drift="false"
    local n_snaps=0 n_entries=0 d created reason label snapshot
    backend="$(xgen_backend)"
    cur="$(xgen_current)"
    running="$(xgen_running_id)"
    pending="$(xgen_pending)"
    ref="$cur"
    if [[ -n "$running" && -f "$(xgen_manifest_path "$running")" ]]; then
        ref="$running"
    fi
    if [[ -n "$ref" ]]; then
        dir="$(xgen_gen_dir "$ref")"
        created="$(xgen_manifest_field "$ref" created)"
        reason="$(xgen_manifest_field "$ref" reason)"
        label="$(xgen_manifest_field "$ref" label)"
        snapshot="$(xgen_snapshot_path "$ref")"
        then_hash="$(sed -n 's/.*"etc_sha256": *"\([^"]*\)".*/\1/p' "$dir/manifest.json" 2>/dev/null | head -1)"
        now_hash="$(xgen_hash_tree "$X_GEN_ROOT/etc" 2>/dev/null || true)"
        if [[ -n "$then_hash" && "$then_hash" != "n/a" && -n "$now_hash" && "$then_hash" != "$now_hash" ]]; then
            drift="true"
        fi
    fi
    for d in "$X_GEN_SNAPSHOTS"/[0-9]*; do
        [[ -e "$d" ]] || continue
        n_snaps=$((n_snaps + 1))
    done
    for d in "$X_GEN_BOOT_DIR"/loader/entries/x-gen-*.conf; do
        [[ -e "$d" ]] || continue
        n_entries=$((n_entries + 1))
    done
    if [[ -f "$X_GEN_BOOT_DIR/grub/custom.cfg" ]]; then
        n_entries=$((n_entries + $(grep -c -- '--id x-gen-' "$X_GEN_BOOT_DIR/grub/custom.cfg" 2>/dev/null || true)))
    fi
    printf '{"schema":1,"backend":"%s","running":"%s","default":"%s","pending":%s,"created":"%s","reason":"%s","label":"%s","snapshot":"%s","snapshots":%s,"entries":%s,"drift":%s}\n' \
        "$backend" \
        "$(xgen_json_str "$running")" \
        "$(xgen_json_str "$cur")" \
        "$(if [[ -n "$pending" ]]; then printf '"%s"' "$(xgen_json_str "$pending")"; else printf 'null'; fi)" \
        "$(xgen_json_str "$created")" \
        "$(xgen_json_str "$reason")" \
        "$(xgen_json_str "$label")" \
        "$(xgen_json_str "$snapshot")" \
        "$n_snaps" "$n_entries" "$drift"
}


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
    mount -o "ro,subvol=$(xgen_subvol_prefix)/$id" "$dev" "$mnt" || {
        rmdir "$mnt" 2>/dev/null || true
        xgen_die "cannot mount snapshot $id"
    }
    printf '%s\n' "$mnt"
}

xgen_restore() {
    local id="$1" path="$2" dest="${3:-}" rel
    [[ -n "$id" && -n "$path" ]] || xgen_die "usage: x gen restore <path> [--from ID]"
    xgen_check_state_readable
    if ! xgen_is_safe_relpath "$path"; then
        xgen_die "path escapes the snapshot: $path"
    fi
    rel="${path#/}"
    [[ -n "$rel" ]] || xgen_die "invalid empty path"
    [[ -n "$dest" ]] || dest="/$rel"

    local snap mnt="" root src
    snap="$(xgen_snapshot_path "$id")"
    [[ -d "$snap" ]] || xgen_die "generation $id not found ($snap)"
    mnt="$(xgen_snapshot_mount "$id")"
    root="${mnt:-$snap}"
    src="$root/$rel"

    if [[ ! -e "$src" ]]; then
        xgen_release_mount "$mnt"
        xgen_die "$rel not found in generation $id"
    fi

    xgen_restore_from "$src" "$dest"
    xgen_release_mount "$mnt"
    xgen_log "restored $rel from generation $id -> $dest"
}

# Restores every file of a package using the file list of the package database
# inside the snapshot (pacman's local db, or xpm's local db).
xgen_restore_pkg() {
    local pkg="$1" id="$2" dest="${3:-}"
    [[ -n "$pkg" && -n "$id" ]] || xgen_die "usage: x gen restore --pkg <name> [--from ID]"
    [[ "$pkg" != */* ]] || xgen_die "invalid package name: $pkg"
    xgen_check_state_readable

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
        if ! xgen_is_safe_relpath "$rel"; then
            xgen_warn "skipping unsafe path in the package file list: $rel"
            continue
        fi
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
