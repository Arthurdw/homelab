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
4. **Talos** (Kubernetes OS) — see §5.
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

## 5. Talos

- `talosctl upgrade` supports **one minor version at a time**; check the Talos upgrade docs and `kubeconfig`
  compatibility.
- Upgrade control planes one node at a time, then workers; watch health between nodes.
- Use `talosctl health`/`kubectl get nodes` and keep etcd healthy.
- Rollback: `talosctl upgrade` cannot downgrade in place — plan for redeploy.
- Talos **machine config** (including `machine.secrets`) is a Tier-2 secret: back it up off-box.

## 6. Kubernetes via Flux

- Controller upgrades: bump the chart `version` in `kubernetes/infrastructure/**/release.yaml` in a PR; Flux
  reconciles. Watch rollout.
- Kubernetes **API** upgrades are driven by Talos, not Flux.
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

A release has to be **14 days old** before Renovate proposes it. Merging to `main` is a deploy (Flux applies
it within minutes, §6), so automerge is limited to changes that apply nothing live, plus patch releases of
stateless charts. Automerge only happens through a PR whose CI passed.

| Automerges | Never automerges |
| --- | --- |
| GitHub Actions: minor, patch, digest | Any major |
| CI and workstation tools (OpenTofu CLI, helm, kind, sops, linters…): minor, patch | Cilium, MetalLB, Technitium, Authentik |
| OpenTofu providers and lock files: minor, patch (the owner runs `tofu plan/apply`) | Immich (chart, server, Postgres), Seafile, SeaDoc, MariaDB, memcached, Postgres images |
| cert-manager, Traefik, csi-driver-nfs, kube-prometheus-stack, local-path-provisioner: patch | Audiobookshelf, Kopia, Stremio, Homepage, Flux (`fluxcd/flux2`, opened as one grouped PR) |
| | Talos and Kubernetes: labelled `manual-upgrade` |

- Minor releases of the stateless charts open a PR and wait for review.
- **Talos and Kubernetes:** merging the PR only changes `versions.yaml`. Upgrade the cluster first
  (§5), then merge.
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
