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
6. **Container images / app versions** — via Flux/Renovate PRs.

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
- After reboot, verify VMs start (respecting the GPU passthrough on the `portainer` VM).
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
