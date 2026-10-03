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
| `/var/lib/x/generations/<id>/migrations.txt` | Marcadores de migración aplicados (`usuario<TAB>marcador`) |
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
| `x gen status [--json]` | Muestra backend, running vs default, rollback pendiente y drift de `/etc` |
| `x gen rollback <id> [--no-safety]` | Cambia el default boot a una generación (aplica al reiniciar) |
| `x gen boot` | Regenera las entries de boot por generación |
| `x gen diff <a> <b>` | Diferencias de paquetes/servicios/migraciones/kernel/`/etc` entre dos generaciones |
| `x gen verify [id]` | Compara el sistema vivo contra una generación (exit 1 con drift) |
| `x gen pin <id> [--unpin]` | Protege una generación de `x gen prune` |
| `x gen prune [--keep N] [--older-than DAYS] [--dry-run]` | Elimina generaciones viejas (pinned, running y default siempre quedan) |
| `x gen restore <path> [--from ID] [--dest PATH]` | Restaura un archivo o directorio desde un snapshot |
| `x gen restore --pkg <name> [--from ID] [--dest ROOT]` | Restaura todos los archivos de un paquete (db pacman/xpm del snapshot) |
| `x gen export <id> [--out FILE] [--with-data] [--sign]` | Empaqueta (y opcionalmente firma) una generación como bundle portable |
| `x gen import <file> [--force] [--allow-metadata-only]` | Importa un bundle a `$X_GEN_STATE` (`--force` reemplaza) |
| `x gen quota init [--limit SIZE]` / `status` | Habilita quotas btrfs y muestra uso / tabla de qgroups |
| `x gen plan <system.toml>` | Imprime las acciones para cumplir la declaración declarativa |
| `x gen apply <system.toml> [--dry-run]` | Aplica la declaración y registra una generación |

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
que `x_sync_config` en `install/helpers/sync.sh`). Las rutas se validan: se
rechazan componentes `..` y las listas de archivos de paquete con rutas
inseguras se saltean con un warning.

`/var/lib/x` y `/.snapshots` son `0700 root`: los comandos de lectura
(`list`, `status`, `diff`, ...) imprimen un error claro de "re-ejecutá con
sudo" en vez de una lista vacía cuando se corren sin privilegios.

`x gen diff` compara `packages.tsv` (versiones agregadas/eliminadas/
actualizadas), `services.txt`, `migrations.txt`, el kernel y el hash de `/etc`.
`x gen verify` corre la misma comparación contra el sistema **vivo** y sale
distinto de cero si hay drift (útil como chequeo scripteable).

`x gen prune` borra metadatos, snapshot y entry de boot de las generaciones
fuera de la ventana, pero **siempre** conserva pinned, running y default;
`--older-than DAYS` además protege las generaciones recientes aunque queden
fuera de la ventana por cantidad. Si elimina el objetivo `pending` (solo
posible si estaba unpinned), limpia el marcador.

## Entries de boot y semántica del rollback

- Una entry por generación retenida en el menú (GRUB: `custom.cfg`;
  systemd-boot: `loader/entries/x-gen-<id>.conf`), más `x.conf` espejando la
  default y una entry `x-rescue` (mismo kernel, `systemd.unit=rescue.target`).
- La generación **running** bootea el kernel vivo del ESP (`/vmlinuz-linux`)
  porque su raíz muta in-place (las actualizaciones mantienen los módulos en
  sync). Las generaciones **congeladas** bootean su copia archivada
  (`/boot/x/gen-<id>/...`), que coincide con su `/usr/lib/modules` congelado.
- **Multi-kernel**: una entry por kernel instalado, detectado desde
  `/usr/lib/modules/<release>/pkgbase` (`linux`, `linux-lts`, ...). El kernel
  primario (manifiesto `kernel.release`) conserva el id `x-gen-<id>`; el resto
  usa `x-gen-<id>-<pkgbase>`. Los kernels congelados se archivan por pkgbase en
  `/boot/x/gen-<id>/<pkgbase>/`. Las generaciones legacy de un solo kernel
  mantienen el layout viejo y emparejan vmlinuz/initramfs por sufijo.
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

## Export e import

`x gen export <id>` empaqueta los metadatos de la generación (manifiesto,
capturas, migraciones, kernel archivado) como `tar.zst` (o `tar.gz` sin zstd).
`--with-data` agrega el snapshot: `btrfs send` en btrfs (root) o copia del
árbol con backend `dir`. Los bundles llevan `BUNDLE.sha256` (hash de cada
archivo) y `x gen import` lo verifica, abortando si no coincide; los bundles
sin manifiesto (formato viejo) importan con un warning. `--sign` agrega una
firma gpg separada (`<bundle>.sig`) con `X_GEN_SIGN_KEY`; el import la verifica
si está presente y avisa si falta. El import es estricto con los datos: si el
bundle trae un snapshot btrfs que no se puede importar (backend distinto, falla
de receive) aborta antes de tocar el estado salvo `--allow-metadata-only`. Al
restaurar un stream `btrfs send` se bifurca el subvolumen recibido para que la
generación quede escribible. La generación importada no se selecciona
automáticamente — usá `x gen rollback <id>` después. Los duplicados fallan
salvo `--force`.

Es la vía de portabilidad: mover una generación entre máquinas o respaldarla
sin saber de `btrfs send`/`receive`, y la base del modo degradado de WSL.

## Generaciones de home

Las generaciones de sistema cubren el subvolumen raíz; `/home` queda afuera a
propósito. Una segunda capa, propiedad del usuario, versiona los dotfiles con
copias de archivos (sin root, sin btrfs, funciona en WSL):

| Comando | Descripción |
|---------|-------------|
| `x home` / `x home list` | Lista las generaciones de home (`*` marca la actual) |
| `x home new [--label L]` | Registra una copia de los dotfiles incluidos |
| `x home status [--json]` | Generación actual y drift |
| `x home diff <a> <b>` | Diferencias por archivo (agregado/eliminado/cambiado) |
| `x home restore <path> [--from ID] [--dest PATH]` | Restaura un dotfile (backup `.bak.<ts>`) |
| `x home prune [--keep N] [--dry-run]` | Elimina generaciones viejas (actual y pinned quedan) |

Las generaciones de home también se registran automáticamente (best effort,
nunca bloquean el aprovisionamiento): `x setup --user` registra `pre-setup`
antes de sembrar/sincronizar dotfiles, y `x update` registra `pre-update`
antes de las migraciones. `X_HGEN_SKIP=1` desactiva las capturas automáticas.

Store: `~/.local/share/x/home-gens/<id>/` con `manifest.json`, `files/`
(copia) y `files.sha256` (listado por archivo). Incluye por defecto:
`.bashrc`, `.bash_profile`, `.profile`, `.zshrc`, `.zshenv`, `.gitconfig` y
`.config`; se saltean los directorios `Cache`, `CachedData`, `GPUCache` y
`logs` en cualquier parte del árbol. Las rutas se validan para que un restore
nunca escape del home.

## Transacciones de pacman

El paquete `x-scripts` instala dos hooks de pacman:

| Hook | Cuándo | Efecto |
|------|--------|--------|
| `/etc/pacman.d/hooks/10-x-gen-pre.hook` | PreTransaction | Generación de seguridad (`reason: pacman-pre`) |
| `/etc/pacman.d/hooks/20-x-gen-post.hook` | PostTransaction | Registra el resultado (`reason: pacman`) |

Ambos llaman a `/usr/share/x/hooks/pacman-gen.sh`, que es no-op cuando todavía
no hay generación actual (instalador/pacstrap), en sistemas no-btrfs o cuando
`X_GEN_SKIP=1` — justo lo que `x update` setea en su propio `pacman -Syu` para
manejar él mismo sus generaciones pre/post. Esto cierra el hueco de "kernel
actualizado fuera de `x update`": toda transacción manual de pacman queda
capturada.

## Backends y entorno

| Variable | Default | Significado |
|----------|---------|-------------|
| `X_GEN_BACKEND` | `auto` | `auto` detecta btrfs; `btrfs`, `dir` (tests/degradado), `off` |
| `X_GEN_STATE` | `/var/lib/x` | Raíz de estado (subvol `@xstate` en instalaciones) |
| `X_GEN_DIR` | `$X_GEN_STATE/generations` | Store de manifiestos |
| `X_GEN_CURRENT` | `$X_GEN_STATE/current` | Archivo con la generación default |
| `X_GEN_SNAPSHOTS` | `/.snapshots` | Store de snapshots (punto de montaje) |
| `X_GEN_SUBVOL_PREFIX` | auto | Ruta in-fs del store (opción de mount `subvol=`); se deriva del montaje btrfs (`/@snapshots`), override solo para forzar |
| `X_GEN_ROOT` | `/` | Árbol a snapshotear (los tests usan una raíz falsa) |
| `X_GEN_CMDLINE` | `/proc/cmdline` | Cmdline registrado en el manifiesto |
| `X_GEN_BOOT` | `auto` | `on`/`off`/`auto` (auto: activo con btrfs) |
| `X_GEN_BOOT_DIR` | `/boot` | Ruta del ESP con kernels y entries |
| `X_GEN_BOOT_KEEP` | `3` | Generaciones retenidas en el menú de boot |
| `X_GEN_KEEP` | `5` | Generaciones retenidas por `x gen prune` (mismas reglas: pinned/running/default) |
| `X_GEN_QGROUP` | — | Límite de tamaño exclusivo para `x gen quota init` (p.ej. `50G`) |
| `X_GEN_SIGN_KEY` | — | Id de clave gpg usada por `x gen export --sign` |
| `X_GEN_LIVE_SUBVOL` | — | `root_subvol` de la generación viva (instalador: `/@`) |
| `X_GEN_RUNNING` | del cmdline | Id de la generación running (tests) |
| `X_GEN_SKIP` | `0` | `1` desactiva las generaciones automáticas en los hooks |

En un sistema no-btrfs (o WSL) `xgen_supported` es falso y cada hook es un
no-op; la CLI reporta que las generaciones no están disponibles.

## Límite de espacio (qgroups de btrfs)

`x gen quota init [--limit SIZE]` habilita quotas btrfs en el subvolumen de
snapshots y fija un límite **exclusivo** (`btrfs qgroup limit -e`), así el
presupuesto solo cuenta los datos propios de los snapshots. `x gen quota
status` muestra el uso y la tabla de qgroups. El límite lo aplica btrfs
(las escrituras fallan al excederse), así que conviene combinarlo con
retención (`x gen prune --keep N`) y dejar margen; los scripts nunca fijan un
límite solos.

## Sistema declarativo (`system.toml`)

La capa declarativa es estilo `configuration.nix`: un `system.toml`
reconciliado con `x gen plan` (solo lectura) y `x gen apply` (ejecuta y
registra una generación con `reason: apply`):

```toml
[system]
hostname = "x"
timezone = "UTC"
locale = "en_US.UTF-8"

[packages]
explicit = ["kitty", "neovim"]

[services]
enable = ["NetworkManager"]

[theme]
name = "x-dark"
```

`x gen plan system.toml` imprime las acciones (hostname/timezone/locale,
instalar/habilitar/tema) y `x gen apply` las ejecuta:

- `[system]` — hostname, timezone y locale se setean solo si difieren.
- `[packages] explicit` — los paquetes faltantes se instalan con
  `pacman -S --needed`; los instalados fuera de la declaración se reportan
  pero **se conservan** salvo `prune = true`.
- `[services] enable` — las units faltantes se habilitan con
  `systemctl enable`.
- `[theme] name` — se aplica vía `x theme set` como el usuario que invoca.
- `apply` soporta `--dry-run` y respeta `X_DRY_RUN=1`; las acciones de sistema
  necesitan root/sudo. Nunca elimina sin `prune`.
- Después de aplicar se registra una generación (best effort) para poder
  difearla o revertirla como cualquier otra.

## Todavía no implementado

Boot por selección en el menú (el rollback es un comando, como
`nixos-rebuild --rollback`), UKIs con Secure Boot y retención por tiempo.

## Tests

- `test/generations.sh` — creación, manifiestos, list, status/drift, diff,
  restore (path y `--pkg`).
- `test/generations-boot.sh` — entries de boot (systemd-boot + GRUB), kernel
  running vs congelado, retención del ESP, rollback, pin/unpin, prune, estado
  pending.
- `test/generations-multikernel.sh` — entries por pkgbase para `linux` +
  `linux-lts`, layout archivado y fallback legacy.
- `test/generations-system.sh` — parser de `system.toml`, acciones del plan,
  política de prune y apply en dry-run.
- `test/pacman-hooks.sh` — guards del wrapper (sin current, `X_GEN_SKIP`),
  reasons y archivos de hook instalados.
- `test/generations-export.sh` — round-trip export/import (metadata y datos),
  duplicados y restore desde una generación importada.
- `test/home-gens.sh` — generaciones de home: captura, exclusiones, drift,
  diff, restore, rechazo de escape de rutas, prune y despacho por CLI.
- `test/generations-btrfs.sh` — btrfs real con loop: `sudo bash
  test/generations-btrfs.sh` (se saltea sin root).

Los dos primeros corren en `test/smoke.sh`, sin root.
