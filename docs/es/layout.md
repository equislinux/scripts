# x — referencia de layout

Repo de aprovisionamiento del sistema x (por scripts, sin instalador gráfico;
ADR-0001/ADR-0003 en `DECISIONS.md` en la raíz del workspace).

## Árbol

| Ruta | Rol |
|------|-----|
| `bin/x` | El dispatcher de la CLI `x` (sin args/`help`/`list`/`-h`/`--help` imprimen la ayuda). |
| `bin/x-*.sh` | Un archivo por subcomando, resuelto por nombre + metadatos de cabecera. Ver `cli.md`. |
| `install/` | Orquestadores de aprovisionamiento por fase. Ver `provisioning.md`. |
| `install/system.sh` | Entrada root: encadena `config.sh` → `hardware.sh` → `login.sh` → `post-install.sh`. |
| `install/config.sh` | Root: siembra `/etc/skel` desde `skel/` y aplica el overlay de `/etc` desde `etc/`. |
| `install/hardware.sh` | Root: detecta/ejecuta los módulos bajo `hardware/`. |
| `install/login.sh` | Root: habilita servicios base (NetworkManager). |
| `install/post-install.sh` | Root: branding final; hoy es un stub. |
| `install/user.sh` | Aprovisionamiento de usuario (delega en `user-seed.sh` vía `runuser` si corre como root; luego node e Hyprland opcionales). |
| `install/user-seed.sh` | Siembra el home desde el skeleton y sincroniza `config/` a `~/.config`. |
| `install/helpers/common.sh` | Librería bash: log/warn/error, helpers de privilegios y usuario target, exporta `X_ROOT`. |
| `install/helpers/sync.sh` | Sync idempotente de árboles: `x_copy_tree`, `x_seed_home`, `x_sync_config`. |
| `install/x-base.packages` | Lista de paquetes base legible por el builder (uno por línea); aún sin consumidor cableado. |
| `skel/` | Seed de `/etc/skel` para usuarios nuevos (hoy un `.bashrc`). |
| `etc/` | Drop-ins de `/etc`, un directorio por ruta (`sysctl.d`, `tmpfiles.d`, `sudoers.d`, `pacman.d/hooks` documentados en su README); aún no se publica ningún drop-in. |
| `config/` | Dotfiles de usuario sincronizados a `~/.config`. `config/hypr/` es solo un punto de entrada documental + wallpaper por defecto; la config real de escritorio viaja offline en el paquete (`/usr/share/x/config/equisdots`), ADR-0005. |
| `migrations/` | Migraciones por usuario idempotentes (`<timestamp>-<name>.sh`), aplicadas por `x migrate` / `x update`. |
| `themes/` | Almacén de temas: `themes/<name>/colors` (key=hex), aplicado por `x theme set`. |
| `hardware/` | Módulos root autocontenidos: `nvidia.sh`, `qemu.sh`. |
| `tools/` | Tools de nivel usuario: `node.sh` (fnm, controlado por `X_NODE`), `hyprland-install.sh` (despliegue offline del escritorio equisdots, controlado por `X_HYPRLAND`). |
| `packaging/` | `PKGBUILD` de `x-scripts` + generador del snapshot offline `vendor-config.sh` + salida `.vendor/` (git-ignored). |
| `test/` | Tests locales sin root: `test/smoke.sh` (sintaxis + helpers + CLI + dry-runs de Hyprland). |
| `docs/` | Esta documentación (`CLI.md`, `LAYOUT.md`, `en/`, `es/`). |

## Mecánica

- Las fases root y de usuario están separadas; cada fase es un script invocable
  e idempotente.
- Capas del home: seed de `/etc/skel` (instalación, `config.sh`) → seed del home
  desde skel solo-lo-que-falta (`user-seed.sh`) → sync de `config/` a
  `~/.config` con backups `.bak.<ts>`.
- Los archivos modificados por el usuario nunca se sobrescriben en silencio: los
  seeds los omiten, el sync de config hace backup primero.
- La config de escritorio se instala de forma limpia desde el snapshot offline
  vendido, no se mantiene aquí (ver `hyprland.md`, ADR-0005).

## Uso

```bash
# CLI (desde el repo o instalada como /usr/bin/x)
bash bin/x help
bash bin/x setup            # sistema (root)
bash bin/x setup --user     # usuario actual
bash bin/x theme set x-dark
bash bin/x migrate
bash bin/x update

# Directo por fase (equivalente)
sudo bash install/system.sh
X_NODE=1 X_HYPRLAND=1 bash install/user.sh
sudo X_HW_NVIDIA=1 X_HW_QEMU=1 bash install/hardware.sh

# Tests locales (sin root)
bash test/smoke.sh
```

## Ver también

- `overview.md` — rol del repo en la org y en el sistema.
- `cli.md` — comandos, cómo añadir comandos, variables de entorno.
- `provisioning.md` — fases, helpers, idempotencia.
- `hyprland.md` — el tool de setup de escritorio offline.
- `packaging.md` — construir `x-scripts` y el snapshot vendido.
WSL lives in its dedicated repos: equislinux/wsl and equislinux/wsl-scripts.
