# Runbook: Talos and Kubernetes bootstrap

This is the Phase 5 procedure for turning freshly booted Talos nodes into a working Kubernetes cluster.
It is **gated by GATE 5** (`docs/PROJECT-PLAN.md` §6): nothing here runs until the owner answers the
open questions (§10) and explicitly opens the gate. Until then the configuration is *scaffolded*, not
applied.

> **Ownership.** VM creation (Proxmox) is OpenTofu's job (Phase 4). This runbook starts **after** the
> node VMs already exist and are powered on with a Talos image. Everything it does is a **Talos tooling**
> action (§4.2 ownership matrix) — do not let an ordinary `tofu apply` bootstrap or upgrade the cluster.

## 0. Interactive nodes

Replace every `<ANGLE_BRACKET>` token with the value the owner decided at GATE 0. The undecided values
live in exactly one place — `talos/inputs.env` — so set them there and re-generate rather than editing
commands ad hoc.

| Token | Meaning | Decided at |
|---|---|---|
| `<CP_IP>` | control-plane node address | GATE 0 |
| `<WORKER_IP>` | worker node address | GATE 0 |
| `<API_ENDPOINT>` | Kubernetes API endpoint / VIP (set as `CLUSTER_ENDPOINT`) | GATE 0 |
| `<CNI_MANIFEST>` | the chosen CNI's install manifest | GATE 0 (CNI is TBD) |

## 1. Pre-checks

- [ ] GATE 5 is open and the owner is present.
- [ ] `talos/inputs.env` reflects the decisions: endpoint, install disk, SANs (no `192.0.2.1` placeholder left).
- [ ] `versions.yaml` pins the intended Talos (`v1.14.4`) and Kubernetes (`v1.37.1`) — read the release
      notes and confirm the pair is still supported before upgrading either.
- [ ] The locally installed `talosctl` matches the pinned Talos minor (`talosctl version --client`).
      A mismatched client is reported by the tooling; upgrade it rather than ignoring the skew.
- [ ] A **restorable, off-box** copy of `talos/out/controlplane.yaml`, `worker.yaml` and `talosconfig`
      exists (Tier-2 secret — see `docs/runbooks/upgrades.md` §5). Losing them loses cluster admin.
- [ ] The node VMs exist and are powered on (Proxmox/Phase 4, out of scope here).
- [ ] You have out-of-band access to `poseidon` in case networking goes wrong.

## 2. Generate configuration

Offline; write only local files.

```sh
./scripts/talos/gen-configs.sh
./scripts/talos/validate.sh
```

This writes `talos/out/controlplane.yaml`, `talos/out/worker.yaml` and `talos/out/talosconfig`. The
directory is **gitignored** and the files embed the cluster PKI and secrets — never commit them. Verify:

```sh
git check-ignore -v talos/out/controlplane.yaml
```

`gen-configs.sh` is idempotent: a second run is a no-op. Only `--force` regenerates, and that **replaces
the cluster PKI/secrets**, invalidating any node already configured from the previous files.

## 3. Boot the node VMs

Out of scope for this runbook. Building a Talos VM (image acquisition, disk bus, size, VLAN) is Phase 4
Proxmox work owned by OpenTofu. Once the VMs are up, each Talos node exposes a maintenance API on its IP
and is ready for the next step.

## 4. Apply machine config

Apply config to the control plane first, then each worker. `--insecure` is used only for the initial
maintenance-mode apply, before the node trusts the cluster CA.

```sh
talosctl apply-config --insecure --nodes <CP_IP>     --file talos/out/controlplane.yaml
talosctl apply-config --insecure --nodes <WORKER_IP> --file talos/out/worker.yaml
```

Point the client at the cluster so later commands do not need `--nodes` on every call:

```sh
talosctl --talosconfig talos/out/talosconfig config endpoint <API_ENDPOINT>
talosctl --talosconfig talos/out/talosconfig config node <CP_IP>
```

Wait for each node to finish installing and reboot into the installed system:

```sh
talosctl --talosconfig talos/out/talosconfig --nodes <CP_IP> version
```

## 5. Bootstrap the control plane

Exactly once, against a single control-plane node. This creates etcd and is **irreversible in place**.

```sh
./scripts/talos/bootstrap.sh --node <CP_IP> --confirm
```

## 6. Retrieve kubeconfig

```sh
./scripts/talos/kubeconfig.sh --node <CP_IP> --confirm
```

The admin kubeconfig is written to the gitignored `talos/out/kubeconfig` and is **not** merged into
`~/.kube/config`. It contains admin credentials — treat it like the machine secrets.

## 7. Install the CNI

`talos/patches/common.yaml` deletes Talos' bundled Flannel document, so Talos has **not** installed a
CNI and pods are not yet networked. Install the chosen CNI:

```sh
kubectl --kubeconfig talos/out/kubeconfig apply -f <CNI_MANIFEST>
```

The CNI is **TBD** (architecture.md §6). Whichever is chosen, confirm it tolerates the pinned Kubernetes
`v1.37.1` and the 4-core host before installing, and record the choice in `versions.yaml`.

## 8. Verification

A successful `bootstrap` is not proof the cluster works. Check all of the following from *outside* the
control plane:

```sh
talosctl --talosconfig talos/out/talosconfig health --nodes <CP_IP>
talosctl --talosconfig talos/out/talosconfig etcd members
kubectl --kubeconfig talos/out/kubeconfig get nodes -o wide
kubectl --kubeconfig talos/out/kubeconfig get pods -A -o wide
kubectl --kubeconfig talos/out/kubeconfig get --raw='/readyz?verbose'
```

Expected, at minimum: etcd reports one member; the control-plane node is `Ready`; the worker joins and is
`Ready`; every system pod (and the CNI's pods) is `Running`; the API responds `ok` to `/readyz`.

## 9. Rollback and limitations

These are real and are the reason the gate exists. Read them before starting.

- **`talosctl bootstrap` cannot be undone in place.** It creates etcd; there is no "un-bootstrap". To
  start over you must reset or recreate the node (`talosctl reset` wipes the node's disks) and bootstrap
  again — a new etcd, and any previously created Kubernetes objects are gone.
- **Regenerating machine configs changes the cluster identity.** `gen-configs.sh --force` produces a new
  PKI/secrets. Nodes already configured from the old files become inconsistent with any node configured
  from the new ones; a clean re-provision is required. Back up `talos/out/` before any regeneration.
- **There is no in-place Talos OS downgrade.** `talosctl upgrade` moves forward one minor at a time; a
  failed upgrade is recovered by redeploying the node, not by rolling the version back.
- **No high availability.** Every node is a VM on the single host `poseidon`. Losing that host loses the
  whole cluster; there is no failover and no quorum to fall back on. This runbook makes **no HA claim**.
- **Losing `talos/out/` is losing cluster admin.** The machine configs and talosconfig are the only copies
  of the cluster secrets (they are deliberately not committed). Keep a restorable, off-box copy.
- **Bootstrap ordering matters.** Bootstrapping more than one node, or before a control plane is healthy,
  can leave etcd in a state that requires a node reset. Bootstrap exactly one control-plane node, once.

## 10. If the bootstrap is interrupted

- If `apply-config` failed for a node: fix the cause and re-apply; the node is still in maintenance mode
  and nothing has been created yet.
- If `bootstrap` failed: check the control-plane node's logs (`talosctl --nodes <CP_IP> logs
  controld`) and confirm the node is otherwise healthy before retrying. Do **not** immediately
  bootstrap a second node.
- If the cluster is unrecoverable: reset the affected nodes and return to step 2. Record what happened in
  `docs/runbooks/phase-reports/`.
