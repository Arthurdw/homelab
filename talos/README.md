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
| `inputs.lab.env` | yes | Libvirt lab inputs (`scripts/lab/virt/`): lab endpoint, `/dev/vda`, node-IP SANs, no worker patch. |
| `patches/common.yaml` | yes | Every node: removes the bundled Flannel so Cilium is the CNI (decisions §3.3). |
| `patches/controlplane.yaml` | yes | Control plane: disables kube-proxy (Cilium replaces it; Talos rejects this document on workers). |
| `patches/worker.yaml` | yes | Workers: the `local-path-provisioner` user volume on the data disk (decisions §3.4). |
| `out/` | **no** (gitignored) | Generated `controlplane.yaml`, `worker.yaml`, `talosconfig`. Contains secrets. |

Patches are Talos 1.14 **multi-document** patches (matched by `apiVersion`/`kind`), not legacy
`machine:`/`cluster:` paths, which collide with the generated documents and fail `talosctl validate`.
A patch file containing only comments is skipped.

`WORKER_PATCH` selects the worker patch (default `talos/patches/worker.yaml`; empty skips it). The lab sets
it empty because the lab worker has a single 40 GiB disk with no room for the 90 GiB user volume, so the lab
has no `/var/mnt/local-path-provisioner`.

## Generating and validating

Both scripts are offline: they read and write local files only.

```sh
./scripts/talos/gen-configs.sh            # generate into talos/out/ (no-op if it already exists)
./scripts/talos/gen-configs.sh --dry-run  # print the command, write nothing
./scripts/talos/gen-configs.sh --force    # regenerate (REPLACES the cluster PKI/secrets)
TALOS_INPUTS=talos/inputs.lab.env ./scripts/talos/gen-configs.sh   # lab configs into talos/out/lab
just talos-validate                       # talosctl validate --mode metal on every config
```

**`talos/out/` must never be committed.** Check with `git check-ignore -v talos/out/controlplane.yaml`.

## Booting and bootstrapping

Not here. OpenTofu owns the VMs (`infrastructure/environments/homelab/proxmox/talos.tf`), and the bootstrap
is a gated live operation: follow `docs/runbooks/talos-bootstrap.md`. The guarded helpers are in
`scripts/talos/`.

## Values set at cutover (`TODO(GATE 4)`)

- `CLUSTER_ENDPOINT`: the control-plane address from the node range (decisions §2.1). The placeholder is an
  RFC 5737 documentation address.
- `ADDITIONAL_SANS`: an API DNS name, if one is created.
- `INSTALL_IMAGE`: derived from `TALOS_PLATFORM` and `TALOS_SCHEMATIC` as the Image Factory installer
  (`factory.talos.dev/nocloud-installer/<schematic>:<talos>`). `ghcr.io/siderolabs/installer` is no longer
  published. The schematic is `talos/schematic.yaml` (`siderolabs/kata-containers`, `siderolabs/qemu-guest-agent`),
  shared by production and the lab (only the platform differs), and must match `talos_image_schematic_id`
  in the Proxmox environment. To change it, edit the file, `curl -sX POST --data-binary @talos/schematic.yaml
  https://factory.talos.dev/schematics`, and update the id in `talos/inputs.env`, `scripts/talos/gen-configs.sh`
  and the Proxmox environment. Existing nodes pick it up with `talosctl upgrade --image`.
- NTP: the Talos default until the internal time source is decided.
