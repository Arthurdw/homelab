# Backup Matrix

> **Template + current draft.** Every important dataset/workload needs a row. Values marked **TBD** are
> unconfirmed — do not treat them as decided. Governed by `docs/backup-policy.md`.

Legend: **T** = tier · **Irrep.** = irreplaceable? · **Snap** = local snapshot policy · **Off** = offsite?
**Mech** = mechanism · **Restore** = restore procedure reference.

## Datasets (TrueNAS `main`) — current state, to be redesigned

| Dataset / dir | T | Irrep. | Auth. source of truth | Snap | Off | Mech | Schedule | Retention | Encryption | Restore | Monitoring |
|---|---|---|---|---|---|---|---|---|---|---|---|
| `main` personal dirs (TBD which) | TBD | likely yes (photos/docs) | local | **TBD** | **TBD** | TBD | TBD | TBD | yes | TBD | TBD |
| `main` media (movies/shows) | 3 | no | re-downloadable | optional | no | — | — | — | n/a | re-download | n/a |
| `main/ix-apps/...` (app data, 490 G s3 export) | TBD | TBD | app | **none today** ⚠️ | TBD | TBD | TBD | TBD | yes | TBD | TBD |
| `main/backups/timemachine/jolien` | 2 | no (copy of the Mac) | Mac | daily / 7 d | no | Time Machine over SMB, encrypted on the Mac | hourly while the Mac is on | Time Machine's own thinning | yes (client) | `runbooks/household-backups.md` (a) | TBD |
| `main/tier1/jolien/photos` | 1 | yes (RAWs, client work) | her external drives | hourly / 30 d (tier1 task) | yes (deferred, §5.5) | FreeFileSync "Update" over SMB, re-run by RealTimeSync | on change, and when a drive is plugged in | nothing deleted by the sync; ZFS 30 d | none at rest (§5.17) | `runbooks/household-backups.md` (d) | TBD (FreeFileSync logs on the Mac only) |
| `main/backups/kopia` | 2 | yes (only copy of the Windows and Linux backups) | repo | daily / 14 d | yes (deferred, §5.5) | Kopia client to the repository server, client-side encryption | daily per client | per policy: 14 daily / 8 weekly / 12 monthly | yes (client) | `runbooks/household-backups.md` (b); `kopia` CLI works without the cluster | TBD |
| `main/apps/seafile` | TBD | yes | app | hourly / 14 d | yes (deferred, §5.5) | ZFS snapshots + DB dump | hourly | 14 d | TBD | restore needs the dump and this dataset from the same time (§5.8); `scripts/backup/db-restore-test.sh seafile` proves the dump (lab: 195 tables, 3 databases) | TBD |
| `main/proxmox` (incl. 3 TB VM disk) | TBD | TBD | VM | **TBD** | TBD | TBD | TBD | TBD | yes | TBD | TBD |

## Workloads / configuration

| Item | T | Irrep. | Auth. source of truth | Off | Mech | Notes |
|---|---|---|---|---|---|---|
| TrueNAS config export | 2 | yes | NAS | yes | file | export after each config change |
| OpenTofu state (per system) | 2 | yes | backend | yes | encrypted | recoverable without cluster |
| Talos machine secrets + kubeconfig | 2 | yes | Vault/offline | yes | encrypted | never in repo |
| SOPS/age private key | 2 | **critical** | offline escrow | yes | offline | losing it loses all encrypted secrets |
| Immich DB + media | TBD | likely yes | app | yes | DB dump + media backup | related recovery set; order matters. Dump: daily `pg_dump` (`kubernetes/apps/immich/backup.yaml`), same alerts and `scripts/backup/db-restore-test.sh immich` (lab: restored, 71 tables) |
| Authentik DB + `authentik-credentials` Secret | TBD | yes (users, flows, providers) | app | TBD | daily `pg_dump` to `nas-nfs` (`kubernetes/apps/authentik/backup.yaml`), 14 kept; alerts on stale, failed and size-anomalous dumps | restore with the same `secret-key`; `scripts/backup/db-restore-test.sh authentik` proves the dump (lab: restored, 230 tables) |
| Dunia/arthur devices (Kopia clients) | 2 | yes | the device | yes, via `main/backups/kopia` | Kopia snapshot of the home dir | decisions §5.9; run `kopia snapshot list` after setup and check each client has a snapshot under a week old |
| Audiobookshelf config/media | TBD | depends | app | TBD | TBD | classify media by replaceability |
| free-games-claimer data (`local-path`) | 3 | no | the stores | no | none | browser profile and claim logs; on loss, log in again via noVNC (`docs/runbooks/free-games-claimer.md`) |
| Flux repo (+ secret decryption) | 2 | yes | Git | yes | Git + encrypted secrets | repo is public; secrets separate |
| UniFi config export | 2 | yes | UDM Pro | yes | file | export before each change |
| Proxmox VM configs | 2 | yes | host | yes | file | `/etc/pve` export |

## Rules

- A dataset without a tier is **unclassified** and must be flagged, not assumed backed up.
- Media that is re-downloadable defaults to **Tier 3** (local only) unless the owner marks an exception.
- Snapshots are **not** backups of the same pool.

## Open items

- Decide which `main` directories are **T1** (owner input).
- Choose offsite mechanism + destination.
- Per-dataset snapshot retention.
- Restore procedures per row (link to `docs/disaster-recovery.md` when written).
