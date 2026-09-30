# x — CLI

`x` is the provisioning CLI of the x system (ADR-0003 in `DECISIONS.md` at the
workspace root). Its implementation lives in `bin/` of this repo and is
installed as `/usr/bin/x` (symlink to `/usr/share/x/bin/x`) by the `x-scripts`
package. When working from a checkout it can be invoked as `bash bin/x`.

Dispatch is by **naming convention plus header-comment metadata**, with no
central registry: adding a command means adding one file in `bin/`.

## Usage

```bash
x <command> [arguments]
x help          # or: x list, x -h, x --help
```

`x` with no arguments prints the help. The dispatcher exports `X_BIN` (the
`bin/` directory) and `X_CLI=1` so subcommands know they run through the CLI.

## Commands

Summaries are the `x:summary` headers of each file (shown by `x help`).

| Command | Description |
|---------|-------------|
| `x setup` | Provisions the system as root (`install/system.sh`; config, hardware, login, post-install). Elevates with sudo when needed. |
| `x setup --user` | Provisions the current user (`install/user.sh`; home seed + config sync + optional node and Hyprland). |
| `x theme list` | Lists available themes under `themes/`. |
| `x theme set <name>` | Applies a theme palette: copies `themes/<name>/colors` to `~/.config/x/theme.conf` (backing up the previous one) and records the active theme in `~/.local/state/x/theme`. |
| `x migrate` | Runs the user's pending idempotent migrations. |
| `x update` | `pacman -Syu` (privileged) followed by the user's migrations. |
| `x hardware` | Runs the hardware phase (detection + modules). Requires root. |
| `x info` | Shows version, repo, user and environment info. |
| `x gen` / `x gen list` | Lists the system generations (`*` marks the current one). See `generations.md`. |
| `x gen new` | Creates a generation: btrfs snapshot + manifest (`--reason`, `--label`). |
| `x gen status` | Shows the running vs default generation, pending rollback and `/etc` drift. |
| `x gen rollback <id>` | Switches the default boot to a generation (applies on reboot; `--no-safety`). |
| `x gen boot` | Regenerates the per-generation boot entries. |
| `x gen diff` | Shows package/service/kernel/`/etc` differences between two generations. |
| `x gen pin <id>` | Protects a generation from pruning (`--unpin`). |
| `x gen prune` | Removes old generations, keeping pinned/running/default (`--keep N`, `--dry-run`). |
| `x gen restore <path>` | Restores a file/directory from a generation (`--from ID`, `--dest PATH`). |
| `x gen restore --pkg <name>` | Restores every file owned by a package. |

Root-only commands enforce root inside the dispatcher (see metadata below) and
print an error if run as a non-root user.

### Aliases

Aliases are defined with `x:aliases` metadata and let a single token map to a
command file:

| Alias | Resolves to |
|-------|-------------|
| `theme`, `themes` | `x-theme-list.sh` (so `x theme` lists themes) |
| `hardware`, `hw` | `x-hardware.sh` |
| `info`, `status`, `doctor` | `x-info.sh` |
| `migrate`, `migrations` | `x-migrate.sh` |
| `update`, `upgrade`, `up` | `x-update.sh` |
| `gen`, `generation`, `generations` | `x-gen-list.sh` (so `x gen` lists generations) |

## Dispatch mechanics

Resolution tries the longest file-name prefix first, then falls back to the
first argument matched against `x:aliases`:

- `x theme set nord` → looks up `x-theme.sh`, then `x-theme-set.sh`; the latter
  exists, so `nord` is passed to `x-theme-set.sh`.
- `x theme` (single token) → no `x-theme.sh`; the alias `theme` on
  `x-theme-list.sh` matches.
- `x nonexistent` → error with help (exit 1).

The file must be **executable** to be resolved. The dispatcher only consumes
`x:summary`, `x:aliases` and `x:root`; remaining arguments are forwarded to the
subcommand, which validates its own arguments (`x setup --help`,
`x theme set` with the wrong arity errors out, etc.).

## Adding a command

Create `bin/x-<group>-<verb>.sh` as an executable script with metadata in the
header:

```bash
#!/usr/bin/env bash
# x:summary=one line shown by x help
# x:aliases=alias1 alias2      # optional
# x:root=true                  # optional: require root to run
set -euo pipefail

X_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# ...
```

- `x:summary` — one-line description, shown in `x help` and `x list`.
- `x:aliases` — optional space-separated aliases resolved against the first
  token.
- `x:root=true` — makes the dispatcher refuse to run as a non-root user.
- `x:args` — optional; informational only, not parsed by the dispatcher. Use it
  to document the expected arguments in the header.

There is no central registry and no registration step.

## Environment variables

| Variable | Default | Meaning |
|----------|---------|---------|
| `X_BIN` | `<repo>/bin` | Directory of the CLI (exported by the dispatcher). |
| `X_CLI` | — | `1` when running through the dispatcher (exported by it). |
| `X_ROOT` | `<repo>` | Repository/payload root (exported by `install/helpers/common.sh`). |
| `X_STATE_DIR` | `~/.local/state/x` | User state directory (theme, migration markers). |
| `X_THEMES_DIR` | `<repo>/themes` | Theme store. |
| `X_THEME_CONF` | `~/.config/x/theme.conf` | Output file written by `x theme set`. |
| `X_MIGRATIONS_DIR` | `<repo>/migrations` | Migration scripts directory. |
| `X_SKEL_DIR` | `/etc/skel` | Skeleton seeded into the home. |
| `X_CONFIG_SEED` | `<repo>/config` | Dotfile tree synced to `~/.config`. |
| `X_TS` | current timestamp | Timestamp used for `.bak.<ts>` backups. |
| `X_DRY_RUN` | `0` | `1` makes privileged/user helpers log instead of running. |
| `X_NODE` | `0` | `1` installs the node toolchain (fnm) in the user phase. |
| `X_HYPRLAND` | `1` | `0` skips the Hyprland setup in the user phase. |
| `X_HW_AUTO` | `1` | `0` disables hardware auto-detection in the hardware phase. |
| `X_HW_NVIDIA` | `0` | `1` forces the NVIDIA module. |
| `X_HW_QEMU` | `0` | `1` enables the QEMU/libvirt module. |
| `X_GEN_BACKEND` | `auto` | `auto`, `btrfs`, `dir` (tests/degraded) or `off`. See `generations.md`. |
| `X_GEN_STATE` / `X_GEN_DIR` / `X_GEN_CURRENT` | `/var/lib/x/...` | Generation state, manifests and current id. |
| `X_GEN_SNAPSHOTS` | `/.snapshots` | Snapshot store (mount point). |
| `X_GEN_SUBVOL_PREFIX` | `$X_GEN_SNAPSHOTS` | In-fs path used by mount/boot options. |
| `X_GEN_ROOT` | `/` | Tree captured by a generation (tests use a fake root). |
| `X_GEN_CMDLINE` | `/proc/cmdline` | Kernel cmdline recorded in the manifest. |
| `X_GEN_BOOT` / `X_GEN_BOOT_DIR` / `X_GEN_BOOT_KEEP` | `auto` / `/boot` / `3` | Boot-entry management and retention. |
| `X_GEN_KEEP` | `5` | Generation retention for `x gen prune`. |
| `X_GEN_LIVE_SUBVOL` | — | `root_subvol` of the live generation (installer uses `/@`). |
| `X_GEN_RUNNING` | from cmdline | Running generation id (tests). |
| `X_GEN_SKIP` | `0` | `1` disables automatic generations in the setup/update hooks. |

Hyprland-setup specific variables (`X_HYPR_*`) are documented in
`hyprland.md`.

## State

- `~/.local/state/x/` — user state: `theme` (active theme) and
  `migrations/<name>` (applied-migration markers).
- `~/.config/x/` — generated user config, e.g. `theme.conf`.
- `/var/lib/x/` — system state: `generations/<id>/` (manifests and captures)
  and `current` (current generation id); snapshots live in `/.snapshots/`.

The env overrides above let tests and development redirect every state/output
path away from the real home (see `test/smoke.sh`).

## x setup --online

Runs the original equisdots installer (`equisdots/dots setup`) from a
temporary clone, then cleans up. Use it when already logged in and the offline
packaged setup is not enough. It asks for the sudo password when the upstream
script needs it.

    x setup --user --online
