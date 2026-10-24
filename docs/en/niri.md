# x — niri/equisdots setup tool

`tools/niri-install.sh` is the non-interactive niri/equisdots desktop setup for
X Linux. It runs as the **target user** (never as root) and delegates the stack
to the official [`equisdots/niri-meta`](https://github.com/equisdots/niri-meta)
meta installer (`dotsniri`) in online mode.

## What it does

1. Clones or updates `equisdots/niri-meta` in the per-user cache
   (`$XDG_CACHE_HOME/x/niri-meta`, ref `main` by default).
2. Runs `dotsniri setup -y`: installs the niri stack packages (niri,
   xwayland-satellite, quickshell, portals, session tools, fonts, ...), clones
   the owned/shared equisdots repos, deploys the shared Quickshell shell, niri
   overlays, plugins, app configs, user units and the niri session entry.
3. Selects niri as the default desktop (`dotsniri desktop niri`).
4. Installs the X/equisdots static SDDM login theme (from the shared
   `equisdots/login` clone) and enables `sddm`.

The equisdots repositories are read-only inputs; nothing under the equisdots
org is modified. The shared data root remains `~/.config/hypr`; the niri
compositor config lives in `~/.config/niri`.

## Environment

| Variable | Default | Meaning |
|---|---|---|
| `X_NIRI_REF` | `main` | niri-meta branch/ref to clone/update. |
| `X_NIRI_CACHE_DIR` | `$XDG_CACHE_HOME/x` | clone cache. |
| `X_NIRI_DRYRUN` | `0` | print the plan without touching the system. |
| `X_NIRI_SKIP_LOGIN` | `0` | do not install the SDDM theme / enable sddm. |

The text installer creates a temporary `%wheel NOPASSWD: ALL` sudoers file for
the duration of the setup, because `dotsniri` installs packages, PAM, the
session entry and the login theme with sudo.

## Validation

```bash
bash -n tools/niri-install.sh
X_NIRI_DRYRUN=1 tools/niri-install.sh
niri validate -c ~/.config/niri/config.kdl
dotsniri doctor
```
