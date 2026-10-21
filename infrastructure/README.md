# infrastructure/

OpenTofu for the systems Kubernetes cannot own (`docs/architecture.md` §7). There is one root, and one
state, per system:

| Root | Provider | Notes |
|---|---|---|
| `environments/homelab/proxmox` | `bpg/proxmox` | Talos VMs via `modules/talos-vm` |
| `environments/homelab/truenas` | `truenas/truenas` 1.5.14 | **BLOCKED** until hercules-nas runs TrueNAS >= 25.04 (see its README) |
| `environments/homelab/unifi` | `ubiquiti-community/unifi` 0.59.0 | additive-only; never in CI |

PR CI (`.github/workflows/ci.yml`) runs `tofu fmt -check` and `tofu validate` per root, with no
credentials. Lock files (`.terraform.lock.hcl`) are committed; `.terraform/` is not.

## CI plan preview (dormant)

`.github/workflows/tofu-plan.yml` runs `tofu plan -lock=false -input=false` for one chosen root. It
**never applies**: there is no apply step, and `permissions` is `contents: read`. It is dormant until the
owner sets up the pieces below. Live applies stay manual and gated (`docs/PROJECT-PLAN.md`).

**Why a self-hosted runner.** GitHub-hosted runners are on the public internet. Poseidon,
hercules-nas and the UDM are on a private LAN with no inbound ports (`docs/architecture.md` §5;
emergency access is Tailscale only). A hosted runner cannot reach the APIs, and opening them up is
not acceptable. The job therefore runs on `[self-hosted, homelab]`, a runner inside the LAN.
(`.github/actionlint.yaml` declares the custom label.)

**Why manual and protected.** The workflow is `workflow_dispatch` only, so no PR, and in particular no
fork PR, can schedule code onto the LAN runner. The job uses the `homelab-plan` environment. Configure
it with required reviewers (the owner), restricted to the `main` branch, so every run needs an approval
and the secrets are only released to approved runs from `main`.

**What the owner must add** (Settings, Environments, `homelab-plan`):

| Kind | Name | Used by | Value |
|---|---|---|---|
| secret | `PROXMOX_VE_API_TOKEN` | proxmox | `user@realm!tokenid=secret`, ideally a read-only (PVEAuditor) token |
| variable | `PROXMOX_ENDPOINT` | proxmox | `https://<poseidon>:8006/` |
| secret | `TRUENAS_API_KEY` | truenas | API key, ideally of a read-only user |
| variable | `TRUENAS_ENDPOINT` | truenas | `wss://<hercules-nas>/api/current` |

Plus a runner registered to this repo with the `homelab` label, which can reach both APIs.

Limitations:

- **truenas cannot plan yet.** Provider 1.5.14 only speaks `/api/current` (TrueNAS >= 25.04), and
  hercules-nas runs 24.10.2.4. A truenas run fails at connect until the owner upgrades the NAS.
- **UniFi is not included.** Its API key is full-access and is never placed in CI
  (`docs/secrets-and-state.md` §4). Plan it on the owner's machine.
- **The state backend is local/undecided** (`docs/secrets-and-state.md` §5). The job uses
  `tofu init -backend=false`, so the plan compares against an **empty** state and shows every resource
  as a create. It still checks credentials, connectivity and provider-side validation, but it is not a
  drift check. Once a backend with locking is chosen, give the runner read access to it. Keep
  `-lock=false`, because a preview must never hold or break an apply's lock.
- The bpg/proxmox provider's SSH block (`agent = true`) is only used for file uploads, not for
  planning. A plan needs no SSH key on the runner.
