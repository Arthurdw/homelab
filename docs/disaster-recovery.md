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
| SOPS/age private key | offline escrow | without it, encrypted Git secrets are unreadable |
| Talos machine secrets + kubeconfig | offline escrow | needed to rebuild/adopt the cluster |
| Proxmox/TrueNAS/UniFi creds + API keys | password manager | reconfigure IaC providers |
| OpenTofu state (or ability to rebuild) | encrypted backend | infra ownership |

If the age key and restic password exist and the offsite data is intact, the homelab is **rebuildable**.

## 3. Scenario: NAS / pool lost (hardware intact)

1. Do not force-import or re-create the pool on questionable disks.
2. Verify the exact failure (controller? cable? disk? pool metadata?).
3. Restore Tier-1 data from offsite to new storage first (see §6).
4. Rebuild the pool per `docs/storage.md`; recreate datasets/shares/snapshot tasks.
5. Restore Tier-2 config; re-enable services; re-point CIFS/NFS consumers.

## 4. Scenario: Proxmox host lost

1. Reinstall PVE to a known state.
2. Restore `/etc/pve` + VM configs (Tier 2); recreate GPU passthrough config for the `portainer` VM.
3. Restore/rebuild VMs: VM disks that lived on the NAS come back with the NAS; local disks come from backup.
4. Confirm the storage link and CIFS mounts before starting VMs.

## 5. Scenario: Kubernetes / Talos lost

1. Bootstrap Flux (`flux bootstrap …`, see `kubernetes/clusters/homelab/README.md`) — infrastructure then apps
   reconcile automatically.
2. Restore the SOPS age key Secret and any cluster secrets **before** apps need them.
3. Restore app data (Immich DB+media, etc.) from offsite; the manifests are already in Git.
4. Verify Ingress/TLS/DNS and backup jobs.

## 6. Restoring data from restic (sketch; the offsite target is not chosen yet, `docs/decisions.md` §5.5)

```sh
export RESTIC_REPOSITORY='sftp:backup@CHANGE-ME:/srv/restic/homelab'
export RESTIC_PASSWORD_FILE=/root/.restic-password

restic snapshots                                   # find the snapshot to restore
restic restore latest --target /mnt/restore-test   # restore to a SCRATCH path first
# verify contents, THEN copy into place (never restore over the live tree first)
```

## 7. Verification checklist

- [ ] Tier-1 data present and openable (sample real files, not just counts)
- [ ] Tier-2 config/secrets restored (Tofu state, Talos secrets, age key, app secrets)
- [ ] Network/DNS/ingress work
- [ ] Apps serve data and can be logged into
- [ ] Backup jobs run again and a restore test passes
- [ ] Monitoring/alerts are live

## 8. Post-incident

- Write down the root cause and the recovery time actually achieved.
- Fix the gap that made this hard (this runbook).
- Update `docs/risk-register.md`.
