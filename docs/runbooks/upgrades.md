# Runbooks: Upgrades

Ordered, reversible upgrade procedures. **Rule: never upgrade blind, never upgrade everything at once,
and always have a rollback before you start.** Pin versions (see `versions.yaml`) and change one thing per
window.

## 0. Before any upgrade

- [ ] Read the release notes / changelog for **breaking changes** and required intermediate versions.
- [ ] Confirm the current and target versions and any **supported upgrade path** (no skipping majors).
- [ ] Take a **restorable** backup or snapshot (a snapshot is *not* an offsite backup).
- [ ] Note the rollback step and how to invoke it.
- [ ] Pick a maintenance window; announce it if it affects the household.
- [ ] Have out-of-band access (a way back in even if the network/UI is down).

## 1. Order of upgrades

Upgrade **bottom-up**, verifying each layer before the next:

1. **Firmware/BIOS** (rarely; only when needed for a fix) and **NIC/boot device** firmware.
2. **TrueNAS** (storage) — see §3.
3. **Proxmox VE** (hypervisor) — see §4.
4. **Talos** (Kubernetes OS), then the **Kubernetes version**: both through tuppr, see §5.
5. **Kubernetes components** via Flux (controllers, then apps) — see §6.
6. **Container images / app versions** — via Renovate PRs that Flux applies on merge (see §8).

## 2. General rules

- One component per window unless a tested path says otherwise.
- Version skew is enforced by upstreams (Kubernetes, Talos): check the supported skew **before** starting.
- After each step: verify health from *outside* the upgraded component.
- If a step regresses, **roll back first**, investigate second.

## 3. TrueNAS SCALE

- Read the release notes; TrueNAS updates are usually in-place but **config backup first** (Section → System →
  General → Save Config), stored off-box.
- Prefer the documented update path; avoid skipping major versions.
- ZFS **pool** feature flags can be permanent — do not enable a newer on-disk feature unless you accept that
  the pool can no longer be imported by an older version.
- Verify pools/datasets/shares/snapshots and both replication and snapshot tasks afterwards.
- Rollback: boot into the previous boot environment from the console.

## 4. Proxmox VE

Upgrade a **standalone** host (no cluster quorum concerns here) with:

```sh
# On the host, in a maintenance window:
apt update
apt full-upgrade -y        # or the documented `pve` upgrade sequence between major versions
# between majors, follow the official "Upgrade from X to Y" page step by step
```

- Back up `/etc/pve` and VM configs first.
- **Snapshot or back up VMs** before upgrading, or ensure they are restorable.
- After reboot, verify VMs start, `talos-wk-1` with its Tesla P4 passthrough (`gpu.tf`), and that the node
  still reports allocatable `nvidia.com/gpu`.
- Rollback: restore the VM/host from backup; there is no supported downgrade for a major PVE version.

## 5. Talos and Kubernetes (tuppr)

Talos and the Kubernetes version are upgraded by **tuppr** (`kubernetes/upgrades`, decision
`docs/decisions.md` §5.20), not by hand. The targets are two objects in Git:

- `kubernetes/upgrades/plans/talos.yaml`: TalosUpgrade `cluster`, the Talos version of every node.
- `kubernetes/upgrades/plans/kubernetes.yaml`: KubernetesUpgrade `kubernetes`, the Kubernetes version.

Renovate bumps each together with its pin in `versions.yaml` (§8). **Merging that PR is the upgrade:** Flux
applies the new version and tuppr rolls it out.

- **Talos:** before touching any node, tuppr pulls the new installer on every node. Then it upgrades one node
  at a time: it drains the node, waits for NFS volumes to detach, reboots the node, and checks it comes back
  `Ready` on the new version. It checks that every node is `Ready` before each node. Each node keeps its own
  schematic: tuppr swaps only the version tag of the node's installer image, so `talos-wk-1` stays on the
  GPU schematic.
- **Kubernetes:** tuppr runs `talosctl upgrade-k8s`, which upgrades the control plane components, then every
  kubelet. No node reboots.
- Only one upgrade runs at a time. The node running the tuppr controller is upgraded first (its pod
  restarts once with the reboot), then the others by name. The upgrade Job runs on another node.
- A `PrePullFailed` that recovers on its own is usually Image Factory building a new schematic and version
  on first request (`no pull progress after 1m30s`); tuppr retries it.
- **The single control plane** (`talos-cp-1`, no VIP) means the Kubernetes API is down while it reboots
  (a few minutes). Running pods keep serving, but Flux, kubectl and tuppr pause until it is back.

### Before merging

- **One minor at a time.** Talos and Kubernetes support only one minor step per upgrade, and tuppr does not
  check this. Renovate opens a separate PR per minor. If several are open, merge the oldest, wait for it to
  finish, then merge the next one.
- Check the Talos support matrix for the Kubernetes version (`versions.yaml` notes), and Talos before
  Kubernetes when both move.
- For a new Kubernetes minor, check that Flux supports it (`versions.yaml`: the `flux` notes).
- Read the release notes. Talos cannot be downgraded in place: the way back is a reinstall from the
  machine configs.

### Watch, pause, retry

```sh
kubectl get talosupgrade,kubernetesupgrade -w     # phase and current node
kubectl -n system-upgrade get jobs,pods           # the per-node upgrade Jobs
kubectl describe talosupgrade cluster             # health check and pre-pull events

# Pause (also before upgrading by hand), then resume
kubectl annotate talosupgrade cluster tuppr.home-operations.com/suspend="true"
kubectl annotate talosupgrade cluster tuppr.home-operations.com/suspend-

# `Failed` is final until you act: fix the cause, then restart the run
kubectl annotate talosupgrade cluster tuppr.home-operations.com/reset="$(date)"
```

The same annotations work on `kubernetesupgrade kubernetes`. A failed or stuck upgrade raises the tuppr
alerts (mail, like every other alert).

### Machine config

tuppr writes the new installer image into each node's live machine config. `scripts/talos/gen-configs.sh`
reads the same version from `versions.yaml`, so a later `--regen` produces the same image. The machine
config (including `machine.secrets`) is a Tier-2 secret: back it up off-box.

### One-time setup

tuppr needs Talos API access, which is the `KubeTalosAPIAccessConfig` document in
`talos/patches/controlplane.yaml` (role `os:admin`, namespace `system-upgrade` only). Until the control plane
runs it, the talos.dev CRD does not exist, the tuppr HelmRelease fails to install, and nothing is upgraded.
The owner applies it once:

```sh
just talos-regen                                    # same PKI, then talosctl validate
just talos-upgrade-config 10.20.0.11                # dry run: review the diff
just talos-upgrade-config 10.20.0.11 --mode=auto    # apply to the control plane
kubectl api-resources --api-group=talos.dev         # lists serviceaccounts
flux reconcile kustomization upgrades --with-source
```

The dry run should show the new `KubeTalosAPIAccessConfig` document and, if the node runs an older Talos than
`versions.yaml`, the installer tag (used only by the next upgrade). Anything else means the live config has
drifted from the repo: stop and look first.

### By hand (fallback)

With the plan suspended, the manual procedure still works: `talosctl upgrade --image <installer>:<version>`
on one node at a time, then `talosctl health`, and `talosctl upgrade-k8s --to <version>` for Kubernetes. Set
the plan to the version the cluster now runs before removing the suspend annotation.

## 6. Kubernetes via Flux

- Controller upgrades: bump the chart `version` in `kubernetes/infrastructure/**/release.yaml` in a PR; Flux
  reconciles. Watch rollout.
- The Kubernetes version is upgraded by tuppr (§5), not by a chart bump.
- App upgrades: bump chart/image versions; rely on Flux health checks and `dependsOn` ordering.
- Rollback: revert the commit; Flux reconciles back. If a CRD was changed, rollback may need care — check
  the release notes.

## 7. After

- [ ] Re-run the verification checklist for the component (health, data, DNS, ingress, backups).
- [ ] Confirm backups still run and a restore test still passes.
- [ ] Commit the version bump / record the new version in `versions.yaml`.
- [ ] Note anything surprising for the next time.

## 8. Renovate

The Renovate GitHub App opens update PRs from `renovate.json5`. It watches the Flux HelmReleases,
HelmRepositories and OCIRepositories, image tags in manifests and HelmRelease values, the OpenTofu providers
and lock files, the GitHub Actions, and every pin with a `# renovate:` comment above it (`versions.yaml`, CI
tool versions in `.github/workflows/ci.yml`, `scripts/ci/install-ci-tools.sh`, `scripts/lab/*.sh`). A
`versions.yaml` pin uses the same dependency name as its manifest, so both change in the same PR.

A release has to be **14 days old** before Renovate proposes it. The exception is ghcr.io (Immich and its chart
and Postgres, Homepage, the local-path and tuppr charts): Renovate gets release dates only from Docker Hub, so those
updates open at once and never automerge. Check how old the release is before merging. Merging to `main` is a deploy (Flux applies
it within minutes, §6), so automerge is limited to changes that apply nothing live, plus patch releases of
stateless charts. Automerge only happens through a PR whose CI passed.

| Automerges | Never automerges |
| --- | --- |
| GitHub Actions: minor, patch, digest | Any major |
| CI and workstation tools (OpenTofu CLI, helm, kind, sops, linters…): minor, patch | Cilium, MetalLB, Technitium, Authentik |
| OpenTofu providers and lock files: minor, patch (the owner runs `tofu plan/apply`) | Immich (chart, server, Postgres), Seafile, SeaDoc, MariaDB, memcached, Postgres images |
| cert-manager, Traefik, csi-driver-nfs, kube-prometheus-stack: patch | Audiobookshelf, Kopia, Stremio, Homepage, Flux (`fluxcd/flux2`, opened as one grouped PR) |
| | Anything on ghcr.io, including local-path-provisioner and tuppr (no release date, so no 14-day wait) |
| | Talos and Kubernetes: labelled `cluster-upgrade`, one PR per minor |

- Minor releases of the stateless charts open a PR and wait for review.
- **Talos and Kubernetes:** merging the PR upgrades the cluster (tuppr, §5). Merge one minor at a time,
  oldest first, and check the support matrix and Flux's supported versions before merging.
- **Seafile:** the `local_settings.py` mount path in `kubernetes/apps/seafile/seafile.yaml` contains the
  version. Bump it in the same PR.
- **SeaDoc** (`docker.io/seafileltd/sdoc-server`, wikis and `.sdoc` files): take a new major only once the
  Seafile manual for the running server version ships it (`seadoc.yml` in haiwen/seafile-admin-docs). Seafile
  14.0 ships the 2.0 line.
- **Flux:** Renovate regenerates `gotk-components.yaml` as a whole with the new `flux` CLI. It never bumps
  the controller images one by one. Read the Flux release notes before merging.
- There is no Dependency Dashboard issue (`dependencyDashboard: false`): an update opens its PR once it is
  14 days old. To take one sooner, bump the pin by hand in a PR.
- Not tracked: the gitleaks image in the `Justfile`, `TALOS_VERSION_DEFAULT` in `scripts/lab/virt/lib.sh`,
  the BadgerOps provider pin and the app-version comments in `versions.yaml`. Bump them by hand.

**Install (once):** go to <https://github.com/apps/renovate>, choose **Configure**, and grant **Only select
repositories**: this one. Renovate finds `renovate.json5` and starts opening PRs on its
first run. Because Renovate merges its own PRs, branch protection on `main` must require the CI checks.
