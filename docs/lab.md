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

Commands: `just lab-up` · `just lab-status` · `just lab-sync` · `just lab-down` · `just lab-tools`.

`just lab-tools` installs the pinned binaries (`kind`, `flux`, `age`, `sops`) into `~/.local/bin` — **no sudo**
and exact versions, so the agent/CI can always run it. On Arch/Omarchy, `just lab-tools --native` installs the
distro packages instead (`kind`, `fluxcd`, `age`, `sops` are all in `extra`; no AUR helper needed). That mode
needs sudo and may lag the pins (e.g. `fluxcd` 2.9.5 vs pin 2.9.6) — the script **reports the drift** rather
than hiding it. Use `--dry-run` to preview either mode.

### Why HTTP, not `git://` or SSH

- Flux's `GitRepository` accepts only `http(s)://` and `ssh://` — the `git://` protocol is out.
- The Git server must be reachable **before** any ingress exists (Traefik is deployed *from* it), so it is
  fronted by a plain ClusterIP Service (`homelab-git.lab-git.svc.cluster.local`), never by Traefik.
- SSH would need per-client key distribution for no benefit here; anonymous read over smart HTTP is simpler.

## Target fixtures still to build (libvirt guests)

The lab is moving from "kind only" to **libvirt / virt-manager guests**, because what has to be proven is the
*platform* — Talos nodes on virtualised hardware, storage over the network, and Flux reconciling on top — not
just the GitOps tree. See `docs/decisions.md` §1.1 and §2.4.

- **Talos nodes** → two libvirt guests booting Talos; validates machine config, bootstrap, Cilium, MetalLB and
  the entire Flux tree end-to-end. This is the primary fixture.
- **NAS stand-in** → a small Linux guest exporting **NFS and SMB** (+ snapshots, + a ZFS-on-disk option).
  Deliberately **not** nested TrueNAS: ZFS-in-ZFS burns the RAM budget and tests the wrong layer. Real TrueNAS
  still gets its own fixture when the `truenas` OpenTofu root needs exercising.
- **Proxmox provider** → an on-demand nested PVE guest; `tofu` applies against its API only.
- **UniFi provider** → self-hosted UniFi Network Application container as the controller fixture.
  ⚠️ The real **UDM Pro** cannot be virtualized and its API differs from the self-hosted controller. Per
  decision 1.2, the real UDM is not written to at all before cutover.

## Hard constraints on this workstation (verified 2026-10-16)

- Intel Ultra 7 155H, 22 threads; `vmx` present and `kvm_intel nested=Y` — nested VMs work.
- `virsh`, `virt-install`, `virt-manager` and `qemu-system-x86_64` are all installed, but **`libvirtd` is
  disabled and inactive**. Enabling it needs root and the agent has no passwordless sudo:
  `sudo systemctl enable --now libvirtd` and `sudo usermod -aG libvirt $USER` (re-login). **Owner action.**
- **RAM is the binding constraint, not disk.** 30 GiB total with ~10 GiB available and swap already in use;
  disk is fine at ~393 G free.
- Docker already runs many images/containers, and the **kind** lab cluster (kube-apiserver et al.) is one of the
  bigger consumers — stop it before starting the heavy libvirt guests.

### Sizing that fits the current machine

| Guest | RAM | Disk | Purpose |
|---|---|---|---|
| `lab-talos-cp` | 2 GiB | 20 GiB | control plane, direct on libvirt |
| `lab-talos-wk` | 4 GiB | 40 GiB | worker (all workloads) |
| `lab-nas` | 2 GiB | 50 GiB | Linux stand-in exporting NFS + SMB (not nested TrueNAS) |
| `lab-pve` | 4 GiB | 40 GiB | on-demand, only to exercise the OpenTofu Proxmox layer |

Keep **kind** for the K8s/Flux layer, and run the heavy libvirt guests **one at a time** rather than all at
once. If the full stack must run together, the honest options are freeing ~12 GiB on this machine or adding
RAM — recorded rather than assumed.

## Non-negotiables

- CI (L0) never requires production credentials and never applies anything.
- No lab fixture ever reaches the real UDM Pro / NAS / Proxmox until its layer passes and a gate is opened.
- Results of lab runs are recorded in `docs/runbooks/phase-reports/` — actual output, pass/fail, limitations.
