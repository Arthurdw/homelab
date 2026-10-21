# Offsite backup (restic)

**Dormant.** These run against the offsite repository, and the offsite target is deferred
(`docs/decisions.md` §5.5). Nothing installs them yet. Policy: `docs/backup-policy.md`.

| File | Purpose |
|---|---|
| `restic-backup.sh` | `restic backup` of `BACKUP_PATHS`, then `forget --prune` with the `KEEP_*` retention. |
| `restic-check.sh` | `restic check --read-data-subset`, plus an optional sample restore into a scratch directory. |
| `restic-restore-diff.sh` | Restores the newest snapshot into a scratch directory and `diff -r`s it against the live `BACKUP_PATHS`. The non-destructive restore test. |
| `db-restore-test.sh` | Restores the newest Immich or Authentik `pg_dump` into a throwaway postgres pod in a scratch namespace, compares table counts, and deletes the namespace. |
| `backup-alert.sh` | Emails "unit X failed on host Y" plus its last 50 journal lines over SMTP (`curl`), per `docs/decisions.md` §5.1. |
| `backup-freshness.sh` | Fails when the last fully successful backup is older than `BACKUP_MAX_AGE_HOURS` (default 36). |
| `env.example` | The environment the backup scripts read. Copy it outside the repo; never commit real values. |
| `alert.env.example` | The SMTP settings the alert reads. Placeholders only. |
| `test/alert-selftest.sh` | `just backup-selftest` (also in CI): runs `backup-alert.sh` against local SMTP sinks (`test/smtp-sink.py`, throwaway cert) and `systemd-analyze verify` on stub-pathed copies of `systemd/`. Installs nothing. |
| `systemd/` | Daily backup (02:30), weekly check (Sunday 04:00) and daily freshness check (08:00) as oneshot services with timers, plus the `homelab-backup-alert@.service` template. |

## Alerting

- **Failure:** the backup, check and freshness services all carry
  `OnFailure=homelab-backup-alert@%n.service`, so any non-zero exit mails the failing unit's name, host,
  timestamp and journal tail.
- **Staleness:** `restic-backup.sh` writes the epoch time to `/var/lib/homelab/backup-last-success`
  (`BACKUP_STAMP_FILE`) only after backup, retention and `restic check` all succeeded. The freshness check
  fails, and so alerts, when that stamp is missing or older than the threshold. This catches what a per-run
  `OnFailure=` cannot: a timer that never fired, a host that was off, a disabled unit.
- **Credentials:** the SMTP login lives in a netrc file (`/etc/homelab/alert.netrc`, mode 0600) that `curl`
  reads with `--netrc-file`; the password never appears in argv, the environment, or the repo. TLS is
  required (`--ssl-reqd`).

- **Size anomalies:** two checks, both of which fail a unit that already alerts.
  - `restic-backup.sh` compares the snapshot's source size with the previous snapshot's
    (`restic >= 0.17`) and exits non-zero below `BACKUP_MIN_PERCENT` (default 50), before retention and
    before the success stamp, so the failure mail and the freshness check both trip. It fires once per
    drop: the next run compares against the smaller snapshot.
  - The database dump CronJobs (`kubernetes/apps/*/backup.yaml`) fail the Job when a dump is under
    `DUMP_MIN_PERCENT` (50) of the previous one and keep it as `*.dump.suspect`, so the existing
    `DatabaseBackupJobFailed` rule alerts. Suspects are never restore points and the next run still
    compares against the last good dump.
  - **Accepting a legitimate shrink** (you deleted data on purpose). Dumps: the check keeps failing
    nightly against the larger good dump until you accept the suspect. Rename it on the NAS export,
    `mv <app>-<ts>.dump.suspect <app>-<ts>.dump` (it is the newest file, so it becomes the baseline),
    then the next run passes and clears `DatabaseBackupJobFailed`. Restic: nothing to do; the
    snapshot is kept and the next run compares against it. To skip a check for a single run, set
    `BACKUP_MIN_PERCENT=0` in the shell that runs `restic-backup.sh`.

## Restore tests

```sh
# Databases (kubectl context of the cluster; restores into a scratch namespace, then deletes it):
scripts/backup/db-restore-test.sh immich
scripts/backup/db-restore-test.sh authentik

# Restic (same environment as the backup): restore into a temp dir and diff against the source.
set -a; . /etc/homelab/backup.env; set +a
scripts/backup/restic-restore-diff.sh
```

On a live dataset the diff reports files changed since the snapshot; run it right after a backup.

## Trying it in the lab

The libvirt lab (`docs/lab.md`) has no offsite target. The full install below has been run inside
`lab-nas` (`just lab-nas-ssh`) against a local throwaway repository and a `test/smtp-sink.py` sink trusted via
`CURL_CA_BUNDLE`: backup, check, freshness, both failure mails and a timer firing all worked. Debian 12 ships
restic 0.14, so the size check is skipped there.

For a quicker loop, the scripts also run from a container or the workstation with the NAS export mounted
read-only at `/mnt/main/k8s`, against a throwaway repository in a gitignored directory with a generated
password:

```sh
restic init                                   # with RESTIC_REPOSITORY / RESTIC_PASSWORD_FILE pointing at the scratch repo
BACKUP_PATHS=/mnt/main/k8s RESTIC_TAG=lab BACKUP_STAMP_FILE=./stamp scripts/backup/restic-backup.sh
scripts/backup/backup-freshness.sh            # BACKUP_STAMP_FILE as above
RESTIC_RESTORE_DIR=./rc scripts/backup/restic-check.sh
scripts/backup/restic-restore-diff.sh
```

`restic-backup.sh` does not run `restic init`; initialise the repository once by hand. Keep the hostname
stable between runs, or restic treats each run as a new host and retention and the size check never
see the earlier snapshots.

## Install (once a target exists)

On the host that runs the backup, as root:

```sh
install -m 0755 scripts/backup/restic-backup.sh /usr/local/bin/homelab-restic-backup
install -m 0755 scripts/backup/restic-check.sh  /usr/local/bin/homelab-restic-check
install -m 0755 scripts/backup/backup-alert.sh  /usr/local/bin/homelab-backup-alert
install -m 0755 scripts/backup/backup-freshness.sh /usr/local/bin/homelab-backup-freshness
install -d -m 0700 /etc/homelab
install -d -m 0755 /var/lib/homelab
install -m 0600 scripts/backup/env.example /etc/homelab/backup.env         # then edit it
install -m 0600 scripts/backup/alert.env.example /etc/homelab/alert.env   # then edit it
# SMTP login, read by curl itself (never put the password in argv or alert.env):
install -m 0600 /dev/null /etc/homelab/alert.netrc
#   then edit it to one line: machine <smtp-host> login <user> password <password>
install -m 0644 scripts/backup/systemd/* /etc/systemd/system/
systemctl daemon-reload
```

Prove the alert path before relying on it — this sends a real mail:

```sh
systemctl start homelab-backup-alert@test.service
journalctl -u homelab-backup-alert@test.service -n 20
```

Then enable the timers. Enable the freshness timer only **after** the first backup has succeeded, or it will
alert daily about a stamp that cannot exist yet:

```sh
systemctl enable --now homelab-backup.timer homelab-backup-check.timer
systemctl start homelab-backup.service && cat /var/lib/homelab/backup-last-success
systemctl enable --now homelab-backup-freshness.timer
```

Until the offsite target exists none of this is installed, so nothing runs and nothing alerts.
