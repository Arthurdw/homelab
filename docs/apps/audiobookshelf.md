# Audiobookshelf

Self-hosted audiobook and podcast server with a web UI and mobile apps. Single Node.js process with a
SQLite database.

- **Namespace:** `audiobookshelf`
- **Manifests:** `kubernetes/apps/audiobookshelf/` (this directory)
- **Status:** static L0 only — **not yet applied to any cluster** (values verified by `helm template`).

## Pins

| Component | Pin | Where | Verified |
|---|---|---|---|
| Helm chart | `2.5.1` | `release.yaml` (`chart.spec.version`), `source.yaml` | `helm search repo --versions`, 2026-10-16 (already latest) |
| App image | `2.37.1` | `release.yaml` (`image.tag`) | chart `values.yaml` / `appVersion` |

Recorded in `versions.yaml` (`helm_charts.audiobookshelf`). No pin change was needed — `2.5.1` is the
newest published chart.

## Ingress & authentication

- **Exposed:** only the web UI (the single Service, HTTP, port 8080) via an `Ingress`
  (`className: traefik`, TLS via the `internal-ca` ClusterIssuer).
- **Not exposed:** nothing else is published; Audiobookshelf has no separate administrative port (admin
  lives in the authenticated UI), so the single Ingress is the whole surface.
- **To whom:** the `*.invalid` placeholder resolves nowhere; once replaced with the real internal
  hostname the surface is intended for **LAN + Tailscale** clients only. There is **no public
  exposure** (`docs/decisions.md` §5.2).
- **Authentication:** Audiobookshelf's own users/roles (first-run root user). SSO via Authentik is
  **not** wired yet.
- **TODO:** Traefik TLS/redirect policy is still open in
  `kubernetes/infrastructure/traefik/release.yaml`.

## Storage

The chart creates the PVCs itself from the values in `release.yaml`.

| Volume | Contents | Class | Size | Why |
|---|---|---|---|---|
| `audiobookshelf-config` | **SQLite DB** (users/books/libraries/settings) + settings | `local-path` | 5Gi | DB must not be on network storage (`docs/decisions.md` §4.3) |
| `audiobookshelf-library` | audiobook/podcast media | `nas-nfs` | 500Gi | bulk data on the NAS (§4.1) |
| `audiobookshelf-metadata` | covers, cache, streams, downloads, logs | `nas-nfs` | 50Gi | regenerable but large; keep it off the node SSD |
| `audiobookshelf-backup` | the app's built-in logical backups | `nas-nfs` | 20Gi | recoverable copies survive node loss |

The chart's `config` doc-string says the config location "must not be mounted over the network" — this is
exactly why `config` (the SQLite DB) is on `local-path`. Its `library` doc-string repeats the same
sentence, but the library is bulk media, not the database, so it correctly goes on `nas-nfs`
(`docs/decisions.md` §4.1).

`nas-nfs` and `local-path` are **platform-provided StorageClasses** (Phase 6, `kubernetes/infrastructure`)
and are out of scope for this directory.

## Secrets

- **None required.** Audiobookshelf keeps its accounts inside the SQLite database (on `local-path`); the
  chart needs no external Secret and this directory creates none.
- If an integration ever needs a credential, follow the same rule as the other apps: reference an
  externally managed, SOPS-encrypted Secret by name (`.sops.yaml` fails closed until GATE 4) — never a
  cleartext Secret manifest.

## Resources

Single worker, 3 vCPU / 16 GiB, no HA.

| Workload | Requests | Limits |
|---|---|---|
| `audiobookshelf` | 100m / 256Mi | 1 / 1Gi |

## Backup & restore

- **Database (logical):** Audiobookshelf has a built-in backup feature that writes a consistent copy of
  the SQLite DB plus selected metadata into `BACKUP_PATH` (`/backups`, the `nas-nfs` `…-backup` PVC).
  **Enable the schedule in-app:** Settings → Backups (a scheduled task), so dumps land on the NAS
  automatically. This is the "scheduled logical dump to the NAS" for this app; it is configured in the
  UI rather than in IaC (the app has no chart value for the schedule).
- **Media:** the library on `nas-nfs` is covered by the NAS snapshot/backup policy for
  `main/apps/audiobookshelf`. Audiobooks are often re-downloadable → Tier 3 by default; user-uploaded
  or unique content should be re-tiered in `docs/backup-matrix.md`.
- **Restore (database):** stop the Deployment, restore the `config` PVC from a backup (or the app's own
  restore from `…-backup`), start the Deployment. Restore media by re-populating `…-library` from a NAS
  snapshot.
- **Classification:** `docs/backup-matrix.md` → "Audiobookshelf config/media" (classify media by
  replaceability — **open**).
- **Not yet done:** no restore performed (Phase 10); no backup monitoring yet (Phase 8).

## Upgrade & rollback

- **Chart bump:** change `chart.spec.version` in `release.yaml` (and `versions.yaml`), read the upstream
  changelog, one app at a time, verify after each (`docs/runbooks/upgrades.md`).
- **App version:** `image.tag`.
- **SQLite:** schema migrations run automatically on start; take a fresh backup before upgrading.
- **Rollback:** Flux/`helm` rolls the Deployment back to the previous image. Because the new version may
  have migrated the SQLite schema, restore the pre-upgrade backup if the old version must run again.

## Exposure summary

| Surface | Reachable from | Notes |
|---|---|---|
| audiobookshelf web UI | LAN + Tailscale (once hostname set) | the only exposed surface |

## Verification

```sh
helm template audiobookshelf christianhuth/audiobookshelf --version 2.5.1 \
  --namespace audiobookshelf --skip-tests --include-crds --kube-version 1.37.1 -f <values>
kubectl kustomize kubernetes/apps/audiobookshelf
```

## Open items / TODOs

- **Hostname** is a `.invalid` placeholder — replace at GATE 7 (internal DNS zone undecided).
- **Timezone** set to `Etc/UTC` — set to the owner's real TZ when handed over.
- **Scheduled backups** must be enabled in the app UI (Settings → Backups).
- **Authentik SSO** — not wired yet.
- **Restore drill** and **backup monitoring** — Phase 8/10.
- **StorageClasses** `nas-nfs` / `local-path` are provided by the platform layer.
