# Cluster: lab

Flux entrypoints for the **throwaway kind/lab cluster** (`docs/lab.md`, `scripts/lab/lab-up.sh`).
Same three `Kustomization` objects as `../homelab/`, pointing at the same shared tree, but
`cluster-settings.yaml` here carries the **lab** address plan (`docs/decisions.md` §2.4):

| Variable | Value |
|---|---|
| `METALLB_POOL` | `10.99.100.100-10.99.100.199` |
| `NFS_SERVER` | `10.99.100.10` (the `lab-nas` stand-in) |

Each Kustomization reads it via `postBuild.substituteFrom`. `scripts/lab/lab-up.sh` and
`lab-sync.sh` apply this directory (and `cluster-settings.yaml` first, so no `${VAR}` is ever
substituted with an empty string). Keep the key set identical to `../homelab/` —
`scripts/ci/check-cluster-settings.sh` enforces that.

This directory is not bootstrapped by `flux bootstrap`; the lab harness installs Flux and applies
these objects directly. There is deliberately no committed root `kustomization.yaml` (same reason
as `../homelab/`).
