# homelab

Infrastructure-as-code and GitOps for a small, fully reproducible homelab: **Proxmox VE**, **TrueNAS**,
**UniFi**, **Talos Linux**, **Kubernetes**, and **Flux CD**.

> **Status: work in progress.** The environment is being rebuilt from scratch (greenfield). Nothing in this
> repository has been applied to live infrastructure yet. The hosts are treated as production and are only
> touched after an explicit, documented approval gate.

## Start here

| Document | What it is |
|---|---|
| [`docs/SPEC.md`](docs/SPEC.md) | The governing project specification |
| [`docs/PROJECT-PLAN.md`](docs/PROJECT-PLAN.md) | Execution plan, phases, gates, and agent operating rules |
| [`docs/architecture.md`](docs/architecture.md) | Target architecture (proposal) |
| [`docs/hardware.md`](docs/hardware.md) | Hardware inventory (verified) |
| [`docs/network-plan.md`](docs/network-plan.md) | Network topology and plan |
| [`docs/storage.md`](docs/storage.md) | Storage layout and plan |
| [`docs/risk-register.md`](docs/risk-register.md) | Known risks |
| [`docs/lab.md`](docs/lab.md) | Local test-driven development / lab strategy |
| [`versions.yaml`](versions.yaml) | Pinned tool and provider versions |

## Operating rules (short version)

- **Audit before implementing.** No changes to live systems without an approval gate.
- **Never commit secrets** — no keys, tokens, state, kubeconfigs, or private addresses. See [`SECURITY.md`](SECURITY.md).
- **The owner performs destructive actions** (wipes/reinstalls). Automation never does.
- **UniFi is additive-only** — existing house-network config is never modified by IaC.
- Every module is **lab-tested before it touches hardware**.

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the workflow and commit conventions.

## License

See [`LICENSE`](LICENSE).
