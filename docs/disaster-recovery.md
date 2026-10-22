# Disaster Recovery

How to get back up after losing part or all of the homelab. **RTO/RPO are TBD** (owner decision; see
`docs/backup-policy.md`). Priorities: personal data first, then service, then comfort.

> Assumption: `docs/backup-policy.md` is implemented and encryption keys/recovery material are stored
> **outside** the homelab. If they are not, some of these steps cannot be completed.

## 0. Golden rules

- **Do not improvise writes on failed storage.** Stop, assess, then act — a wrong action can turn a
  recoverable failure into permanent loss.
- Prefer restoring to **new/clean** infrastructure over mutating a suspect system.
- Recover **data before services**; services can be rebuilt from the repo.
- Record what you did; update this runbook afterwards.

## 1. Recovery order

1. **Confirm what is lost** vs intact (storage, host, network, cluster, offsite).
2. **Preserve** any surviving copy of the data before doing anything else.
3. **Restore personal/irreplaceable data** (Tier 1) to trusted storage.
4. **Restore Tier-2 config/secrets** (see §2) — you need these to rebuild everything else.
5. **Rebuild the platform** (network → storage → hypervisor → OS → Kubernetes) with IaC/GitOps.
6. **Restore app data** and reconcile with Flux.
7. **Verify** with the acceptance checklist; only then trust the system again.

## 2. Credential / key material (do these first)

| Material | Where it lives | Why it matters |
|---|---|---|
| restic repository password | offsite escrow | without it, offsite backups are unreadable |
| Kopia repository password | SOPS in Git (`kopia-repository`), plus an offline copy | without it, the household backups on the NAS are unreadable |
| SOPS/age private key | offline escrow | without it, encrypted Git secrets are unreadable |
| Talos machine secrets + kubeconfig | offline escrow | needed to rebuild/adopt the cluster |
| Proxmox/TrueNAS/UniFi creds + API keys | password manager | reconfigure IaC providers |
| OpenTofu state (or ability to rebuild) | encrypted backend | infra ownership |

If the age key and restic password exist and the offsite data is intact, the homelab is **rebuildable**.

## 3. Scenario: NAS / pool lost (hardware intact)

1. Do not force-import or re-create the pool on questionable disks.
2. Verify the exact failure (controller? cable? disk? pool metadata?).
3. Restore Tier-1 data from offsite to new storage first (see §6.1 and §6.3).
4. Rebuild the pool per `docs/storage.md`; recreate datasets/shares/snapshot tasks.
5. Restore Tier-2 config; re-enable services; re-point CIFS/NFS consumers.

## 4. Scenario: Proxmox host lost

1. Reinstall PVE to a known state.
2. Restore `/etc/pve` + VM configs (Tier 2); the GPU mapping and passthrough come back with `tofu apply` (`gpu.tf`).
3. Restore/rebuild VMs: VM disks that lived on the NAS come back with the NAS; local disks come from backup.
4. Confirm the storage link and CIFS mounts before starting VMs.

## 5. Scenario: Kubernetes / Talos lost

1. Bootstrap Flux (`flux bootstrap …`, see `kubernetes/clusters/homelab/README.md`) — infrastructure then apps
   reconcile automatically.
2. Restore the SOPS age key Secret and any cluster secrets **before** apps need them.
3. Restore app data (Immich DB+media, etc.) from the NAS dumps or offsite (§6.2); the manifests are already in Git.
   If the cluster cannot come back at all, §6 recovers the data with plain tools.
4. Verify Ingress/TLS/DNS and backup jobs.

## 6. Restoring data without Kubernetes

Everything below needs only the NAS files, a workstation (or the NAS itself) with `docker` or the plain tools, and
the secret material of §2. No cluster, no Flux, no `kubectl`. Proven on the lab (2026-10-21) with the lab NAS
files copied to a scratch directory and throwaway containers; paths on the real NAS are the dataset paths in
`docs/storage.md`, the layout below is the lab's `main/k8s` export.

Work on a **copy** (or a read-only mount) of the NAS files, never on the live export, and in a scratch directory
outside the repo. Everything below writes only to that scratch directory.

### 6.0 Get the passwords out of Git (no Kubernetes)

The Kopia repository password is the Secret `kopia-repository` in `kubernetes/overlays/<env>/apps/`, SOPS
encrypted in Git. Decrypt it with the age key from escrow (§2) and keep the result out of the repo:

```sh
export SOPS_AGE_KEY_FILE=~/.config/homelab/lab-age.key   # the escrowed age key; without it sops fails with
                                                         # "identity did not match any of the recipients"
umask 077
scripts/secrets/decrypt.sh --extract '["stringData"]["password"]' \
  kubernetes/overlays/lab/apps/kopia-repository.sops.yaml > /path/to/scratch/kopia-pw
```

The database dumps need no password: they are restored into a fresh database (the PostgreSQL dumps carry no
owners or privileges). The Authentik `secret-key` is a separate Secret
(`authentik-credentials`) and **must be put back unchanged** or sessions and tokens are invalid; it comes from
the same SOPS tree.

### 6.1 Household files from the Kopia repository

The repository is a plain filesystem repository (`<nas>/kopia/kopia-repository`). Any machine with the same
major `kopia` version (`versions.yaml`, `app_images.kopia`) can open it. In a container, with the repository
mounted read-only:

```sh
docker run --rm --user "$(id -u):$(id -g)" \
  -v /path/to/nas-copy/kopia-repository:/repo:ro -v /path/to/scratch/kopia-pw:/pw:ro \
  -v /path/to/scratch/restore:/restore -v /path/to/scratch/state:/state \
  -e USER=restore -e HOME=/state -e KOPIA_CACHE_DIRECTORY=/state/cache -e KOPIA_LOG_DIR=/state/logs \
  -e KOPIA_CONFIG_PATH=/state/repo.config --entrypoint sh docker.io/kopia/kopia:<pinned tag> -c '
    export KOPIA_PASSWORD="$(cat /pw)"
    kopia repository connect filesystem --path=/repo --readonly
    kopia snapshot list --all                      # --all: by default only this user@host is listed, i.e. nothing
    kopia snapshot restore <root-object-id> /restore/files   # the k... id in that listing'
```

The `USER`, `HOME`, cache and log variables are needed because the image runs as root by default and writes to
`/app`; as another uid it fails with "mkdir /app/logs: permission denied" and "Current requires cgo or $USER".
`--readonly` keeps the connect from writing to the repository. Restore into the scratch directory, compare, and
only then copy into place: `diff -r <source> <restored>` (or `kopia snapshot verify --verify-files-percent=100`
for the repository itself).

### 6.2 Databases from the dumps on the NAS

The dump CronJobs write to the NAS next to the app data: `authentik/authentik-db-backups/authentik-<ts>.dump`
(`pg_dump --format=custom`), `immich/immich-db-backups/immich-<ts>.dump` and
`seafile/seafile-db-backups/seafile-<ts>.sql.gz` (`mariadb-dump` of `ccnet_db`, `seafile_db`, `seahub_db`). Take
the newest file that does not end in `.partial` or `.suspect`. Start a fresh container of the **same image** as
the app (`versions.yaml`) and restore into it:

```sh
# Authentik (postgres image from kubernetes/apps/authentik/backup.yaml)
docker run -d --name dr-pg -e POSTGRES_PASSWORD=<throwaway> -v /path/to/dumps/authentik:/b:ro <postgres image>
docker exec dr-pg createdb -U postgres authentik
docker exec dr-pg pg_restore -U postgres -d authentik --no-owner --exit-on-error /b/authentik-<ts>.dump

# Seafile (mariadb image from kubernetes/apps/seafile/backup.yaml); the dump creates the three databases itself
docker run -d --name dr-maria -e MARIADB_ROOT_PASSWORD=<throwaway> -v /path/to/dumps/seafile:/b:ro <mariadb image>
docker exec dr-maria sh -c 'gzip -t /b/seafile-<ts>.sql.gz && zcat /b/seafile-<ts>.sql.gz | mariadb -uroot -p"$MARIADB_ROOT_PASSWORD"'
```

Allow a few minutes: the Authentik restore (230 tables) took about a minute and the Seafile one longer, because
the container fsyncs on every statement. Wait for the restore to finish before counting. Then run the same
sanity checks as `scripts/backup/db-restore-test.sh`: table count against `pg_restore -l` or `CREATE TABLE`
lines in the dump, the three Seafile databases, and non-zero `authentik_core_user`, `django_migrations`,
`ccnet_db.EmailUser`. Remove the containers afterwards (`docker rm -f dr-pg dr-maria`).

Immich: the same `pg_restore` works, but the image must ship the vector extension Immich uses; take the image
from `kubernetes/apps/immich`, not plain `postgres`. (Not rehearsed without Kubernetes; the Immich restore test
in the cluster passes.)

### 6.3 Offsite restic repository (dormant until the target is chosen, `docs/decisions.md` §5.5)

```sh
export RESTIC_REPOSITORY='<target chosen in §5.5>'
export RESTIC_PASSWORD_FILE=/path/to/escrowed/restic-password

restic snapshots                                   # find the snapshot to restore
restic restore latest --target /mnt/restore-test   # restore to a SCRATCH path first
# verify contents, THEN copy into place (never restore over the live tree first)
```

`scripts/backup/restic-restore-diff.sh` does the restore-and-diff for the newest snapshot.

## 7. Verification checklist

- [ ] Tier-1 data present and openable (sample real files, not just counts)
- [ ] Tier-2 config/secrets restored (Tofu state, Talos secrets, age key, app secrets)
- [ ] Network/DNS/ingress work
- [ ] Apps serve data and can be logged into
- [ ] Backup jobs run again and a restore test passes
- [ ] Monitoring/alerts are live

### Final checklist: can the data be recovered without Kubernetes?

Run this once per environment (and after any change to the backup layout). A line is only ticked when it was
done with plain tools against the NAS files, with the cluster stopped or absent. Last full run: the lab,
2026-10-21; the real-hardware column is still open.

| # | Check | Lab, 2026-10-21 | Real hardware |
|---|---|---|---|
| 1 | The age key and the Kopia password are reachable without the cluster (escrow, and `scripts/secrets/decrypt.sh`) | done | open |
| 2 | The Kopia repository opens read-only with `kopia` alone and lists its snapshots (`--all`) | done | open |
| 3 | A snapshot restores into a scratch directory and `diff -r` against the source is empty | done (see below) | open |
| 4 | `kopia snapshot verify --verify-files-percent=100` passes | done | open |
| 5 | The newest Authentik dump restores with `pg_restore` into a fresh container of the pinned image; table count equals the dump's; users and migrations non-zero | done | open |
| 6 | The newest Seafile dump passes `gzip -t`, restores into a fresh MariaDB, the three databases exist, table count equals the dump's `CREATE TABLE` count, accounts and migrations non-zero | done | open |
| 7 | The newest Immich dump restores into the Immich postgres image | not done without Kubernetes (Immich stays paused; passes via `db-restore-test.sh`) | open |
| 8 | An offsite restic restore and diff (`restic-restore-diff.sh`) | not possible, no offsite target (`docs/decisions.md` §5.5) | open |
| 9 | The Authentik `secret-key` and the Seafile secrets are recoverable from the SOPS tree | the SOPS tree decrypts; not rehearsed against a rebuilt cluster | open |
| 10 | Throwaway containers and scratch files removed; nothing written to the NAS | done | open |

Lab evidence for 3: the real lab repository holds one 41-byte snapshot of a scratch directory that no longer
exists, so it restored (two files) but had no source to diff. A snapshot of the three real dump files (6.2 MB)
was then taken into a copy of the repository and restored: `diff -r` was empty and `verify` passed. Evidence for
5 and 6: Authentik dump `20261021T002340Z` restored 230 tables (3 users, 15 flows, 777 migrations; no
applications yet, the dump predates the Seafile provider); Seafile dump `20261021T113555Z` restored 195 tables
(195 `CREATE TABLE` in the dump), 1 account, 83 migrations, 1 library.

## 8. Post-incident

- Write down the root cause and the recovery time actually achieved.
- Fix the gap that made this hard (this runbook).
- Update `docs/risk-register.md`.
