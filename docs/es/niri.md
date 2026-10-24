# x — herramienta de instalación de niri/equisdots

`tools/niri-install.sh` es el instalador no interactivo del escritorio
niri/equisdots para X Linux. Se ejecuta como **usuario destino** (nunca como
root) y delega el stack en el meta instalador oficial
[`equisdots/niri-meta`](https://github.com/equisdots/niri-meta) (`dotsniri`) en
modo online.

## Qué hace

1. Clona o actualiza `equisdots/niri-meta` en la caché del usuario
   (`$XDG_CACHE_HOME/x/niri-meta`, ref `main` por defecto).
2. Ejecuta `dotsniri setup -y`: instala los paquetes del stack niri (niri,
   xwayland-satellite, quickshell, portales, herramientas de sesión, fuentes,
   ...), clona los repos propios/compartidos de equisdots, despliega la shell
   Quickshell compartida, los overlays de niri, plugins, configs de apps,
   unidades de usuario y la entrada de sesión niri.
3. Selecciona niri como escritorio por defecto (`dotsniri desktop niri`).
4. Instala el tema SDDM estático de X/equisdots (desde el clon compartido
   `equisdots/login`) y habilita `sddm`.

Los repos de equisdots son entradas de solo lectura; no se modifica nada de la
org equisdots. La raíz de datos compartida sigue siendo `~/.config/hypr`; la
config del compositor niri vive en `~/.config/niri`.

## Entorno

| Variable | Default | Significado |
|---|---|---|
| `X_NIRI_REF` | `main` | Rama/ref de niri-meta a clonar/actualizar. |
| `X_NIRI_CACHE_DIR` | `$XDG_CACHE_HOME/x` | caché de clones. |
| `X_NIRI_DRYRUN` | `0` | imprime el plan sin tocar el sistema. |
| `X_NIRI_SKIP_LOGIN` | `0` | no instala el tema SDDM ni habilita sddm. |

El instalador de texto crea un `%wheel NOPASSWD: ALL` temporal durante el
setup, porque `dotsniri` instala paquetes, PAM, la entrada de sesión y el tema
de login con sudo.

## Validación

```bash
bash -n tools/niri-install.sh
X_NIRI_DRYRUN=1 tools/niri-install.sh
niri validate -c ~/.config/niri/config.kdl
dotsniri doctor
```
