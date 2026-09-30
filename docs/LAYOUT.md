# x — scripts (layout)

**Provisioning** repo of the x system (via scripts, no graphical installer;
see ADR-0001/ADR-0003 in `DECISIONS.md` at the workspace root).

## Tree

| Path | Role |
|------|------|
| `bin/` | `x` CLI (dispatcher + `x-*.sh` subcommands by convention). See `docs/CLI.md`. |
| `install/` | Provisioning orchestrators per phase. |
| `install/helpers/` | Bash libraries: `common.sh` (log/privileges/root), `sync.sh` (idempotent tree sync) and `xgen.sh` (generations: btrfs snapshot + manifest). |
| `install/system.sh` | Root entry: chains `config.sh` → `hardware.sh` → `login.sh` → `post-install.sh`. |
| `install/config.sh` | Root: seeds `/etc/skel` from `skel/` and applies the `/etc` overlay from `etc/`. |
| `install/hardware.sh` | Root: detects/runs the modules under `hardware/`. |
| `install/login.sh` | Root: base services (NetworkManager, ...). |
| `install/post-install.sh` | Root: final branding (will integrate with `x-release`). |
| `install/user.sh` | User provisioning (delegates to `user-seed.sh` when run as root). |
| `install/user-seed.sh` | Seeds the home: `x_seed_home` from `/etc/skel` and `x_sync_config` from `config/` to `~/.config`. |
| `install/x-base.packages` | Base package list readable by the builder (one per line). |
| `skel/` | `/etc/skel` seed for new users. |
| `etc/` | `/etc` drop-ins (sysctl.d, tmpfiles.d, ...). One dir per path. |
| `config/` | User dotfiles synced to `~/.config` (with backup). `hypr/` is only a documentation entry point + default wallpaper; the desktop config ships offline in the package (`/usr/share/x/config/equisdots`, equisdots org) via `tools/hyprland-install.sh` (ADR-0005). |
| `migrations/` | Per-user idempotent migrations (`<timestamp>-<name>.sh`), applied by `x migrate`. |
| `themes/` | Theme store: `themes/<name>/colors` (key=hex), applied by `x theme set`. |
| `hardware/` | Self-contained modules: `nvidia.sh`, `qemu.sh`. |
| `tools/` | Optional per-user toolchains/installers: `node.sh` (fnm), `hyprland-install.sh` (equisdots desktop from the offline snapshot; online fallback via `equisdots/dots`). |
| `test/` | Local tests without root. |

## Mechanics (ADR-0003)

- Root and user phases are separate; each phase is an invocable script.
- Home layers: seed `/etc/skel` (install) → `x_seed_home` (only what is
  missing) → `x_sync_config` with `.bak.<ts>` backup.
- All scripts are idempotent; files modified by the user are not overwritten
  without leaving a backup.
- Generations (`x gen`): `x setup` and `x update` create immutable snapshots
  with a manifest; `x gen restore` recovers paths from them. See
  `docs/en/generations.md` (or `docs/es/generations.md`).

## Usage

- As root (during the install/ISO or on an already installed system):
  `bash install/system.sh`.
- As user (finalize): `X_NODE=1 bash install/user.sh`.
- Optional extras: `X_HW_NVIDIA=1 X_HW_QEMU=1` to force hardware modules.
WSL lives in its dedicated repos: xlnux/wsl and xlnux/wsl-scripts.
