# Homelab Infrastructure — Master Plan & Agent Playbook

**Status:** Phase 0 (audit) in progress
**Owner:** Arthur
**Mode:** **Greenfield rebuild, owner-driven.** Once the project is ready, the **owner** will fully wipe and
reinstall both hosts (`poseidon` Proxmox and `hercules-nas` TrueNAS). Agents **never** perform the reset —
they only build, lab-test, and (with approval) apply the IaC that reconfigures the hosts afterwards.
OpenTofu import/adoption of existing resources is not required; today's live config matters only as
(a) data to preserve and (b) design input. **Both hosts are treated as production and are read-only to
agents until the owner explicitly opens a gate.**
**Repo state:** public; contains `LICENSE`, `.gitignore`, `docs/`.

This document is the single source of truth for how the project is executed. Read it fully before making
changes. The governing specification is **`docs/SPEC.md`** (the owner's project brief); where this plan is
ambiguous or differs, `docs/SPEC.md` wins unless a deviation is recorded in §9 below.

Raw discovery output (addresses, serials) lives in **`docs/private/`** and must never be committed.

---

## 0. Rules of engagement

1. **Audit before implementation.** Inventory → propose → wait → change. No installing software or touching live systems first.
2. **No inventions.** Never invent hardware, disks, IPs, API capabilities, provider resources, or backup needs. Inspect read-only, ask, or mark `[UNKNOWN]`.
3. **No destructive actions without per-operation approval.** See §1.
4. **Verify claims.** Label everything: *implemented / validated statically / tested in lab / tested live / documented-not-implemented / planned*.
5. **Small reviewable diffs.** One logical change per commit; no platform for its own sake.
6. **Challenge the spec.** Material deviations get reasoned documentation (§9 decision log), not silent changes.
7. **Stop at every ⛔ GATE** until the owner explicitly approves.
8. **Update this file** (checkboxes, status log, decision log) in the same PR as the work.
9. **Nothing private in tracked files.** Addresses, serials, credentials → `docs/private/` (gitignored) or chat.
10. **Read-only until the owner opens the gate.** Both hosts are production. Do not modify them — and do not script, automate, or plan an automated reset — until the owner explicitly says that step may run.

## 1. Red lines — never without explicit, operation-specific approval

- Destroy/recreate a VM, container, pool, dataset, or filesystem.
- Repartition, format, wipe, or repurpose any physical disk.
- Create, destroy, or change a ZFS pool.
- The **wipe/reinstall of Proxmox or TrueNAS** — **the owner performs this, never the agent**; agents must not initiate, script, automate, or `tofu destroy` toward it. Requires a verified backup + rollback/restore plan first.
- Live UniFi changes beyond the additive policy in §4.4.
- `tofu apply` that destroys/replaces existing resources. **Never `-auto-approve` on live infra.**
- Delete persistent app data or backups.
- Credential rotation that could lock out admins or break services.
- Any migration that removes the source before the destination is verified.
- Enabling auto-prune on a backup destination before retention + deletion-protection are tested.

A successful command is not proof of safety.

## 2. Priorities & non-negotiables

Priorities (in order): data safety/recoverability → security → correctness/reproducibility → maintainability →
hardware/cost efficiency → convenience.

- **Out of scope, do not touch or depend on:** the external Dokploy server and its Tailscale route.
- **UniFi must not break the house.** Current network stays as-is; new config is *added beside* it (§4.4).
- Repo stays public/open-source; never commit credentials, keys, Talos secrets, kubeconfigs, state, plans, `.env`.
- No Jellyfin.
- Management interfaces stay private; recovery must not depend on Kubernetes being up.

---

## 3. Verified environment facts (from 2026-10-16 read-only discovery)

> Sanitized — no addresses/serials here. Full detail: `docs/private/audit-findings.md`.

| Item | Finding | Impact |
|---|---|---|
| Proxmox host | Debian 12, **PVE 8.4.11**, kernel 6.8.12-13-pve | matches spec |
| Proxmox CPU/RAM | i5-7400 4c/4t, 46 GiB RAM — currently ~42 GiB used by one 40 GB VM | real capacity ≠ current load; spec's warning confirmed |
| Proxmox storage | single Crucial SSD → LVM (root 96 G ext4, lvmthin 360 G free, 8 G swap). **No ZFS** | local-lvm is empty → room for VM disks |
| GPU | **Tesla P4 present**, IOMMU already enabled | passthrough plausible; verify IOMMU group before promising |
| Proxmox VMs | one VM (`portainer`, 40 GB RAM, 3 TB disk) | temporary workload |
| Proxmox↔NAS link | dedicated point-to-point link, **link-local addressing**, used as **CIFS/SMB** storage | **spec assumed NFS — actual is SMB** |
| TrueNAS | **SCALE 24.10.2.4**, i5-7400, **32 GiB non-ECC**, 141 d uptime | matches "separate NAS" |
| NAS boot device | **3-way mirror of 3×250 GB SSDs** | over-provisioned for boot; note for redesign |
| NAS pool `main` | **raidz3, 8×4 TB HDD**, 29.1 T raw / 17.8 T used / 11.3 T free, 61 % full, frag 17 % | spec's numbers confirmed exactly; `free` is physical (parity included) → true usable free is lower |
| NAS cache | **1 TB NVMe as L2ARC, 76 % full** | suggests RAM-starved reads; reassess in redesign |
| NAS apps | **Docker containers running + Tailscale up on the NAS** | "NAS is just storage" is false today |
| Snapshots / BEs | 82 snapshots; **5 boot environments** | cleanup opportunity |
| Management network | VLAN-tagged; NAS side labels differ from Proxmox side | verify tag consistency during redesign |
| UniFi | UDM Pro is the LAN gateway; current DNS/DHCP/inventory **not yet captured** | needs API token or UI export |

**Unknowns still open** (see §10 for the full capture list): `main` datasets/shares/ACLs, snapshot &
replication tasks, service list, DNS resolver config, UniFi VLAN/DHCP/DNS state, NIC speeds, P4 IOMMU group,
what the `portainer` VM actually holds.

---

## 4. Target architecture

| Layer | Choice | Notes |
|---|---|---|
| Hypervisor | Proxmox VE | existing host, to be rebuilt clean |
| IaC | OpenTofu, separate state per system | `unifi` / `proxmox` / `truenas` (+ `talos` only if justified) |
| Storage | TrueNAS for persistent data; local SSD for VM boot disks | decide NFS vs SMB vs CSI from requirements |
| Network | UniFi UDM Pro, **additive-only** automation (§4.4) | storage link subnet to be redesigned deliberately |
| Kubernetes | Talos Linux + Flux CD | topology per §4.1 |
| Ingress/certs | Traefik + cert-manager (Cloudflare DNS-01) | mgmt stays private; Tunnel for select apps only |
| Identity | Authentik (web SSO) | never required for infra recovery |
| DNS | Technitium (candidate) | must not be a bootstrap circular dependency |
| Apps | Immich, Audiobookshelf, Nextcloud **or** Seafile (pick one), Stremio/debrid (local-only), Forgejo (later) | incremental |

### 4.1 Topology decision (Phase 0 hypothesis)
One physical host ⇒ multiple control-plane VMs ≠ HA. **Hypothesis: 1 control-plane + 1–2 workers**, expandable
later. Never claim host-level HA. Decide from measured workload need.

### 4.2 Ownership boundaries (no overlaps)
- **OpenTofu:** infra resources + VM lifecycle.
- **Talos tooling:** bootstrap, machine config, OS upgrades.
- **Flux:** all ongoing Kubernetes config (platform + apps).
- **Runbooks/scripts:** exceptional recovery/migration ops.

### 4.3 Testing & lab strategy  ← core requirement
We will not test against live hardware. Tests run in layers:

- **L0 — Static (CI, no infra):** `tofu fmt -check -recursive` + `validate` + tflint + trivy/checkov;
  `kustomize build` + `kubeconform` + `conftest` (+ `helm lint`/`template`, `flux-local` for Flux rendering);
  `shellcheck`+`shfmt`, `yamllint`, `markdownlint`, `gitleaks`. Pinned tool versions. PRs never touch live.
- **L1 — Disposable fixtures (ephemeral):**
  - *Proxmox provider* → nested **PVE-in-a-VM** (workstation reports `kvm_intel nested=Y`).
  - *TrueNAS provider* → **TrueNAS SCALE VM** with a few small virtio disks.
  - *UniFi provider* → **self-hosted UniFi Network Application in Docker** as a fixture (caveat: UDM Pro's
    internal controller API differs — best-effort; real UDM changes stay gated/manual).
  - *Talos* → `talosctl cluster create` (docker) or QEMU; validates machine config + bootstrap offline.
  - *OpenTofu modules* → native `tofu test`.
- **L2 — Integration rehearsal:** full stack in the lab (nested PVE + nested NAS + Talos + Flux) before any
  real apply. The eventual **wipe + rebuild itself is a rehearsed runbook**, executed only with approval.
- **L3 — Restore/DR drills:** restore backups into isolated targets; record results.

**Constraints to respect**
- Workstation: 22 threads, KVM + libvirt/qemu present, but **~6.6 GiB RAM free and disk 91 % full (~90 G free)** →
  needs cleanup and/or a dedicated disk/NVMe before it can host PVE+NAS guests simultaneously.
- `poseidon` has only 4 cores and is currently RAM-saturated → poor host for heavy nested labs until rebuilt.
- **Can't be virtualized:** Tesla P4 passthrough and the real UDM Pro → these are tested on hardware only, under gate.

**Rule:** every module/config used against live infra must first pass its L1/L2 target; CI is L0-only.

### 4.4 UniFi policy — additive-only, non-breaking
1. IaC may **create new** objects (new VLANs/subnets, DHCP reservations, firewall rules for new infra) freely.
2. IaC must **never modify, rename, or delete** existing objects that serve current house devices.
3. Adoption/migration of an existing UniFi object happens **only** as an explicit, scheduled per-object task,
   with a fresh config export and a written rollback, approved at a gate.
4. Take a UniFi config export before any change; keep the previous one until validated.
5. IPv6 DNS behaviour must be checked so it doesn't silently bypass the internal resolver.
6. The UniFi API key is **full-access** (no read-only option), so these rules are enforced by **process**:
   plan-only by default, applies are manual with the owner present, and the key lives outside the repo
   (see `docs/secrets-and-state.md` §4).

---

## 5. Target repo structure

```text
homelab/
├── README.md  CONTRIBUTING.md  SECURITY.md  LICENSE
├── versions.yaml
├── docs/
│   ├── architecture.md  hardware.md  network-plan.md  storage.md
│   ├── backup-policy.md  backup-matrix.md  security.md
│   ├── secrets-and-state.md  upgrades.md  disaster-recovery.md
│   ├── private/            # gitignored — raw audit data
│   └── runbooks/           # incl. phase-reports/
├── infrastructure/{modules,environments/homelab/{unifi,proxmox,truenas,talos}}
├── kubernetes/{bootstrap,infrastructure,security,platform,apps}
├── scripts/                # incl. lab fixture bring-up
├── tests/
└── .github/workflows/
```

---

## 6. Phases

### Phase 0 — Audit & architecture (in progress)
- [x] Repo state inspected; prior work confirmed intentionally deleted
- [x] Read-only discovery of Proxmox + TrueNAS (raw in `docs/private/`, sanitized in `docs/`)
- [x] Capture gaps closed: `main` datasets, shares, services, snapshot task, DNS, NIC speeds, VM 100, P4 IOMMU group
- [x] Drafted `docs/hardware.md`, `network-plan.md`, `storage.md`, `risk-register.md`, `lab.md` + `versions.yaml`
- [ ] Capture UniFi state (API token or UI export) — read-only
- [ ] Data-preservation plan: confirm Tier-1 directories + the VM disk on the `proxmox` share
- [ ] Write `docs/architecture.md` (target) + migration/rebuild plan
- [ ] Produce open-questions list → **⛔ GATE 0**

### Phase 1 — Repository foundation
- [ ] README/CONTRIBUTING/SECURITY/versions.yaml; scaffolding per §5
- [ ] CI L0 (fmt/validate/lint/scan) with pinned tool versions; secret scanning
- [ ] Secret strategy (SOPS+age) + **state backend** design → `docs/secrets-and-state.md`
- [ ] `scripts/` + `tests/` lab harness skeleton (kind/k3d, UniFi controller container, nested PVE/NAS) → **⛔ GATE 1**

### Phase 2 — TrueNAS inventory & backup design
- [ ] Finish NAS inventory incl. `main` datasets, shares, SSO/users, tasks, services
- [ ] Classify every dataset into backup tiers (§7)
- [ ] Backup matrix draft; choose mechanism (remote ZFS replication vs restic/borg) with evidence
- [ ] Evaluate offsite machine at family member's home (capacity/power/network/admin)
- [ ] Verify `truenas/truenas` provider: release status, API version, OpenTofu compatibility, resource coverage
- [ ] Local snapshot policy → **⛔ GATE 2**

### Phase 3 — Infrastructure IaC (greenfield — build, don't import)
- [ ] OpenTofu roots per state boundary; providers pinned + compatibility documented
- [ ] Author UniFi/Proxmox/TrueNAS configs under the **additive-only** policy (§4.4)
- [ ] **Every config validated in L1 fixtures before any live plan**
- [ ] CI: plan preview on PRs; protected environment for applies → **⛔ GATE 3 before any live apply**

### Phase 4 — Approved rebuild (owner wipes; agent reconfigures)  ⚠️ destructive
- [ ] Pre-flight: verified backups, config exports, written step-by-step restore plan, **owner approval**
- [ ] **Owner** wipes/reinstalls Proxmox — agent does **not** touch it; afterwards agent applies `proxmox` Tofu and builds the Talos VM template
- [ ] **Owner** reinstalls TrueNAS — agent does **not** touch it; afterwards agent applies `truenas` Tofu
- [ ] Pool: **preserve/import if the owner chooses** (spec §6.2 preference), else rebuild only with explicit per-operation approval
- [ ] Configure datasets/shares/permissions/services; verify storage link (interface, MTU, throughput)
- [ ] Re-apply UniFi objects additively; verify management reachability after each step → **⛔ GATE 4 per risky step**

### Phase 5 — Talos & Kubernetes bootstrap
- [ ] Pin Talos + Kubernetes versions; build node VMs via Tofu; secrets kept out of repo
- [ ] Bootstrap control plane, join workers, CNI, storage reachability, ingress
- [ ] No HA claims on single host → **⛔ GATE 5**

### Phase 6 — Flux & platform services
- [ ] Bootstrap Flux from repo with clear ordering/health checks
- [ ] Platform: ingress, CSI/storage, DNS (with independent recovery), cert-manager, monitoring baseline
- [ ] Bootstrap must not depend on in-cluster DNS or Authentik → break-glass documented → **⛔ GATE 6**

### Phase 7 — Applications (incremental)
- [ ] One app at a time; documented per-app (pins, ingress/auth, storage, secrets, resources, backup+restore, upgrade/rollback, exposure)
- [ ] Immich media+DB consistency; Audiobookshelf; Nextcloud **or** Seafile (decision documented); Stremio local-only; Forgejo later → **⛔ GATE 7 before any public exposure**

### Phase 8 — Backup automation & verification
- [ ] Implement offsite mechanism: encryption, retention, deletion protection, monitoring, schedule
- [ ] Verify first backup **and restore it** (into a test target)
- [ ] Alerts: last-success age, failures, size anomalies; document transfer times → **⛔ GATE 8 after a successful restore test**

### Phase 9 — Upgrade & operations automation
- [ ] Talos upgrade runbook (pre-checks, order, verification, rollback limitations honored)
- [ ] K8s/tool/chart upgrades: manual gate, changelog read, one at a time, verify after each
- [ ] Prove normal applies never side-effect OS upgrades → **⛔ GATE 9**

### Phase 10 — Disaster recovery validation
- [ ] DR runbooks for the spec's scenario list
- [ ] Non-destructive restore tests (file-level offsite, config, DB consistency)
- [ ] Verify recovery without Kubernetes; final recovery checklist → **⛔ GATE 10 = exit**

---

## 7. Backup tiers

| Tier | Content | Offsite | Retention/notes |
|---|---|---|---|
| 1 | Irreplaceable personal data (photos, docs, unique projects) | **Yes**, encrypted, versioned, daily | restore-tested; alerts |
| 2 | Operational (NAS config export, Tofu state, key secrets, app DBs, costly app config, Git/IaC) | Where justified | recoverable without cluster |
| 3 | Replaceable bulk (movies, ISOs, media, caches) | No by default | local snapshots only if worth it |
| 4 | Disposable (temp, build/derived data) | No | verify exclusions don't kill sole copies |

Hard rules: a dataset must have a tier (unclassified data gets flagged); snapshots ≠ backups; DBs need consistent
dumps; deletion protection must be **tested**; keys stored outside both source and destination; monitor last-success
age + size anomalies.

---

## 8. Fact-collection checklist (read-only) — remaining
- **TrueNAS:** `zfs list -r main` (used/avail/quota/reservation/mountpoint), `sharing.smb.query`,
  `sharing.nfs.query`, `user.query`/`group.query`, `replication.query`, `pool.snapshottask.query`,
  `service.query`, `/etc/resolv.conf`, `smartctl -x` per disk, `ethtool` per NIC.
- **Proxmox:** `qm config 100` (redact secrets), `ethtool` speeds, P4 IOMMU group, `apt-get -s upgrade`, `smartctl -H`.
- **UniFi:** VLANs, DHCP ranges, DNS servers, IPv6 settings, firmware (API token preferred, else UI export).
- **Offsite candidate:** hardware, disks, bandwidth, power, admin, physical security.

---

## 9. Decision log (append-only)

| Date | Decision | Rationale |
|---|---|---|
| 2026-10-16 | **Greenfield rebuild**: no import/adoption; wipe both hosts once ready | owner intent; simplifies IaC |
| 2026-10-16 | **Owner performs the host reset; agents are read-only** until the owner opens a gate | owner instruction; hosts treated as production |
| 2026-10-16 | **UniFi key is full-access → process-enforced least privilege** (plan-only, additive-only, key off-repo) | provider offers no read-only keys |
| 2026-10-16 | **UniFi additive-only**, non-breaking migration | must not disrupt house appliances |
| 2026-10-16 | **Layered lab testing** (§4.3); no live testing without gate | safety + reproducibility |
| 2026-10-16 | Raw discovery data kept in gitignored `docs/private/` | repo is public |

## 10. Open questions for the owner

1. ⛔ May an agent use a **read-only UniFi API token** (vs. you exporting the UI config)?
2. ⛔ Confirm the **Tier-1 data set** on the NAS (photos/documents/which VM exports) so it is preserved pre-wipe.
3. Is any existing TrueNAS pool to be **preserved/imported**, or fully designed fresh? (RaidZ3 of 8×4 TB is already good.)
4. Offsite machine at the sister's home: exists today, or to be purchased? bandwidth/power sensitivity?
5. Alert channel preference (Telegram / email / other)?
6. Domain/Cloudflare for cert-manager + Tunnel? Public exposure preferences?
7. VPN for remote admin (Tailscale already on the NAS — reuse or separate)?
8. Workstation cleanup: OK to free/move data (~90 G free) or add a disk/NVMe for the lab?

## 11. Status log (append-only)

| Date | Phase | Event |
|---|---|---|
| 2026-10-16 | 0 | Read-only discovery of Proxmox + TrueNAS; findings recorded (private). No changes made. |
| 2026-10-16 | 0 | Plan document + `.gitignore` created. Greenfield + UniFi additive-only + lab-testing decisions logged. |
| 2026-10-16 | 0 | Governing spec captured as `docs/SPEC.md`; "owner resets hosts, agents read-only" rule recorded. |
| 2026-10-16 | 0 | Phase 0 docs drafted (hardware/network/storage/risk/lab) + `versions.yaml` (latest versions verified 2026-10-16). |
| 2026-10-16 | 1 | Target architecture + repo foundation (README, CONTRIBUTING, SECURITY, CI, linting, secret scanning) + `docs/secrets-and-state.md`. |
| 2026-10-16 | 1 | Justfile task runner + `.actrc` added; CI verified locally with `act` (opentofu, kubernetes, lint jobs pass). |
| 2026-10-16 | 2 | Backup policy + backup matrix drafted (`docs/backup-policy.md`, `docs/backup-matrix.md`); mechanism choice still open. |
| 2026-10-16 | 3 | OpenTofu roots scaffolded for proxmox/truenas/unifi; `tofu validate` passes and provider OpenTofu-1.13.1 compatibility confirmed. |
| 2026-10-16 | 5-7 | Flux GitOps tree scaffolded (`kubernetes/`): infra controllers + 2 apps; manifests build with kustomize and pass kubeconform. |
| 2026-10-16 | 8 | restic backup/verify scripts + systemd units added (env-driven, no secrets committed). |
| 2026-10-16 | 9-10 | Upgrade and disaster-recovery runbooks added (`docs/runbooks/`, `docs/disaster-recovery.md`). |

## 12. Phase report template (`docs/runbooks/phase-reports/phase-NN.md`)

```text
1. What was inspected
2. What changed (files only)
3. Design rationale
4. Validations/tests run
5. Actual results (pass/fail, exact)
6. Risks / unresolved issues
7. Manual actions still required
8. Live change made? (describe + approval ref / No)
9. Needed next (approval / info / gate)
```

## 13. Definition of done (summary)
Infra version-controlled + pinned + additive-safe; TrueNAS inventoried with explicit preservation and no
unapproved destructive ops; backup matrix with Tier-1 offsite + **tested** restores and independent keys;
Kubernetes reproducibly bootstrapped with clear ownership and documented upgrade/recovery; no secrets in the
public repo; CI does PR validation and gates live applies; **lab tests exist for each module before it touches hardware**.
