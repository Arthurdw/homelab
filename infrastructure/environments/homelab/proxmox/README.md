# Proxmox root configuration

Manages Proxmox VE resources (VM lifecycle, supported infra) for the homelab.

**Status:** scaffold — no resources defined yet. Provider is pinned; nothing is applied.

## Usage

```sh
cd infrastructure/environments/homelab/proxmox

# Credentials via environment (never committed):
export PROXMOX_VE_API_TOKEN='user@realm!tokenid=secret'

cp terraform.tfvars.example terraform.tfvars   # then edit; tfvars is gitignored
tofu init -backend=false
tofu validate
tofu plan                                      # review only
```

**Applies are gated** — see `docs/PROJECT-PLAN.md`. Do not `tofu apply` against live infrastructure without
explicit owner approval, and never `-auto-approve`.

## Ownership

OpenTofu owns Proxmox resources + VM lifecycle (see `docs/architecture.md` §7). Kubernetes resources are
owned by Flux, not here.
