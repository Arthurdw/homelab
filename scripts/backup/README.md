# Offsite backup (restic)

**Dormant.** These run against the offsite repository, and the offsite target is deferred
(`docs/decisions.md` §5.5). Nothing installs them yet. Policy: `docs/backup-policy.md`.

| File | Purpose |
|---|---|
| `restic-backup.sh` | `restic backup` of `BACKUP_PATHS`, then `forget --prune` with the `KEEP_*` retention. |
| `restic-check.sh` | `restic check --read-data-subset`, plus an optional sample restore into a scratch directory. |
| `env.example` | The environment both scripts read. Copy it outside the repo; never commit real values. |
| `systemd/` | Daily backup (02:30) and weekly check (Sunday 04:00) as oneshot services with timers. |

## Install (once a target exists)

On the host that runs the backup, as root:

```sh
install -m 0755 scripts/backup/restic-backup.sh /usr/local/bin/homelab-restic-backup
install -m 0755 scripts/backup/restic-check.sh  /usr/local/bin/homelab-restic-check
install -d -m 0700 /etc/homelab
install -m 0600 scripts/backup/env.example /etc/homelab/backup.env   # then edit it
install -m 0644 scripts/backup/systemd/* /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now homelab-backup.timer homelab-backup-check.timer
```

Failure alerting is not wired yet. When it is (SMTP, decisions §5.1), add `OnFailure=` to both services,
pointing at a unit that ships with it.
