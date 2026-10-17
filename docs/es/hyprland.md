# x — tool de setup de Hyprland/equisdots

`tools/hyprland-install.sh` es nuestro **setup de escritorio no interactivo**
para x. Aprovisiona el stack de escritorio de equisdots para el **usuario
target** (se niega a correr como root; las operaciones root van por sudo). Lo
invoca la fase de usuario (`install/user.sh`, controlado por `X_HYPRLAND`,
activo por defecto) y puede ejecutarse a mano.

Objetivos de diseño (ADR-0005):

- Las configs del escritorio viajan **offline** dentro del paquete
  `x-scripts` (snapshot de equisdots) y se despliegan sin clonar nada en el
  setup de un sistema instalado.
- La org equisdots es la fuente de verdad y su instalador oficial es
  [`equisdots/dots`](https://github.com/equisdots/dots); sus repos se usan
  **de solo lectura**, nunca se integran ni se modifican. El fallback online
  delega la colocación del payload en `dots install`.
- **NVIDIA es propiedad de la fase hardware de X** (`hardware/nvidia.sh`). El
  tool nunca instala drivers por su cuenta; solo cuando hay GPU NVIDIA y
  ningún driver instalado recurre al setup NVIDIA de equisdots
  (`hyprland/install.sh --nvidia-only`), y cuando el driver ya existe solo
  completa la pieza `envycontrol`/sudoers que usa `gpu-mode.sh`. La fase
  completa `dots system` nunca corre aquí.

## Fuentes de verdad (externas, rama `main`)

| Repo | Contenido vendido |
|------|-------------------|
| `equisdots/hyprland` | Config Lua (`hyprland.lua`, módulos, `hypridle.conf`), `rofi`, `dunst`, `cava`, `pam.d/quickshell` y `scripts` (helpers que caen en `~/.config/hypr/scripts`). |
| `equisdots/shell` | UI Quickshell (barra, popups, paneles, lock) → `~/.config/hypr/scripts/quickshell`. |
| `equisdots/palettes` | Set de paletas JSON + schema → `.../quickshell/dock/palettes`. |
| `equisdots/theme-sync` | Motor de theming cross-app (`~/.local/bin/theme-sync`). |
| `equisdots/davincix` | Kernel del motor de wallpapers (`~/.local/bin/davincix`). |
| `equisdots/timex` | Motor de hora/clima + UI (`~/.local/bin/timex`, `.../quickshell/ui/timex`). |
| `equisdots/login` | Greeter SDDM estático y minimal (instalación de sistema puntual). |
| `equisdots/dots` | Meta instalador/updater + `install-xwww.sh` standalone. |
| `xscriptor-colors/terminal` | kitty (`emulators/kitty`) y starship (`prompts/starship`). |
| `xscriptor-colors/nvim` | todo el árbol de config de nvim. |

El snapshot vendido vive en `/usr/share/x/config` en un sistema instalado (lo
produce `packaging/vendor-config.sh`; ver `packaging.md`). `config/hypr/` en
este repo es solo un punto de entrada documental más el wallpaper por defecto;
no es la config del escritorio.

## Cómo funciona el tool

1. **Resolver el payload.**
   - Offline (por defecto en un sistema instalado): usa el snapshot de
     equisdots en `/usr/share/x/config/equisdots`; no se clona nada.
   - Override: `X_HYPR_SOURCE=<raíz del snapshot>` (tests/dev; el árbol del
     llamante nunca se modifica).
   - Fallback (sin snapshot, p. ej. un checkout de desarrollo): clona
     `equisdots/dots` (`--depth 1`, rama `X_HYPR_REF`) y ejecuta
     `dots install`, la colocación oficial. `X_HYPR_OFFLINE=1` prohíbe el
     clon.
2. **Paquetes.** Quita primero los `quickshell`/`swayosd` oficiales (la config
   apunta a las versiones `-git`), instala una lista oficial (stack Hyprland,
   portales xdg, qt5/qt6 wayland, sddm, rofi + rofi-emoji, kitty, starship,
   dunst, satty, gpu-screen-recorder, pipewire, red, fuentes, ...) con
   `pacman -S --needed`, y paquetes AUR (`quickshell-git`, `swayosd-git`,
   `bibata-cursor-theme`, `mpvpaper`, `networkmanager-dmenu-git`) vía un
   `yay`/`paru` existente, instalando `yay` si no hay ninguno. Los fallos se
   avisan, no son fatales.
3. **Payload de usuario.**
   - Offline: prepara el snapshot en `~/.local/share/equisdots` y replica
     exactamente `dots install`: config de hyprland → `~/.config/hypr`,
     rofi/dunst/cava → `~/.config`, scripts → `~/.config/hypr/scripts`
     (purgando artefactos legacy pre-equisdots), shell → `.../quickshell`,
     paletas → `.../quickshell/dock/palettes`, wrappers en `~/.local/bin`
     (`dots`, `theme-sync`, `davincix`, `timex`), UI de timex, semilla y
     migración de `settings.json` con `jq`, y el timer mensual de dotfiles.
   - Online: `dots install` hace esa colocación.
4. **Configs de apps (offline).** kitty, starship
   (`~/.config/equisdots/starship`) y nvim desde el snapshot; después el motor
   `theme-sync` regenera los artefactos de paleta
   (kitty/starship/nvim/rofi/cava/qt/gtk/...).
5. **xwww.** Instala el daemon de wallpapers (lo necesita davincix) con el
   instalador standalone de equisdots (release verificado por checksum,
   fallback a build desde fuente) cuando falta `xwww-daemon`.
6. **Fuente.** Instala Hack Nerd Font para el usuario (descarga) y la copia a
   `/usr/share/fonts`.
7. **Login + PAM + servicios.** Instala el tema SDDM estático
   (`equisdots/login`), escribe `/etc/pam.d/quickshell` y habilita
   NetworkManager, SDDM, power-profiles-daemon, swayosd-libinput-backend,
   bluetooth y los servicios de pipewire del usuario.
8. **NVIDIA.** Si hay GPU NVIDIA y ningún driver instalado, ejecuta el
   `hyprland/install.sh --nvidia-only -y` upstream. Si el driver ya está,
   solo completa la función GPU mode de equisdots: instala `envycontrol` (AUR,
   si falta) con la regla passwordless `/etc/sudoers.d/99-gpu-mode` que usa
   `gpu-mode.sh`.
9. Escribe `~/.local/state/equisdots-version`, asegura `~/.local/bin` en el
   PATH de los shells e imprime el mensaje de finalización.

## Comandos de usuario y recuperación

`dots`, `theme-sync`, `davincix` y `timex` son wrappers en `~/.local/bin` que
apuntan a los repos bajo `~/.local/share/equisdots`. El tool añade ese
directorio al PATH de cada rc existente (y crea `~/.profile` si no hay
ninguno); `skel/.bashrc` ya lo exporta, así que los logins por TTY (vía
`~/.bash_profile`) siempre pueden alcanzarlos. Cada paso del despliegue es
best-effort: los wrappers se escriben aunque falle un paso posterior.

Si el escritorio no arranca, el stack puede repararse desde una TTY:

```bash
x setup --user     # re-desplegar configs/payload (snapshot offline)
dots install       # clonar/actualizar el payload
dots doctor        # comprobar dependencias, clones y rutas instaladas
```

## Modos de despliegue

- **Offline (por defecto en un sistema instalado):** usa el snapshot de
  equisdots incluido en `x-scripts` (`/usr/share/x/config`).
- **Online (`X_HYPR_ONLINE=1`):** ignora el snapshot, clona `equisdots/dots`
  (ref configurable con `X_HYPR_REF`), ejecuta su `dots install` oficial
  (repos, plugins y merge de settings) y descarga las configs de apps
  (kitty/starship/nvim) desde `xscriptor-colors`. Si falla, el instalador cae
  al snapshot.

El instalador elige el modo con `hyprland=yes` (snapshot) o
`hyprland=online` (lo último desde GitHub; `hyprland_ref` opcional en el JSON).

## Flags / entorno

| Variable | Default | Significado |
|----------|---------|-------------|
| `X_HYPR_CONFIG` | `/usr/share/x/config` | Árbol de config empaquetado (offline). |
| `X_HYPR_SOURCE` | — | Override de la raíz del snapshot (`$X_HYPR_SOURCE/equisdots`); solo lectura. |
| `X_HYPR_REF` | `main` | Rama/commit del clon de fallback `equisdots/dots`. |
| `X_HYPR_ONLINE` | `0` | `1` = ignorar el snapshot y desplegar lo último desde GitHub. |
| `X_APP_REF` | `main` | Rama/commit de las configs de apps (solo modo online). |
| `X_HYPR_BASE` | `~/.local/share/equisdots` | Destino de clones/wrappers. |
| `X_HYPR_DRYRUN` | `0` | `1` = resolver la fuente y solo imprimir el plan (sin instalar). |
| `X_HYPR_OFFLINE` | `0` | `1` = forzar offline; falla en vez de clonar. |
| `X_HYPR_KEEP_SRC` | `0` | `1` = conservar el clon temporal de `equisdots/dots`. |

```bash
# solo plan, desde un snapshot (sin cambios)
X_HYPR_DRYRUN=1 X_HYPR_SOURCE=/ruta/a/x-config bash tools/hyprland-install.sh
# solo plan, árbol offline
X_HYPR_DRYRUN=1 X_HYPR_CONFIG=/usr/share/x/config bash tools/hyprland-install.sh
# solo plan, modo online (sin red en dry-run)
X_HYPR_DRYRUN=1 X_HYPR_ONLINE=1 bash tools/hyprland-install.sh
# setup completo para el usuario actual
bash tools/hyprland-install.sh
```

Ejecutar siempre como el usuario target; `test/smoke.sh` ejercita
`X_HYPR_DRYRUN` y los overrides de snapshot sin root.
