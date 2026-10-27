# Runbooks

Operational, step-by-step procedures. Keep them executable by someone (or something) who was not there when
the system was built.

- `upgrades.md` — ordered, reversible upgrade procedures for every layer.
- `host-network-bootstrap.md` — after a fresh install, put Proxmox and TrueNAS on their VLAN 4 management
  addresses and the storage link.
- `launch.md` — the owner's ordered go-live checklist for the real hosts, from credentials to Flux.
- `talos-bootstrap.md` — turn freshly booted Talos nodes into a Kubernetes cluster.
- `secrets.md` — SOPS + age: key ceremony, add/rotate, recovery, CI.
- `sso.md` — Authentik as the login portal: the OIDC values to paste into Immich and Audiobookshelf, Immich's SMTP.
- `host-proxies.md` — Proxmox and TrueNAS UIs at `pve`/`nas.lab.ardw.be` through Traefik; refreshing the pinned certs.
- `stremio.md` — pointing the Stremio apps at `stremio.lab.ardw.be`; why it is local-only.
- `free-games-claimer.md` — first store logins via noVNC, the optional login Secret, the Epic captcha.
- `flux.md` — Flux dashboards and alert in Grafana, Capacitor as a local UI, the CLI equivalents.
- `break-glass.md` — access by IP and local credentials when DNS, SSO, Traefik or MetalLB are down.
- `household-backups.md` — Time Machine for the Mac, Kopia for Windows and Linux, Seafile client.
- `public-shares.md` — Seafile and Immich share links through the Cloudflare Tunnel: setup, outside checks, rollback.
- `phase-reports/` — historical build reports: `phase-01-10-scaffold.md`, `phase-lab-virt-2026-10-20.md`.
- `../disaster-recovery.md` — recovery after losing part or all of the homelab.
- `../secrets-and-state.md` — how secrets and state are stored and recovered.
- `../backup-policy.md` / `../backup-matrix.md` — what is backed up and how it is verified.

Conventions: every runbook states its **pre-checks**, its **rollback**, and its **verification**. If a step
can lose data, it says so and requires explicit confirmation.
