# x — generations

Generations are the system-versioning layer of X Linux: each relevant change
produces a **bootable snapshot** of the root tree plus a **manifest** with the
system state. NixOS-like in behavior (numbered generations, rollback, granular
restore) without a content-addressed store: the snapshots are btrfs
subvolumes, the boot menu lists them and `x gen rollback` switches the default.

Installed systems created by the text installer use the btrfs layout
(`@`, `@home`, `@snapshots`, `@xstate`); the first generation is created at the
end of the installation.

## What a generation contains

| Path | Content |
|------|---------|
| `/.snapshots/<id>` | Writable snapshot of the live root (bootable restore point) |
| `/var/lib/x/generations/<id>/manifest.json` | Provenance: reason, parent, tooling, kernel, cmdline, hashes, `root_subvol` |
| `/var/lib/x/generations/<id>/packages.tsv` | `pacman -Q` capture (or `xpm query` when xpm is the only manager) |
| `/var/lib/x/generations/<id>/services.txt` | Enabled systemd units |
| `/var/lib/x/generations/<id>/migrations.txt` | Applied per-user migration markers (`user<TAB>marker`) |
| `/var/lib/x/generations/<id>/boot/` | Archived kernel/initramfs (used to boot frozen generations) |
| `/var/lib/x/generations/<id>/snapshot.uuid` | btrfs UUID of the snapshot |
| `/var/lib/x/generations/<id>/pinned` | Marker: never prune this generation's boot entry |
| `/var/lib/x/current` | Generation booted by default (the selected one) |
| `/var/lib/x/pending` | Set by rollback: target to boot on next reboot |

`/var/lib/x` is its own subvolume (`@xstate`) so metadata is shared by every
generation (it is not captured by the snapshots). The manifest hashes `/etc`
(`configs.etc_sha256`), so `x gen status` reports drift.

## Layout

```
@            -> /            (live root; the first generation)
@home        -> /home        (user data; never touched by rollback)
@snapshots   -> /.snapshots  (generation snapshots, mode 0700)
@xstate      -> /var/lib/x   (shared generation metadata, mode 0700)
```

`/tmp` is tmpfs (written by the installer to `/etc/fstab`).

## Commands

| Command | Description |
|---------|-------------|
| `x gen` / `x gen list` | Lists generations; `*` marks the default (current) one |
| `x gen new [--reason R] [--label L]` | Records a generation (snapshot + manifest + boot entry) |
| `x gen status [--json]` | Shows backend, running vs default, pending rollback and `/etc` drift |
| `x gen rollback <id> [--no-safety]` | Switches the default boot to a generation (applies on reboot) |
| `x gen boot` | Regenerates the per-generation boot entries |
| `x gen diff <a> <b>` | Package/services/migrations/kernel/`/etc` differences between two generations |
| `x gen verify [id]` | Compares the live system against a generation (exit 1 on drift) |
| `x gen pin <id> [--unpin]` | Protects a generation from `x gen prune` |
| `x gen prune [--keep N] [--older-than DAYS] [--dry-run]` | Removes old generations (pinned, running and default always stay) |
| `x gen restore <path> [--from ID] [--dest PATH]` | Restores a file or directory from a snapshot |
| `x gen restore --pkg <name> [--from ID] [--dest ROOT]` | Restores every file owned by a package (pacman/xpm db inside the snapshot) |
| `x gen export <id> [--out FILE] [--with-data]` | Packs a generation into a portable bundle |
| `x gen import <file> [--force]` | Imports a bundle into `$X_GEN_STATE` (`--force` replaces) |

```bash
sudo x gen new --reason manual --label "before tinkering"
x gen list
x gen status
x gen diff 0001 0003
sudo x gen rollback 0002        # boot generation 0002 on next reboot
sudo x gen restore /etc/sddm.conf --from 0002
sudo x gen restore --pkg kitty --from 0002
sudo x gen pin 0002             # never prune it
sudo x gen prune --keep 5 --dry-run
```

Restore never clobbers silently: a differing file is moved to
`<file>.bak.<ts>` before the snapshot version is copied (same contract as
`x_sync_config` in `install/helpers/sync.sh`). Paths are validated: `..`
components are rejected, and package file lists with unsafe paths are skipped
with a warning.

`/var/lib/x` and `/.snapshots` are `0700 root`: read commands (`list`,
`status`, `diff`, ...) print a clear "re-run with sudo" error instead of an
empty list when run unprivileged.

`x gen diff` compares `packages.tsv` (added/removed/updated versions),
`services.txt`, `migrations.txt`, the kernel release and the `/etc` hash.
`x gen verify` runs the same comparison against the **live** system and exits
non-zero on drift (useful as a scriptable check).

`x gen prune` deletes metadata, snapshot and boot entry of the generations
outside the keep window, but **always** keeps pinned, running and default ones;
`--older-than DAYS` additionally protects (and therefore keeps) recent
generations even when they fall outside the count window. When prune removes
the `pending` target (only possible if it was unpinned), the marker is cleared.

## Boot entries and rollback semantics

- One entry per kept generation in the boot menu (GRUB: `custom.cfg`,
  systemd-boot: `loader/entries/x-gen-<id>.conf`), plus `x.conf` mirroring the
  default one and an `x-rescue` entry (same kernel, `systemd.unit=rescue.target`).
- The **running** generation boots the live kernel from the ESP (`/vmlinuz-linux`)
  because its root mutates in place (updates keep modules in sync). **Frozen**
  generations boot their archived kernel copy (`/boot/x/gen-<id>/...`), which
  matches their frozen `/usr/lib/modules`.
- **Multi-kernel**: one entry per installed kernel, detected from
  `/usr/lib/modules/<release>/pkgbase` (`linux`, `linux-lts`, ...). The
  primary kernel (manifest `kernel.release`) keeps the plain `x-gen-<id>`
  entry id; the rest get `x-gen-<id>-<pkgbase>`. Frozen kernels are archived
  per pkgbase under `/boot/x/gen-<id>/<pkgbase>/`. Legacy single-kernel
  generations keep the old layout and pair vmlinuz/initramfs by name suffix.
- The ESP keeps the last `X_GEN_BOOT_KEEP` generations plus the default,
  running and `pinned` ones; pruning the ESP never deletes the btrfs snapshot
  or the metadata, so any generation can be re-selected later (`rollback`
  recreates its entry and kernel copy on demand).
- `x gen rollback <id>` creates a pre-rollback **safety** generation, pins the
  target, updates `current`/`pending` and rewrites the boot defaults. `/home`
  is untouched.
- `x gen status` tells apart the **running** generation (parsed from the kernel
  cmdline `rootflags=subvol=...`), the **default** (next boot) and a **pending**
  rollback.

## Automatic creation

- `x setup` (system phases) ends with a generation (`reason: setup`).
- `x update` creates a **pre-update safety** generation, runs `pacman -Syu` +
  migrations, and records a second generation (`reason: update`). If pacman
  fails, the safety generation is kept for recovery.
- During the installer, `x setup` runs with `X_GEN_SKIP=1`; the installer
  creates generation `0001` (`reason: install`, live subvol `/@`) after the
  bootloader step, with `X_GEN_LIVE_SUBVOL=/@`.

`x gen new` records state; it does not change the default boot (use
`x gen rollback` for that).

## Export and import

`x gen export <id>` packs the generation metadata (manifest, captures,
migrations, archived kernel) as `tar.zst` (or `tar.gz` without zstd).
`--with-data` adds the snapshot itself: `btrfs send` on btrfs (root) or a tree
copy with the `dir` backend. Bundles carry `BUNDLE.sha256` (hash of every
file) and `x gen import` verifies it, aborting on mismatch; bundles without
the manifest (older format) import with a warning. Restoring a `btrfs send`
stream forks the received subvolume to keep the generation writable. The
imported generation is not selected automatically — use `x gen rollback <id>`
after importing. Duplicates fail unless `--force`.

This is the portability path: moving a generation between machines or backing
it up without `btrfs send`/`receive` knowledge, and the base for the WSL
degraded mode.

## Home generations

System generations cover the root subvolume; `/home` stays out of them on
purpose. A second, user-owned layer versions the dotfiles with plain file
copies (no root, no btrfs, works on WSL):

| Command | Description |
|---------|-------------|
| `x home` / `x home list` | Lists home generations (`*` marks the current one) |
| `x home new [--label L]` | Records a copy of the included dotfiles |
| `x home status [--json]` | Current generation and drift |
| `x home diff <a> <b>` | Per-file differences (added/removed/changed) |
| `x home restore <path> [--from ID] [--dest PATH]` | Restores a dotfile (`.bak.<ts>` backup) |
| `x home prune [--keep N] [--dry-run]` | Removes old generations (current and pinned stay) |

Home generations are recorded automatically too (best effort, never blocks
provisioning): `x setup --user` records `pre-setup` before seeding/syncing
dotfiles, and `x update` records `pre-update` before migrations.
`X_HGEN_SKIP=1` disables the automatic captures.

Store: `~/.local/share/x/home-gens/<id>/` with `manifest.json`, `files/`
(copy) and `files.sha256` (per-file listing). Default include list:
`.bashrc`, `.bash_profile`, `.profile`, `.zshrc`, `.zshenv`, `.gitconfig` and
`.config`; directory names `Cache`, `CachedData`, `GPUCache` and `logs` are
skipped anywhere in the tree. Paths are validated so a restore can never
escape the home.

## Pacman transactions

The `x-scripts` package ships two pacman hooks:

| Hook | When | Effect |
|------|------|--------|
| `/etc/pacman.d/hooks/10-x-gen-pre.hook` | PreTransaction | Safety generation (`reason: pacman-pre`) |
| `/etc/pacman.d/hooks/20-x-gen-post.hook` | PostTransaction | Records the result (`reason: pacman`) |

Both call `/usr/share/x/hooks/pacman-gen.sh`, which is a no-op when there is no
current generation yet (installer/pacstrap), on non-btrfs systems, or when
`X_GEN_SKIP=1` — exactly what `x update` sets on its own `pacman -Syu` call so
it can manage its pre/post generations itself. This closes the "kernel updated
outside `x update`" gap: any manual pacman transaction is captured.

## Backends and environment

| Variable | Default | Meaning |
|----------|---------|---------|
| `X_GEN_BACKEND` | `auto` | `auto` detects btrfs; `btrfs`, `dir` (tests/degraded), `off` |
| `X_GEN_STATE` | `/var/lib/x` | State root (`@xstate` subvolume on installs) |
| `X_GEN_DIR` | `$X_GEN_STATE/generations` | Manifest store |
| `X_GEN_CURRENT` | `$X_GEN_STATE/current` | Default-boot id file |
| `X_GEN_SNAPSHOTS` | `/.snapshots` | Snapshot store (mount point) |
| `X_GEN_SUBVOL_PREFIX` | auto | In-fs path of the snapshot store (mount option `subvol=`); derived from the btrfs mount (`/@snapshots`), override only to force |
| `X_GEN_ROOT` | `/` | Tree to snapshot (tests use a fake root) |
| `X_GEN_CMDLINE` | `/proc/cmdline` | Cmdline recorded in the manifest |
| `X_GEN_BOOT` | `auto` | `on`/`off`/`auto` (auto: enabled with btrfs) |
| `X_GEN_BOOT_DIR` | `/boot` | ESP path holding kernels and boot entries |
| `X_GEN_BOOT_KEEP` | `3` | Generations kept in the boot menu |
| `X_GEN_KEEP` | `5` | Generations kept by `x gen prune` (same rules: pinned/running/default) |
| `X_GEN_LIVE_SUBVOL` | — | `root_subvol` for the live generation (installer: `/@`) |
| `X_GEN_RUNNING` | from cmdline | Running generation id (tests) |
| `X_GEN_SKIP` | `0` | `1` disables automatic generations in hooks |

On a non-btrfs system (or WSL) `xgen_supported` is false and every hook is a
no-op; the CLI reports that generations are unavailable.

## Declarative system (`system.toml`)

The declarative layer mirrors `configuration.nix`: a `system.toml` reconciled
with `x gen plan` (read-only) and `x gen apply` (executes and records a
generation with `reason: apply`):

```toml
[system]
hostname = "x"
timezone = "UTC"
locale = "en_US.UTF-8"

[packages]
explicit = ["kitty", "neovim"]

[services]
enable = ["NetworkManager"]

[theme]
name = "x-dark"
```

`x gen plan system.toml` prints the actions (set hostname/timezone/locale,
install/enable/theme) and `x gen apply` executes them:

- `[system]` — hostname, timezone and locale are set only when they differ.
- `[packages] explicit` — missing packages are installed with
  `pacman -S --needed`; installed packages outside the declaration are
  reported but **kept** unless `prune = true`.
- `[services] enable` — missing units are enabled with `systemctl enable`.
- `[theme] name` — applied through `x theme set` as the invoking user.
- `apply` supports `--dry-run` and honors `X_DRY_RUN=1`; the system actions
  need root/sudo. Removals never happen without `prune`.
- After applying, a generation is recorded (best effort) so the change can be
  diffed or rolled back like any other.

## Not implemented yet

Boot load-on-selection (rollback is a command, like
`nixos-rebuild --rollback`), SELinux/secure-boot UKIs, the disk-space limit
via btrfs qgroups, and time-based retention.

## Tests

- `test/generations.sh` — creation, manifests, list, status/drift, diff,
  restore (path and `--pkg`).
- `test/generations-boot.sh` — boot entries (systemd-boot + GRUB), running vs
  frozen kernels, ESP retention, rollback, pin/unpin, prune, pending state.
- `test/generations-multikernel.sh` — per-pkgbase entries for `linux` +
  `linux-lts`, archived kernel layout and legacy fallback.
- `test/generations-system.sh` — `system.toml` parser, plan actions, prune
  policy and dry-run apply.
- `test/pacman-hooks.sh` — wrapper guards (no current, `X_GEN_SKIP`), reasons
  and shipped hook files.
- `test/generations-export.sh` — export/import round-trip (metadata and data),
  duplicate handling and restore from an imported generation.
- `test/home-gens.sh` — home generations: capture, exclusions, drift, diff,
  restore, path-escape rejection, prune and CLI dispatch.
- `test/generations-btrfs.sh` — real loop-mounted btrfs: `sudo bash
  test/generations-btrfs.sh` (skipped without root).

The first two run in `test/smoke.sh`, without root.
