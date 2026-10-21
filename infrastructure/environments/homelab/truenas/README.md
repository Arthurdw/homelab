# TrueNAS root configuration

> **Requires TrueNAS >= 25.04 (25.10 preferred); the live apply is owner-gated.** The pinned provider
> `truenas/truenas` 1.5.14 speaks only the JSON-RPC 2.0 API at `/api/current`, which first shipped in 25.04. Its own
> README says older releases "cannot connect". The owner reinstalled hercules-nas on **SCALE 25.10.7** on 2026-10-21
> (`versions.yaml`), which is the fixture version where the root was proven.
> The vendor tested the provider on 26.0 and 25.10. 25.04 connects, but the vendor never tested it.

Manages TrueNAS SCALE resources for the homelab: datasets, NFS and SMB shares, snapshot tasks and the household accounts.

**Status:** the resources up to and including `backups.tf` are **proven against a local fixture**, not against hercules-nas. A throwaway
TrueNAS SCALE 25.10.7 VM (`just lab-truenas`, then `just lab-truenas-plan`) ran init, validate, plan (3 to
add), apply (3 added), a check of the objects through the API, and a second plan with no changes. No destroy
step runs, because the dataset and share carry `prevent_destroy`; `just lab-truenas down` discards the
fixture instead. Nothing has run against the real NAS (25.10.7 since the 2026-10-21 reinstall; the live apply is owner-gated). See `docs/lab.md`.

> **Data safety:** this root can destroy datasets. Treat every `plan` as write-capable. Applies are
> gated (see `docs/PROJECT-PLAN.md`) and need explicit owner approval. Never `-auto-approve`.

## What it manages

Additive only. It creates new objects under the existing pool. It never manages the pool or
existing datasets/shares (`main`, `main/arthur`, `main/proxmox`, ...; `docs/storage.md`), and it imports
nothing (deviation D1). The one network object, the storage-link bond, is created rather than imported:
the provider can only import PHYSICAL interfaces, never configure them.

| Resource | What | Source |
|---|---|---|
| `storage-link.tf`: `truenas_network_interface.storage_link` | one-port failover bond `bond1` over the 10 GbE port (`storage_link_interface`, no default), `10.99.0.2/30`, MTU 9000, no DHCP; management interface untouched. Fixture-proven only | decisions §2.2 |
| `truenas_dataset.k8s` | `main/k8s`, parent for csi-driver-nfs PVC directories; `prevent_destroy` | decisions §4.1, §4.2 |
| `truenas_nfs_share.k8s` | `/mnt/main/k8s`, storage link only, `maproot root:root` (no_root_squash), `sec=sys` | `kubernetes/infrastructure/storage/release.yaml` |
| `truenas_periodic_snapshot_task.k8s` | daily, recursive, 14 days | decisions §4.1 ("main/k8s NFS export") |
| `backups.tf`: `main/backups/{timemachine/jolien,kopia}` | datasets; the Time Machine one has a quota (`timemachine_jolien_quota_gib`, no default) | decisions §5.9 |
| `truenas_smb_share.timemachine_jolien` + `_acl`, `truenas_filesystem_acl` | `TIMEMACHINE_SHARE` purpose, one user only (`truenas_user.jolien`) | decisions §5.9 |
| `users.tf`: `truenas_user.{jolien,dunia}` | created here: SMB on, own primary group, shell `nologin`, no sudo; passwords from the ephemeral `user_jolien_password` / `user_dunia_password` (no default, never in state); `prevent_destroy` | decisions §5.9 |
| `users.tf`: `truenas_user.arthur` | the owner's existing admin login, **imported** by an `import` block (id looked up by name), never changed: groups, sudo, shell, password, home, lock state and UID are in `ignore_changes`; `prevent_destroy` | |
| `truenas_nfs_share.{kopia,seafile}` | `main/backups/kopia`, `main/apps/seafile`; same networks and maproot as the k8s export | decisions §5.8, §5.9 |
| snapshot tasks | `timemachine` daily / 7 d, `kopia` daily / 14 d, `main/apps` hourly / 14 d | decisions §4.1 |
| `tiers.tf`: `main/tier1` + `{arthur,jolien,dunia}` (SMB), `main/media`, `main/scratch` | datasets, `prevent_destroy`; no shares, no quotas | decisions §4.1 |
| `tiers.tf` snapshot tasks | `tier1` hourly (minute 10) / 30 d, recursive; `media` weekly (Sun 01:00) / 4 w; **none** for `scratch` | decisions §4.1 |

`backups.tf` needs one manual prerequisite on the NAS: **Apple SMB2/3 protocol extensions** on (NAS-wide, so
not managed here). See `docs/runbooks/household-backups.md`. `users.tf` needs the user `arthur` to exist
already (the plan fails at the lookup otherwise) and the two password variables exported.

**Not created, and why:**

- **A Proxmox backups/ISO export.** decisions §4.2 says they go to a NAS NFS export
  (prune 7d/4w/6m), but it names no dataset or path. Add one once that is decided (`main/backups` now exists).
- **Shares, quotas and the media protocol for the tier datasets** (`tiers.tf`). decisions §4.1 names no share
  names, accounts, quotas or, for `main/media`, which of SMB/NFS applies, so none are invented. Each is a
  `TODO(owner)` in the file. `main/scratch` has no snapshot task on purpose (§4.1: none).
- **Which data goes in which tier.** The datasets exist and are empty. Classifying the owner's future data
  is the owner's call.
- **NFS service settings.** The export needs NFSv4 enabled (csi-driver-nfs pins
  `nfsvers=4.1`) and the NFS service running and bound to the storage-link address. The provider has
  `truenas_nfs_config` and `truenas_service`, but both are NAS-wide singletons that already exist.
  Managing them would take over existing settings that serve the current `arthur` NFS share. Configure
  them by hand at cutover, or adopt them deliberately later. TODO(GATE 4).
- **Replication / offsite.** The target is undecided (decisions §5.5).

**`tiers.tf` is validated (`tofu fmt`, `tofu validate`) but not yet applied on the fixture.** The host was under
memory pressure (swap in use, memory PSI above 5 %) on 2026-10-21, so the 6 GiB `lab-truenas` VM was not
started. Run `just lab-truenas`, `just lab-truenas-plan` and a second plan before relying on it.
The weekly `dow = "0"` and `lifetime_unit = "WEEK"` values in particular are unchecked against the API.

**Household backup datasets and the tier policy:** the Time Machine and Kopia datasets and `main/apps/seafile`
are already covered by their own tasks, which match §4.1. `main/backups` holds no data of its own and a task on it
would break their different retention, so it has none (reasoning in `tiers.tf`).

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
  - `users.tf` (2026-10-21): with a stand-in `arthur` (in `builtin_administrators`, shell bash) created on the
    fixture first, the plan showed `truenas_user.arthur will be imported` and no change to it; apply created
    `jolien` and `dunia` (SMB, own group, `nologin`, no sudo); `arthur`'s groups, shell, home, lock and UID
    were the same after apply; the re-plan was "No changes". Setting `groups = []`, `locked = true` and a new
    shell on `arthur` in an override file still planned "No changes" (`ignore_changes` holds). An unset
    `home` is sent as `""` and refused on create, hence `home = "/var/empty"`.
- **Not verified:** anything on hercules-nas (blocked, see above), destroy (`prevent_destroy`), a Talos
  node mounting the export, and 25.04. Run a post-upgrade `plan` first.

## Usage

```sh
cd infrastructure/environments/homelab/truenas

# Keep the API key in the environment, not on disk:
export TF_VAR_truenas_api_key='...'          # or TRUENAS_API_KEY
export TF_VAR_truenas_endpoint='wss://<host>/api/current'
read -rs TF_VAR_user_jolien_password && export TF_VAR_user_jolien_password   # new accounts only
read -rs TF_VAR_user_dunia_password && export TF_VAR_user_dunia_password

cp terraform.tfvars.example terraform.tfvars   # then edit; tfvars is gitignored
tofu init -backend=false
tofu validate
tofu plan                                      # review only; blocked until the NAS runs >= 25.04
```

## Notes

- Provider: `truenas/truenas` 1.5.14 (validated against OpenTofu 1.13.1).
- State backend: undecided (`docs/secrets-and-state.md` §5).
