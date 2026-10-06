# x-scripts — visión general

`x-scripts` es el **payload de aprovisionamiento y CLI** del sistema x. Es el
repo `equislinux/scripts` (antes el repo `x`) y, junto con el resto de repos de la
organización `equislinux`, implementa la iniciativa *reboot* que sustituyó el
instalador gráfico basado en Calamares por aprovisionamiento por scripts
(mecánica Omarchy, implementación y branding propios). Ver ADR-0001/ADR-0002 en
`DECISIONS.md` en la raíz del workspace (`x-lnux`).

## Rol en la organización

| Repo  | Rol |
|-------|-----|
| `equislinux/x` | La distro: perfil archiso, builds ISO/WSL y flujo de instalación. |
| `equislinux/scripts` | **Este repo**: fases de aprovisionamiento, setup de usuario, CLI `x`, migraciones y temas, empaquetado como `x-scripts`. |
| `equislinux/xpkg` / `equislinux/xpm` | Tooling Rust de empaquetado/gestión de paquetes. |
| `equislinux/x-repo` | Repo de paquetes + portal. |

La distro (`x`) consume este repo empaquetado como el paquete `x-scripts`; el
instalador ejecuta las fases root (`x setup`) durante la instalación y la fase
de usuario (`x setup --user`) en el primer arranque. El tooling Rust
(`xpkg`/`xpm`) está fuera de alcance para el empaquetado por ahora (ver el doc
de packaging y el ROADMAP del workspace).

## Qué aporta este repo

- `install/` — orquestadores de fase para aprovisionamiento de sistema (root) y
  usuario, con helpers de sync idempotentes y los motores de generaciones
  (`xgen.sh` para snapshots del sistema, `xgen-home.sh` para dotfiles).
- `bin/` — la CLI `x` (dispatcher + subcomandos por convención de nombres),
  incluidos `x gen ...` y `x home ...`.
- `hooks/` — wrappers de hooks de pacman (`pacman-gen.sh`) referenciados por
  los drop-ins de `etc/pacman.d/hooks/`.
- `skel/`, `etc/`, `config/` — semillas de dotfiles para `/etc/skel`, drop-ins
  de `/etc` y configs de usuario.
- `hardware/`, `tools/` — módulos opcionales (NVIDIA, QEMU/libvirt, node) y el
  tool de setup del escritorio Hyprland.
- `migrations/`, `themes/` — migraciones por usuario y temas por paleta.
- `packaging/` — el PKGBUILD de `x-scripts` y el generador del snapshot de
  config offline (`vendor-config.sh`).
  payload).
- `test/` — tests locales sin root (`test/smoke.sh`).

## Rol en el sistema

En un sistema x instalado, el paquete instala todo bajo `/usr/share/x` y
expone la CLI como `/usr/bin/x` (un symlink a `/usr/share/x/bin/x`). El payload
es lo que convierte un Arch recién pacstrapeado en una máquina x aprovisionada:

1. Las fases root configuran el sistema (skel, drop-ins de `/etc`, módulos de
   hardware, servicios).
2. La fase de usuario siembra el home, sincroniza los dotfiles y aprovisiona el
   escritorio (stack Hyprland) **offline** desde un snapshot de config
   vendido.
3. `x` es la CLI del día a día para temas, migraciones y actualizaciones, más
   **generaciones**: `x gen` versiona el sistema (snapshots booteables,
   rollback, restore granular) y `x home` versiona los dotfiles del usuario.

Ver `cli.md`, `provisioning.md`, `generations.md`, `hyprland.md` y
`packaging.md`.

## Fuentes de configuración

Las configs de escritorio **no** se mantienen en esta organización: la org
equisdots es dueña del stack (`equisdots/hyprland`, `equisdots/shell`,
`equisdots/palettes`, `equisdots/theme-sync`, `equisdots/davincix`,
`equisdots/timex`, `equisdots/login`, `equisdots/dots`, rama `main`) y las
configs de apps vienen de `xscriptor-colors/terminal` (kitty/starship) y
`xscriptor-colors/nvim`. Todas se usan de solo lectura; el instalador oficial
es `equisdots/dots`. Un snapshot de todo el stack se vende dentro del paquete
para uso offline. Ver `hyprland.md` y ADR-0005.

## Rama y estado

Los entregables *reboot* de este repo se trackean en **`main`** (rama actual;
existe un `x/reboot` local de referencia). El seguimiento de fases en el
`ROADMAP.md` de este repo y del workspace está mayormente completo hasta la
etapa "distro instalable"; restos de auditoría pendientes para este repo
incluyen `x-base.packages` sin consumidor, pulido de CLI, más cobertura de
decisiones viven en los `ROADMAP.md`/`DECISIONS.md` de la raíz del workspace
(`x-lnux`).
WSL lives in its dedicated repos: equislinux/wsl and equislinux/wsl-scripts.
