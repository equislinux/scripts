# x — fases de aprovisionamiento

El aprovisionamiento se divide en fases de **sistema (root)** y de **usuario**,
cada una un script invocable bajo `install/`. La mecánica sigue a Omarchy
(ADR-0003 en `DECISIONS.md` en la raíz del workspace) con implementación
propia.

## Cadena de sistema (root)

`install/system.sh` es la entrada root: encadena `config.sh` →
`hardware.sh` → `login.sh` → `post-install.sh` y exige root.

| Fase | Script | Qué hace |
|------|--------|----------|
| Config | `install/config.sh` | Siembra `/etc/skel` desde `skel/` (`x_copy_tree`) y aplica el overlay de `/etc` desde `etc/`, un directorio por ruta de `/etc` (p.ej. `etc/sysctl.d/` → `/etc/sysctl.d`). Hoy `etc/` solo documenta los drop-ins previstos; aún no se publica ninguno. |
| Hardware | `install/hardware.sh` | Detecta y ejecuta módulos autocontenidos bajo `hardware/` (`nvidia.sh`, `qemu.sh`). NVIDIA corre si `X_HW_NVIDIA=1` o se autodetecta una GPU NVIDIA (`X_HW_AUTO=1`); QEMU corre solo si `X_HW_QEMU=1`. |
| Login | `install/login.sh` | Habilita servicios base del sistema (NetworkManager). Los arranca solo cuando systemd es PID 1, así que es seguro dentro de un chroot/imagen live. Omite si systemd no está. |
| Post-install | `install/post-install.sh` | Identidad/branding final del sistema. Hoy es un stub que registra una integración pendiente con el tooling de release. |

Cada fase exige root (`x_require_root`) y es segura de ejecutar por separado.

## Fase de usuario

`install/user.sh` aprovisiona al usuario actual y resuelve el target vía
`SUDO_USER` cuando se eleva:

1. Ejecuta `install/user-seed.sh` (como el usuario target vía `runuser` si se
   corre como root):
   - siembra el home desde el skeleton (`x_seed_home`, solo lo que falta),
   - sincroniza `config/` a `~/.config` (`x_sync_config`, con backups).
2. Si `X_NODE=1`, instala el toolchain de node (`tools/node.sh`, fnm).
3. Si `X_HYPRLAND` (default `1`), aprovisiona el escritorio Hyprland/equisdots
   (`tools/hyprland-install.sh`, offline desde el snapshot de equisdots
   empaquetado; fallback online vía `equisdots/dots`).

```bash
# como el usuario target (finalizar)
bash install/user.sh
# forzar el toolchain de node
X_NODE=1 bash install/user.sh
# omitir el escritorio Hyprland
X_HYPRLAND=0 bash install/user.sh
```

## Helpers

`install/helpers/common.sh` — helpers de log y privilegios; exporta `X_ROOT`:

- `log`/`warn`/`error` (prefijo coloreado; `error` sale con código 1).
- `has_cmd` — comprobación de existencia de un comando.
- `x_require_root` — aborta salvo que se corra como root.
- `x_target_user`/`x_target_home` — resuelven el target del aprovisionamiento
  (`SUDO_USER` si está, si no el usuario actual).
- `run_privileged`/`run_as_user` — elevan o cambian de usuario vía
  `sudo`/`runuser`; respetan `X_DRY_RUN=1` (imprimen en vez de ejecutar).

`install/helpers/sync.sh` — sync de árboles sin rsync:

- `x_copy_tree <src> <dst>` — sobrescribe: copia los contenidos de `src` a
  `dst` (semillas de primera instalación como `/etc/skel` y el overlay de
  `/etc`).
- `x_seed_home <skel> <home>` — crea solo lo que falta; nunca sobrescribe
  archivos del usuario (sin backup, no toca nada existente).
- `x_sync_config <src> <dst>` — replica un árbol de dotfiles en `dst`; un
  archivo que difiere se mueve a `<file>.bak.<ts>` antes de copiar la versión
  nueva. Idempotente: los archivos sin cambios se dejan igual y no se genera
  un backup extra.

`install/helpers/xgen.sh` — motor de generaciones (snapshot btrfs + manifiesto):

- `xgen_new` — crea una generación (snapshot, manifiesto, capturas de
  paquetes/servicios, archivo del kernel).
- `xgen_maybe_new` — hook que usan `x setup` (`install/system.sh`) y
  `x update`; no-op cuando las generaciones no están soportadas o
  `X_GEN_SKIP=1`.
- `xgen_list`/`xgen_status`/`xgen_restore`/`xgen_verify` — inspeccionan
  generaciones, comparan el sistema vivo y restauran archivos/directorios.
  Contrato completo en `generations.md`.

`install/helpers/xgen-home.sh` — generaciones de home (copias de dotfiles, sin
root ni btrfs): `hgen_new`, `hgen_list`, `hgen_status`, `hgen_diff`,
`hgen_restore` y `hgen_prune`, que respaldan los comandos `x home`.
`user-seed.sh` registra una captura `pre-setup` antes de tocar dotfiles y
`x update` registra una `pre-update`; `X_HGEN_SKIP=1` desactiva ambas.

Hooks de pacman: `hooks/alpm/{10-x-gen-pre,95-x-gen-post}.hook` (instalados en
`/usr/share/libalpm/hooks/`) llaman
a `hooks/pacman-gen.sh`, que es no-op sin generación actual, en no-btrfs o con
`X_GEN_SKIP=1` (lo que `x update` setea en su propio pacman para manejar él
mismo sus generaciones pre/post). Detalles en `generations.md`.

## Modelo de idempotencia

- Las fases y los helpers están diseñados para re-ejecutarse con seguridad: los
  seeds no pisan datos del usuario, el sync de config deja backups, los enables
  de servicios y las instalaciones de paquetes son `--needed`/guardadas.
- Las migraciones por usuario añaden la última capa de cambio idempotente (ver
  abajo).
- `test/smoke.sh` verifica los helpers sin root: protección de sobrescritura de
  `x_seed_home`, backup-y-aplica más idempotencia de segunda pasada de
  `x_sync_config`, sintaxis de todos los bash, los dry-runs del tool de
  Hyprland y el despacho/temas/migraciones de la CLI.

## Migraciones (por usuario)

Las migraciones son scripts bash idempotentes
`migrations/<timestamp>-<name>.sh`, aplicados por `x migrate` y por `x update`.
Una ejecución correcta se marca en `~/.local/state/x/migrations/<name>`; las
migraciones que fallan se notifican y no se marcan. Deben ser sin red y seguras
de repetir. Ver `migrations/README.md`.

## Interruptores de entorno

Ver la tabla completa en `cli.md`. Los que importan por fase:

- Config/seed: `X_SKEL_DIR`, `X_CONFIG_SEED`, `X_TS`.
- Hardware: `X_HW_AUTO`, `X_HW_NVIDIA`, `X_HW_QEMU`.
- Usuario: `X_NODE`, `X_HYPRLAND`.
- Global: `X_DRY_RUN`.

## Puntos de entrada

| Acción | Comando |
|--------|---------|
| Sistema (root) durante la instalación | `x setup` / `sudo bash install/system.sh` |
| Finalizar usuario | `x setup --user` / `bash install/user.sh` |
| Solo hardware | `x hardware` / `sudo bash install/hardware.sh` |
| Migraciones | `x migrate` |
| Actualizar + migraciones | `x update` |
