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

## Target fixtures (to build in Phase 1)

- **Proxmox provider** → nested PVE guest (KVM; `nested=Y` confirmed) → `tofu` applies against its API.
- **TrueNAS provider** → TrueNAS SCALE guest with a few virtio disks → dataset/share/user resources.
- **UniFi provider** → self-hosted UniFi Network Application container as the controller fixture.
  ⚠️ The real **UDM Pro** cannot be virtualized; its API differs from the self-hosted controller.
  Real UDM changes therefore stay **gated, exported, and rollback-planned**, not blindly applied.
- **Talos** → `talosctl cluster create` (docker) and/or QEMU; validates machine config + bootstrap offline.
- **Kubernetes/Flux** → `kind`/`k3d` cluster; `flux-local` for rendering; `kubeconform` for schemas.

## Hard constraints on this workstation (as of 2026-10-16)

- Intel Ultra 7 155H, 22 threads, **KVM present, nested enabled**.
- **RAM ~6.6 GiB free** and **disk 91 % full (~90 G free)** → running PVE **and** NAS guests together is not
  realistic until resources are freed or a disk/NVMe is added.
- Docker already hosts 124 images / several containers — account for this.

### Options to make the lab viable (owner input)
1. Free space/RAM on the workstation (clean Docker images, unused data).
2. Add an NVMe/SSD dedicated to VM images.
3. Use a separate spare machine as the lab host.
4. Run only one heavy fixture at a time (e.g. NAS **or** PVE), lightweight ones otherwise.

## Non-negotiables

- CI (L0) never requires production credentials and never applies anything.
- No lab fixture ever reaches the real UDM Pro / NAS / Proxmox until its layer passes and a gate is opened.
- Results of lab runs are recorded in `docs/runbooks/phase-reports/` — actual output, pass/fail, limitations.
