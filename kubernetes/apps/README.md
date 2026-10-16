# Apps

User-facing workloads. Each app is a directory containing a `kustomization.yaml`, an optional Flux
`source` (HelmRepository/OCIRepository) and a `HelmRelease` (or plain manifests).

**Status:** scaffold. Values are intentionally minimal (`values: {}` with TODO markers) so nothing is
invented; production values, persistence and secrets are decided at GATE 0 and wired here.

Recovery-critical app data (Immich DB + media, Audiobookshelf library) is in the backup matrix —
see `docs/backup-matrix.md`.
