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
| Immich server image | `v3.2.0` | `release.yaml` (`controllers…image.tag`) | chart `values.yaml` default / README requires the tag |
| Immich ML image | `v3.2.0-cuda` | `release.yaml` (`machine-learning…image.tag`) | Immich's CUDA build of the same release; Renovate groups it with the server |
| PostgreSQL image | `16-vectorchord0.4.3-pgvectors0.2.0@sha256:1a078b2…` | `postgres.yaml`, `backup.yaml` | Immich's own image for PG16; moved from 14 on 2026-10-23 by dump and restore |
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
- **To whom:** the host is `immich.lab.ardw.be` (`docs/decisions.md` §5.7), resolved only by the
  internal Technitium resolver. Immich itself is for **LAN + Tailscale** clients only (no DMZ, no inbound
  ports — `docs/decisions.md` §5.2).
- **Public share links** (`docs/decisions.md` §5.13): `photos.ardw.be` reaches only
  **immich-public-proxy** (`public-proxy.yaml`, Service port 3000) through the homelab Cloudflare Tunnel. It
  serves `/share/<key>` anonymously, needs no API key, hides EXIF/location metadata and follows each share's
  download toggle. Immich's `server.externalDomain` is set to `https://photos.ardw.be` by
  `just immich-external-domain`, so the links Immich shows point at the proxy. Owner steps:
  `docs/runbooks/public-shares.md`.
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

`nas-nfs` and `local-path` are **platform-provided StorageClasses** (`kubernetes/infrastructure`)
and are out of scope for this directory. `ReadWriteOnce` is used throughout: there is a single worker
node, and NFS does not enforce single-mount exclusivity, so rolling updates overlap cleanly.

## Secrets

- Requires an externally managed Secret **`immich-db`** in namespace `immich`, keys `username` and
  `password` (referenced by name from `release.yaml`, `postgres.yaml`, `backup.yaml`).
- **Not created here.** It must be a SOPS-encrypted Secret (e.g. `kubernetes/apps/immich/immich-db.sops.yaml`)
  committed only after the production age recipient exists (`.sops.yaml` fails closed until the production recipient exists).
- TODO(secrets): create `immich-db` via `scripts/secrets/encrypt.sh`; no credential is ever committed
  in cleartext.

## Resources

Single worker, 3 vCPU / 16 GiB, no HA — requests are deliberately modest.

| Workload | Requests | Limits |
|---|---|---|
| `immich-server` | 250m / 512Mi | 1 / 2Gi |
| `immich-machine-learning` | 500m / 1Gi | 2 / 4Gi, `nvidia.com/gpu: 1` |
| `immich-valkey` | 50m / 64Mi | 250m / 256Mi |
| `immich-postgres` | 250m / 512Mi | 1 / 2Gi |

## GPU

Machine learning (face detection and recognition, smart search) runs on the Tesla P4 (`docs/hardware.md`):

- **Path:** OpenTofu passes the card to `talos-wk-1` (`infrastructure/environments/homelab/proxmox/gpu.tf`);
  Talos loads the proprietary NVIDIA driver (the P4 is Pascal; `talos/schematic-gpu.yaml`,
  `talos/patches/gpu-worker.yaml`); the device plugin (`kubernetes/infrastructure/nvidia-device-plugin`)
  advertises `nvidia.com/gpu`; the ML pod asks for one and runs under the `nvidia` RuntimeClass with the
  `-cuda` image.
- **Lab:** no GPU. `kubernetes/overlays/lab/apps` removes the RuntimeClass and the GPU limit; the CUDA
  image falls back to the CPU.
- **Sharing:** the plugin time-slices the card into 4 `nvidia.com/gpu` (decisions §3.8), so the ML pod's
  one slot leaves three for other GPU pods. Every pod sees the full 8 GB with no memory isolation.
- **Verify:** `kubectl get node talos-wk-1 -o jsonpath='{.status.allocatable.nvidia\.com/gpu}'` returns
  `4`, and the ML logs list `CUDAExecutionProvider` when a model loads.
- **Cooling:** the P4 is passive; a host fan header follows its temperature
  (`docs/runbooks/gpu-fan-control.md`).
- **If the GPU is missing** (passthrough off, driver not loaded), the ML pod stays Pending on
  `nvidia.com/gpu`. Fall back by deleting the RuntimeClass and GPU limit from `release.yaml`.

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
- **Not yet done:** no restore has been performed (drill pending); the cron dump is not yet
  monitored (alert on last-success age pending).
- TODO(storage): confirm the `nas-nfs` export lets uid/gid `999` write (the dump job runs as that uid).

## Upgrade & rollback

- **Chart bump:** change `ref.tag` in `source.yaml` (and `versions.yaml`), read the upstream changelog,
  one app at a time, verify after each (`docs/runbooks/upgrades.md`).
- **App version:** `controllers.main.containers.main.image.tag` — the chart does **not** follow Immich
  releases, so this must be bumped deliberately.
- **Database:** immutable-ish; **do not** jump PostgreSQL major versions in place. Immich upgrades must
  match the migrations shipped in the app version.
- **PostgreSQL major (e.g. 16 → 17):** a new binary refuses the old data directory, so bumping only the
  tag crash-loops the database (PR #13 did that on 2026-10-23). Each major lives in its own
  subdirectory of the volume (`PGDATA=/var/lib/postgresql/data/pg<major>` in `postgres.yaml`), so the
  old files stay as a fallback. The owner runs it:
  1. `flux suspend kustomization apps`, `flux suspend helmrelease immich -n immich`, and scale
     `immich-server` to 0.
  2. Dump on the old major: `kubectl -n immich exec immich-postgres-0 -- sh -c 'pg_dumpall --clean
     --if-exists -U "$POSTGRES_USER"' | gzip > immich.sql.gz`, plus a NAS copy with
     `kubectl -n immich create job --from=cronjob/immich-db-dump immich-db-dump-premajor`.
  3. One PR moves the tag in `postgres.yaml`, `backup.yaml` and `versions.yaml` **and** `PGDATA` to
     the new major's directory. Merge it, then `flux resume kustomization apps`. The pod starts on an
     empty new cluster.
  4. Restore with Immich's search_path fix:
     `gunzip < immich.sql.gz | sed "s/SELECT pg_catalog.set_config('search_path', '', false);/SELECT
     pg_catalog.set_config('search_path', 'public, pg_catalog', true);/g" | kubectl -n immich exec -i
     immich-postgres-0 -- sh -c 'psql -U "$POSTGRES_USER" -d postgres'`. Errors about the role that
     already exists are expected.
  5. Scale `immich-server` back to 1, `flux resume helmrelease immich -n immich`, check the library.
  6. Weeks later, delete the old major's files from the volume.
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

- **Certificate** — switch the Ingress issuer from `internal-ca` to the Let's Encrypt wildcard once the
  Cloudflare DNS-01 issuer exists (`docs/decisions.md` §5.7).
- **`immich-db` Secret** — create (SOPS-encrypted) before first deploy.
- **Authentik SSO** — not wired yet.
- **Restore drill** and **backup monitoring** — not done yet.
- **DB container hardening** — prove running as uid 999 (needs a writable `/etc/postgresql`).
- **StorageClasses** `nas-nfs` / `local-path` are provided by the platform layer.
