# x — provisioning phases

Provisioning is split into **system (root)** and **user** phases, each an
invocable script under `install/`. The mechanics follow Omarchy (ADR-0003 in
`DECISIONS.md` at the workspace root) with an implementation of our own.

## System chain (root)

`install/system.sh` is the root entry: it chains
`config.sh` → `hardware.sh` → `login.sh` → `post-install.sh` and requires root.

| Phase | Script | What it does |
|-------|--------|--------------|
| Config | `install/config.sh` | Seeds `/etc/skel` from `skel/` (`x_copy_tree`) and applies the `/etc` overlay from `etc/`, one directory per `/etc` path (e.g. `etc/sysctl.d/` → `/etc/sysctl.d`). Currently `etc/` only documents the intended drop-ins; none are shipped yet. |
| Hardware | `install/hardware.sh` | Detects and runs self-contained modules under `hardware/` (`nvidia.sh`, `qemu.sh`). NVIDIA runs if `X_HW_NVIDIA=1` or an NVIDIA GPU is auto-detected (`X_HW_AUTO=1`); QEMU runs only if `X_HW_QEMU=1`. |
| Login | `install/login.sh` | Enables base system services (NetworkManager). Starts them only when systemd is PID 1, so it is safe inside a chroot/live image. Skips when systemd is absent. |
| Post-install | `install/post-install.sh` | Final system identity/branding. Currently a stub that logs a pending integration with the release tooling. |

Each phase requires root (`x_require_root`) and is safe to run by itself.

## User phase

`install/user.sh` provisions the current user and resolves the target via
`SUDO_USER` when elevated:

1. Runs `install/user-seed.sh` (as the target user via `runuser` when running
   as root):
   - seeds the home from the skeleton (`x_seed_home`, only what is missing),
   - syncs `config/` into `~/.config` (`x_sync_config`, with backups).
2. If `X_NODE=1`, installs the node toolchain (`tools/node.sh`, fnm).
3. If `X_HYPRLAND` (default `1`), provisions the Hyprland/equisdots desktop
   (`tools/hyprland-install.sh`, offline from the packaged equisdots snapshot;
   online fallback via `equisdots/dots`).

```bash
# as the target user (finalize)
bash install/user.sh
# force the node toolchain
X_NODE=1 bash install/user.sh
# skip the Hyprland desktop
X_HYPRLAND=0 bash install/user.sh
```

## Helpers

`install/helpers/common.sh` — logging and privilege helpers, exports `X_ROOT`:

- `log`/`warn`/`error` (colored prefix; `error` exits 1).
- `has_cmd` — command existence check.
- `x_require_root` — aborts unless running as root.
- `x_target_user`/`x_target_home` — resolve the provisioning target
  (`SUDO_USER` if set, otherwise the current user).
- `run_privileged`/`run_as_user` — elevate or switch user via `sudo`/`runuser`;
  honor `X_DRY_RUN=1` (print instead of execute).

`install/helpers/sync.sh` — tree sync without rsync:

- `x_copy_tree <src> <dst>` — overwrites: copies `src` contents into `dst`
  (first-install seeds such as `/etc/skel` and the `/etc` overlay).
- `x_seed_home <skel> <home>` — creates only what is missing; never overwrites
  user files (no backup, nothing is touched).
- `x_sync_config <src> <dst>` — mirrors a dotfile tree into `dst`; a file that
  differs is moved to `<file>.bak.<ts>` before the new version is copied.
  Idempotent: unchanged files are left alone and no extra backup is made.

`install/helpers/xgen.sh` — generation engine (btrfs snapshot + manifest):

- `xgen_new` — creates a generation (snapshot, manifest, package/service
  captures, kernel archive).
- `xgen_maybe_new` — hook used by `x setup` (`install/system.sh`) and
  `x update`; no-op when generations are unsupported or `X_GEN_SKIP=1`.
- `xgen_list`/`xgen_status`/`xgen_restore` — inspect generations and restore
  files/directories. Full contract in `generations.md`.

## Idempotency model

- Phases and helpers are designed to be re-run safely: seeds do not clobber
  user data, config sync leaves backups, service enables and package installs
  are `--needed`/guarded.
- Per-user migrations add the final layer of idempotent change (see below).
- `test/smoke.sh` verifies the helpers without root: overwrite protection of
  `x_seed_home`, backup-and-apply plus second-pass idempotency of
  `x_sync_config`, syntax of every bash file, the Hyprland tool dry-run paths
  and the CLI dispatch/theme/migration behavior.

## Migrations (per user)

Migrations are idempotent bash scripts `migrations/<timestamp>-<name>.sh`,
applied by `x migrate` and by `x update`. A successful run is marked in
`~/.local/state/x/migrations/<name>`; failing migrations are reported and not
marked. They must be network-free and safe to repeat. See `migrations/README.md`.

## Environment toggles

See the full table in `cli.md`. The ones that matter per phase:

- Config/seed: `X_SKEL_DIR`, `X_CONFIG_SEED`, `X_TS`.
- Hardware: `X_HW_AUTO`, `X_HW_NVIDIA`, `X_HW_QEMU`.
- User: `X_NODE`, `X_HYPRLAND`.
- Global: `X_DRY_RUN`.

## Entry points

| Action | Command |
|--------|---------|
| System (root) during install | `x setup` / `sudo bash install/system.sh` |
| User finalize | `x setup --user` / `bash install/user.sh` |
| Hardware only | `x hardware` / `sudo bash install/hardware.sh` |
| Migrations | `x migrate` |
| Update + migrations | `x update` |
