# scripts — ROADMAP

Payload de aprovisionamiento + CLI `x`. La planificación principal vive en este
repositorio; el detalle por área está en `docs/`.

## Hecho

- Payload por fases (`install/`), CLI (`x setup`, `theme`, `migrate`, `update`,
  `hardware`, `info`) y flag `x setup --user --online`.
- Configs del escritorio empaquetadas offline como snapshot del stack
  equisdots (`packaging/vendor-config.sh`); tool de hyprland sin NVIDIA por
  defecto (fase hardware) con fallback al setup NVIDIA de equisdots.
- Docs en `docs/en` y `docs/es`; tambien en el repo wiki `equislinux/wiki`.
- Generaciones: motor `xgen` (snapshot btrfs booteable + manifiesto), CLI
  `x gen` (new/list/status/boot/rollback/diff/verify/pin/prune/restore/export/
  import), hooks de pacman pre/post, generaciones de home (`x home`) y docs
  en/es (ver `docs/en/generations.md`).

## Pendiente (auditoría)

- Clobber de `config.sh` (semántica de backup) y reauditoría de deps del
  PKGBUILD, alias + subargs del CLI.

## Sincronizacion

No hay sincronizacion roadmap->issues (workflow eliminado).
