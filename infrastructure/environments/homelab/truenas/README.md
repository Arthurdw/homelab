# TrueNAS root configuration

> **BLOCKED: requires TrueNAS >= 25.04 (25.10 preferred). Upgrading hercules-nas is an owner action, done before
> cutover.** The pinned provider `truenas/truenas` 1.5.14 speaks only the JSON-RPC 2.0 API at
> `/api/current`, which first shipped in 25.04. Its own README says older releases "cannot connect".
> The live NAS runs **24.10.2.4** (`versions.yaml`), so no `plan` or `apply` can work until it is upgraded.
> The vendor tested the provider on 26.0 and 25.10. 25.04 connects, but the vendor never tested it.

Manages TrueNAS SCALE resources for the homelab: datasets, NFS shares and snapshot tasks.

**Status:** resources written and **proven against a local fixture**, not against hercules-nas. A throwaway
TrueNAS SCALE 25.10.7 VM (`just lab-truenas`, then `just lab-truenas-plan`) ran init, validate, plan (3 to
add), apply (3 added), a check of the objects through the API, and a second plan with no changes. No destroy
step runs, because the dataset and share carry `prevent_destroy`; `just lab-truenas down` discards the
fixture instead. Nothing has run against the real NAS (24.10.2.4, owner upgrade pending). See `docs/lab.md`.

> **Data safety:** this root can destroy datasets. Treat every `plan` as write-capable. Applies are
> gated (see `docs/PROJECT-PLAN.md`) and need explicit owner approval. Never `-auto-approve`.

## What it manages

Additive only. It creates new objects under the existing pool. It never manages the pool or
existing datasets/shares (`main`, `main/arthur`, `main/proxmox`, ...; `docs/storage.md`), and it imports
nothing (deviation D1).

| Resource | What | Source |
|---|---|---|
| `truenas_dataset.k8s` | `main/k8s`, parent for csi-driver-nfs PVC directories; `prevent_destroy` | decisions §4.1, §4.2 |
| `truenas_nfs_share.k8s` | `/mnt/main/k8s`, storage link only, `maproot root:root` (no_root_squash), `sec=sys` | `kubernetes/infrastructure/storage/release.yaml` |
| `truenas_periodic_snapshot_task.k8s` | daily, recursive, 14 days | decisions §4.1 ("main/k8s NFS export") |
| `backups.tf`: `main/backups/{timemachine/jolien,kopia}` | datasets; the Time Machine one has a quota (`timemachine_jolien_quota_gib`, no default) | decisions §5.9 |
| `truenas_smb_share.timemachine_jolien` + `_acl`, `truenas_filesystem_acl` | `TIMEMACHINE_SHARE` purpose, one user only (looked up, created by the owner) | decisions §5.9 |
| `truenas_nfs_share.{kopia,seafile}` | `main/backups/kopia`, `main/apps/seafile`; same networks and maproot as the k8s export | decisions §5.8, §5.9 |
| snapshot tasks | `timemachine` daily / 7 d, `kopia` daily / 14 d, `main/apps` hourly / 14 d | decisions §4.1 |

`backups.tf` needs two manual prerequisites on the NAS: the SMB user (`timemachine_jolien_user`) and **Apple SMB2/3
protocol extensions** on (NAS-wide, so not managed here). See `docs/runbooks/household-backups.md`.

**Not created, and why:**

- **A Proxmox backups/ISO export.** decisions §4.2 says they go to a NAS NFS export
  (prune 7d/4w/6m), but it names no dataset or path. Add one once that is decided (`main/backups` now exists).
- **The other tier datasets** (tier1, apps, media, scratch in §4.1) and their snapshot tasks. They
  depend on the pool preserve-vs-rebuild decision at cutover (§1.4) and on the owner's data
  screening (`docs/storage.md`).
- **NFS service settings.** The export needs NFSv4 enabled (csi-driver-nfs pins
  `nfsvers=4.1`) and the NFS service running and bound to the storage-link address. The provider has
  `truenas_nfs_config` and `truenas_service`, but both are NAS-wide singletons that already exist.
  Managing them would take over existing settings that serve the current `arthur` NFS share. Configure
  them by hand at cutover, or adopt them deliberately later. TODO(GATE 4).
- **Replication / offsite.** The target is undecided (decisions §5.5).

## TODO(GATE 4)

- **NFS client network vs routing.** `k8s_nfs_allowed_networks` defaults to the storage link
  `10.99.0.0/30` (Proxmox `.1`, NAS `.2`). The Talos nodes are on `10.20.0.0/24` and are not on
  that link. Either Proxmox routes or NATs node traffic onto the link (the NAS then sees `10.99.0.1`, which
  the default allows), or the design changes. That needs a decision, and the variable must match it.
- **maproot group name** (`root` on SCALE). Confirm it on the upgraded NAS.
- **Pool name `main`.** It is a contract with `/mnt/main/k8s` in the StorageClass. If the pool is
  rebuilt under another name, both sides move together.

## Verified against

- Provider schema (`tofu providers schema -json`) and the README bundled with
  `truenas/truenas` 1.5.14. OpenTofu `init -backend=false` + `validate`.
- **The L1 fixture** (TrueNAS SCALE 25.10.7, `just lab-truenas-plan`, 2026-10-21) showed these work:
  - `share_type = "NFS"` and the `maproot_*` names `root`/`root`;
  - `networks` comes back as `["10.99.100.0/24"]`;
  - the snapshot `schedule` and `naming_schema` round-trip, with a second plan of "No changes".
- **Not verified:** anything on hercules-nas (blocked, see above), destroy (`prevent_destroy`), a Talos
  node mounting the export, and 25.04. Run a post-upgrade `plan` first.

## Usage

```sh
cd infrastructure/environments/homelab/truenas

# Keep the API key in the environment, not on disk:
export TF_VAR_truenas_api_key='...'          # or TRUENAS_API_KEY
export TF_VAR_truenas_endpoint='wss://<host>/api/current'

cp terraform.tfvars.example terraform.tfvars   # then edit; tfvars is gitignored
tofu init -backend=false
tofu validate
tofu plan                                      # review only; blocked until the NAS runs >= 25.04
```

## Notes

- Provider: `truenas/truenas` 1.5.14 (validated against OpenTofu 1.13.1).
- State backend: undecided (`docs/secrets-and-state.md` §5).
