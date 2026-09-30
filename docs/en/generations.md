# x — generations

Generations are the system-versioning layer of X Linux: each relevant change
produces an **immutable snapshot** of the root tree plus a **manifest** with
the system state. NixOS-like in behavior (numbered generations, rollback,
granular restore) without a content-addressed store: the snapshots are btrfs
subvolumes and the manifest records provenance.

Installed systems created by the text installer already use the btrfs layout
(`@`, `@home`, `@snapshots`); the first generation is created at the end of the
installation.

## What a generation contains

| Path | Content |
|------|---------|
| `/.snapshots/<id>` | Read-only snapshot of the root subvolume (`@`) |
| `/var/lib/x/generations/<id>/manifest.json` | Provenance: reason, parent, tooling, kernel, cmdline, hashes |
| `/var/lib/x/generations/<id>/packages.tsv` | `pacman -Q` capture (or `xpm query` when xpm is the only manager) |
| `/var/lib/x/generations/<id>/services.txt` | Enabled systemd units |
| `/var/lib/x/generations/<id>/boot/` | Archived kernel/initramfs of the generation |
| `/var/lib/x/generations/<id>/snapshot.uuid` | btrfs UUID of the snapshot |
| `/var/lib/x/current` | Id of the current generation |

The manifest hashes `/etc` (`configs.etc_sha256`), so `x gen status` can report
drift: files changed since the generation was created.

## Layout

```
@            -> /            (writable root; the live generation)
@home        -> /home        (not snapshotted per generation yet)
@snapshots   -> /.snapshots  (read-only snapshots, mode 0700)
```

`/tmp` is tmpfs (written by the installer to `/etc/fstab`) so snapshots do not
capture transient files.

## Commands

| Command | Description |
|---------|-------------|
| `x gen` / `x gen list` | Lists generations; `*` marks the current one |
| `x gen new [--reason R] [--label L]` | Creates a generation (snapshot + manifest) |
| `x gen status` | Shows the current generation and `/etc` drift |
| `x gen restore <path> [--from ID] [--dest PATH]` | Restores a file or directory from a snapshot |

```bash
sudo x gen new --reason manual --label "before tinkering"
x gen list
x gen status
sudo x gen restore /etc/sddm.conf --from 0002
sudo x gen restore /etc/NetworkManager --from 0001 --dest /tmp/nm
```

Restore never clobbers silently: a differing file is moved to
`<file>.bak.<ts>` before the snapshot version is copied (same contract as
`x_sync_config` in `install/helpers/sync.sh`).

## Automatic creation

- `x setup` (system phases) ends with a generation (`reason: setup`).
- `x update` creates a **pre-update safety** generation, runs
  `pacman -Syu` + migrations, and creates a second generation (`reason:
  update`). If pacman fails, the safety generation is kept for recovery.
- During the installer, `x setup` runs with `X_GEN_SKIP=1`; the installer
  creates generation `0001` (`reason: install`) after the bootloader step.

## Backends and environment

| Variable | Default | Meaning |
|----------|---------|---------|
| `X_GEN_BACKEND` | `auto` | `auto` detects btrfs; `btrfs`, `dir` (tests/degraded), `off` |
| `X_GEN_STATE` | `/var/lib/x` | State root |
| `X_GEN_DIR` | `$X_GEN_STATE/generations` | Manifest store |
| `X_GEN_CURRENT` | `$X_GEN_STATE/current` | Current-id file |
| `X_GEN_SNAPSHOTS` | `/.snapshots` | Snapshot store |
| `X_GEN_ROOT` | `/` | Tree to snapshot (tests use a fake root) |
| `X_GEN_CMDLINE` | `/proc/cmdline` | Cmdline recorded in the manifest |
| `X_GEN_SKIP` | `0` | `1` disables automatic generations in hooks |

On a non-btrfs system (or WSL) `xgen_supported` is false and every hook is a
no-op; the CLI reports that generations are unavailable.

## Not implemented yet

This is phase F0/F1 of the design (see the workspace roadmap): boot entries per
generation and `x gen rollback`, `x gen diff`, `x gen prune/pin`, per-user home
generations, package-level restore (`--pkg`) and the WSL degraded mode.

## Tests

`test/generations.sh` (run by `test/smoke.sh`) exercises creation, manifests,
list, status/drift and restore with the `dir` backend, without root.
