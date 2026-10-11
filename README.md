# x — scripts

Provisioning of the **x** system through scripts (Omarchy style, no graphical
installer). It lives alongside the distro in `equislinux/x` and the tooling in
`xpkg`/`xpm`/`x-repo`.

## Contents

- `install/` — phase orchestrators (config, hardware, login,
  post-install, user) and idempotent sync helpers.
- `skel/` + `etc/` + `config/` — dotfile seeds: `/etc/skel`, `/etc`
  drop-ins and `~/.config` (includes the Hyprland placeholder).
- `hardware/`, `tools/` — optional modules (NVIDIA, QEMU/libvirt, node).
- `test/` — local tests without root.

Structure and mechanics details in `docs/LAYOUT.md`.

## Usage

```bash
# CLI (from the repo or installed as /usr/bin/x)
bash bin/x help
bash bin/x setup            # system (root)
bash bin/x setup --user     # current user
bash bin/x theme set x-dark
bash bin/x migrate
bash bin/x update
bash bin/x kernel list        # kernels: list/install/remove (safety guards)

# Direct per phase (equivalent)
sudo bash install/system.sh
X_NODE=1 bash install/user.sh
```

## Status

Active. The payload ships as `x-scripts` (0.1.0-36) in the `[x]` repository and
reaches installed systems with `x update`; the CLI and modules above are the
current surface. Documentation: https://github.com/equislinux/wiki

`x setup --user --online` runs the original equisdots installer (clone of equisdots/dots in temp, run `dots setup`, cleanup).
WSL lives in its dedicated repos: equislinux/wsl and equislinux/wsl-scripts.
