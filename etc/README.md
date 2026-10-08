# x — /etc drop-ins

This tree is dumped onto `/etc` during the system configuration phase
(`install/config.sh`). Each subdirectory mirrors an `/etc` path:

- `sysctl.d/` — kernel parameters.
- `tmpfiles.d/` — temporary files/permissions.
- `sudoers.d/` — sudo rules.

Pacman hooks are not overlay files: the `x-scripts` package ships them in
`/usr/share/libalpm/hooks/` (same directory as `90-mkinitcpio-*`, so the
post-transaction hook runs after a new kernel's initramfs exists).

Rule: never overwrite package files; always use drop-ins. A file already
modified by the administrator is not overwritten.
