# Homelab — Project Plan

**Status (2026-10-20):** the platform is built and validated **offline**. The Flux tree reconciles in the kind
lab. Nothing has been applied to a real cluster or to the physical hosts.
**Owner:** Arthur
**Mode:** greenfield rebuild, proven on local VMs first (`docs/decisions.md` §1.1). The physical hosts
(`poseidon` Proxmox, `hercules-nas` TrueNAS) stay read-only until the owner wipes and reinstalls them from ISO.
After that install, everything comes from IaC (§1.2–1.4).

This file is the to-do list and the execution rules. Where things are defined:

- **Decisions:** `docs/decisions.md` wins over everything else, including this file.
- **Architecture:** `docs/architecture.md`.
- **Facts:** `docs/hardware.md`, `docs/network-plan.md`, `docs/storage.md`.
- **The owner's original brief:** `docs/SPEC.md`. It is historical; where it differs, decisions.md applies.

Raw discovery output (addresses, serials) lives in the gitignored **`docs/private/`** and is never committed or
quoted.

---

## 0. Rules of engagement

1. **Audit before implementation.** Inventory, propose, wait, then change. Never touch live systems first.
2. **No inventions.** Never invent hardware, disks, IPs, API capabilities or provider resources. Inspect
   read-only, ask, or mark the item `[UNKNOWN]`.
3. **No destructive actions without per-operation approval.** See §1.
4. **Label every claim:** *implemented / validated statically / tested in lab / tested live / documented, not
   implemented / planned*. A successful command is not proof.
5. **Small reviewable diffs:** one logical change per commit.
6. **Challenge the spec in writing:** record a deviation in `docs/decisions.md`; never change course silently.
7. **Stop at every ⛔ GATE** until the owner explicitly approves. In code, `TODO(GATE 4)` marks a value that
   can only be confirmed at cutover, such as the control-plane address or a VLAN tag.
8. **Update this file** (checkboxes, open items, status log) in the same change as the work.
9. **Nothing private in tracked files.** Addresses from discovery, serials and credentials go in `docs/private/`
   or in chat.

## 1. Red lines: never without explicit, operation-specific approval

- Destroy or recreate a VM, container, pool, dataset or filesystem.
- Repartition, format, wipe or repurpose a physical disk; create, destroy or change a ZFS pool.
- **Wipe or reinstall Proxmox or TrueNAS.** The owner does this, never an agent. Agents do not initiate, script,
  automate or `tofu destroy` toward it.
- Any write to the physical hosts before cutover (decisions §1.2).
- Live UniFi changes beyond the additive policy in §4.
- A `tofu apply` that destroys or replaces resources. **Never `-auto-approve` on live infra.**
- Delete persistent app data or backups.
- Credential rotation that could lock out admins.
- A migration that removes the source before the destination is verified.
- Auto-prune on a backup destination before retention and deletion protection are tested.

## 2. Priorities and non-negotiables

Priorities, in order:

1. Data safety and recoverability.
2. Security.
3. Correctness and reproducibility.
4. Maintainability.
5. Efficiency.
6. Convenience.

Non-negotiables:

- **Out of scope; do not touch or depend on:** the external Dokploy server and its Tailscale route.
- **The house network must keep working.** UniFi changes are additive only (§4).
- **The repo is public.** Never commit credentials, keys, Talos secrets, kubeconfigs, state, plans or `.env`.
- **No Jellyfin.**
- **Management interfaces stay private.** Recovery must not depend on Kubernetes being up.
- **The lab must not change host networking.** The libvirt harness (`just lab-virt-up`) is run by the owner.

## 3. How things are tested

| Layer | What | Where |
|---|---|---|
| L0, static | gitleaks, the SOPS gate, `tofu fmt`/`validate`, kustomize + kubeconform, the cluster-settings guard, `helm template` of every HelmRelease, actionlint, markdownlint, yamllint, shellcheck | CI (`.github/workflows/ci.yml`), runnable locally with `just ci` (act) or `just check` |
| L0, Talos | `talosctl validate --mode metal` on generated configs | `just talos-validate` (local only) |
| L1, Kubernetes | kind + an in-cluster git server + Flux reconciling the real tree | `just lab-up` |
| L1, nodes | libvirt guests: Talos CP + worker, a Debian NFS/SMB stand-in for the NAS | `just lab-virt-*` (`docs/lab.md`) |
| L1, providers | nested PVE (proxmox provider), self-hosted UniFi controller (unifi provider) | **not built** |
| L2 | the full stack in the lab before any live apply | not started |
| L3 | restore drills into isolated targets | not started |

These cannot be virtualised: Tesla P4 passthrough and the real UDM Pro. They are tested on hardware only, under
a gate. **Rule:** a config used against live infra must first pass its L1/L2 target.

## 4. UniFi policy: additive only, non-breaking

1. IaC may **create** objects (new VLANs and subnets, DHCP reservations, firewall rules for new infra).
2. IaC must **never modify, rename or delete** objects that serve current house devices.
3. An existing object is adopted only as an explicit per-object task: a fresh export, a written rollback, and
   approval at a gate.
4. Take a config export before any change. Keep the previous export until the change is validated.
5. Check that IPv6 DNS does not silently bypass the internal resolver.
6. The API key is full-access (no read-only option exists), so these rules are enforced by process:
   - plan-only by default;
   - applies are manual, with the owner present;
   - the key lives outside the repo (`docs/secrets-and-state.md`, decisions §5.3).

## 5. Repo map

```text
versions.yaml        every pinned version (authoritative) + open compatibility checks
Justfile             task runner: check, ci, validate, k8s-validate, render, talos-*, lab-*, secrets-*
docs/                decisions, architecture, hardware, network-plan, storage, backup-policy, backup-matrix,
                     secrets-and-state, disaster-recovery, risk-register, lab, apps/, runbooks/
                     private/ (gitignored)
infrastructure/      OpenTofu: modules/talos-vm, environments/homelab/{proxmox,truenas,unifi}
talos/               Talos inputs (prod + lab) and machine-config patches; out/ is gitignored
kubernetes/          Flux: clusters/{homelab,lab}, infrastructure/ (controllers + configs), apps/
scripts/             check.sh, ci/, lab/ (kind + virt/), secrets/, talos/, backup/
.github/             CI workflow, dependabot
```

---

## 6. Phases

Legend: `[x]` done · `[ ]` not done; an *italic note* means started. Reconciled against the repo on **2026-10-20**.

### Phase 0: Audit and architecture (complete; GATE 0 answered 2026-10-16)

- [x] Read-only discovery of Proxmox and TrueNAS (raw data in `docs/private/`, sanitized in `docs/hardware.md`)
- [x] Architecture, address plan, topology, storage mapping, CNI and alerts decided (`docs/decisions.md`)
- [ ] Capture UniFi state: the export and the management VLAN tag *(key approved, not yet handed over)*
- [ ] Data-preservation plan: confirm the Tier-1 directories *(deferred to cutover prep, owner-driven)*

### Phase 1: Repository foundation and lab, ⛔ GATE 1

- [x] README, CONTRIBUTING, SECURITY, `versions.yaml`, Justfile
- [x] CI L0 with pinned tools, runnable locally via `act`
- [x] SOPS + age secret tooling and the CI gate; state-backend design (`docs/secrets-and-state.md`)
- [x] kind + Flux lab reconciling the real tree (`just lab-up`)
- [x] libvirt harness for Talos and NAS guests (`scripts/lab/virt/`)
- [ ] **Lab Talos install completes.** Blocked: the guest cannot install its default route, so it has no DNS
      and the installer pull fails (`docs/lab.md`, *Status and known issues*)
- [ ] Lab worker, lab NAS NFS path (now exported at `/mnt/main/k8s`, unverified), and a Talos + Flux run on the
      guests
- [ ] L1 provider fixtures: nested PVE, self-hosted UniFi controller

### Phase 2: TrueNAS inventory and backup design, ⛔ GATE 2

- [x] Backup policy and matrix drafted (`docs/backup-policy.md`, `docs/backup-matrix.md`); tiered dataset design
      (decisions §4.1)
- [ ] Classify every dataset into a tier *(needs owner input)*
- [ ] Choose the mechanism (ZFS replication vs restic) once the offsite target exists *(deferred, decisions §5.5)*
- [ ] Verify the `truenas/truenas` provider against the 24.10 API (`versions.yaml` verification_tasks)
- [ ] Local snapshot policy

### Phase 3: Infrastructure IaC (greenfield: build, don't import), ⛔ GATE 3 before any live apply

- [x] OpenTofu roots per state boundary; providers pinned; lock files committed; `tofu validate` clean
- [x] Proxmox: the `talos-vm` module and the decided topology (1 CP + 1 worker with a data disk)
- [ ] TrueNAS resources (datasets, NFS share, snapshot tasks) *(needs live-API verification)*
- [ ] UniFi resources: K8s VLAN 20 and storage link, additive only *(needs the export and provider verification)*
- [ ] Every config validated in an L1 fixture before any live plan
- [ ] CI plan preview; protected environment for applies

### Phase 4: Hardware cutover (owner-executed), ⛔ GATE 4 per risky step

> Deferred until the VM lab has proven every module. Until then the physical servers get **no writes of any
> kind** (decisions §1.2).

- [ ] Pre-flight (owner): all data verified as backed up; config exports captured; written step-by-step plan
- [ ] Owner reinstalls Proxmox and TrueNAS from ISO
- [ ] Everything after the ISO install is applied by IaC. Hand-made config is a defect
- [ ] Pool: preserve/import vs rebuild is decided at cutover, after backups are verified (decisions §1.4)
- [ ] Fill every `TODO(GATE 4)` value (`grep -rn "TODO(GATE 4)"`); verify the storage link (interface, MTU,
      throughput)

### Phase 5: Talos and Kubernetes bootstrap, ⛔ GATE 5

- [x] Talos v1.14.4 / K8s v1.37.1 pinned; config generation and offline validation (`talos/`, `scripts/talos/`)
- [x] Patches: Flannel and kube-proxy off for Cilium; the local-path user volume on the worker data disk
- [x] Guarded bootstrap/kubeconfig helpers and runbook (`docs/runbooks/talos-bootstrap.md`)
- [ ] Bootstrap the control plane, join the worker, bring up Cilium, check storage reachability *(lab first)*
- [ ] No HA claims on a single host

### Phase 6: Flux and platform services, ⛔ GATE 6

- [x] Flux tree with ordering: infrastructure → infrastructure-configs → apps; per-cluster `cluster-settings`
      (MetalLB pool, NFS server) substituted at build time
- [x] Cilium, MetalLB, Traefik, cert-manager, Technitium, kube-prometheus-stack (SMTP alerts), csi-driver-nfs
      (`nas-nfs`), local-path; all render; the kind lab installed cert-manager, MetalLB and Traefik
- [ ] Real Flux bootstrap against a Talos cluster
- [ ] Let's Encrypt DNS-01 ClusterIssuer via Cloudflare with a zone-scoped token, and a wildcard for
      `*.lab.ardw.be` (decisions §5.7). Today only `internal-ca` exists
- [ ] Traefik: HTTP→HTTPS redirect, default certificate, dashboard exposure
- [ ] Technitium: persistence, forwarders, a fixed LoadBalancer IP, trimmed ports; the split-horizon records
- [ ] Monitoring persistence (Prometheus, Alertmanager and Grafana state is ephemeral today)
- [ ] mDNS reflection across zones, if needed (decisions §2.6)
- [ ] Break-glass access that does not depend on in-cluster DNS or Authentik is documented

### Phase 7: Applications, ⛔ GATE 7 before any public exposure

- [x] Immich and Audiobookshelf specified, rendering, with per-app notes (`docs/apps/`); hosts are
      `<app>.lab.ardw.be`
- [ ] `immich-db` Secret (SOPS) before first deploy; move the app certificates to the LE wildcard
- [ ] Authentik SSO
- [ ] Nextcloud **or** Seafile (decision recorded), Stremio local-only, Forgejo mirror later (decisions §5.4)

### Phase 8: Backup automation and verification, ⛔ GATE 8 after a successful restore test

- [x] restic backup/check scripts and systemd units (`scripts/backup/`; dormant until a target exists)
- [x] Immich database dump job (`kubernetes/apps/immich/backup.yaml`)
- [ ] Offsite target purchased and built (decisions §5.5, deferred)
- [ ] Wire the backup failure alerts (`OnFailure=`; see `scripts/backup/README.md`)
- [ ] First backup **and a restore of it** into a test target
- [ ] Alerts on last-success age, failures and size anomalies

### Phase 9: Upgrades and operations, ⛔ GATE 9

- [x] Upgrade runbook (`docs/runbooks/upgrades.md`): Talos, K8s, charts, one at a time with verification
- [ ] Resolve the open compatibility checks in `versions.yaml`: the Flux K8s range, the UniFi provider, Helm 4
- [ ] Prove that normal applies never trigger OS upgrades

### Phase 10: Disaster recovery validation, ⛔ GATE 10 = exit

- [x] DR runbooks for the spec's scenarios (`docs/disaster-recovery.md`)
- [ ] Non-destructive restore tests (offsite files, config, DB consistency)
- [ ] Recovery verified without Kubernetes; final checklist

---

## 7. Backup tiers

| Tier | Content | Offsite | Notes |
|---|---|---|---|
| 1 | Irreplaceable personal data (photos, documents, unique projects) | **Yes**: encrypted, versioned, daily | restore-tested; alerts |
| 2 | Operational (NAS config, Tofu state, key secrets, app DBs, Git/IaC) | where justified | recoverable without the cluster |
| 3 | Replaceable bulk (movies, ISOs, media, caches) | no | local snapshots only if worth it |
| 4 | Disposable (temp, build output) | no | check exclusions don't hit sole copies |

Hard rules:

- Every dataset has a tier; unclassified data is flagged.
- Snapshots are not backups.
- Databases need consistent dumps.
- Deletion protection must be **tested**.
- Keys are stored outside both the source and the destination.
- Monitor last-success age and size anomalies.

## 8. Still open with the owner

- **UniFi:** the API key handover, a config export, and the management VLAN tag and NAS/Proxmox VLAN mismatch.
- **Offsite:** hardware to purchase or build (decisions §5.5).
- **Cloudflare:** a token scoped to `lab.ardw.be` for DNS-01 (needed before real certificates).
- **Tier 1:** the directory list, at cutover prep.
- **Redaction policy:** `docs/SPEC.md` replaces private addresses with placeholders. `docs/network-plan.md`
  and `docs/decisions.md` show the planned RFC 1918 addresses. Pick one convention.

## 9. Status log (append-only, one line per event)

| Date | Phase | Event |
|---|---|---|
| 2026-10-16 | 0 | Read-only discovery of both hosts; findings kept private. No changes made. |
| 2026-10-16 | 0 | Plan, `docs/SPEC.md`, Phase 0 docs and `versions.yaml` drafted. |
| 2026-10-16 | 1 | Repo foundation, CI (verified with `act`), Justfile, secrets design. |
| 2026-10-16 | 2,8 | Backup policy/matrix drafted; restic scripts and systemd units written. |
| 2026-10-16 | 3 | OpenTofu roots for proxmox/truenas/unifi; providers validate under OpenTofu 1.13.1. |
| 2026-10-16 | 6,7 | Flux tree scaffolded; kind lab built. The lab found a CRD-ordering bug and a Technitium values bug; both fixed. |
| 2026-10-16 | 1 | CI gained the `helm template` render check for every HelmRelease. |
| 2026-10-16 | 0 | **GATE 0 answered** (`docs/decisions.md`). Found that the NAS points at a dead resolver; recorded, not changed. |
| 2026-10-16 | 3,5 | `talos-vm` module and topology authored; Talos config generation validates. Nothing applied. |
| 2026-10-16 | 6 | csi-driver-nfs (`nas-nfs`), Cilium with kube-proxy replacement, local-path on a worker data disk. |
| 2026-10-16 | 6,8 | Alertmanager SMTP delivery; the SOPS gate enforced in CI. |
| 2026-10-16 | 7 | Immich and Audiobookshelf fully specified. |
| 2026-10-16 | 1 | Fixed a false-green `just k8s-validate` that validated nothing. |
| 2026-10-16 | 1 | libvirt guest harness added; the Talos install is blocked on the guest default route. |
| 2026-10-20 | all | Review-and-cleanup round. Bugs fixed: per-environment `cluster-settings` (no more TEST-NET MetalLB pool in production); PSA `privileged` labels on the cilium/metallb/storage/monitoring namespaces; the Immich dump job's shell; `gen-configs --force` passthrough; the lab worker skips the 90 GiB volume; the lab NAS exports the production NFS path; restic check no longer restores all of Tier 1; `lab-git-image` no longer copies ignored files; the systemd unit fixes. Also: stale gate labels, hostnames per §5.7, and this plan rewritten. |

## 10. Definition of done

- [ ] Infra version-controlled, pinned and additive-safe, and applied from IaC after cutover
- [ ] TrueNAS inventoried, with explicit preservation and no unapproved destructive operations
- [ ] Tier-1 offsite backups with **tested** restores and independent keys
- [ ] Kubernetes reproducibly bootstrapped, with documented upgrade and recovery
- [x] No secrets in the public repo (`.gitignore`, gitleaks and the SOPS gate in CI)
- [x] CI validates every PR statically *(live-apply gating still to add)*
- [ ] Every live-facing config proven in the lab first *(K8s/Flux layer yes; Talos guests, PVE and UniFi
      fixtures not yet)*
