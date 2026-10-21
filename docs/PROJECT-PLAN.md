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
| L1, providers | nested PVE (proxmox provider), self-hosted UniFi controller (unifi provider) | `just lab-pve-plan`, `just lab-unifi-plan` (`docs/lab.md`) |
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
- [x] Lab Talos install completes *(2026-10-20: static per-node network config, Image Factory installer; the
      control plane bootstraps and the worker joins, `docs/lab.md`)*
- [x] Lab worker and lab NAS NFS/SMB path (exported at `/mnt/main/k8s`) verified
- [x] A full Talos + Flux run on the guests *(2026-10-20, `clean-slate@f61c006`: 3 Kustomizations and all 11
      HelmReleases Ready; `docs/runbooks/phase-reports/phase-lab-virt-2026-10-20.md`)*
- [x] L1 UniFi fixture: self-hosted Network Application 10.6.106, provider 0.59.0; plan 1 add, apply, second plan
      "No changes" (`just lab-unifi-plan`, `docs/lab.md`). Unproven: the API-key path, UDM gateway/zone
      behaviour, the real VLAN 20 conflict gate
- [x] L1 Proxmox fixture: nested Proxmox VE 8.4, provider bpg/proxmox 0.116.1; plan 3 to add, apply, second plan
      "No changes", destroy 3, run twice on 2026-10-21 (`just lab-pve-plan`, `docs/lab.md`). Unproven: booting the
      Talos VMs under Proxmox, the real host's datastore, bridge, VLAN tag and token privileges

### Phase 2: TrueNAS inventory and backup design, ⛔ GATE 2

- [x] Backup policy and matrix drafted (`docs/backup-policy.md`, `docs/backup-matrix.md`); tiered dataset design
      (decisions §4.1)
- [ ] Classify every dataset into a tier *(the tier datasets themselves are authored in `truenas/tiers.tf` and
      applied on the L1 fixture (2026-10-21: `main/tier1` with arthur, jolien and dunia, `main/media`,
      `main/scratch`; re-plan "No changes"). Not yet on the real NAS, and deciding which of the owner's future
      data goes in which tier needs owner input)*
- [ ] Choose the mechanism (ZFS replication vs restic) once the offsite target exists *(deferred, decisions §5.5)*
- [x] Verify the `truenas/truenas` provider: 1.5.14 against an L1 TrueNAS SCALE 25.10.7 fixture (2026-10-21,
      `just lab-truenas-plan`): plan 3 to add, apply, API check, second plan "No changes". It needs SCALE ≥ 25.04
      (its WebSocket API) and hercules-nas runs 24.10, so a real plan waits on the owner's upgrade
- [ ] Local snapshot policy *(all §4.1 tasks are authored: `truenas/k8s.tf`, `backups.tf`, `tiers.tf`. The `tiers.tf`
      tasks (tier1 recursive hourly at :10, 30 DAY; media Sundays 01:00, 4 WEEK) were applied on the L1 fixture
      on 2026-10-21 and read back over the API, re-plan "No changes". Nothing runs on the real NAS: that apply
      is owner-gated)*

### Phase 3: Infrastructure IaC (greenfield: build, don't import), ⛔ GATE 3 before any live apply

- [x] OpenTofu roots per state boundary; providers pinned; lock files committed; `tofu validate` clean
- [x] Proxmox: the `talos-vm` module and the decided topology (1 CP + 1 worker with a data disk)
- [ ] TrueNAS resources *(the `main/k8s` dataset, its NFS share and snapshot task (`truenas/k8s.tf`), and the
      household backup datasets, Time Machine share, Kopia and Seafile exports (`truenas/backups.tf`) are
      authored and proven on the L1 fixture. **Blocked** on the real NAS: ≥ 25.04, see Phase 2)*
- [ ] UniFi resources: K8s VLAN 20 and storage link, additive only *(the `hl-k8s` network, VLAN 20, is
      authored on provider 0.59.0 with `prevent_destroy` and validates. The host fixed IPs (poseidon
      `10.10.1.1`, hercules-nas `10.10.1.10`) are a narrow, owner-approved take-over of those two client
      records (`unifi/host-reservations.tf`), proven on the L1 fixture. Open: the `TODO(GATE 4)` values,
      the storage link, and a plan against the export)*
- [x] Every config validated in an L1 fixture before any live plan *(`unifi`, `proxmox` and `truenas` roots:
      `just lab-unifi-plan`, `just lab-pve-plan`, `just lab-truenas-plan`)*
- [ ] CI plan preview; protected environment for applies *(`.github/workflows/tofu-plan.yml` is written and
      dormant: manual dispatch only, a self-hosted `homelab` runner, plan only, never apply. The runner and
      the `homelab-plan` environment are owner setup)*

### Phase 4: Hardware cutover (owner-executed), ⛔ GATE 4 per risky step

> Deferred until the VM lab has proven every module. Until then the physical servers get **no writes of any
> kind** (decisions §1.2).

- [ ] Pre-flight (owner): all data verified as backed up; config exports captured; written step-by-step plan
- [x] Owner reinstalls Proxmox and TrueNAS from ISO *(confirmed by the owner on 2026-10-21; both answer on VLAN 4:
      `poseidon` web UI on 10.10.1.1:8006, `hercules-nas` web UI on 10.10.1.10. Versions still to record)*
- [ ] Everything after the ISO install is applied by IaC. Hand-made config is a defect
- [x] Pool: rebuilt empty by the owner on 2026-10-21 as RAIDZ2 (8× 4 TB) with an NVMe SLOG, name `main` kept (decisions §1.4)
- [ ] Fill every `TODO(GATE 4)` value (`grep -rn "TODO(GATE 4)"`); verify the storage link (interface, MTU,
      throughput)

### Phase 5: Talos and Kubernetes bootstrap, ⛔ GATE 5

- [x] Talos v1.14.4 / K8s v1.37.1 pinned; config generation and offline validation (`talos/`, `scripts/talos/`)
- [x] Patches: Flannel and kube-proxy off for Cilium; the local-path user volume on the worker data disk
- [x] Guarded bootstrap/kubeconfig helpers and runbook (`docs/runbooks/talos-bootstrap.md`)
- [x] Bootstrap the control plane, join the worker, bring up Cilium *(lab, 2026-10-20; both nodes Ready)*
- [x] Check storage reachability from the cluster *(lab: a `nas-nfs` PVC bound and a pod wrote and read a file)*
- [x] No HA claims on a single host *(audited 2026-10-21 with `git grep` for HA, failover, redundancy and
      high availability: every hit disclaims HA (architecture, decisions §3.1, risk R11, Talos bootstrap,
      local-path, storage) or is about disk redundancy, never node redundancy)*

### Phase 6: Flux and platform services, ⛔ GATE 6

- [x] Flux tree with ordering: infrastructure → infrastructure-configs → apps; per-cluster `cluster-settings`
      (MetalLB pool, NFS server) substituted at build time
- [x] Cilium, MetalLB, Traefik, cert-manager, Technitium, kube-prometheus-stack (SMTP alerts), csi-driver-nfs
      (`nas-nfs`), local-path; all render; the kind lab installed cert-manager, MetalLB and Traefik
- [ ] Real Flux bootstrap against a Talos cluster *(lab Talos: done, the full tree is Ready. Real cluster: not started)*
- [x] Let's Encrypt DNS-01 ClusterIssuers (staging, production) via Cloudflare, and a `*.lab.ardw.be` wildcard
      Certificate whose issuer is per cluster (`CLUSTER_ISSUER`: `internal-ca` on the lab). Issuing for real
      needs the Cloudflare token and an ACME email (§8)
- [x] Traefik: HTTP→HTTPS redirect, the wildcard as default certificate (TLSStore), dashboard internal only
- [x] Technitium: persistence, forwarders, a fixed LoadBalancer IP for DNS only, web UI ClusterIP; a CronJob that
      creates the `lab.ardw.be` zone with its apex and wildcard records pointing at Traefik
- [x] Monitoring persistence on `local-path` (Prometheus 20Gi with 15d / 18GB retention, Alertmanager, Grafana)
- [ ] mDNS reflection across zones, if needed (decisions §2.6) *(decided at cutover, on the UDM; nothing in
      this repo yet)*
- [x] Break-glass access that does not depend on in-cluster DNS or Authentik is documented
      (`docs/runbooks/break-glass.md`)

### Phase 7: Applications, ⛔ GATE 7 before any public exposure

- [x] Immich and Audiobookshelf specified, rendering, with per-app notes (`docs/apps/`); hosts are
      `<app>.lab.ardw.be`
- [x] `immich-db` Secret (SOPS) before first deploy; app certificates come from the wildcard *(lab Secret
      generated; the production one waits on the key ceremony, `kubernetes/overlays/homelab/README.md`)*
- [x] Authentik SSO *(Authentik is deployed at `auth.lab.ardw.be` with a daily database dump and mails through
      the relay as `auth@lab.ardw.be`; Seafile signs in through it, declared by a blueprint. Proven in the lab
      2026-10-21: the OIDC discovery document is served for `seafile`, and Seafile's `/oauth/login/` answers 302
      to Authentik's authorize endpoint with `client_id=seafile`; the full login, driven with curl and a throwaway
      user, worked end to end (Seahub user created, uid = hashed `sub`, contact email set), after fixing the
      provider's grant types and, lab only, in-cluster DNS and CA trust for Seahub. Production still needs a
      check that the Seafile pod can reach `auth.ardw.be`, runbook household-backups (c). Other
      apps are still to be wired)*
- [x] Seafile (decisions §5.8) at `seafile.lab.ardw.be`, MariaDB with a daily dump *(proven in the lab
      2026-10-21: login page, admin API token. Authentik OIDC sign-in added the same day)*
- [x] Household device backups (decisions §5.9): Time Machine share for jolien, Kopia server at
      `kopia.lab.ardw.be` for dunia and arthur *(Kopia: a client snapshot through Traefik in the lab;
      Time Machine: the share on the TrueNAS fixture. Runbook: `docs/runbooks/household-backups.md`)*
- [ ] Stremio/debrid: no workload chosen; if one is added it stays local-only (SPEC §12.6)
- [ ] Forgejo mirror *(deferred until production, `docs/future-work.md`; decisions §5.4, §5.6)*

### Phase 8: Backup automation and verification, ⛔ GATE 8 after a successful restore test

- [x] restic backup/check scripts and systemd units (`scripts/backup/`; dormant until a target exists)
- [x] Database dump jobs for Immich, Authentik and Seafile (`kubernetes/apps/*/backup.yaml`), with staleness,
      never-succeeded and failure alerts for every `<app>-db-dump` CronJob
- [ ] Offsite target purchased and built (decisions §5.5, deferred; `docs/future-work.md`)
- [x] Wire the backup failure alerts (`OnFailure=` mails the unit and its journal tail; `scripts/backup/README.md`)
- [x] First backup **and a restore of it** into a test target *(proven in the lab, 2026-10-20: both DB dumps
      restored into a throwaway postgres with matching table counts; restic backup, check and `diff -r` restore.
      `scripts/backup/README.md`)*
- [ ] First backup and restore against the real offsite target (pending the target)
- [x] Alerts on last-success age, failures and size anomalies *(dump under `DUMP_MIN_PERCENT` fails the Job and
      so `DatabaseBackupJobFailed`; restic under `BACKUP_MIN_PERCENT` exits 1 and `OnFailure=` mails. Alerts
      proven to "pending" only, no mail sent)*

### Phase 9: Upgrades and operations, ⛔ GATE 9

- [x] Upgrade runbook (`docs/runbooks/upgrades.md`): Talos, K8s, charts, one at a time with verification
- [ ] Resolve the open compatibility checks in `versions.yaml` *(UniFi provider: done, 0.59.0. Helm 4: partly.
      Flux on K8s 1.37: running on the lab, 1.37.1; the full tree is Ready. TrueNAS provider: proven on a 25.10 fixture; the real NAS is blocked on its version)*
- [x] Prove that normal applies never trigger OS upgrades: on the L1 Proxmox fixture (2026-10-21), bumping
      `versions.yaml` v1.14.4 to v1.14.3 planned "1 to add, 0 to change, 1 to destroy" (only
      `proxmox_download_file.talos`); after apply the VM disks were unchanged and a re-plan was clean. Reasoning in
      the `talos-vm` README

### Phase 10: Disaster recovery validation, ⛔ GATE 10 = exit

- [x] DR runbooks for the spec's scenarios (`docs/disaster-recovery.md`)
- [ ] Non-destructive restore tests (offsite files, config, DB consistency) *(`db-restore-test.sh` (Immich and
      Authentik PostgreSQL, Seafile MariaDB) and `restic-restore-diff.sh` exist and ran in the lab; still to run
      on real hardware)*
- [ ] Recovery verified without Kubernetes; final checklist *(lab, 2026-10-21: no Kubernetes API used. Kopia
      repository opened read-only with `kopia` and the password decrypted from the SOPS tree, a snapshot of the
      real Authentik and Seafile dumps restored with an empty `diff -r`, `kopia snapshot verify` clean. The
      newest Authentik dump restored into a fresh postgres (230 tables, 777 migrations) and the Seafile dump
      into a fresh MariaDB (195 tables, 1 account, 83 migrations). Doc defects fixed in `disaster-recovery.md`
      §6: placeholder restic sketch, no Kopia or DB steps, no password retrieval, kopia needs `--all` and
      `USER`/`HOME`/cache env as non-root. Checklist: §7 of that file. Still open: the same run on real
      hardware, the offsite restic restore (no target), the Immich dump without Kubernetes, and a restore
      against a rebuilt cluster)*

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

- **UniFi:** the API key handover and a config export. The management VLAN is 4 (owner, 2026-10-21); the
  uplink port behind the unmanaged switch needs VLANs 4 and 20 tagged (`docs/runbooks/host-network-bootstrap.md`).
- **Offsite:** hardware to purchase or build (decisions §5.5).
- **Cloudflare:** a DNS-01 token scoped to `Zone → DNS → Edit` on `ardw.be` (the zone Cloudflare hosts,
  confirmed 2026-10-21; decisions §5.7), kept by the owner until the key ceremony. No `*` record on the zone
  (owner, 2026-10-21). The ACME account email is `dev@arthurdw.com`.
- **SMTP:** the relay password (into the SMTP Secrets at the key ceremony), the relay allowing
  `homelab@lab.ardw.be` to send as each per-app From address, and the alert recipients (decisions §5.1).
- **Production key ceremony:** the age key, then the production Secrets
  (`kubernetes/overlays/homelab/README.md`). Until then production `infrastructure` can't become Ready.
- **TrueNAS upgrade to SCALE ≥ 25.04:** the `truenas/truenas` provider needs it; without it `truenas/` stays
  unapplied. The root itself is proven on a 25.10 lab fixture.
- **Production LoadBalancer IPs:** `cluster-settings` proposes `10.20.0.100` (Traefik) and `10.20.0.101`
  (Technitium); not yet in `docs/decisions.md`.
- **Flux on K8s 1.37.1:** the whole tree is Ready on the lab at 1.37.1; keep it.
- **Small calls:** the Traefik dashboard is reachable in-cluster on 8080 (`api.insecure`); Technitium forwards
  over plain UDP (DoT/DoH is an option); whether the `nas-nfs` export accepts the PostgreSQL dump jobs'
  uid 999.
- **Household backups (decisions §5.9):** the Mac's disk size (sets `timemachine_jolien_quota_gib`); on the
  real NAS, create the `jolien` SMB user and enable the Apple SMB2/3 extensions (SMB service settings) before
  the TrueNAS apply (`infrastructure/environments/homelab/truenas/README.md`).
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
| 2026-10-20 | 3,6,7,8 | Built the open buildable items: LE DNS-01 issuers and the wildcard, Traefik redirect/default cert/dashboard, Technitium persistence and zone bootstrap, monitoring persistence, break-glass runbook, Authentik with a DB dump, generic dump alerts, restic failure and freshness alerts, lab SOPS overlays, UniFi VLAN 20 on 0.59.0, TrueNAS `main/k8s` (blocked on NAS ≥ 25.04), dormant plan-preview workflow. Fixed `infrastructure-configs` stalling `apps`. Nothing applied. |
| 2026-10-20 | 1,5,6 | Local libvirt lab run: Talos CP + worker installed and Ready (v1.14.4 / K8s v1.37.1), NAS NFS/SMB serving, Flux adopted Cilium and the whole tree is Ready (3 Kustomizations, 11 HelmReleases, `clean-slate@f61c006`). Fixes: NAS seed as a virtio disk, Image Factory installer, static node network, service CIDR /16, CP 3 GiB and worker 6 GiB, `cache='unsafe'`, HelmRelease remediation retries, a lab local-path path, the Prometheus data-dir chown, and the Authentik Secret rename (`authentik-credentials`) (`docs/runbooks/phase-reports/phase-lab-virt-2026-10-20.md`). |
| 2026-10-20 | 2,5 | Lab proofs: UniFi L1 fixture (plan, apply, clean re-plan on provider 0.59.0; fixed `setting_preference = "manual"` on the network) and the backup/restore proof (dumps, restic, restore tests, size anomalies). Production bugs fixed: Immich dump `securityContext`, partial dumps, `restic-check.sh` deleting a non-empty directory, a `maxdepth` listing. Real offsite target and real hardware still pending (`docs/runbooks/phase-reports/phase-lab-virt-2026-10-20.md`). |
| 2026-10-21 | 2,3,5,9 | L1 fixtures for every OpenTofu root: nested Proxmox VE 8.4 (`just lab-pve-plan`; plan, apply, clean re-plan, destroy, run twice) and TrueNAS SCALE 25.10.7 (`just lab-truenas-plan`; plan 3 to add, apply, API check, clean re-plan). OS-upgrade proof: a Talos version bump on the PVE fixture replaced only the image download, not the VMs (`ignore_changes` in `talos-vm`). Technitium chart 1.13.5 (15.6.2) fixes the auth.config loss and the start-up crash. Lab re-verified: dumps, restore tests, NFS, MetalLB, DNS. Backup alert mail proven against local SMTP sinks and the units verified (`just backup-selftest`, in CI); the `To:` header is now comma-separated. `DatabaseBackupJobFailed` fired in the lab and Alertmanager mailed firing and resolved to a sink. The backup units ran on `lab-nas` (backup, check, freshness, failure mails, a timer firing); restic now gets a cache dir under systemd (`docs/runbooks/phase-reports/phase-lab-virt-2026-10-20.md`). |
| 2026-10-21 | 3,7,8 | Mail: the relay `mail.a-line.be:465` (implicit TLS) with one login and a From per app (decisions §5.1); Alertmanager and Authentik config verified rendered in the lab; ACME contact `dev@arthurdw.com`. TrueNAS `backups.tf`: Time Machine share (quota, Apple extensions), Kopia and Seafile datasets and exports, snapshot tasks, proven on the fixture (apply, clean re-plan). Seafile 14.0.9 and the Kopia 0.23.1 server in the lab: Seahub login and API token, a Kopia client snapshot through Traefik (gRPC needs HTTPS to the backend), the Seafile dump job ran. The lab worker (6 GiB) is at 97% of memory requests. |

## 10. Definition of done

- [ ] Infra version-controlled, pinned and additive-safe, and applied from IaC after cutover
- [ ] TrueNAS inventoried, with explicit preservation and no unapproved destructive operations
- [ ] Tier-1 offsite backups with **tested** restores and independent keys
- [ ] Kubernetes reproducibly bootstrapped, with documented upgrade and recovery
- [x] No secrets in the public repo (`.gitignore`, gitleaks and the SOPS gate in CI)
- [x] CI validates every PR statically *(live-apply gating still to add)*
- [ ] Every live-facing config proven in the lab first *(K8s/Flux layer yes; Talos guests yes, Flux on them
      yes; PVE, UniFi and TrueNAS fixtures yes; the alert mail against local SMTP sinks and `systemd-analyze verify`
      of the units yes; a backup rule firing through Alertmanager to a sink yes; the units installed and run by their
      timers on `lab-nas`, failure mails included, yes. Open: a real send through the relay, once its password is set)*
