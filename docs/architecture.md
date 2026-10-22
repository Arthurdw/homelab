# Target Architecture

> **Status:** accepted at GATE 0 (2026-10-16); nothing here has been applied to the live hosts. Grounded in
> the audit (`docs/hardware.md`, `network-plan.md`, `storage.md`). The reasoning behind each choice is in
> `docs/decisions.md`, which wins wherever this summary and it disagree.

## 1. Principles

- Data safety first, then security, correctness, maintainability, cost, convenience.
- Infrastructure also recoverable **without** Kubernetes.
- Simple over clever; 4 physical cores total on the compute host — no heavy control planes.
- One owner per resource (see §7).

## 2. Layer map

```text
                    ┌────────────────────────── GitHub (public repo) ──────────────────────────┐
                    │  infrastructure/ (OpenTofu)      kubernetes/ (Flux)      docs/  ci/       │
                    └───────┬─────────────────────────────────────┬────────────────────────────┘
                            │ plan/apply (gated)                  │ reconcile
                            ▼                                     ▼
   ┌───────────────┐   ┌───────────────────────────┐      ┌───────────────────────────┐
   │ UniFi UDM Pro │   │ Proxmox VE (poseidon)     │      │ Kubernetes (Talos VMs)    │
   │  network      │◄──┤  VM lifecycle (OpenTofu)  ├─────►│  Flux → platform & apps   │
   └───────────────┘   └────────────┬──────────────┘      └────────────┬──────────────┘
                                    │ 10 GbE (dedicated)               │ NFS/CSI
                                    ▼                                  ▼
                         ┌───────────────────────┐
                         │ TrueNAS (hercules-nas)│  pools, datasets, shares, snapshots
                         └──────────┬────────────┘
                                    │ encrypted, versioned, offsite
                                    ▼
                         ┌───────────────────────┐
                         │ Offsite backup target │  (undecided — §5.5)  
                         └───────────────────────┘
```

## 3. Compute plan (Proxmox)

Verified: i5-7400 (4c/4t), 46 GiB RAM, single 489 GiB SSD (SPOF), no ZFS on host, empty `local-lvm` (360 GiB).

- **VM boot disks live on `local-lvm`** (local SSD) — *not* on the NAS. The current setup puts a 3 TB VM disk
  on SMB; that couples VM I/O to the network and the NAS and should not continue.
- **Kubernetes topology: 1 control plane + 2 workers**, all on the single host (`docs/decisions.md` §3.1,
  provisional until the lab measures real usage). *No HA claim* — host loss = cluster loss.
- Reserve capacity for the hypervisor + at least one non-Kubernetes service VM; never overcommit RAM to the
  point where the host thrashes (today's 42/46 GiB usage is a temporary outlier, not a target).

| Guest | vCPU | RAM | Disk (local-lvm) |
|---|---|---|---|
| `talos-cp-1` | 2 | 4 GiB | 20 GiB |
| `talos-wk-1` | 3 | 16 GiB | 80 GiB boot + 100 GiB data (`local-path`, decisions §3.4); Tesla P4 passthrough (`gpu.tf`) |
| `talos-wk-2` | 3 | 12 GiB | 40 GiB boot + 100 GiB data; no GPU (decisions §3.6) |

## 4. Storage plan (TrueNAS)

Verified: `main` = RaidZ3, 8×4 TB (~29.1 T raw), 1 TB NVMe L2ARC, 3-way SSD boot mirror, ~492 G of apps.

- The fate of the **RaidZ3 pool** (preserve/import vs rebuild) is **deferred to cutover**, after the owner's
  backups are verified (decisions §1.4). Reassess whether the 3-way boot mirror and the L2ARC are right-sized.
- **Dataset hierarchy:** one dataset tree per tier (decisions §4.1) so snapshot and backup policy differ
  per tier.
- **Snapshots:** replace the single non-recursive daily task with **per-dataset, recursive** policies and
  explicit retention. Child datasets (currently unsnapshotted) must be covered.
- **Protocols:** NFS for Proxmox backups/ISOs and the Kubernetes CSI (`nas-nfs`); SMB for user shares
  (decisions §4.2). Databases stay on node-local `local-path` with logical dumps to the NAS (§4.3).
- No Ceph/Longhorn for a single-host setup unless justified.

## 5. Network plan

See `docs/network-plan.md`. **Decided at GATE 0** (rationale: `docs/decisions.md` §2):

- **K8s on a new VLAN 20, `10.20.0.0/24`**: UDM gateway `10.20.0.1`, nodes `10.20.0.11–29`, MetalLB pool
  `10.20.0.100–199`. Keeps cluster traffic off the management segment, and it is additive-only on the UDM.
- **Storage link:** moves from link-local to `10.99.0.0/29` (Proxmox `.1`, NAS `.2`, talos-cp-1 `.3`, talos-wk-1
  `.4`, talos-wk-2 `.5`, no gateway, MTU 9000). Each Talos VM has a second NIC on it, so NFS needs no routing. MTU is
  **provisional** until throughput is measured at cutover.
- **Pods `10.244.0.0/16`, Services `10.96.0.0/16`** — identical in every environment, deliberately.
- **Lab addresses are disjoint**: nodes/VIPs `10.99.100.0/24`, storage link `10.99.101.0/30`.
- **IPv6 disabled** on the new K8s and storage segments; the house LAN is left untouched.
- **Management stays private.** Emergency access is Tailscale — no DMZ, no inbound ports.
- **UniFi policy: additive-only** — never modify existing objects that serve house devices (`docs/PROJECT-PLAN.md` §4.4).

## 6. Kubernetes & GitOps

- **Talos Linux** (pinned `v1.14.4`, Kubernetes `v1.37.1`) for all nodes; machine configs generated, secrets
  never committed.
- **Topology:** 1 control plane (2 vCPU / 4 GiB / 20 GiB) + 2 workers (3 vCPU and a **100 GiB data disk**
  each; `talos-wk-1` 16 GiB / 80 GiB boot with the Tesla P4, `talos-wk-2` 12 GiB / 40 GiB boot without); all VM disks on the host
  SSD, never on the NAS. A worker's data disk exists so the node-local `local-path` StorageClass has a
  non-system disk to hold its Talos user volume (`docs/decisions.md` §3.4, §4.3). GPU pods run on
  `talos-wk-1`, which carries a soft `PreferNoSchedule` taint so ordinary pods prefer `talos-wk-2` (§3.6).
  **No HA claim** — one host means host loss is cluster loss.
- **CNI: Cilium** with kube-proxy replacement (NetworkPolicy support, fewer components on a 4-thread host).
  Provisional — Flannel is the documented fallback if resources prove insufficient.
- **Flux** (`v2.9.6`) owns all ongoing Kubernetes config; separate `infrastructure/`, `infrastructure/configs/`
  and `apps/`. Bootstrap must not depend on in-cluster DNS or Authentik; break-glass access documented.
- **Upgrades:** dedicated workflow; ordinary applies must never upgrade Talos/K8s/OS as a side effect.

## 7. Ownership matrix

| Component | Owner | Not allowed |
|---|---|---|
| Runtime K8s resources | **Flux** | OpenTofu mutating them (except documented bootstrap) |
| Proxmox / UniFi / TrueNAS resources | **OpenTofu** | Flux |
| Talos bootstrap / OS upgrade | **Talos tooling** | OpenTofu side effects |
| Exceptional recovery/migration | **Runbooks/scripts** | ad-hoc manual drift |

## 8. Applications (incremental; each must document pins, ingress/auth, storage, secrets, resources, backup+restore, upgrade/rollback, exposure)

Order: ingress+certs → DNS → identity → monitoring → Immich → Audiobookshelf → private cloud
(Seafile, decisions §5.8) → local-only services → Forgejo (later). No Jellyfin.

- **Traefik** + **cert-manager** (Cloudflare DNS-01, narrowly scoped creds); management UIs never public.
- **Authentik** for web SSO; never required to recover infrastructure; break-glass creds kept independently.
- **Immich:** media on TrueNAS; DB backed up consistently; media+DB treated as a related recovery set.
  Immich ML runs on the Tesla P4, passed through to `talos-wk-1` and handed to pods by the NVIDIA device plugin.

## 9. Backup & DR (summary — `docs/backup-policy.md`, `docs/backup-matrix.md`)

- Four tiers; Tier-1 offsite, encrypted, versioned; Tier-3 excluded by default.
- Destination: **undecided** (decisions §5.5); the design stays target-agnostic and restic-shaped.
- Deletion protection + independent key storage; **restore tests are the proof**, not job success.

## 10. Secrets, state & CI

- **Secrets:** SOPS + age; age key + recovery material stored **outside** the repo and outside the sole
  infra they recover. UniFi/Proxmox/TrueNAS API creds via env vars from outside the repo.
- **State:** separate OpenTofu state per system; backend with locking chosen in Phase 1; never in the K8s
  cluster it must rebuild; encrypted backups; documented recovery.
- **CI:** PR static validation only (no live creds, no applies); gated manual plan/apply; SHA-pinned actions;
  untrusted forks isolated.
- **Lab:** layered local testing (`docs/lab.md`) — every module passes a lab fixture before touching hardware.

## 11. Deviations from the spec (owner-approved)

| # | Deviation | Rationale |
|---|---|---|
| D1 | Greenfield rebuild; **no** resource import/adoption | owner intent; hosts will be reset by the owner |
| D2 | **UniFi additive-only**, never modify existing objects | protect house appliances |
| D3 | Mandatory lab testing before any live apply (beyond spec §15 "optional") | spec §2.3 honesty + safety |
| D4 | Owner performs the wipe/reset; agents read-only until gated | owner instruction |

## 12. Open items

All GATE 0 questions are answered in `docs/decisions.md`. Still open: the management VLAN tag and the
NAS/Proxmox VLAN mismatch (both need the UniFi configuration export) and the offsite target (§5.5).
