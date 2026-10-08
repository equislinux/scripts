# x — empaquetado

El payload de aprovisionamiento se empaqueta como **`x-scripts`** con un
**PKGBUILD + makepkg** simple en `packaging/`. (El tooling Rust `xpkg`/`xpm`
queda fuera del alcance de empaquetado por ahora; ver el ROADMAP del
workspace, Fase 4.)

## Construir `x-scripts`

`packaging/PKGBUILD` produce el paquete Arch (`any`, depende de `bash`):

- Instala `bin`, `install`, `skel`, `etc`, `config`, `hardware`, `tools`,
  `migrations`, `themes` y `hooks` en **`/usr/share/x`**.
- Hace ejecutables todos los `*.sh` (y el dispatcher `x`) bajo
  `/usr/share/x/{bin,install,hardware,tools,hooks}`.
- El overlay de `/etc` lo aplica `x setup` (`install/config.sh`). Los hooks de
  pacman van en el paquete (`hooks/alpm/*.hook` →
  `/usr/share/libalpm/hooks/`); `hooks/pacman-gen.sh` es el wrapper que llaman
  (ver `provisioning.md` y `generations.md`).
- Instala `/usr/bin/x` como symlink a `/usr/share/x/bin/x`.
- Si existe `packaging/.vendor/x-config`, sus contenidos se fusionan en
  `/usr/share/x/config` (el snapshot offline del escritorio que usa
  `tools/hyprland-install.sh`). **No hay entradas remotas en `source=()`**: el
  snapshot se vende en el repo y nunca se descarga en el build.

Metadatos de versión: `pkgver=0.1.0`, `pkgrel` se sube por iteración
(actualmente 13 en el PKGBUILD). Puede quedar un artefacto de build antiguo
(`*.pkg.tar.zst`) en el directorio, pero es stale y está git-ignored; al
reconstruir se produce el pkgrel actual.

Para construir (sin red para las fuentes de config; el árbol vendido debe
existir primero, ver abajo):

```bash
cd packaging
makepkg   # requiere packaging/.vendor/x-config presente
```

`packaging/.gitignore` ignora `src/`, `pkg/`, `.vendor/` y los artefactos
construidos.

## `vendor-config.sh` — el snapshot offline

`packaging/vendor-config.sh` regenera el snapshot vendido en
**`packaging/.vendor/x-config`** desde los repos externos de origen (rama
`main`), que se usan de solo lectura y siguen siendo la fuente de verdad:

- `equisdots/{dots,hyprland,shell,palettes,theme-sync,davincix,timex,login}`
  → `equisdots/<repo>` (todo el stack de escritorio; `equisdots/dots` es el
  instalador oficial y trae el `install-xwww.sh` standalone).
- `xscriptor-colors/terminal` → solo kitty (`kitty.conf` + `themes/`) y
  starship (`prompts/starship`: plantilla + temas).
- `xscriptor-colors/nvim` → todo el árbol de `nvim`.

Comportamiento:

- Se niega a correr como root; requiere `git` y acceso a red (clones shallow).
- Elimina `.git`/`.github` de cada clon y del árbol final.
- Verifica que estén los archivos clave del stack (config Lua de hyprland,
  política PAM, entry point del shell, paletas, motores, instalador de login,
  kitty/starship/nvim).
- No se excluye nada de NVIDIA: el snapshot queda completo para que el tool
  pueda recurrir al setup NVIDIA upstream de equisdots cuando haga falta (la
  fase hardware de X sigue siendo la dueña de la instalación del driver).
- Nunca modifica los repos externos.
- Imprime los commits fijados de las fuentes y un conteo de archivos por
  directorio.

```bash
packaging/vendor-config.sh        # desde la raíz del repo
packaging/vendor-config.sh /path/to/repo
```

La salida `.vendor` es **git-ignored**, así que un mantenedor debe
(re)generarla antes de construir; no forma parte del historial de git.
`config/hypr/README.md` documenta el mismo flujo.

### Reproducibilidad (`vendor-config.lock`)

Los commits resueltos se registran en **`packaging/vendor-config.lock`**
(trackeado). En la siguiente ejecución cada clon se deja en su commit fijado (se
descarga directo con `git fetch --depth 1 origin <sha>`), así que reconstruir el
paquete desde el mismo lock produce el mismo snapshot. El lock se reescribe
cuando cambia: commitéalo junto con el snapshot regenerado.

- `X_VENDOR_BRANCH=ref` — rama a clonar (default `main`).
- `X_VENDOR_NO_LOCK=1` — ignorar el lock (resolver los tips de rama) y reescribirlo.
- `X_VENDOR_LOCK=path` — override del fichero de lock.

## Layout vendido

```
packaging/.vendor/x-config
├── equisdots/
│   ├── dots/ hyprland/ shell/ palettes/ theme-sync/ davincix/ timex/ login/
├── kitty/     (kitty.conf + themes/)
├── starship/  (starship.toml + themes/)
└── nvim/      (árbol de config completo)
```

El PKGBUILD lo instala como `/usr/share/x/config`; refleja el layout de
`~/.local/share/equisdots` que usa `dots install` (`equisdots/<repo>`), que es
exactamente como lo consume `tools/hyprland-install.sh` en offline.

## Uso offline en la ISO

El sentido del vendoring es que un **escritorio Hyprland/equisdots pueda
aprovisionarse offline** justo después de instalar:

1. Un mantenedor ejecuta `vendor-config.sh` y construye `x-scripts` (snapshot
   embebido en el paquete).
2. La distro (`equislinux/x`) instala `x-scripts` en el destino y corre las fases
   root durante la instalación.
3. En el primer arranque la fase de usuario ejecuta
   `tools/hyprland-install.sh`, que encuentra
   `/usr/share/x/config/equisdots` y despliega todo el escritorio **sin clonar
   nada externo**. La instalación de paquetes (oficiales + AUR + la release de
   xwww) es lo único que necesita repositorio/red: las configs viajan dentro
   del paquete.

Notas / estado actual (del ROADMAP del workspace):

- `x-base.packages` (la lista base legible por el builder) se empaqueta pero
  aún no tiene consumidor cableado en el builder de la distro.
- El bundling de un mirror offline en la distro (instalación 100% sin red)
  sigue siendo una mejora pendiente en `equislinux/x`.
