# Proxmox root configuration

Manages Proxmox VE resources for the homelab — currently the three Talos node VMs via the
[`talos-vm`](../../../modules/talos-vm/README.md) module.

**Status:** VM provisioning authored; **nothing applied to the real host**. Provider pinned; state
backend still TBD (`docs/secrets-and-state.md` §5). Proven against the L1 Proxmox fixture (a real
nested Proxmox VE 9.2, `just lab-pve-plan`): plan, apply, a clean second plan and destroy. The VMs
there are created stopped and small; the real host's storage, bridge, VLAN and token are unproven
(see Verification below).

## Storage link

`storage-link.tf` manages `vmbr1`: port `nic2`, `10.99.0.1/29`, MTU 9000, no gateway (the poseidon end of the
10 GbE link to the NAS, `docs/decisions.md` §2.2). Each Talos VM gets a second NIC (net1) on `vmbr1`, untagged, MTU
9000, no cloud-init address (`talos_storage_link_nic`, default `true`); Talos machine config gives it `10.99.0.3/29`
(cp), `10.99.0.4/29` (talos-wk-1) or `10.99.0.5/29` (talos-wk-2), so NFS goes straight over the link. Adding it to running VMs is a hotplug, no reboot. The role needs no extra privilege. `nic2` itself must carry
`mtu 9000` first (a hand-written `iface nic2 inet manual` / `mtu 9000` stanza, see
`docs/runbooks/host-network-bootstrap.md`), because PVE refuses a bridge MTU above its port's. A hand-made
`vmbr1` is adopted with `tofu import proxmox_network_linux_bridge.storage_link poseidon:vmbr1`. Variables:
`storage_link_{bridge,port,address,mtu}`. Proven on the lab fixture only (create, import, destroy, jumbo ping
to the NAS fixture); the real link is unmeasured.

## Host services

Two things run on the host itself, installed over SSH by `terraform_data` resources (root SSH, the agent):

- `fan-control.tf` (`gpu_fan_control`): the GPU fan controller, which sets the Tesla P4's fan header from the
  card's temperature (`docs/runbooks/gpu-fan-control.md`, `docs/decisions.md` §3.8).
- `host-metrics.tf` (`host_metrics`): Debian's `prometheus-node-exporter` on the management address, with the
  controller's metrics in its textfile directory; scraped by
  `kubernetes/infrastructure/configs/proxmox-host-scrapeconfig.yaml`. `just lab-pve-plan` installs it on the lab
  fixture, checks it answers, re-plans clean and purges it.

Both are `null` by default and are removed from the host when set back to `null`.

## Decided topology (docs/decisions.md §3.1)

| Guest | vCPUs | RAM | Disk | Datastore |
|---|---|---|---|---|
| `talos-cp-1` | 2 | 4 GiB | 20 GiB | `local-lvm` |
| `talos-wk-1` | 3 | 16 GiB | 80 GiB boot + **100 GiB data**; the Tesla P4 (`gpu.tf`) | `local-lvm` |
| `talos-wk-2` | 3 | 12 GiB | 40 GiB boot + **100 GiB data**; no GPU | `local-lvm` |

**All boot disks live on `local-lvm` (the host SSD)** — never the NAS (§3.2). The old 3 TB
qcow2 on the NAS is not carried forward. 8 vCPU on 4 host threads is a 2× overcommit,
acceptable for a mostly idle homelab; 32 GiB of guest RAM leaves the 8 GiB reserve inside 46 GiB; the five disks provision 340 GiB of the 360 GiB thin pool (`docs/decisions.md` §3.6); there is **no HA claim** — one host means host loss is cluster loss.

Each worker's extra **data disk** (module variable `data_disk`, `data_disk_gb` in
[`talos.tf`](talos.tf)) backs the Talos user volume for the node-local `local-path`
StorageClass (§3.4, §4.3); the control plane has none.

The whole topology is readable in one file: [`talos.tf`](talos.tf).

## The Talos image (explicit + verified)

The OS image is the **Talos Image Factory `nocloud` disk**, fetched by Proxmox itself with
`proxmox_download_file` and imported per VM:

```text
https://factory.talos.dev/image/08d87116314dbc848da5843a26140ad62f1a97d0d27a5358f6380337e865b739/<version>/nocloud-amd64.raw.zst
```

- The id is `talos/schematic-gpu.yaml` (`talos_image_schematic_id`), the GPU worker's image. Every other node
  must be moved to its installer image (`talos/schematic.yaml`) with `talosctl upgrade --image` after creation:
  without the card, the NVIDIA extensions block the boot and Talos reboots the node every 70 minutes.
- `<version>` is parsed from `versions.yaml` (`kubernetes.talos`), so the URL cannot drift
  from the pin. For `v1.14.4` the URL was verified with `curl -sI` (HTTP 200,
  `application/octet-stream`, 231366805 bytes) — see the task report.
- `nocloud` (not `metal`) is the Proxmox platform: Proxmox's cloud-init drive is a NoCloud
  datasource from which Talos reads its `network-config`.
- The artifact is compressed (`.raw.zst`), so it is downloaded as `content_type = "iso"`
  with `decompression_algorithm = "zst"` and passed to the module as `file_id` (compressed
  images cannot use `import_from`).

## Addressing (environment differences are variables)

Production and lab differ; the code does not hardcode either:

| Variable | Production | Lab (`docs/decisions.md` §2.4) |
|---|---|---|
| `vm_bridge` | `vmbr0` (confirm at cutover) | libvirt bridge |
| `k8s_vlan_id` | `20` | `null` (flat) |
| `k8s_gateway` | `10.20.0.1` | `10.99.100.1` |
| `talos_cp_ipv4` / `talos_wk_ipv4` / `talos_wk2_ipv4` | `10.20.0.11` / `10.20.0.12` / `10.20.0.13` | `10.99.100.11` / `10.99.100.12` / `10.99.100.13` |

Nodes live in `10.20.0.11–29`; lab nodes in `10.99.100.0/24`. Node addresses reach the
guest through Proxmox's cloud-init `network-config`.

## Host capacity guard

A `check` block in [`talos.tf`](talos.tf) warns if the sum of guest RAM would eat into the
reserved headroom (`proxmox_host_memory_reserve_mb`) of the host's 46 GiB. It is a warning,
not a hard failure — the host headroom is a judgement call (`docs/architecture.md` §3).

## Usage

```sh
cd infrastructure/environments/homelab/proxmox

# Credentials via environment (never committed):
export PROXMOX_VE_API_TOKEN='user@realm!tokenid=secret'

cp terraform.tfvars.example terraform.tfvars   # then edit; tfvars is gitignored
tofu init -backend=false
tofu validate
tofu plan                                      # review only — needs API access
```

**Applies are gated** — see `docs/PROJECT-PLAN.md`. Do not `tofu apply` against live
infrastructure without explicit owner approval, and never `-auto-approve`.

## Machine config is NOT delivered here

By decision (`docs/architecture.md` §7), OpenTofu owns the VM lifecycle but **Talos
tooling owns machine config and bootstrap**. The module default is
`talos_machine_config_delivery = "talosctl"`: the VM boots the nocloud image in maintenance
mode and `talosctl apply-config` (see `scripts/talos/`) delivers the config. The
`cloud-init-snippet` mode exists for lab/dev only.

## Out of scope here

TrueNAS and UniFi resources are authored in their own roots — this root does not touch
them. The NAS remains for backups/ISOs only (never VM disks).

## Verification

- `tofu fmt -check -recursive infrastructure/` — formatting.
- `tofu validate` — schema/type correctness (backend disabled; no live access).
- `just lab-pve-plan` — plan, apply, second plan (must be clean) and destroy against the L1 fixture
  only (`docs/lab.md` "Proxmox fixture"). Against the real host, `tofu plan` still needs API access.
- `curl -sI` on the image URL — confirms the artifact exists for the pinned version.

## Ownership

OpenTofu owns Proxmox resources + VM lifecycle (`docs/architecture.md` §7). Kubernetes
resources are owned by Flux, not here.
