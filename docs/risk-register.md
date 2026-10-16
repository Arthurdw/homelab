# Risk Register

> Initial register from the **2026-10-16** read-only audit. Revisit each phase. Severity is
> preliminary and evidence-based where noted; assumptions are marked.

| ID | Risk | Impact | Likelihood | Mitigation / next step | Status |
|---|---|---|---|---|---|
| R1 | Proxmox root/boot disk is a **single SSD** (no mirror) | Host down until reinstall; VMs lost unless backed up | Medium | Back up VM configs; document reinstall runbook; consider mirror on rebuild | Open |
| R2 | **No replication / no offsite backup** of NAS data today | Pool loss = permanent data loss | Medium | Tiered backup design (Phase 2/8); offsite destination | Open |
| R3 | Snapshot task is **non-recursive**, 2-week retention; child datasets uncovered | Apps data (incl. 490 G S3 export) not snapshotted | High | Redesign snapshot policy per dataset (Phase 2) | Open |
| R4 | **VM disk on SMB over network** (3000 G qcow2 on NAS) | Latency, write consistency, failure coupling | Medium | Re-evaluate VM storage placement; local SSD for VMs where practical | Open |
| R5 | Capacity accounting discrepancy (17.8 T alloc vs ~8.3 T logical) unexplained | Wrong sizing → bad backup/retention decisions | Medium | `zfs list -o space`, `compressratio`; verify units | Open |
| R6 | NAS is **non-ECC** RAM | Silent corruption risk | Low–Med | Accept + backups with checksums; document | Accepted (interim) |
| R7 | L2ARC ~76 % full indicates **RAM pressure** | Poor read performance | Medium | Reassess ARC sizing on rebuild; consider more RAM over L2ARC | Open |
| R8 | `<INTERNAL_RESOLVER_IP>` is a **single internal resolver** | DNS outage blocks services; possible bootstrap dependency | Medium | Ensure fallback resolver + documented restore; check redundancy | Open |
| R9 | **Kubernetes hosted DNS** could become a recovery circular dependency | Cannot bootstrap cluster without DNS that needs the cluster | Medium | Technitium with stable LAN IP or external fallback; test recovery (spec §9.4) | Open |
| R10 | **UniFi provider is pre-release** (`0.60.0-beta.0`) | Automation may break/regress | Medium | Prefer stable; test in lab; additive-only policy limits blast radius | Open |
| R11 | **Single physical host** for all Kubernetes nodes | No real HA; host loss = cluster loss | High (by design) | Do not claim HA; keep control-plane count low; document recovery | Accepted (constraint) |
| R12 | **185 pending OS updates** on Proxmox | Unpatched vulnerabilities | Medium | Define patch policy; patch windows with reboot plan | Open |
| R13 | Secrets/state strategy undefined | Leakage or unrecoverable state | Medium | SOPS+age design with keys off-system (Phase 1) | Open |
| R14 | GPU passthrough in use by a temporary VM | Reproducibility/conflict when other workloads need the P4 | Low | Document passthrough config; decide intended GPU consumer | Open |
| R15 | **Offsite destination unconfirmed** (family home) | No independent copy for Tier-1 data | Medium | Phase 2 evaluation; cost/bandwidth/power assessment | Open |
| R16 | Workstation is disk/RAM constrained for a lab | Limited local TDD capacity | Medium | Clean up disk; add NVMe; or dedicate a lab host | Open |
| R17 | Unknowns in the audit (UniFi config, ACLs, tags) | Wrong assumptions in design | Medium | Finish capture; verify before depending on any value | Open |
| R19 | **UniFi API key is full-access** (cannot be read-only) | A leak or mistaken apply can take the house network offline | Medium | Plan-only applies from a trusted host; additive-only; export before change; rotate; re-check for a limited local admin (`docs/secrets-and-state.md` §4) | Open |
| R18 | "Greenfield wipe" may destroy unbacked-up data if assumptions are wrong | Irreversible data loss | Low–Med | Owner-driven reset; verify backups of Tier-1 **before** any wipe (spec §3.2/§6.2) | Open |

## Assumptions not yet verified
- UniFi VLAN/DHCP/DNS full configuration (no API token yet).
- Which `main` directories are irreplaceable vs replaceable (owner input needed).
- Actual usable free space after RaidZ3 overhead.
- Whether the P4 passthrough is stable under sustained load.
