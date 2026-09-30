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
| `x gen status` | Shows backend, running vs default, pending rollback and `/etc` drift |
| `x gen rollback <id> [--no-safety]` | Switches the default boot to a generation (applies on reboot) |
| `x gen boot` | Regenerates the per-generation boot entries |
| `x gen diff <a> <b>` | Package/services/migrations/kernel/`/etc` differences between two generations |
| `x gen verify [id]` | Compares the live system against a generation (exit 1 on drift) |
| `x gen pin <id> [--unpin]` | Protects a generation from `x gen prune` |
| `x gen prune [--keep N] [--older-than DAYS] [--dry-run]` | Removes old generations (pinned, running and default always stay) |
| `x gen restore <path> [--from ID] [--dest PATH]` | Restores a file or directory from a snapshot |
| `x gen restore --pkg <name> [--from ID] [--dest ROOT]` | Restores every file owned by a package (pacman/xpm db inside the snapshot) |

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
`x_sync_config` in `install/helpers/sync.sh`).

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
  default one.
- The **running** generation boots the live kernel from the ESP (`/vmlinuz-linux`)
  because its root mutates in place (updates keep modules in sync). **Frozen**
  generations boot their archived kernel copy (`/boot/x/gen-<id>/...`), which
  matches their frozen `/usr/lib/modules`.
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
| `X_GEN_SUBVOL_PREFIX` | `$X_GEN_SNAPSHOTS` | In-fs path of the snapshot store (mount option `subvol=`) |
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

## Not implemented yet

Per-user home generations, pacman/xpm transaction hooks, the declarative
`system.toml` + `x gen apply`, the WSL degraded mode,
generation export/import (`btrfs send/receive`), boot-load-on-selection
(rollback is a command, like `nixos-rebuild --rollback`) and retention by time
instead of count.

## Tests

- `test/generations.sh` — creation, manifests, list, status/drift, diff,
  restore (path and `--pkg`).
- `test/generations-boot.sh` — boot entries (systemd-boot + GRUB), running vs
  frozen kernels, ESP retention, rollback, pin/unpin, prune, pending state.
- `test/pacman-hooks.sh` — wrapper guards (no current, `X_GEN_SKIP`), reasons
  and shipped hook files.
- `test/generations-btrfs.sh` — real loop-mounted btrfs: `sudo bash
  test/generations-btrfs.sh` (skipped without root).

The first two run in `test/smoke.sh`, without root.
