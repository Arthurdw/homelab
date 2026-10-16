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

See `docs/network-plan.md`. Headlines:

- **Storage link:** currently link-local over 10 GbE. Proposal: move to a **static private `/24`, no default
  gateway** on a dedicated interface/VLAN (spec §9.2), verified end-to-end (MTU, throughput, binding).
- **Management stays private.** Document the emergency access path.
- **Kubernetes CIDRs** (node/pod/service) chosen to avoid collisions with the LAN, NAS Docker bridges, and
  future VLANs — **TBD**.
- **DNS (Technitium):** stable LAN address; must not be a bootstrap circular dependency; documented fallback
  resolver. IPv6 behaviour made intentional.
- **UniFi policy: additive-only** — never modify existing objects that serve house devices (plan §4.4).

## 6. Kubernetes & GitOps

- **Talos Linux** (pinned, e.g. `v1.14.4` — compat matrix to verify) for all nodes; machine configs generated,
  secrets never committed.
- **Flux** (`v2.9.6`, range to verify) owns all ongoing Kubernetes config; separate `bootstrap/`,
  `infrastructure/`, `platform/`, `apps/`.
- **Bootstrap must not depend** on in-cluster DNS or Authentik; break-glass access documented.
- **CNI:** **TBD** (evaluate Cilium vs a lighter option given the 4-core host).
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

## 12. Open decisions (for GATE 0)

1. Kubernetes topology + exact VM sizing (proposal §3).
2. Preserve/re-import the `main` pool on rebuild, or rebuild it?
3. Storage subnet redesign (keep link-local vs private `/24`).
4. Kubernetes node/pod/service CIDRs; CNI choice.
5. Dataset hierarchy names and per-tier snapshot policy.
6. Backup mechanism (ZFS replication vs restic/borg) — evidence in Phase 2.
7. Offsite destination: exists yet? hardware/network/power.
8. DNS: what serves `<INTERNAL_RESOLVER_IP>` today; intended Technitium design.
