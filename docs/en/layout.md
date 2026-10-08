# x — layout reference

Provisioning repo of the x system (scripts, no graphical installer;
ADR-0001/ADR-0003 in `DECISIONS.md` at the workspace root).

## Tree

| Path | Role |
|------|------|
| `bin/x` | The `x` CLI dispatcher (no args/`help`/`list`/`-h`/`--help` print help). |
| `bin/x-*.sh` | One file per subcommand, resolved by naming + header metadata. See `cli.md`. |
| `install/` | Provisioning orchestrators per phase. See `provisioning.md`. |
| `install/system.sh` | Root entry: chains `config.sh` → `hardware.sh` → `login.sh` → `post-install.sh`. |
| `install/config.sh` | Root: seeds `/etc/skel` from `skel/` and applies the `/etc` overlay from `etc/`. |
| `install/hardware.sh` | Root: detects/runs modules under `hardware/`. |
| `install/login.sh` | Root: enables base services (NetworkManager). |
| `install/post-install.sh` | Root: final branding; currently a stub. |
| `install/user.sh` | User provisioning (delegates to `user-seed.sh` via `runuser` when run as root; then optional node + Hyprland). |
| `install/user-seed.sh` | Seeds the home from the skeleton and syncs `config/` to `~/.config`. |
| `install/helpers/common.sh` | Bash library: log/warn/error, privilege and target-user helpers, exports `X_ROOT`. |
| `install/helpers/sync.sh` | Idempotent tree sync: `x_copy_tree`, `x_seed_home`, `x_sync_config`. |
| `install/x-base.packages` | Base package list readable by the builder (one per line); no consumer wired yet. |
| `skel/` | `/etc/skel` seed for new users (currently a `.bashrc`). |
| `etc/` | `/etc` drop-ins, one directory per path (`sysctl.d`, `tmpfiles.d`, `sudoers.d` documented in its README); no drop-ins shipped yet. |
| `config/` | User dotfiles synced to `~/.config`. `config/hypr/` is only a documentation entry point + default wallpaper; the real desktop config ships offline in the package (`/usr/share/x/config/equisdots`), ADR-0005. |
| `migrations/` | Per-user idempotent migrations (`<timestamp>-<name>.sh`), applied by `x migrate` / `x update`. |
| `themes/` | Theme store: `themes/<name>/colors` (key=hex), applied by `x theme set`. |
| `hardware/` | Self-contained root modules: `nvidia.sh`, `qemu.sh`. |
| `tools/` | User-level tools: `node.sh` (fnm, gated by `X_NODE`), `hyprland-install.sh` (offline equisdots desktop deployment, gated by `X_HYPRLAND`). |
| `packaging/` | `PKGBUILD` for `x-scripts` + `vendor-config.sh` offline snapshot generator + `.vendor/` output (git-ignored). |
| `test/` | Local tests without root: `test/smoke.sh` (syntax + helpers + CLI + Hyprland dry-runs). |
| `docs/` | This documentation (`CLI.md`, `LAYOUT.md`, `en/`, `es/`). |

## Mechanics

- Root and user phases are separate; each phase is an invocable, idempotent
  script.
- Home layers: seed `/etc/skel` (install, `config.sh`) → seed home from skel
  only-what-is-missing (`user-seed.sh`) → sync `config/` into `~/.config` with
  `.bak.<ts>` backups.
- Files modified by the user are never silently overwritten: seeds skip them,
  config sync backs them up first.
- The desktop config is installed cleanly from the offline vendored snapshot,
  not maintained here (see `hyprland.md`, ADR-0005).

## Usage

```bash
# CLI (from the repo or installed as /usr/bin/x)
bash bin/x help
bash bin/x setup            # system (root)
bash bin/x setup --user     # current user
bash bin/x theme set x-dark
bash bin/x migrate
bash bin/x update

# Direct per phase (equivalent)
sudo bash install/system.sh
X_NODE=1 X_HYPRLAND=1 bash install/user.sh
sudo X_HW_NVIDIA=1 X_HW_QEMU=1 bash install/hardware.sh

# Local tests (no root)
bash test/smoke.sh
```

## See also

- `overview.md` — role of the repo in the org and the system.
- `cli.md` — commands, adding commands, env vars.
- `provisioning.md` — phases, helpers, idempotency.
- `hyprland.md` — the offline desktop setup tool.
- `packaging.md` — building `x-scripts` and the vendored snapshot.
WSL lives in its dedicated repos: equislinux/wsl and equislinux/wsl-scripts.
