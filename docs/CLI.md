# x — CLI (overview)

`x` is the provisioning CLI of the x system (ADR-0003). Its implementation
lives in `bin/` and it is installed as `/usr/bin/x` (symlink to
`/usr/share/x/bin/x`) by the `x-scripts` package.

Full reference: **[docs/en/cli.md](en/cli.md)** (English) and
**[docs/es/cli.md](es/cli.md)** (Spanish) — dispatcher metadata contract, every
command argument and all environment variables.

## Command groups

| Group | Commands |
|-------|----------|
| Provisioning | `x setup [--user] [--online]`, `x hardware`, `x migrate`, `x update`, `x theme list/set`, `x info` |
| AI agents | `x agent install [--bundle x\|dev\|full]`, `x agent status`, `x agent remove` |
| System generations | `x gen new`, `list`, `status [--json]`, `boot`, `rollback`, `diff`, `verify`, `pin`, `prune`, `restore`, `export`, `import` |
| Home generations | `x home new`, `list`, `status [--json]`, `diff`, `restore`, `prune` |
| Help | `x help` |

System generations are documented in **[generations.md](en/generations.md)**
(English) and **[generations.md](es/generations.md)** (Spanish): snapshots,
boot entries, rollback, granular restore, pacman hooks, home generations,
export/import.

## Adding a command

Create `bin/x-<group>-<verb>.sh` (executable) with metadata in the header
comments (`x:summary`, optional `x:aliases`/`x:args`, `x:root=true`). There is
no central registry: adding a command means adding one file. See
`docs/en/cli.md`.

## State

- `~/.local/state/x/` — user state: active theme and migration markers.
- `~/.local/share/x/home-gens/` — home generations (dotfiles).
- `~/.config/x/` — generated user config (e.g. `theme.conf`).
- `/var/lib/x/` — system generation metadata (`@xstate` subvolume on installs).
- `/.snapshots/` — system generation snapshots.

## x setup --online

Runs the upstream equisdots installer (`equisdots/dots setup`) from a
temporary clone, then cleans up. Use it when already logged in and the offline
packaged setup is not enough. It asks for the sudo password when the upstream
script needs it.

    x setup --user --online
