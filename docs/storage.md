# Storage

> Current state **discovered** 2026-10-16 (read-only). Sizes are as reported; verify units before sizing
> decisions. Exact serials in `docs/private/`.

## TrueNAS `main` pool

- **Topology:** single **RaidZ3** vdev, 8× Seagate 4 TB HDD → 3-disk redundancy.
- **Reported:** 29.1 T raw · 17.8 T allocated · 11.3 T free · 61 % full · frag 17 % · health ONLINE · 0 errors.
- **Cache:** 1 TB NVMe as **L2ARC**, ~76 % full (read-cache; not persistent data).
- **Accounting discrepancy to resolve:** `zpool list` reports **17.8 T allocated**, while `zfs list` shows
  only **~8.3 T** logical in `main` and ~5.19 T available. RaidZ3 parity alone (~1.6×) does not fully
  explain the gap — **verify units/accounting** (`zfs list -o space main`, `zfs get compressratio`) before
  planning capacity or backup sizes.

## Datasets (current)

| Dataset | Used | Notes |
|---|---|---|
| `main` | ~7.8 T (own data) | holds the share directories (below) |
| `main/ix-apps` | ~493 G | TrueNAS apps; includes `app_mounts/s3/export` ~490 G |
| `main/.system/*` | ~1.8 G | system (samba4, nfs, netdata, configs) |
| `boot-pool` + 5 boot environments | ~14 G | OS; 5 BEs is more than needed |

## Shares (current)

| Share | Path | Protocol | Access |
|---|---|---|---|
| `arthur` | `main/arthur` | SMB **+ NFS** | rw |
| `proxmox` | `main/proxmox` | SMB | rw; mounted by Proxmox as its `hercules` storage |
| `jolien` | `main/jolien` | SMB | rw |
| `dunia` | `main/dunia` | SMB | rw |

**Proxmox consumption:** the `proxmox` share is mounted **CIFS/SMB** over the 10 GbE link and hosts a
**3000 GB qcow2** VM disk for the running `portainer` VM. So a VM's boot disk currently lives on the NAS
over SMB — a latency and failure-coupling consideration for the redesign.

## Snapshots / replication (current)

- One snapshot task: **daily 00:00 on `main`, `recursive=false`, 2-week retention**.
  → **Gap:** child datasets (e.g. `main/ix-apps/...`) are **not** covered.
- Total snapshots: 82.
- **Replication: none configured.** No offsite or second-copy target.

## Applications running on the NAS (current)

`tailscale`, `syncthing`, `arthur-syncthing`, `dunia-syncthing`, `s3` (Docker-based TrueNAS apps).
So the NAS is not storage-only; it runs services and holds app data (493 G incl. the S3 export).

## Data-preservation candidates (Tier-1 screening — owner must confirm)

The share directories under `main` (`arthur`, `jolien`, `dunia`, `proxmox`) plus any irreplaceable
content inside `ix-apps` are the from-now-on **treated-as-valuable** set. The `proxmox` share also holds a
VM disk image. Exact per-directory sizes and which are irreplaceable are **open questions** (Phase 2).

## Target design (to be decided — Phase 2)

- Dataset hierarchy with explicit per-dataset snapshot + backup policy (the current single non-recursive
  task is insufficient).
- Decide NFS vs SMB vs other for Proxmox storage and any Kubernetes CSI, based on latency/consistency —
  **do not** put latency-sensitive databases on network storage without evidence.
- Evaluate whether the 3-way boot mirror and 1 TB L2ARC are justified for the role, or right-sized.
- No Ceph/Longhorn unless justified for a single-host setup.
