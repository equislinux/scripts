# x — generaciones

Las generaciones son la capa de versionado del sistema X Linux: cada cambio
relevante produce un **snapshot inmutable** del árbol raíz más un **manifiesto**
con el estado del sistema. Estilo NixOS en el comportamiento (generaciones
numeradas, rollback, restore granular) sin store content-addressed: los
snapshots son subvolúmenes btrfs y el manifiesto registra la procedencia.

Los sistemas instalados por el instalador de texto ya usan el layout btrfs
(`@`, `@home`, `@snapshots`); la primera generación se crea al final de la
instalación.

## Qué contiene una generación

| Ruta | Contenido |
|------|-----------|
| `/.snapshots/<id>` | Snapshot read-only del subvolumen raíz (`@`) |
| `/var/lib/x/generations/<id>/manifest.json` | Procedencia: motivo, padre, tooling, kernel, cmdline, hashes |
| `/var/lib/x/generations/<id>/packages.tsv` | Captura de `pacman -Q` (o `xpm query` si xpm es el único gestor) |
| `/var/lib/x/generations/<id>/services.txt` | Unidades systemd habilitadas |
| `/var/lib/x/generations/<id>/boot/` | Kernel/initramfs archivados de la generación |
| `/var/lib/x/generations/<id>/snapshot.uuid` | UUID btrfs del snapshot |
| `/var/lib/x/current` | Id de la generación actual |

El manifiesto hashea `/etc` (`configs.etc_sha256`), así `x gen status` puede
reportar drift: archivos cambiados desde que se creó la generación.

## Layout

```
@            -> /            (raíz escribible; la generación viva)
@home        -> /home        (todavía no se snapshotea por generación)
@snapshots   -> /.snapshots  (snapshots read-only, modo 0700)
```

`/tmp` es tmpfs (el instalador lo escribe en `/etc/fstab`) para que los
snapshots no capturen archivos transitorios.

## Comandos

| Comando | Descripción |
|---------|-------------|
| `x gen` / `x gen list` | Lista las generaciones; `*` marca la actual |
| `x gen new [--reason R] [--label L]` | Crea una generación (snapshot + manifiesto) |
| `x gen status` | Muestra la generación actual y el drift de `/etc` |
| `x gen restore <path> [--from ID] [--dest PATH]` | Restaura un archivo o directorio desde un snapshot |

```bash
sudo x gen new --reason manual --label "antes de tocar"
x gen list
x gen status
sudo x gen restore /etc/sddm.conf --from 0002
sudo x gen restore /etc/NetworkManager --from 0001 --dest /tmp/nm
```

El restore nunca pisa en silencio: un archivo que difiere se mueve a
`<archivo>.bak.<ts>` antes de copiar la versión del snapshot (mismo contrato
que `x_sync_config` en `install/helpers/sync.sh`).

## Creación automática

- `x setup` (fases de sistema) termina con una generación (`reason: setup`).
- `x update` crea una generación de **seguridad pre-update**, corre
  `pacman -Syu` + migraciones, y crea una segunda generación (`reason:
  update`). Si pacman falla, la generación de seguridad queda para recuperar.
- Durante la instalación, `x setup` corre con `X_GEN_SKIP=1`; el instalador
  crea la generación `0001` (`reason: install`) después del bootloader.

## Backends y entorno

| Variable | Default | Significado |
|----------|---------|-------------|
| `X_GEN_BACKEND` | `auto` | `auto` detecta btrfs; `btrfs`, `dir` (tests/degradado), `off` |
| `X_GEN_STATE` | `/var/lib/x` | Raíz de estado |
| `X_GEN_DIR` | `$X_GEN_STATE/generations` | Store de manifiestos |
| `X_GEN_CURRENT` | `$X_GEN_STATE/current` | Archivo con el id actual |
| `X_GEN_SNAPSHOTS` | `/.snapshots` | Store de snapshots |
| `X_GEN_ROOT` | `/` | Árbol a snapshotear (los tests usan una raíz falsa) |
| `X_GEN_CMDLINE` | `/proc/cmdline` | Cmdline registrado en el manifiesto |
| `X_GEN_SKIP` | `0` | `1` desactiva las generaciones automáticas en los hooks |

En un sistema no-btrfs (o WSL) `xgen_supported` es falso y cada hook es un
no-op; la CLI reporta que las generaciones no están disponibles.

## Todavía no implementado

Esto es la fase F0/F1 del diseño (ver el roadmap del workspace): entries de
boot por generación y `x gen rollback`, `x gen diff`, `x gen prune/pin`,
generaciones del home por usuario, restore por paquete (`--pkg`) y el modo
degradado de WSL.

## Tests

`test/generations.sh` (lo ejecuta `test/smoke.sh`) cubre creación, manifiestos,
list, status/drift y restore con el backend `dir`, sin root.
