# Lab & Local Test-Driven Development

Goal: **every piece of IaC/config is exercised in a disposable local lab before it ever touches the real
hosts.** The physical hosts are treated as production and are never the test bed.

## Layers

| Layer | What | Where | Runs on PR? |
|---|---|---|---|
| L0 static | `tofu fmt/validate`, tflint, trivy/checkov, `kustomize build`, `kubeconform`, `conftest`, `helm lint`, shellcheck/shfmt, yamllint, markdownlint, gitleaks | CI + local | yes (no live creds) |
| L1 fixtures | nested **Proxmox VE** VM, **TrueNAS SCALE** VM, **UniFi Network Application** container, **Talos** (`talosctl cluster create`/QEMU), **kind/k3d** cluster | this workstation | optional |
| L2 rehearsal | full stack in the lab (PVE + NAS + Talos + Flux) end-to-end | workstation / dedicated lab host | manual |
| L3 restore/DR | restore backups into isolated targets | lab | manual |

## What is built today (L1)

`just lab-up` brings up a disposable Kubernetes lab on this workstation:

| Component | What it is | Status |
|---|---|---|
| kind cluster `homelab-lab` | a real Kubernetes API | built |
| in-cluster Git server (`lab-git`) | smart-HTTP git serving a bare mirror of this repo | built |
| Flux | installed by the harness; reconciles the **real** `kubernetes/` tree | built |
| SOPS age key | generated lab key → `sops-age` Secret (lab-only) | built |

Commands: `just lab-up` · `just lab-status` · `just lab-down` · `just lab-tools`.

### Why HTTP, not `git://` or SSH

- Flux's `GitRepository` accepts only `http(s)://` and `ssh://` — the `git://` protocol is out.
- The Git server must be reachable **before** any ingress exists (Traefik is deployed *from* it), so it is
  fronted by a plain ClusterIP Service (`homelab-git.lab-git.svc.cluster.local`), never by Traefik.
- SSH would need per-client key distribution for no benefit here; anonymous read over smart HTTP is simpler.

## Target fixtures still to build

- **Proxmox provider** → nested PVE guest (KVM; `nested=Y` confirmed) → `tofu` applies against its API.
- **TrueNAS provider** → TrueNAS SCALE guest with a few virtio disks → dataset/share/user resources.
- **UniFi provider** → self-hosted UniFi Network Application container as the controller fixture.
  ⚠️ The real **UDM Pro** cannot be virtualized; its API differs from the self-hosted controller.
  Real UDM changes therefore stay **gated, exported, and rollback-planned**, not blindly applied.
- **Talos** → `talosctl cluster create` (docker) and/or QEMU; validates machine config + bootstrap offline.

## Hard constraints on this workstation (as of 2026-10-16)

- Intel Ultra 7 155H, 22 threads, **KVM present, nested enabled**.
- Resources were freed on 2026-10-16: **~14 GiB RAM available** and **~419 G free disk (56 % used)** — enough for
  the kind/Flux lab. (Earlier snapshot: ~6.6 GiB / 91 % used.)
- Docker already hosts many images/containers — account for this.

### Still needs owner input for the heavy fixtures
1. A dedicated NVMe/SSD for VM images (keeps the root disk from filling again).
2. A separate spare machine as the lab host, if we want PVE **and** NAS guests running together.

## Non-negotiables

- CI (L0) never requires production credentials and never applies anything.
- No lab fixture ever reaches the real UDM Pro / NAS / Proxmox until its layer passes and a gate is opened.
- Results of lab runs are recorded in `docs/runbooks/phase-reports/` — actual output, pass/fail, limitations.
