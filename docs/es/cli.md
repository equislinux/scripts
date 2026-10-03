# x — CLI

`x` es la CLI de aprovisionamiento del sistema x (ADR-0003 en `DECISIONS.md` en
la raíz del workspace). Su implementación vive en `bin/` de este repo y se
instala como `/usr/bin/x` (symlink a `/usr/share/x/bin/x`) con el paquete
`x-scripts`. Trabajando desde un checkout se invoca como `bash bin/x`.

El despacho es por **convención de nombres más metadatos en comentarios de
cabecera**, sin registro central: añadir un comando es añadir un archivo en
`bin/`.

## Uso

```bash
x <command> [arguments]
x help          # o: x list, x -h, x --help
```

`x` sin argumentos imprime la ayuda. El dispatcher exporta `X_BIN` (el
directorio `bin/`) y `X_CLI=1` para que los subcomandos sepan que corren vía
CLI.

## Comandos

Los resúmenes son las cabeceras `x:summary` de cada archivo (los muestra
`x help`).

| Comando | Descripción |
|---------|-------------|
| `x setup` | Aprovisiona el sistema como root (`install/system.sh`; config, hardware, login, post-install). Eleva con sudo si hace falta. |
| `x setup --user` | Aprovisiona al usuario actual (`install/user.sh`; seed del home + sync de config + node e Hyprland opcionales). |
| `x theme list` | Lista los temas disponibles bajo `themes/`. |
| `x theme set <name>` | Aplica un tema: copia `themes/<name>/colors` a `~/.config/x/theme.conf` (con backup del anterior) y registra el tema activo en `~/.local/state/x/theme`. |
| `x migrate` | Ejecuta las migraciones idempotentes pendientes del usuario. |
| `x update` | `pacman -Syu` (privilegiado) seguido de las migraciones del usuario. |
| `x hardware` | Ejecuta la fase de hardware (detección + módulos). Requiere root. |
| `x info` | Muestra versión, repo, usuario e info del entorno. |
| `x gen` / `x gen list` | Lista las generaciones del sistema (`*` marca la actual). Ver `generations.md`. |
| `x gen new` | Crea una generación: snapshot btrfs + manifiesto (`--reason`, `--label`). |
| `x gen status` | Muestra running vs default, rollback pendiente y el drift de `/etc`. |
| `x gen rollback <id>` | Cambia el default boot a una generación (aplica al reiniciar; `--no-safety`). |
| `x gen boot` | Regenera las entries de boot por generación. |
| `x gen diff` | Muestra diferencias de paquetes/servicios/migraciones/kernel/`/etc` entre dos generaciones. |
| `x gen verify` | Compara el sistema vivo contra una generación (exit 1 con drift). |
| `x gen pin <id>` | Protege una generación del podado (`--unpin`). |
| `x gen prune` | Elimina generaciones viejas conservando pinned/running/default (`--keep N`, `--older-than DAYS`, `--dry-run`). |
| `x gen restore <path>` | Restaura un archivo/directorio desde una generación (`--from ID`, `--dest PATH`). |
| `x gen restore --pkg <name>` | Restaura todos los archivos de un paquete. |
| `x gen export` / `x gen import` | Empaqueta/restaura un bundle de generación (`--with-data`, `--force`). |
| `x gen quota init` / `status` | Habilita quotas btrfs y muestra uso / tabla de qgroups. |
| `x gen plan` | Imprime las acciones para cumplir una declaración `system.toml`. |
| `x gen apply` | Aplica una declaración `system.toml` (`--dry-run`); registra una generación. |
| `x home` / `x home list` | Lista las generaciones de home del usuario (dotfiles). |
| `x home new` / `status` / `diff` / `restore` / `prune` | Ciclo de vida de las generaciones de home. Ver `generations.md`. |

Los comandos solo-root lo hacen cumplir dentro del dispatcher (ver metadatos
más abajo) e imprimen un error si se ejecutan como usuario no root.

### Aliases

Los aliases se definen con el metadato `x:aliases` y permiten que un token
único mapee a un archivo de comando:

| Alias | Resuelve a |
|-------|-----------|
| `theme`, `themes` | `x-theme-list.sh` (así `x theme` lista los temas) |
| `hardware`, `hw` | `x-hardware.sh` |
| `info`, `status`, `doctor` | `x-info.sh` |
| `migrate`, `migrations` | `x-migrate.sh` |
| `update`, `upgrade`, `up` | `x-update.sh` |
| `gen`, `generation`, `generations` | `x-gen-list.sh` (así `x gen` lista las generaciones) |

## Mecánica del despacho

La resolución prueba primero el prefijo de nombre de archivo más largo y luego
cae al primer argumento comparado contra `x:aliases`:

- `x theme set nord` → busca `x-theme.sh`, luego `x-theme-set.sh`; existe este
  último, así que `nord` se pasa a `x-theme-set.sh`.
- `x theme` (token único) → no hay `x-theme.sh`; el alias `theme` de
  `x-theme-list.sh` coincide.
- `x inexistente` → error con ayuda (exit 1).

El archivo debe ser **ejecutable** para poder resolverse. El dispatcher solo
consume `x:summary`, `x:aliases` y `x:root`; el resto de argumentos se
reenvían al subcomando, que valida sus propios argumentos (`x setup --help`,
`x theme set` con arity incorrecto da error, etc.).

## Cómo añadir un comando

Crea `bin/x-<grupo>-<verbo>.sh` como script ejecutable con metadatos en la
cabecera:

```bash
#!/usr/bin/env bash
# x:summary=una línea mostrada por x help
# x:aliases=alias1 alias2      # opcional
# x:root=true                  # opcional: exige root para ejecutarse
set -euo pipefail

X_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# ...
```

- `x:summary` — descripción de una línea, mostrada en `x help` y `x list`.
- `x:aliases` — aliases opcionales separados por espacios, resueltos contra el
  primer token.
- `x:root=true` — hace que el dispatcher se niegue a ejecutarlo como usuario no
  root.
- `x:args` — opcional; solo informativo, no lo parsea el dispatcher. Úsalo para
  documentar los argumentos esperados en la cabecera.

No hay registro central ni paso de registro.

## Variables de entorno

| Variable | Default | Significado |
|----------|---------|-------------|
| `X_BIN` | `<repo>/bin` | Directorio de la CLI (lo exporta el dispatcher). |
| `X_CLI` | — | `1` cuando corre vía dispatcher (lo exporta él). |
| `X_ROOT` | `<repo>` | Raíz del repo/payload (la exporta `install/helpers/common.sh`). |
| `X_STATE_DIR` | `~/.local/state/x` | Directorio de estado de usuario (tema, marcadores de migración). |
| `X_THEMES_DIR` | `<repo>/themes` | Almacén de temas. |
| `X_THEME_CONF` | `~/.config/x/theme.conf` | Archivo de salida de `x theme set`. |
| `X_MIGRATIONS_DIR` | `<repo>/migrations` | Directorio de scripts de migración. |
| `X_SKEL_DIR` | `/etc/skel` | Skeleton que se siembra en el home. |
| `X_CONFIG_SEED` | `<repo>/config` | Árbol de dotfiles que se sincroniza a `~/.config`. |
| `X_TS` | timestamp actual | Timestamp usado para backups `.bak.<ts>`. |
| `X_DRY_RUN` | `0` | `1` hace que los helpers privilegiados/de usuario registren en lugar de ejecutar. |
| `X_NODE` | `0` | `1` instala el toolchain de node (fnm) en la fase de usuario. |
| `X_HYPRLAND` | `1` | `0` omite el setup de Hyprland en la fase de usuario. |
| `X_HW_AUTO` | `1` | `0` desactiva la autodetección de hardware en la fase de hardware. |
| `X_HW_NVIDIA` | `0` | `1` fuerza el módulo NVIDIA. |
| `X_HW_QEMU` | `0` | `1` habilita el módulo QEMU/libvirt. |
| `X_GEN_BACKEND` | `auto` | `auto`, `btrfs`, `dir` (tests/degradado) u `off`. Ver `generations.md`. |
| `X_GEN_STATE` / `X_GEN_DIR` / `X_GEN_CURRENT` | `/var/lib/x/...` | Estado, manifiestos e id actual de las generaciones. |
| `X_GEN_SNAPSHOTS` | `/.snapshots` | Store de snapshots (punto de montaje). |
| `X_GEN_SUBVOL_PREFIX` | `$X_GEN_SNAPSHOTS` | Ruta in-fs usada por mount/opciones de boot. |
| `X_GEN_ROOT` | `/` | Árbol capturado por una generación (los tests usan una raíz falsa). |
| `X_GEN_CMDLINE` | `/proc/cmdline` | Cmdline del kernel registrado en el manifiesto. |
| `X_GEN_BOOT` / `X_GEN_BOOT_DIR` / `X_GEN_BOOT_KEEP` | `auto` / `/boot` / `3` | Gestión y retención de entries de boot. |
| `X_GEN_KEEP` | `5` | Retención de generaciones para `x gen prune`. |
| `X_HGEN_STATE` / `X_HGEN_HOME` | `~/.local/share/x/home-gens` / `$HOME` | Store y home capturado de las generaciones de home. |
| `X_HGEN_INCLUDE` / `X_HGEN_EXCLUDE` | dotfiles + `.config` / `Cache CachedData GPUCache logs` | Rutas capturadas por `x home new`. |
| `X_HGEN_KEEP` | `10` | Retención de generaciones de home para `x home prune`. |
| `X_GEN_LIVE_SUBVOL` | — | `root_subvol` de la generación viva (el instalador usa `/@`). |
| `X_GEN_RUNNING` | del cmdline | Id de la generación running (tests). |
| `X_GEN_SKIP` | `0` | `1` desactiva las generaciones automáticas en los hooks de setup/update. |

Las variables específicas del setup de Hyprland (`X_HYPR_*`) se documentan en
`hyprland.md`.

## Estado

- `~/.local/state/x/` — estado de usuario: `theme` (tema activo) y
  `migrations/<name>` (marcadores de migración aplicada).
- `~/.config/x/` — config de usuario generada, p.ej. `theme.conf`.
- `/var/lib/x/` — estado de sistema: `generations/<id>/` (manifiestos y
  capturas) y `current` (id de la generación actual); los snapshots viven en
  `/.snapshots/`.

Los overrides de entorno anteriores permiten que los tests y el desarrollo
redirijan cada ruta de estado/salida fuera del home real (ver `test/smoke.sh`).

## x setup --online

Ejecuta el instalador original de equisdots (`equisdots/dots setup`) desde un
clon temporal y lo limpia después. Úsalo cuando ya hayas iniciado sesión y el
setup empaquetado offline no baste. Pedirá la contraseña de sudo cuando el
script original la necesite.

    x setup --user --online
