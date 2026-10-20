# Runbooks

Operational, step-by-step procedures. Keep them executable by someone (or something) who was not there when
the system was built.

- `upgrades.md` — ordered, reversible upgrade procedures for every layer.
- `talos-bootstrap.md` — turn freshly booted Talos nodes into a Kubernetes cluster.
- `secrets.md` — SOPS + age: key ceremony, add/rotate, recovery, CI.
- `phase-reports/` — historical build reports.
- `../disaster-recovery.md` — recovery after losing part or all of the homelab.
- `../secrets-and-state.md` — how secrets and state are stored and recovered.
- `../backup-policy.md` / `../backup-matrix.md` — what is backed up and how it is verified.

Conventions: every runbook states its **pre-checks**, its **rollback**, and its **verification**. If a step
can lose data, it says so and requires explicit confirmation.
