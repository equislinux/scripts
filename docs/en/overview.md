# x-scripts — overview

`x-scripts` is the **provisioning payload and CLI** of the x system. It is the
`equislinux/scripts` repo (formerly the `x` repo) and, together with the other
repos of the `equislinux` organization, implements the *reboot* initiative that
replaced the Calamares-based graphical installer with scripted provisioning
(Omarchy mechanics, own implementation and branding). See ADR-0001/ADR-0002 in
`DECISIONS.md` at the workspace root (`x-lnux`).

## Role in the organization

| Repo  | Role |
|-------|------|
| `equislinux/x` | The distro: archiso profile, ISO/WSL builds and install flow. |
| `equislinux/scripts` | **This repo**: provisioning phases, user setup, `x` CLI, migrations and themes, packaged as `x-scripts`. |
| `equislinux/xpkg` / `equislinux/xpm` | Rust packaging/package-manager tooling. |
| `equislinux/x-repo` | Package repository + portal. |

The distro (`x`) consumes this repo packaged as the `x-scripts` package; the
installer runs the root phases (`x setup`) during install and the user phase
(`x setup --user`) at first boot. The Rust tooling (`xpkg`/`xpm`) is currently
out of scope for packaging (see the packaging doc and the workspace ROADMAP).

## What this repo provides

- `install/` — phase orchestrators for system (root) and user provisioning,
  with idempotent sync helpers and the generation engines (`xgen.sh` for
  system snapshots, `xgen-home.sh` for dotfile generations).
- `bin/` — the `x` CLI (dispatcher + subcommands by naming convention),
  including `x gen ...` and `x home ...`.
- `hooks/` — pacman hook wrappers (`pacman-gen.sh`) referenced by the
  `etc/pacman.d/hooks/` drop-ins.
- `skel/`, `etc/`, `config/` — dotfile seeds for `/etc/skel`, `/etc`
  drop-ins and user configs.
- `hardware/`, `tools/` — optional modules (NVIDIA, QEMU/libvirt, node) and
  the Hyprland desktop setup tool.
- `migrations/`, `themes/` — per-user migrations and palette themes.
- `packaging/` — the `x-scripts` PKGBUILD and the offline config snapshot
  generator (`vendor-config.sh`).
- `test/` — local tests without root (`test/smoke.sh`).

## Role in the system

On an installed x system the package installs everything below
`/usr/share/x` and exposes the CLI as `/usr/bin/x` (a symlink to
`/usr/share/x/bin/x`). The payload is what turns a freshly pacstrapped Arch
into a provisioned x machine:

1. Root phases configure the system (skel, `/etc` drop-ins, hardware modules,
   services).
2. The user phase seeds the home, syncs dotfiles and provisions the desktop
   (Hyprland stack) **offline** from a vendored config snapshot.
3. `x` is the day-to-day CLI for themes, migrations and updates, plus
   **generations**: `x gen` versions the system (bootable snapshots, rollback,
   granular restore) and `x home` versions the user's dotfiles.

See `cli.md`, `provisioning.md`, `generations.md`, `hyprland.md` and
`packaging.md`.

## Configuration sources

The desktop configs are **not** maintained in this organization: the equisdots
org owns the stack (`equisdots/hyprland`, `equisdots/shell`,
`equisdots/palettes`, `equisdots/theme-sync`, `equisdots/davincix`,
`equisdots/timex`, `equisdots/login`, `equisdots/dots`, branch `main`) and the
app configs come from `xscriptor-colors/terminal` (kitty/starship) and
`xscriptor-colors/nvim`. All are used read-only; the official installer is
`equisdots/dots`. A snapshot of the whole stack is vendored into the package
for offline use. See `hyprland.md` and ADR-0005.

## Branch and status

The *reboot* deliverables of this repo are tracked on **`main`** (current
branch; a local `x/reboot` also exists for reference). The phase tracking in
`ROADMAP.md` of this repo and of the workspace root is mostly complete through
the "distro installable" stage; remaining audit items for this repo include
`x-base.packages` without a consumer, CLI polish, more unit coverage for the
helpers/phases and WSL unification. Progress and decisions live in the
`ROADMAP.md`/`DECISIONS.md` files at the workspace root (`x-lnux`).
WSL lives in its dedicated repos: equislinux/wsl and equislinux/wsl-scripts.
