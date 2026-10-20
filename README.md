# homelab

Infrastructure-as-code and GitOps for a small, fully reproducible homelab: **Proxmox VE**, **TrueNAS**,
**UniFi**, **Talos Linux**, **Kubernetes**, and **Flux CD**.

> **Status: work in progress.** The environment is being rebuilt from scratch (greenfield). Nothing in this
> repository has been applied to live infrastructure yet. The hosts are treated as production and are only
> touched after an explicit, documented approval gate.

## Start here

| Document | What it is |
|---|---|
| [`docs/PROJECT-PLAN.md`](docs/PROJECT-PLAN.md) | Execution plan, phase checklist, gates, open items |
| [`docs/decisions.md`](docs/decisions.md) | Every decision and its reasoning — the source of truth |
| [`docs/architecture.md`](docs/architecture.md) | Target architecture (summary of the decisions) |
| [`docs/hardware.md`](docs/hardware.md) | Hardware inventory (verified) |
| [`docs/network-plan.md`](docs/network-plan.md) | Network topology and plan |
| [`docs/storage.md`](docs/storage.md) | Storage layout and plan |
| [`docs/risk-register.md`](docs/risk-register.md) | Known risks |
| [`docs/lab.md`](docs/lab.md) | Local test-driven development / lab strategy |
| [`docs/runbooks/`](docs/runbooks/) · [`docs/apps/`](docs/apps/) | Procedures, and per-application notes |
| [`docs/SPEC.md`](docs/SPEC.md) | The original project brief (historical; `decisions.md` wins) |
| [`versions.yaml`](versions.yaml) | Pinned tool, provider and chart versions |

## Operating rules (short version)

- **Audit before implementing.** No changes to live systems without an approval gate.
- **Never commit secrets** — no keys, tokens, state, kubeconfigs, or private addresses. See [`SECURITY.md`](SECURITY.md).
- **The owner performs destructive actions** (wipes/reinstalls). Automation never does.
- **UniFi is additive-only** — existing house-network config is never modified by IaC.
- Every module is **lab-tested before it touches hardware**.

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the workflow and commit conventions.

## Repository layout

```text
docs/            plan, decisions, architecture, runbooks, risk register
infrastructure/  OpenTofu: modules/ + environments/homelab/{proxmox,truenas,unifi} — validated, nothing applied
talos/           machine-config patches + inputs (inputs.env = prod, inputs.lab.env = lab); output is gitignored
kubernetes/      Flux GitOps: clusters/{homelab,lab} (per-env roots + cluster-settings) + infrastructure/ + apps/
scripts/         check.sh, ci/, talos/, secrets/, backup/ (restic), lab/ (kind + git server) and lab/virt/ (libvirt)
Justfile         task runner: `just --list`
```

## Local development

Everything is testable locally; nothing requires live infrastructure.

```sh
just --list          # all tasks
just check           # local gate: lint + gitleaks + tofu fmt/validate + helm render
just k8s-validate    # build every kustomization and kubeconform it
just talos-validate  # generate and validate Talos machine configs offline
just ci              # run the GitHub Actions workflow locally with `act`

just lab-up          # kind + in-cluster git server + Flux reconciling this working tree
just lab-sync        # re-bake the working tree into the lab and re-sync Flux
just lab-virt-up     # libvirt guests: Talos control plane + worker + NAS stand-in (try --dry-run)
```

CI is static (no credentials, no applies) and is verified locally with [`act`](https://github.com/nektos/act)
before pushing.

## License

See [`LICENSE`](LICENSE).
