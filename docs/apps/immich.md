# Immich

Self-hosted photo & video library. Serves the web UI/API and runs background jobs (thumbnails,
transcoding, smart search) plus a machine-learning worker.

- **Namespace:** `immich`
- **Manifests:** `kubernetes/apps/immich/` (this directory)
- **Status:** static L0 only — **not yet applied to any cluster** (values verified by `helm template`).

## Pins

| Component | Pin | Where | Verified |
|---|---|---|---|
| Helm chart | `0.13.4` (`appVersion v3.2.0`) | `source.yaml` (`ref.tag`), `release.yaml` | `helm show chart` (OCI), 2026-10-16 |
| Immich server / ML image | `v3.2.0` | `release.yaml` (`controllers…image.tag`) | chart `values.yaml` default / README requires the tag |
| PostgreSQL image | `14-vectorchord0.4.3-pgvectors0.2.0@sha256:bcf6335…` | `postgres.yaml`, `backup.yaml` | exact tag@digest from Immich `docker/docker-compose.yml` |
| Valkey image | chart default (`9.1.2-alpine@sha256:48332…`) | `release.yaml` (`valkey.enabled`) | chart `values.yaml` |

Chart version is recorded in `versions.yaml` (`helm_charts.immich`); the DB image is in
`versions.yaml` (`app_images.immich_postgres`). Image **tags** are used for the Immich/ML images
(the chart does not expose a digest-only switch here); the database image is pinned by **tag@digest**
because it is the most safety-critical and upstream pins it that way.

## Ingress & authentication

- **Exposed:** only the web UI/API service (`immich-server`, HTTP, port 2283) via an `Ingress`
  (`className: traefik`, TLS via the `internal-ca` ClusterIssuer).
- **Not exposed:** PostgreSQL (`immich-postgres`), Valkey (`immich-valkey`) and `machine-learning` are
  `ClusterIP`-only (the DB Service is headless) and have **no Ingress**. They are reachable only from
  inside the cluster.
- **To whom:** the `*.invalid` placeholder resolves nowhere; once replaced with the real internal
  hostname the surface is intended for **LAN + Tailscale** clients only. There is **no public
  exposure** (no DMZ, no inbound ports — `docs/decisions.md` §5.2).
- **Authentication:** Immich's own account system (first-run admin, per-user accounts). SSO via
  Authentik is **not** wired yet. Immich has no separate administrative port — admin functions live in
  the authenticated web UI, so the exposure statement above covers them.
- **TODO:** Traefik TLS/redirect and per-entrypoint policy are still open in
  `kubernetes/infrastructure/traefik/release.yaml`; the chart's default nginx `proxy-body-size`
  annotation is ignored by Traefik (harmless).

## Storage

| Volume | Contents | Class | Size | Why |
|---|---|---|---|---|
| `immich-library` (PVC, `library-pvc.yaml`) | original + generated media | `nas-nfs` | 500Gi | bulk data belongs on the NAS (`docs/decisions.md` §4.1) |
| `data` (StatefulSet `volumeClaimTemplate`) | PostgreSQL data dir | `local-path` | 20Gi | DB must not live on network storage (§4.3) |
| `immich-db-backups` (PVC, `backup.yaml`) | `pg_dump` logical dumps | `nas-nfs` | 20Gi | consistent copies on the NAS |
| ML model cache (chart PVC) | downloaded ML models | `local-path` | 10Gi | disposable cache; node SSD keeps it off the NAS |

`nas-nfs` and `local-path` are **platform-provided StorageClasses** (Phase 6, `kubernetes/infrastructure`)
and are out of scope for this directory. `ReadWriteOnce` is used throughout: there is a single worker
node, and NFS does not enforce single-mount exclusivity, so rolling updates overlap cleanly.

## Secrets

- Requires an externally managed Secret **`immich-db`** in namespace `immich`, keys `username` and
  `password` (referenced by name from `release.yaml`, `postgres.yaml`, `backup.yaml`).
- **Not created here.** It must be a SOPS-encrypted Secret (e.g. `kubernetes/apps/immich/immich-db.sops.yaml`)
  committed only after the production age recipient exists (`.sops.yaml` fails closed until GATE 4).
- TODO(secrets): create `immich-db` via `scripts/secrets/encrypt.sh`; no credential is ever committed
  in cleartext.

## Resources

Single worker, 3 vCPU / 16 GiB, no HA — requests are deliberately modest.

| Workload | Requests | Limits |
|---|---|---|
| `immich-server` | 250m / 512Mi | 1 / 2Gi |
| `immich-machine-learning` | 500m / 1Gi | 2 / 4Gi |
| `immich-valkey` | 50m / 64Mi | 250m / 256Mi |
| `immich-postgres` | 250m / 512Mi | 1 / 2Gi |

## Backup & restore

> **Immich media and its database are ONE recovery set.** A `pg_dump` without the matching media
> library (or vice-versa) is internally inconsistent: the DB stores asset metadata, hashes and
> references that only make sense alongside exactly the media it was taken with. They **must** be
> backed up, versioned and restored **together and consistently** — the dump in `backup.yaml` is not a
> complete Immich backup on its own.

- **Mechanism:** daily `pg_dump --format=custom` → `immich-db-backups` on the NAS (`CronJob`
  `immich-db-dump`, 03:17 UTC, keeps the 14 newest). The media library on `nas-nfs` is covered by the
  NAS snapshot/backup policy for `main/apps/immich`.
- **Ordering for a consistent set:** take/keep NAS snapshots of the media and the dumps in the same
  window, and restore the DB first, then the media, then start Immich.
- **Restore (logical dump):**

  ```sh
  # into the running database (or a scratch database first):
  kubectl -n immich exec -i statefulset/immich-postgres -- \
    pg_restore --clean --if-exists --no-owner --no-privileges \
      --username=<user> --dbname=immich < immich-<timestamp>.dump
  ```

- **Restore (media):** re-populate `immich-library` from the NAS snapshot of `main/apps/immich`.
- **Classification:** Tier 2/1 candidate (irreplaceable personal photos). Listed in
  `docs/backup-matrix.md` as "Immich DB + media" — **related recovery set; order matters**.
- **Not yet done:** no restore has been performed (Phase 10 drill); the cron dump is not yet
  monitored (Phase 8 alerts: last-success age).
- TODO(storage): confirm the `nas-nfs` export lets uid/gid `999` write (the dump job runs as that uid).

## Upgrade & rollback

- **Chart bump:** change `ref.tag` in `source.yaml` (and `versions.yaml`), read the upstream changelog,
  one app at a time, verify after each (`docs/runbooks/upgrades.md`).
- **App version:** `controllers.main.containers.main.image.tag` — the chart does **not** follow Immich
  releases, so this must be bumped deliberately.
- **Database:** immutable-ish; **do not** jump PostgreSQL major versions in place. Immich upgrades must
  match the migrations shipped in the app version.
- **Rollback:** `helm`/Flux rolls back the Deployment to the previous image; the DB schema may already be
  migrated forward, so **restore the DB dump from before the upgrade** if a downgrade needs the old
  schema. Always take a manual dump immediately before an upgrade:

  ```sh
  kubectl -n immich create job --from=cronjob/immich-db-dump immich-db-dump-preupgrade
  ```

- **Chart rollback:** Flux reverts `ref.tag`; nothing here mutates cluster-scoped resources.

## Exposure summary

| Surface | Reachable from | Notes |
|---|---|---|
| `immich-server` web UI/API | LAN + Tailscale (once hostname set) | the only exposed surface |
| PostgreSQL, Valkey, machine-learning | cluster-internal only | never given an Ingress |
| `immich-db-dump` CronJob | n/a | batch job, no Service |

## Verification

```sh
helm template immich oci://ghcr.io/immich-app/immich-charts/immich --version 0.13.4 \
  --namespace immich --skip-tests --include-crds --kube-version 1.37.1 -f <values>
kubectl kustomize kubernetes/apps/immich
```

## Open items / TODOs

- **Hostname** is a `.invalid` placeholder — replace at GATE 7 (internal DNS zone undecided).
- **`immich-db` Secret** — create (SOPS-encrypted) before first deploy.
- **Authentik SSO** — not wired yet.
- **Restore drill** and **backup monitoring** — Phase 8/10.
- **DB container hardening** — prove running as uid 999 (needs a writable `/etc/postgresql`).
- **StorageClasses** `nas-nfs` / `local-path` are provided by the platform layer.
