# Backup Policy

> Design (Phase 2). **Not yet implemented.** No backup jobs run yet. Governed by `docs/SPEC.md` §7.
> Exact sizes/values are **TBD** pending the inventory; nothing here is claimed as working.

## 1. Objectives

- Critical, irreplaceable data is backed up **offsite**, encrypted, and **versioned** (not a live mirror).
- Replaceable bulk data is **excluded by default**.
- Backups survive total loss of the homelab, independent of the primary pool, credentials, and cluster.
- Every backup is **proven by a restore test**, not by a green job.

## 2. Tiers (classification by recovery cost, not size)

| Tier | Definition | Local snapshots | Offsite | Retention | Notes |
|---|---|---|---|---|---|
| **T1** | Irreplaceable (personal photos/videos, documents, unique projects) | yes, longer history | **required**, encrypted+versioned | daily; long (exact = TBD) | restore-tested; alerts |
| **T2** | Important operational (NAS config export, Tofu state, key secrets, app DBs, costly-to-rebuild config) | yes | where justified | frequent | recoverable without the cluster |
| **T3** | Replaceable bulk (movies/shows, ISOs, re-downloadable media, caches) | optional if space justifies | **no** (default) | short/none | per-dataset exceptions allowed |
| **T4** | Disposable (temp, build/derived data) | no | no | — | verify exclusions don't remove sole copies |

New datasets start **unclassified** and are surfaced for a decision — never assumed backed up.

## 3. Local snapshots (ZFS)

- Per-dataset **recursive** schedules; retention sized to change-rate and free space (TBD per dataset).
- Replace the current single non-recursive `main` task (which leaves child datasets uncovered).
- **Never** let snapshots consume the pool silently — monitor snapshot space and pool capacity.

## 4. Offsite mechanism (to choose on evidence)

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| A. ZFS send/recv to a ZFS-capable remote | efficient, fast restore, dataset-consistent | destination needs ZFS; a naive mirror replicates deletions | **TBD** |
| B. Encrypted dedupe file-level (restic/borg) | selective, encrypted, independent retention, works on non-ZFS | file-level semantics; verify ACL/xattr support on TrueNAS | **TBD** |

Pick **one primary** (or a justified hybrid). Evaluation criteria: initial size, incremental growth, CPU/RAM,
bandwidth/transfer time, destination capacity, restore speed, retention/deletion protection, key recovery,
TrueNAS compatibility.

## 5. Security & deletion protection

- The destination must **not** blindly trust source deletions: dedicated backup identity with least privilege,
  versioned retention, protected/immutable recovery points where practical, separate admin credentials.
- Encryption keys/recovery materials stored **outside** both source and destination; recoverable if the
  homelab is lost.
- Validate actual retention/immutability **semantics by testing**, not by trusting a config flag.

## 6. Consistency

- Databases: use consistent dumps / supported backup mechanisms (never copy live DB files).
- Immich: media + DB are a **related recovery set** — document restore order.
- OpenTofu state: protect confidentiality/integrity; recoverable without Kubernetes.

## 7. Monitoring

Alert on: last successful backup age, failures/skips, unexpected size changes, destination availability,
remaining destination capacity. **A backup is not verified because the job reports success.**

## 8. Acceptance criteria (from spec §7.9)

- [ ] Backup matrix documented for every dataset/workload
- [ ] T1 has an explicit offsite policy; T3 excluded by default
- [ ] Encryption keys recoverable independently
- [ ] Retention/deletion-protection behavior tested
- [ ] Failed/stale backups detectable
- [ ] Representative **restore tests** succeeded (recorded)
- [ ] Full-source-loss recovery steps documented
- [ ] Offsite maintainable without the primary cluster

## 9. Open items

- Choose mechanism A vs B (§4) — evidence in Phase 2.
- Offsite destination hardware/network/power (family home) — unconfirmed.
- Per-dataset retention values.
- Alert channel (owner decision).
