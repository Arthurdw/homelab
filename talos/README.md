# Talos configuration

Inputs and machine-config patches for the Talos nodes. The machine configs themselves are **generated**
locally and never committed, because they embed the cluster PKI and secrets.

> **Status: generated and validated offline, never applied.** No production VM exists. The libvirt lab
> guests boot Talos but do not finish installing yet (see `docs/lab.md`, *Status and known issues*).

## Version pin

`versions.yaml` is authoritative; the generator reads it and does not duplicate the pins.

| Component | Pin | Verification |
|---|---|---|
| Talos | `v1.14.4` | GitHub release `siderolabs/talos` tag `v1.14.4` |
| Kubernetes | `v1.37.1` | bundled by the same Talos release; inside the v1.14 support matrix (1.33–1.37) |

`gen config` is passed `--talos-version`, so an older local `talosctl` still generates correct configs.
Upgrade the client to the pin before touching a live node.

## Layout

| Path | Committed? | Purpose |
|---|---|---|
| `inputs.env` | yes | Production inputs. Values only known at cutover are marked `TODO(GATE 4)`. |
| `inputs.lab.env` | yes | Libvirt lab inputs (`scripts/lab/virt/`): lab endpoint, `/dev/vda`, node-IP SANs, no worker or network patch. |
| `patches/common.yaml` | yes | Every node: removes the bundled Flannel so Cilium is the CNI (decisions §3.3). |
| `patches/controlplane.yaml` | yes | Control plane: disables kube-proxy (Cilium replaces it; Talos rejects this document on workers). |
| `patches/worker.yaml` | yes | Workers: the `local-path-provisioner` user volume on the data disk (decisions §3.4). |
| `patches/network-controlplane.yaml` | yes | Production control plane: storage-link NIC `10.99.0.3/29`, MTU 9000; kubelet node IP and etcd pinned to `10.20.0.0/24` (decisions §2.2). |
| `patches/network-worker.yaml` | yes | Production workers: the `storage0` NIC alias; kubelet node IP pinned to `10.20.0.0/24`. |
| `patches/node-talos-wk-1.yaml` | yes | `talos-wk-1` only: storage-link address `10.99.0.4/29`, MTU 9000. |
| `patches/node-talos-wk-2.yaml` | yes | `talos-wk-2` only: storage-link address `10.99.0.5/29`, MTU 9000. |
| `patches/gpu-worker.yaml` | yes | `talos-wk-1` only: NVIDIA driver modules and `net.core.bpf_jit_harden=1` for the passed-through Tesla P4, the `nvidia.com/gpu.present` label and the `nvidia.com/gpu=present:PreferNoSchedule` taint. |
| `out/` | **no** (gitignored) | Generated `controlplane.yaml`, `worker.yaml` (production: the shared base, never applied), `worker-<node>.yaml` (production: one per worker), `talosconfig`, the `secrets.yaml` bundle, `--regen` backups. Contains secrets. |

Patches are Talos 1.14 **multi-document** patches (matched by `apiVersion`/`kind`), not legacy
`machine:`/`cluster:` paths, which collide with the generated documents and fail `talosctl validate`.
The one exception is `cluster.etcd.advertisedSubnets` in `network-controlplane.yaml`: etcd has no multi-doc
kind in 1.14, and that path validates. A patch file containing only comments is skipped.

`WORKER_PATCH` selects the worker patch (default `talos/patches/worker.yaml`; empty skips it). The lab sets
it empty because the lab worker has a single 40 GiB disk with no room for the 90 GiB user volume, so the lab
has no `/var/mnt/local-path-provisioner`.

`CONTROLPLANE_NETWORK_PATCH` and `WORKER_NETWORK_PATCH` work the same way (defaults `talos/patches/network-*.yaml`).
The lab sets both empty: its guests have one NIC and no storage link.

**Per-node workers.** `WORKER_NODES` (default `talos-wk-1 talos-wk-2`) lists the production workers. For each,
the generator patches the shared `worker.yaml` with `patches/node-<node>.yaml` into `out/worker-<node>.yaml`,
and that file is what the node gets (`just talos-apply`, `just talos-upgrade-config <ip>`). The storage-link
address is the only thing that differs between the two, so it lives in the node files. The lab sets
`WORKER_NODES` empty and applies `worker.yaml` as before.

`GPU_WORKER_PATCH` (default `talos/patches/gpu-worker.yaml`) loads the NVIDIA modules for the Tesla P4 and
marks the node: a label for the device plugin and a soft taint, so ordinary pods prefer `talos-wk-2`.
`GPU_WORKER_NODE` (default `talos-wk-1`) is the one worker that gets it; `talos-wk-2` has no GPU. The lab sets
the patch empty. Every node's image carries the NVIDIA extensions (one shared schematic), but without this
patch nothing loads them. The kubelet sets the taint only when a node registers, so a `talos-wk-1` that is
already in the cluster needs it once with `kubectl taint` (`patches/gpu-worker.yaml`).

`local-path` volumes stay on `talos-wk-1`'s data disk, so their pods stay there too; moving stateful apps to
`talos-wk-2` is a separate change.

**Storage NIC selection.** The patches never name a MAC. A `LinkAliasConfig` called `storage0` matches
`link.driver == "virtio_net" && link.bus_path.endsWith(":13.0")`: Proxmox puts `netN` on PCI slot `0x12+N`
on q35, so `net1` is always `0000:00:13.0`. If the alias matches no link or more than one, Talos does not apply
it and the address stays unset. Check with `talosctl get linkaliasspecs` and `talosctl get addresses`.

## Generating and validating

Both scripts are offline: they read and write local files only.

```sh
./scripts/talos/gen-configs.sh            # generate into talos/out/ (no-op if it already exists)
./scripts/talos/gen-configs.sh --dry-run  # print the command, write nothing
./scripts/talos/gen-configs.sh --regen    # rebuild controlplane/worker*.yaml from secrets.yaml (same PKI)
./scripts/talos/gen-configs.sh --force    # NEW PKI: never on a running cluster
TALOS_INPUTS=talos/inputs.lab.env ./scripts/talos/gen-configs.sh   # lab configs into talos/out/lab
just talos-validate                       # talosctl validate --mode metal on every config
```

**`talos/out/` must never be committed.** Check with `git check-ignore -v talos/out/controlplane.yaml`.

## Booting and bootstrapping

Not here. OpenTofu owns the VMs (`infrastructure/environments/homelab/proxmox/talos.tf`), and the bootstrap
is a gated live operation: follow `docs/runbooks/talos-bootstrap.md`. The guarded helpers are in
`scripts/talos/`.

## Values set at cutover (`TODO(GATE 4)`)

- `ADDITIONAL_SANS`: an API DNS name, if one is created.
- `INSTALL_IMAGE`: derived from `TALOS_PLATFORM` and `TALOS_SCHEMATIC` as the Image Factory installer
  (`factory.talos.dev/nocloud-installer/<schematic>:<talos>`). `ghcr.io/siderolabs/installer` is no longer
  published. The schematic is `talos/schematic.yaml` (`siderolabs/kata-containers`, `siderolabs/qemu-guest-agent`,
  `siderolabs/nonfree-kmod-nvidia-lts`, `siderolabs/nvidia-container-toolkit-lts`), shared by
  production and the lab (only the platform differs), and must match `talos_image_schematic_id`
  in the Proxmox environment. To change it, edit the file, `curl -sX POST --data-binary @talos/schematic.yaml
  https://factory.talos.dev/schematics`, and update the id in `talos/inputs.env`, `scripts/talos/gen-configs.sh`
  and the Proxmox environment. Existing nodes pick it up with `talosctl upgrade --image`.
- NTP: the Talos default until the internal time source is decided.
