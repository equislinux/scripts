# x — generaciones

Las generaciones son la capa de versionado del sistema X Linux: cada cambio
relevante produce un **snapshot booteable** del árbol raíz más un **manifiesto**
con el estado del sistema. Estilo NixOS en el comportamiento (generaciones
numeradas, rollback, restore granular) sin store content-addressed: los
snapshots son subvolúmenes btrfs, el menú de arranque los lista y
`x gen rollback` cambia el default.

Los sistemas instalados por el instalador de texto usan el layout btrfs
(`@`, `@home`, `@snapshots`, `@xstate`); la primera generación se crea al final
de la instalación.

## Qué contiene una generación

| Ruta | Contenido |
|------|-----------|
| `/.snapshots/<id>` | Snapshot escribible de la raíz viva (restore point booteable) |
| `/var/lib/x/generations/<id>/manifest.json` | Procedencia: motivo, padre, tooling, kernel, cmdline, hashes, `root_subvol` |
| `/var/lib/x/generations/<id>/packages.tsv` | Captura de `pacman -Q` (o `xpm query` si xpm es el único gestor) |
| `/var/lib/x/generations/<id>/services.txt` | Unidades systemd habilitadas |
| `/var/lib/x/generations/<id>/boot/` | Kernel/initramfs archivados (para bootear generaciones congeladas) |
| `/var/lib/x/generations/<id>/snapshot.uuid` | UUID btrfs del snapshot |
| `/var/lib/x/generations/<id>/pinned` | Marca: nunca podar su entry de boot |
| `/var/lib/x/current` | Generación que bootea por defecto (la seleccionada) |
| `/var/lib/x/pending` | Lo escribe el rollback: objetivo a bootear en el próximo reinicio |

`/var/lib/x` es su propio subvolumen (`@xstate`), así los metadatos los ven
todas las generaciones (los snapshots no los capturan). El manifiesto hashea
`/etc` (`configs.etc_sha256`), y `x gen status` reporta el drift.

## Layout

```
@            -> /            (raíz viva; la primera generación)
@home        -> /home        (datos de usuario; el rollback no los toca)
@snapshots   -> /.snapshots  (snapshots de generación, modo 0700)
@xstate      -> /var/lib/x   (metadatos compartidos, modo 0700)
```

`/tmp` es tmpfs (el instalador lo escribe en `/etc/fstab`).

## Comandos

| Comando | Descripción |
|---------|-------------|
| `x gen` / `x gen list` | Lista las generaciones; `*` marca la default (actual) |
| `x gen new [--reason R] [--label L]` | Registra una generación (snapshot + manifiesto + entry de boot) |
| `x gen status` | Muestra backend, running vs default, rollback pendiente y drift de `/etc` |
| `x gen rollback <id> [--no-safety]` | Cambia el default boot a una generación (aplica al reiniciar) |
| `x gen boot` | Regenera las entries de boot por generación |
| `x gen diff <a> <b>` | Diferencias de paquetes/servicios/kernel/`/etc` entre dos generaciones |
| `x gen pin <id> [--unpin]` | Protege una generación de `x gen prune` |
| `x gen prune [--keep N] [--dry-run]` | Elimina generaciones viejas (pinned, running y default siempre quedan) |
| `x gen restore <path> [--from ID] [--dest PATH]` | Restaura un archivo o directorio desde un snapshot |
| `x gen restore --pkg <name> [--from ID] [--dest ROOT]` | Restaura todos los archivos de un paquete (db pacman/xpm del snapshot) |

```bash
sudo x gen new --reason manual --label "antes de tocar"
x gen list
x gen status
x gen diff 0001 0003
sudo x gen rollback 0002        # bootea la generación 0002 al reiniciar
sudo x gen restore /etc/sddm.conf --from 0002
sudo x gen restore --pkg kitty --from 0002
sudo x gen pin 0002             # nunca podar
sudo x gen prune --keep 5 --dry-run
```

El restore nunca pisa en silencio: un archivo que difiere se mueve a
`<archivo>.bak.<ts>` antes de copiar la versión del snapshot (mismo contrato
que `x_sync_config` en `install/helpers/sync.sh`).

`x gen diff` compara `packages.tsv` (versiones agregadas/eliminadas/
actualizadas), `services.txt`, el kernel y el hash de `/etc`. `x gen prune`
borra metadatos, snapshot y entry de boot de las generaciones fuera de la
ventana, pero **siempre** conserva pinned, running y default; si elimina el
objetivo `pending` (solo posible si estaba unpinned), limpia el marcador.

## Entries de boot y semántica del rollback

- Una entry por generación retenida en el menú (GRUB: `custom.cfg`;
  systemd-boot: `loader/entries/x-gen-<id>.conf`), más `x.conf` espejando la
  default.
- La generación **running** bootea el kernel vivo del ESP (`/vmlinuz-linux`)
  porque su raíz muta in-place (las actualizaciones mantienen los módulos en
  sync). Las generaciones **congeladas** bootean su copia archivada
  (`/boot/x/gen-<id>/...`), que coincide con su `/usr/lib/modules` congelado.
- El ESP conserva las últimas `X_GEN_BOOT_KEEP` generaciones más la default, la
  running y las `pinned`; podar el ESP nunca borra el snapshot btrfs ni los
  metadatos, así que cualquier generación se puede volver a seleccionar
  (`rollback` recrea su entry y su copia de kernel a demanda).
- `x gen rollback <id>` crea una generación de **seguridad** pre-rollback,
  marca la objetivo como `pinned`, actualiza `current`/`pending` y reescribe los
  defaults del menú. `/home` no se toca.
- `x gen status` distingue la generación **running** (parseada del cmdline
  `rootflags=subvol=...`), la **default** (próximo boot) y un rollback
  **pending**.

## Creación automática

- `x setup` (fases de sistema) termina con una generación (`reason: setup`).
- `x update` crea una generación de **seguridad pre-update**, corre
  `pacman -Syu` + migraciones y registra una segunda generación (`reason:
  update`). Si pacman falla, la de seguridad queda para recuperar.
- Durante la instalación, `x setup` corre con `X_GEN_SKIP=1`; el instalador
  crea la generación `0001` (`reason: install`, subvol vivo `/@`) después del
  bootloader, con `X_GEN_LIVE_SUBVOL=/@`.

`x gen new` registra estado; no cambia el default boot (para eso está
`x gen rollback`).

## Backends y entorno

| Variable | Default | Significado |
|----------|---------|-------------|
| `X_GEN_BACKEND` | `auto` | `auto` detecta btrfs; `btrfs`, `dir` (tests/degradado), `off` |
| `X_GEN_STATE` | `/var/lib/x` | Raíz de estado (subvol `@xstate` en instalaciones) |
| `X_GEN_DIR` | `$X_GEN_STATE/generations` | Store de manifiestos |
| `X_GEN_CURRENT` | `$X_GEN_STATE/current` | Archivo con la generación default |
| `X_GEN_SNAPSHOTS` | `/.snapshots` | Store de snapshots (punto de montaje) |
| `X_GEN_SUBVOL_PREFIX` | `$X_GEN_SNAPSHOTS` | Ruta in-fs del store (opción de mount `subvol=`) |
| `X_GEN_ROOT` | `/` | Árbol a snapshotear (los tests usan una raíz falsa) |
| `X_GEN_CMDLINE` | `/proc/cmdline` | Cmdline registrado en el manifiesto |
| `X_GEN_BOOT` | `auto` | `on`/`off`/`auto` (auto: activo con btrfs) |
| `X_GEN_BOOT_DIR` | `/boot` | Ruta del ESP con kernels y entries |
| `X_GEN_BOOT_KEEP` | `3` | Generaciones retenidas en el menú de boot |
| `X_GEN_KEEP` | `5` | Generaciones retenidas por `x gen prune` (mismas reglas: pinned/running/default) |
| `X_GEN_LIVE_SUBVOL` | — | `root_subvol` de la generación viva (instalador: `/@`) |
| `X_GEN_RUNNING` | del cmdline | Id de la generación running (tests) |
| `X_GEN_SKIP` | `0` | `1` desactiva las generaciones automáticas en los hooks |

En un sistema no-btrfs (o WSL) `xgen_supported` es falso y cada hook es un
no-op; la CLI reporta que las generaciones no están disponibles.

## Todavía no implementado

Generaciones del home por usuario, hooks de transacción de pacman/xpm, el
`system.toml` declarativo + `x gen apply`, el modo degradado de WSL,
export/import de generaciones (`btrfs send/receive`), boot por selección en el
menú (el rollback es un comando, como `nixos-rebuild --rollback`) y retención
por tiempo en lugar de por cantidad.

## Tests

- `test/generations.sh` — creación, manifiestos, list, status/drift, diff,
  restore (path y `--pkg`).
- `test/generations-boot.sh` — entries de boot (systemd-boot + GRUB), kernel
  running vs congelado, retención del ESP, rollback, pin/unpin, prune, estado
  pending.
- `test/generations-btrfs.sh` — btrfs real con loop: `sudo bash
  test/generations-btrfs.sh` (se saltea sin root).

Los dos primeros corren en `test/smoke.sh`, sin root.
