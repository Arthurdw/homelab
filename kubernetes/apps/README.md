# Apps

User-facing workloads. Each app is a directory containing a `kustomization.yaml`, an optional Flux
`source` (HelmRepository/OCIRepository) and a `HelmRelease` (or plain manifests).

`host-proxies/` (Traefik routes to the Proxmox and TrueNAS UIs) is homelab-only: it is listed by
`kubernetes/overlays/homelab/apps`, not by `kustomization.yaml` here, because the lab has no such hosts.

`stremio/` is the Stremio streaming server: local-only (SPEC §12.6), no Authentik, no Cloudflare tunnel route, no
Secret. Its access boundary is internal DNS plus a private-ranges ipAllowList (`docs/runbooks/stremio.md`).

Secrets are SOPS-encrypted and created out-of-band (`docs/runbooks/secrets.md`).

Recovery-critical app data (Immich DB + media, Audiobookshelf library) is in the backup matrix —
see `docs/backup-matrix.md`.
