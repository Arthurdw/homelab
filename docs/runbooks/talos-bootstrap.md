# Runbook: Talos and Kubernetes bootstrap

Procedure for turning freshly booted Talos nodes into a working Kubernetes cluster. Run it only with
the owner present: it applies configuration to live nodes.

> **Ownership.** VM creation (Proxmox) is OpenTofu's job. This runbook starts **after** the
> node VMs already exist and are powered on with a Talos image. Everything it does is a **Talos tooling**
> action (§4.2 ownership matrix) — do not let an ordinary `tofu apply` bootstrap or upgrade the cluster.

## 0. Interactive nodes

Replace every `<ANGLE_BRACKET>` token with the value the owner decided. The values
live in exactly one place — `talos/inputs.env` — so set them there and re-generate rather than editing
commands ad hoc.

| Token | Meaning | Decided at |
|---|---|---|
| `<CP_IP>` | control-plane node address | owner |
| `<WK1_IP>` | `talos-wk-1` address (the GPU worker; `10.20.0.12`) | owner |
| `<WK2_IP>` | `talos-wk-2` address (no GPU; `10.20.0.13`, TODO(GATE 4)) | owner |
| `<API_ENDPOINT>` | Kubernetes API endpoint / VIP (set as `CLUSTER_ENDPOINT`) | owner |

## 1. Pre-checks

- [ ] The owner is present and has approved applying to the live nodes.
- [ ] `talos/inputs.env` reflects the decisions: endpoint, install disk, SANs (no `192.0.2.1` placeholder left).
- [ ] `versions.yaml` pins the intended Talos (`v1.14.4`) and Kubernetes (`v1.37.1`) — read the release
      notes and confirm the pair is still supported before upgrading either.
- [ ] The locally installed `talosctl` matches the pinned Talos minor (`talosctl version --client`).
      A mismatched client is reported by the tooling; upgrade it rather than ignoring the skew.
- [ ] A **restorable, off-box** copy of `talos/out/controlplane.yaml`, the `worker-*.yaml` files and `talosconfig`
      exists (Tier-2 secret — see `docs/runbooks/upgrades.md` §5). Losing them loses cluster admin.
- [ ] The node VMs exist and are powered on (Proxmox/OpenTofu, out of scope here).
- [ ] You have out-of-band access to `poseidon` in case networking goes wrong.

## 2. Generate configuration

Offline; write only local files.

```sh
./scripts/talos/gen-configs.sh
./scripts/talos/validate.sh
```

This writes `talos/out/controlplane.yaml`, one `talos/out/worker-<node>.yaml` per worker
(`worker-talos-wk-1.yaml`, `worker-talos-wk-2.yaml`) and `talos/out/talosconfig`. `talos/out/worker.yaml` is
only the base the per-node files are derived from; never apply it in production. The
directory is **gitignored** and the files embed the cluster PKI and secrets — never commit them. Verify:

```sh
git check-ignore -v talos/out/controlplane.yaml
```

Every worker config carries the `local-path-provisioner` user volume (`talos/patches/worker.yaml`), so each
worker VM needs its data disk (decisions §3.4). Each also gets its storage-link address
(`talos/patches/node-talos-wk-*.yaml`), and only `talos-wk-1` gets the GPU patch with its soft taint
(`talos/patches/gpu-worker.yaml`, decisions §3.6). The libvirt lab uses `TALOS_INPUTS=talos/inputs.lab.env`,
which skips the user-volume and GPU patches, keeps a single `worker.yaml` and writes to `talos/out/lab`.

`gen-configs.sh` is idempotent: a second run is a no-op. `--force` regenerates, and that **replaces
the cluster PKI/secrets**, invalidating any node already configured from the previous files. Once a node runs
the config, use `--regen` instead (section 11).

## 3. Boot the node VMs

Out of scope for this runbook. Building a Talos VM (image acquisition, disk bus, size, VLAN) is OpenTofu's job
Proxmox work owned by OpenTofu. Once the VMs are up, each Talos node exposes a maintenance API on its IP
and is ready for the next step.

## 4. Apply machine config

Apply config to the control plane first, then each worker. `--insecure` is used only for the initial
maintenance-mode apply, before the node trusts the cluster CA.

```sh
talosctl apply-config --insecure --nodes <CP_IP>  --file talos/out/controlplane.yaml
talosctl apply-config --insecure --nodes <WK1_IP> --file talos/out/worker-talos-wk-1.yaml
talosctl apply-config --insecure --nodes <WK2_IP> --file talos/out/worker-talos-wk-2.yaml
```

`just talos-apply` runs the same three commands with the default addresses, then the two `config` lines below.

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

To use it from your normal shell, merge it in as the context `homelab` (`~/.kube/config` is backed up first,
and a re-run replaces the old entry, e.g. after a rebuild):

```sh
just kube-merge                      # ./scripts/talos/kube-merge.sh
kubectx homelab
just kube-merge --name homelab-lab --kubeconfig talos/out/lab/kubeconfig   # the libvirt lab, if wanted
```

## 7. Install the CNI

`talos/patches/common.yaml` deletes Talos' bundled Flannel document, so Talos has **not** installed a
CNI and pods are not yet networked, including the Flux controllers. Install Cilium once, by hand:

```sh
./scripts/talos/install-cni.sh --kubeconfig talos/out/kubeconfig --dry-run   # preview
./scripts/talos/install-cni.sh --kubeconfig talos/out/kubeconfig --confirm
```

The script reads the chart, version and values from `kubernetes/infrastructure/cilium/release.yaml` and
installs them as the Helm release `cilium` in namespace `cilium`, the release that HelmRelease manages.
Flux adopts it on its first reconcile, so from then on Cilium changes go through git only. Cilium runs with
kube-proxy replacement (`docs/decisions.md` §3.3); confirm the pinned chart supports Kubernetes `v1.37.1`
before installing (`versions.yaml`).

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

Expected, at minimum: etcd reports one member; the control-plane node is `Ready`; both workers join and are
`Ready`; `talos-wk-1` shows the taint `nvidia.com/gpu=present:PreferNoSchedule`; every system pod (and the CNI's pods) is `Running`; the API responds `ok` to `/readyz`.

## 9. Rollback and limitations

These are real and are the reason the gate exists. Read them before starting.

- **`talosctl bootstrap` cannot be undone in place.** It creates etcd; there is no "un-bootstrap". To
  start over you must reset or recreate the node (`talosctl reset` wipes the node's disks) and bootstrap
  again — a new etcd, and any previously created Kubernetes objects are gone.
- **`--force` changes the cluster identity.** `gen-configs.sh --force` produces a new PKI/secrets. Nodes
  already configured from the old files become inconsistent with any node configured from the new ones; a
  clean re-provision is required. A patch change on a running cluster is `--regen` (section 11), which keeps
  the PKI. Back up `talos/out/` before any regeneration.
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

## 11. Change machine config on a running cluster

After a change under `talos/patches/` or `talos/inputs.env`. Never `--force` here: it replaces the PKI.

1. Secrets bundle, once. `--regen` refuses without `talos/out/secrets.yaml`. Derive it from the running
   config, which carries the same PKI:

   ```sh
   talosctl gen secrets --from-controlplane-config talos/out/controlplane.yaml -o talos/out/secrets.yaml
   ```

2. Regenerate and validate (offline). The old files go to `talos/out/backup-<UTC time>/`; `talosconfig` and
   `secrets.yaml` are not touched:

   ```sh
   just talos-regen
   ```

3. Dry run per node, control plane first. Read the diff: only the intended documents should change.

   ```sh
   just talos-upgrade-config 10.20.0.11      # talosctl apply-config ... --dry-run
   just talos-upgrade-config 10.20.0.12      # worker-talos-wk-1.yaml
   just talos-upgrade-config 10.20.0.13      # worker-talos-wk-2.yaml
   ```

   The recipe picks each node's own file and refuses an address it does not know.

4. Apply, control plane first. `--mode=auto` reboots only if the change needs it; the dry run says which.

   ```sh
   just talos-upgrade-config 10.20.0.11 --mode=auto
   just talos-upgrade-config 10.20.0.12 --mode=auto
   just talos-upgrade-config 10.20.0.13 --mode=auto
   ```

5. Check `just talos-health` and `kubectl get nodes -o wide`. To go back, copy the backup files over the
   new ones and apply them the same way.

## 12. Add `talos-wk-2` to a running cluster

For a cluster bootstrapped with `talos-wk-1` only (decisions §3.6). The owner runs every step.

1. OpenTofu creates the VM (Proxmox root): set `talos_wk2_ipv4`, `talos_wk2_vmid` and a `talos-wk-2` entry in
   `talos_macs` in `terraform.tfvars`, then `tofu plan` and `tofu apply`. The NAS exports already allow
   `10.99.0.0/29`, which covers `.5`; if `k8s_nfs_allowed_networks` is overridden in the TrueNAS root, add it.
2. Regenerate with the same PKI (section 11, steps 1–2): `just talos-regen`. This writes
   `worker-talos-wk-1.yaml` and `worker-talos-wk-2.yaml`.
3. Push the new config to `talos-wk-1`. Its storage-link address moves to its own patch, and it gains the
   taint. Dry run first, then `just talos-upgrade-config 10.20.0.12 --mode=auto`.
4. The kubelet sets the taint only when a node registers, so add it once by hand. Talos keeps it from then on:

   ```sh
   kubectl taint nodes talos-wk-1 nvidia.com/gpu=present:PreferNoSchedule
   ```

5. Join the new node, which is in maintenance mode: `just talos-apply-node 10.20.0.13`. This runs
   `--insecure` with `worker-talos-wk-2.yaml`.
6. Verify:
   - `kubectl get nodes -o wide` shows `talos-wk-2` `Ready`.
   - `kubectl describe node talos-wk-1 | grep Taints` shows the soft taint.
   - On `talos-wk-2`, the storage link answers (`talosctl -n 10.20.0.13 get addresses` shows `10.99.0.5/29`) and
     an `nas-nfs` PVC mounts there.
   - A GPU pod still lands on `talos-wk-1`.

Existing pods do not move on their own. Pods with `local-path` PVs stay on `talos-wk-1` by design.
