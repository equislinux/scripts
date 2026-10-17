# x — Hyprland/equisdots setup tool

`tools/hyprland-install.sh` is our own **non-interactive** desktop setup for x.
It provisions the equisdots desktop stack for the **target user** (it refuses
to run as root; root operations go through sudo). It is invoked by the user
phase (`install/user.sh`, gated by `X_HYPRLAND`, default on) and can be run by
hand.

Design goals (ADR-0005):

- The desktop configs ship **offline** inside the `x-scripts` package
  (equisdots snapshot) and are deployed without cloning anything at setup time
  on an installed system.
- The equisdots org is the source of truth and the official installer is
  [`equisdots/dots`](https://github.com/equisdots/dots); its repos are used
  **read-only**, never integrated or modified. The online fallback delegates
  the payload placement to `dots install`.
- **NVIDIA is owned by the X hardware phase** (`hardware/nvidia.sh`). The tool
  never installs drivers by itself; only when an NVIDIA GPU is present and no
  driver was installed does it fall back to the upstream equisdots NVIDIA
  setup (`hyprland/install.sh --nvidia-only`), and when the driver already
  exists it only completes the `envycontrol`/sudoers piece used by
  `gpu-mode.sh`. The full `dots system` phase never runs here.

## Sources of truth (external, branch `main`)

| Repo | Content vendored |
|------|------------------|
| `equisdots/hyprland` | Lua config (`hyprland.lua`, modules, `hypridle.conf`), `rofi`, `dunst`, `cava`, `pam.d/quickshell` and `scripts` (helpers dropped into `~/.config/hypr/scripts`). |
| `equisdots/shell` | Quickshell UI (bar, popups, panels, lock) → `~/.config/hypr/scripts/quickshell`. |
| `equisdots/palettes` | Palette JSON set + schema → `.../quickshell/dock/palettes`. |
| `equisdots/theme-sync` | Cross-app theming engine (`~/.local/bin/theme-sync`). |
| `equisdots/davincix` | Wallpaper engine kernel (`~/.local/bin/davincix`). |
| `equisdots/timex` | Time/weather engine + UI (`~/.local/bin/timex`, `.../quickshell/ui/timex`). |
| `equisdots/login` | Static minimal SDDM greeter (one-time system install). |
| `equisdots/dots` | Meta installer/updater + standalone `install-xwww.sh`. |
| `xscriptor-colors/terminal` | kitty (`emulators/kitty`) and starship (`prompts/starship`). |
| `xscriptor-colors/nvim` | the whole nvim config tree. |

The vendored snapshot lives at `/usr/share/x/config` on an installed system
(produced by `packaging/vendor-config.sh`; see `packaging.md`). `config/hypr/`
in this repo is only a documentation entry point plus the default wallpaper;
it is not the desktop config itself.

## How the tool works

1. **Resolve the payload.**
   - Offline (default on an installed system): uses the equisdots snapshot at
     `/usr/share/x/config/equisdots`; nothing is cloned.
   - Override: `X_HYPR_SOURCE=<snapshot root>` (tests/dev; the caller's tree is
     never mutated).
   - Fallback (snapshot absent, e.g. a dev checkout): clones
     `equisdots/dots` (`--depth 1`, branch `X_HYPR_REF`) and runs
     `dots install`, the official placement. `X_HYPR_OFFLINE=1` forbids the
     clone.
2. **Packages.** Drops official `quickshell`/`swayosd` first (the config
   targets the `-git` versions), then installs an official list (Hyprland
   stack, xdg portals, qt5/qt6 wayland, sddm, rofi + rofi-emoji, kitty,
   starship, dunst, satty, gpu-screen-recorder, pipewire, network, fonts,
   ...) with `pacman -S --needed`, and AUR packages (`quickshell-git`,
   `swayosd-git`, `bibata-cursor-theme`, `mpvpaper`,
   `networkmanager-dmenu-git`) via an existing `yay`/`paru`, bootstrapping
   `yay` if none is found. Failures are warned, not fatal.
3. **User payload.**
   - Offline: stages the snapshot into `~/.local/share/equisdots` and mirrors
     `dots install` exactly: hyprland config → `~/.config/hypr`, rofi/dunst/
     cava → `~/.config`, scripts → `~/.config/hypr/scripts` (legacy
     pre-equisdots artifacts purged), shell → `.../quickshell`, palettes →
     `.../quickshell/dock/palettes`, `~/.local/bin` wrappers
     (`dots`, `theme-sync`, `davincix`, `timex`), timex UI, `settings.json`
     seeding/migration with `jq`, and the monthly dotfiles timer.
   - Online: `dots install` does that placement.
4. **App configs (offline).** kitty, starship (`~/.config/equisdots/starship`)
   and nvim from the snapshot, then the `theme-sync` engine regenerates the
   palette artifacts (kitty/starship/nvim/rofi/cava/qt/gtk/...).
5. **xwww.** Installs the wallpaper daemon (davincix needs it) with the
   equisdots standalone installer (checksum-verified release, source
   fallback) when `xwww-daemon` is missing.
6. **Font.** Installs Hack Nerd Font for the user (downloaded) and copies it to
   `/usr/share/fonts`.
7. **Login + PAM + services.** Installs the static SDDM theme
   (`equisdots/login`), writes `/etc/pam.d/quickshell`, and enables
   NetworkManager, SDDM, power-profiles-daemon, swayosd-libinput-backend,
   bluetooth and the user pipewire services.
8. **NVIDIA.** If a GPU is present and no driver is installed, runs the
   upstream `hyprland/install.sh --nvidia-only -y`. If the driver is already
   there, it only completes the equisdots GPU-mode feature: installs
   `envycontrol` (AUR, when missing) with the passwordless
   `/etc/sudoers.d/99-gpu-mode` rule used by `gpu-mode.sh`.
9. Writes `~/.local/state/equisdots-version`, ensures `~/.local/bin` is in the
   shell PATH and prints the completion message.

## User-level commands and recovery

`dots`, `theme-sync`, `davincix` and `timex` are wrapper scripts in
`~/.local/bin` that point at the repos under `~/.local/share/equisdots`. The
tool adds that directory to the PATH of every existing shell rc (and creates
`~/.profile` when none exists); `skel/.bashrc` already exports it, so TTY
logins (through `~/.bash_profile`) can always reach them. Every deploy step is
best-effort, so the wrappers are written even if a later step fails.

If the desktop does not start, the stack can be repaired from a TTY:

```bash
x setup --user     # re-deploy the configs/payload (offline snapshot)
dots install       # clone/update the payload
dots doctor        # check dependencies, clones and installed paths
```

## Deployment modes

- **Offline (default on an installed system):** uses the equisdots snapshot
  shipped in `x-scripts` (`/usr/share/x/config`).
- **Online (`X_HYPR_ONLINE=1`):** ignores the snapshot, clones `equisdots/dots`
  (ref via `X_HYPR_REF`), runs its official `dots install` (repos, plugins and
  the settings merge) and fetches the app configs (kitty/starship/nvim) from
  `xscriptor-colors`. If it fails, the installer falls back to the snapshot.

The installer picks the mode with `hyprland=yes` (snapshot) or
`hyprland=online` (latest from GitHub; optional `hyprland_ref` in the JSON).

## Flags / environment

| Variable | Default | Meaning |
|----------|---------|---------|
| `X_HYPR_CONFIG` | `/usr/share/x/config` | Packaged (offline) config tree. |
| `X_HYPR_SOURCE` | — | Snapshot root override (`$X_HYPR_SOURCE/equisdots`); read-only. |
| `X_HYPR_REF` | `main` | Branch/commit of the `equisdots/dots` fallback clone. |
| `X_HYPR_ONLINE` | `0` | `1` = ignore the snapshot and deploy the latest stack from GitHub. |
| `X_APP_REF` | `main` | Branch/commit of the app configs (online mode only). |
| `X_HYPR_BASE` | `~/.local/share/equisdots` | Repo clones/wrappers target. |
| `X_HYPR_DRYRUN` | `0` | `1` = resolve the source and print the plan only (no install). |
| `X_HYPR_OFFLINE` | `0` | `1` = force offline; fail instead of cloning. |
| `X_HYPR_KEEP_SRC` | `0` | `1` = keep the temporary `equisdots/dots` clone. |

```bash
# plan only, from a snapshot (no changes)
X_HYPR_DRYRUN=1 X_HYPR_SOURCE=/path/to/x-config bash tools/hyprland-install.sh
# plan only, offline tree
X_HYPR_DRYRUN=1 X_HYPR_CONFIG=/usr/share/x/config bash tools/hyprland-install.sh
# plan only, online mode (no network in dry-run)
X_HYPR_DRYRUN=1 X_HYPR_ONLINE=1 bash tools/hyprland-install.sh
# full setup for the current user
bash tools/hyprland-install.sh
```

Always run as the target user; `X_HYPR_DRYRUN` and the snapshot-override paths
are exercised by `test/smoke.sh` without root.
