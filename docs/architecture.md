# Target Architecture

> **Status:** proposal for GATE 0 review. Grounded in the 2026-10-16 audit (`docs/hardware.md`,
> `network-plan.md`, `storage.md`). Items marked **TBD** require an owner decision. Nothing here has been
> applied to the live hosts. Governing spec: `docs/SPEC.md`.

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
                         │ Offsite backup target │  (family home — TBD)
                         └───────────────────────┘
```

## 3. Compute plan (Proxmox)

Verified: i5-7400 (4c/4t), 46 GiB RAM, single 489 GiB SSD (SPOF), no ZFS on host, empty `local-lvm` (360 GiB).

- **VM boot disks live on `local-lvm`** (local SSD) — *not* on the NAS. The current setup puts a 3 TB VM disk
  on SMB; that couples VM I/O to the network and the NAS and should not continue.
- **Kubernetes topology (hypothesis): 1 control-plane + 1 worker** initially, both on the single host.
  Expandable later. *No HA claim* — host loss = cluster loss. **TBD:** exact vCPU/RAM (proposal below,
  sized to leave headroom for the hypervisor and any non-K8s VM).
- Reserve capacity for the hypervisor + at least one non-Kubernetes service VM; never overcommit RAM to the
  point where the host thrashes (today's 42/46 GiB usage is a temporary outlier, not a target).

| Guest (proposal) | vCPU | RAM | Disk |
|---|---|---|---|
| Talos control-plane | 2 | 2–4 GiB | 20 GiB (local-lvm) |
| Talos worker | 2–3 | 6–10 GiB | 40–80 GiB (local-lvm) |
| (later) app/GPU VM | TBD | TBD | TBD |

## 4. Storage plan (TrueNAS)

Verified: `main` = RaidZ3, 8×4 TB (~29.1 T raw), 1 TB NVMe L2ARC, 3-way SSD boot mirror, ~492 G of apps.

- Keep the existing **RaidZ3 pool** (preserve/re-import on rebuild unless a rebuild is explicitly approved —
  spec §6.2). Reassess whether the 3-way boot mirror and the L2ARC are right-sized for the role.
- **Proposed dataset hierarchy (TBD names):** separate datasets for *Tier-1 personal*, *Tier-2 operational/apps*,
  *Tier-3 media*, *Tier-4 scratch* — so snapshot + backup policy can differ per tier.
- **Snapshots:** replace the single non-recursive daily task with **per-dataset, recursive** policies and
  explicit retention. Child datasets (currently unsnapshotted) must be covered.
- **Protocol:** decide NFS vs SMB vs other for Proxmox storage and any Kubernetes CSI based on measured
  latency/consistency. **Do not** place latency-sensitive databases on network storage without evidence.
- No Ceph/Longhorn for a single-host setup unless justified.

## 5. Network plan

See `docs/network-plan.md`. **Decided at GATE 0** (rationale: `docs/decisions.md` §2):

- **K8s on a new VLAN 20, `10.20.0.0/24`**: UDM gateway `10.20.0.1`, nodes `10.20.0.11–29`, MetalLB pool
  `10.20.0.100–199`. Keeps cluster traffic off the management segment, and it is additive-only on the UDM.
- **Storage link:** moves from link-local to `10.99.0.0/30` (Proxmox `.1`, NAS `.2`, no gateway, MTU 9000) —
  **provisional** until throughput and MTU are measured at cutover.
- **Pods `10.244.0.0/16`, Services `10.96.0.0/12`** — identical in every environment, deliberately.
- **Lab addresses are disjoint**: nodes/VIPs `10.99.100.0/24`, storage link `10.99.101.0/30`.
- **IPv6 disabled** on the new K8s and storage segments; the house LAN is left untouched.
- **Management stays private.** Emergency access is Tailscale — no DMZ, no inbound ports.
- **UniFi policy: additive-only** — never modify existing objects that serve house devices (plan §4.4).

## 6. Kubernetes & GitOps

- **Talos Linux** (pinned `v1.14.4`, Kubernetes `v1.37.1`) for all nodes; machine configs generated, secrets
  never committed.
- **Topology:** 1 control plane (2 vCPU / 2 GiB / 20 GiB) + 1 worker (3 vCPU / 16 GiB / 80 GiB); all VM disks
  on the host SSD, never on the NAS. **No HA claim** — one host means host loss is cluster loss.
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

Order proposal: ingress+certs → DNS → identity → monitoring → Immich → Audiobookshelf → private cloud
(Nextcloud **or** Seafile, decided once) → local-only services → Forgejo (later). No Jellyfin.

- **Traefik** + **cert-manager** (Cloudflare DNS-01, narrowly scoped creds); management UIs never public.
- **Authentik** for web SSO; never required to recover infrastructure; break-glass creds kept independently.
- **Immich:** media on TrueNAS; DB backed up consistently; media+DB treated as a related recovery set;
  P4 passthrough proven on this host but its intended consumer is **TBD**.

## 9. Backup & DR (summary — full design in Phase 2/8)

- Four tiers (see `docs/SPEC.md` §7); Tier-1 offsite, encrypted, versioned; Tier-3 excluded by default.
- Destination: family-home machine (**TBD**) — assess capacity/power/network before committing.
- Mechanism: remote ZFS replication **or** restic/borg (compare on evidence) — one primary, no duplicates.
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

## 12. Open decisions — **all answered 2026-10-16**

See `docs/decisions.md` for the reasoning and `docs/PROJECT-PLAN.md` §10 for the summary. In short:

1. Topology + VM sizing → `docs/decisions.md` §3.1 (1 control plane + 1 worker; no HA claim).
2. Preserve/re-import the `main` pool → **deferred to cutover**, after the owner's backups are verified (§1.4).
3. Storage subnet → `10.99.0.0/30` over the 10 GbE link, provisional (§2.2).
4. CIDRs + CNI → §2.3 and §3.3.
5. Dataset hierarchy + per-tier snapshot policy → §4.1.
6. Backup mechanism → target-agnostic until offsite hardware exists (§5.5).
7. Offsite destination → to be purchased or built (§5.5).
8. DNS → the "internal resolver" was dead; Technitium is a genuine fix, not a replacement (§6.1).
9. Git: HTTPS public mirror, SSH over LAN/Tailscale, canonical-remote question open (§5.4, §5.6).

**Still open:** the management VLAN tag and the NAS/Proxmox VLAN mismatch — neither can be resolved without the
UniFi configuration export.
