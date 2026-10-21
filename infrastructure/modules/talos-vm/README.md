# Module `talos-vm`

Creates **one Talos Linux VM on Proxmox VE**, from the Talos `nocloud` disk image, with
the boot disk on a local datastore (`local-lvm` by decision). It is deliberately a
single-VM module: the caller owns the topology (how many nodes, their sizes and their
addresses), which keeps a whole cluster readable in one file.

- Provider: `bpg/proxmox` — pinned to `0.116.1` in `versions.tf` (matches `versions.yaml`).
- The root module passes the provider configuration; this module only pins the version.

## What it encodes (decisions → code)

| Decision | Where | Source |
|---|---|---|
| VM boot disks on the host SSD, never the NAS | `disk_datastore_id` default `local-lvm` | `docs/decisions.md` §3.2 |
| Node-local database storage needs a disk that is not the Talos system disk | optional `data_disk` (worker only) | `docs/decisions.md` §3.4, §4.3 |
| Talos on Proxmox uses the `nocloud` platform; addressing comes from Proxmox's cloud-init `network-config` | `ip_address` / `ip_gateway` → `initialization.ip_config` | Talos docs, `cloud-platforms/nocloud` |
| K8s traffic on its own VLAN | `vlan_id` (null on a flat/lab bridge) | `docs/decisions.md` §2.1 |
| Talos (not OpenTofu) owns machine config and bootstrap | `machine_config_delivery` default `talosctl` | `docs/architecture.md` §7 |
| Disable the Proxmox firewall on the K8s NIC; management stays private | `network_firewall` default `false` | `docs/decisions.md` §5.2 |
| No RAM ballooning | `memory_floating_mb` default `0` | Talos docs, Proxmox guide |

It also follows the Talos Proxmox recommendations: UEFI (`ovmf`) + `q35` + a 4 MiB EFI
disk, virtio NIC, and **not** the `virtio-scsi-single` disk controller (which hangs
Talos bootstrap).

## What it deliberately does NOT encode

- **Machine config / bootstrap / OS upgrade** — those are Talos tooling's job
  (`docs/architecture.md` §7; `scripts/talos/`). OpenTofu never injects them by default.
  In particular, `data_disk` only attaches a raw disk; the Talos `UserVolumeConfig`
  that partitions, mounts and consumes it lives in `talos/patches/worker.yaml`.
- **Instance count / topology / sizing** — the caller decides; see
  `infrastructure/environments/homelab/proxmox/talos.tf`.
- **The OS image** — the caller downloads it (`proxmox_download_file`) and passes a
  status in; that way one artifact serves every node instead of being fetched per VM.
- **IP allocation policy** — the caller supplies each node's address.
- **The QEMU guest agent extension** — enabling the agent needs an image built with the
  `siderolabs/qemu-guest-agent` extension; the module cannot add it to a downloaded image.

## Usage (abridged)

```hcl
module "talos" {
  source   = "../../../../modules/talos-vm"
  for_each = local.talos_nodes          # caller's topology table

  name      = each.key
  vm_id     = each.value.vm_id
  node_name = var.proxmox_node_name

  cpu_cores           = each.value.cpu_cores
  memory_dedicated_mb = each.value.memory_mb
  disk_size_gb        = each.value.disk_gb

  # Worker only (each.value.data_disk_gb is null on the control plane).
  data_disk = each.value.data_disk_gb == null ? null : {
    size_gb = each.value.data_disk_gb
  }

  os_image_file_id = proxmox_download_file.talos.id

  bridge     = var.vm_bridge
  vlan_id    = var.k8s_vlan_id
  ip_address = "${each.value.ipv4}/${var.k8s_prefix_length}"
  ip_gateway = var.k8s_gateway
}
```

## Variables

### Identity

| Name | Type | Default | Purpose |
|---|---|---|---|
| `name` | `string` | — (required) | VM name / Talos hostname; must be a valid DNS name. |
| `vm_id` | `number` | — (required) | Proxmox VMID. |
| `node_name` | `string` | — (required) | This VM's Proxmox VE node name. Host-specific; confirm at cutover. |
| `description` | `string` | `"Talos Linux node — managed by OpenTofu …"` | Proxmox description. |
| `tags` | `list(string)` | `["homelab","kubernetes","talos"]` | Proxmox tags. Proxmox sorts them, so keep the list sorted to avoid drift. |

### Compute

| Name | Type | Default | Purpose |
|---|---|---|---|
| `cpu_cores` | `number` | — (required) | vCPUs (≥ 1). |
| `cpu_type` | `string` | `"x86-64-v2-AES"` | CPU model. Meets Talos's x86-64-v2 requirement and allows migration; `host` is faster, exposes VT-x/AMD-V to the guest (required for Kata Containers) and blocks migration. |
| `memory_dedicated_mb` | `number` | — (required) | Guest RAM in MiB (≥ 2048, Talos's minimum). |
| `memory_floating_mb` | `number` | `0` | Ballooning ceiling. Must stay 0 — Talos cannot use ballooned memory. |

### Firmware

| Name | Type | Default | Purpose |
|---|---|---|---|
| `bios` | `string` | `"ovmf"` | `ovmf` (UEFI, Talos-recommended; adds a 4 MiB EFI disk) or `seabios`. |
| `machine_type` | `string` | `"q35"` | QEMU machine type (`pc` or `q35…`). |
| `os_type` | `string` | `"l26"` | Proxmox guest OS hint. |

### Boot disk

| Name | Type | Default | Purpose |
|---|---|---|---|
| `disk_size_gb` | `number` | — (required) | Boot disk size in GiB (≥ 10). |
| `disk_datastore_id` | `string` | `"local-lvm"` | Datastore for the boot disk (host SSD; never the NAS). |
| `disk_interface` | `string` | `"scsi0"` | Disk bus. Do not use `virtio-scsi-single` (hangs Talos bootstrap). |
| `disk_file_format` | `string` | `"raw"` | `raw` / `qcow2` / `vmdk`. |
| `disk_discard` | `string` | `"on"` | Pass TRIM to the SSD (`on`/`ignore`). |
| `disk_ssd` | `bool` | `true` | Advertise SSD emulation. |

### Data disk (optional)

`data_disk` adds a **second** disk, separate from the boot disk. It is `null` (the
default) unless a node needs local storage: Talos cannot provision a `UserVolumeConfig`
on the system disk, because the `EPHEMERAL` partition spans it and consumes the free
space. The worker's data disk backs the node-local `local-path` StorageClass
(`docs/decisions.md` §3.4, §4.3); it is **not** replicated (node-local, no HA).

| Name | Type | Default | Purpose |
|---|---|---|---|
| `data_disk` | `object({size_gb, interface, datastore_id})` | `null` | Additional disk. `null` = boot disk only. |
| `data_disk.size_gb` | `number` | — (required) | Data disk size in GiB (≥ 1). |
| `data_disk.interface` | `string` | `"scsi1"` | Bus slot; must differ from `disk_interface`. |
| `data_disk.datastore_id` | `string` | `null` → boot disk's | Override the datastore (defaults to `disk_datastore_id` = the host SSD). |

The data disk inherits `disk_file_format`, `disk_discard` and `disk_ssd` from the boot
disk, so it lands on the same SSD with the same TRIM/SSD behaviour.

### OS image source

Exactly one of the two must be set (a `precondition` enforces it):

| Name | Type | Default | Purpose |
|---|---|---|---|
| `os_image_file_id` | `string` | `null` | Status of a compressed/`iso`-content image (e.g. the Image Factory `.raw.zst`) to import as the boot disk. Take it from `proxmox_download_file.<x>.id`. |
| `os_image_import_from` | `string` | `null` | Status of an uncompressed image of `import` content type. Alternative to the above. |

### Network

| Name | Type | Default | Purpose |
|---|---|---|---|
| `bridge` | `string` | — (required) | Proxmox bridge (e.g. `vmbr0`). Host-specific. |
| `vlan_id` | `number` | `null` | 802.1Q tag (1–4094) or `null` on a flat bridge. K8s VLAN is 20 in production. |
| `mac_address` | `string` | `null` | Optional fixed MAC for deterministic addressing/DHCP reservation. |
| `network_model` | `string` | `"virtio"` | NIC model (Talos recommends `virtio`). |
| `network_firewall` | `bool` | `false` | Enable the Proxmox firewall on this NIC. |
| `ip_address` | `string` | `null` | Static IPv4 in CIDR form, delivered via cloud-init `network-config`; `null` = DHCP. |
| `ip_gateway` | `string` | `null` | Default gateway for `ip_address`. |

### Cloud-init disk

| Name | Type | Default | Purpose |
|---|---|---|---|
| `cloud_init_datastore_id` | `string` | `"local-lvm"` | Datastore for the generated NoCloud drive. |
| `cloud_init_interface` | `string` | `"ide2"` | Interface for the cloud-init drive (must not collide with `disk_interface`). |

### QEMU guest agent

| Name | Type | Default | Purpose |
|---|---|---|---|
| `qemu_guest_agent_enabled` | `bool` | `false` | Enable the Proxmox guest agent. Only valid with an image that includes the `siderolabs/qemu-guest-agent` extension — see below. |
| `qemu_guest_agent_timeout` | `string` | `"15m"` | How long Proxmox waits for the agent. |

### Machine-config delivery

| Name | Type | Default | Purpose |
|---|---|---|---|
| `machine_config_delivery` | `string` | `"talosctl"` | `"talosctl"` (maintenance mode; Talos tooling applies config — the §7-compliant default) or `"cloud-init-snippet"` (inject a snippet as user-data; lab/dev only). |
| `machine_config_snippet_id` | `string` | `null` | Status of the snippet (`local:snippets/…`). Required for `cloud-init-snippet`. |

### Lifecycle

| Name | Type | Default | Purpose |
|---|---|---|---|
| `on_boot` | `bool` | `true` | Start the VM when the host boots. |
| `started` | `bool` | `true` | Start the VM after creation. |
| `stop_on_destroy` | `bool` | `true` | Stop (not shut down) on destroy — required with the agent disabled. |
| `serial_console` | `bool` | `true` | Attach a serial device for early boot logs. |

## Outputs

| Name | Purpose |
|---|---|
| `vm_id` | Proxmox VMID. |
| `name` | VM name. |
| `ipv4_addresses` | Guest-agent-reported IPv4 addresses (**empty** unless the agent is enabled). |
| `mac_addresses` | NIC MAC addresses. |
| `qemu_guest_agent_enabled` | Whether the agent was enabled. |

## Talos version bumps cannot upgrade or replace nodes

`docs/architecture.md` §6 and §7 say an ordinary apply must never upgrade Talos as a side effect.
This is the argument that it can't, for the homelab caller
(`environments/homelab/proxmox/talos.tf`):

1. **Only one thing depends on the version.** `local.talos_version` is parsed from
   `versions.yaml`. It feeds exactly two attributes, `url` and `file_name` of
   `proxmox_download_file.talos`. No Talos provider resources exist (no
   `talos_machine_configuration_apply`, no `talos_machine_bootstrap`), so OpenTofu has no path
   to a running node's OS. Machine config is applied by `scripts/talos/` (Talos tooling).
2. **A bump replaces the image file, nothing else.** The new `url`/`file_name` force a new
   `proxmox_download_file`, which downloads the new image into the datastore and deletes the
   old one. Its `id` changes, and that id is this module's `os_image_file_id`.
3. **The VM ignores that change.** The VM resource has
   `lifecycle { ignore_changes = [disk[0].file_id, disk[0].import_from] }`. The image only
   seeds the boot disk at creation: Proxmox copies it into `local-lvm`, so the VM no longer
   reads the image file. The new id is never diffed against the VM. That means no in-place disk
   rewrite and no replacement. (`import_from` is already documented by the provider as "only used
   during initial creation"; `file_id` had no such guarantee, which is why it needs the
   ignore.)
4. **What the plan shows:** `proxmox_download_file.talos` *must be replaced*, and both
   `module.talos[*]` VMs show no changes. Any VM diff in a version-bump plan is a stop sign.
   The same applies to a `talos_image_schematic_id` change.

Consequences:

- New VMs (a new node, or a deliberate `-replace`) boot the *new* image. That is the only
  way an apply puts a new Talos version on a disk, and it is always an explicit operator action.
- Running nodes are upgraded with `talosctl upgrade`, one minor version at a time,
  control plane first (`docs/runbooks/upgrades.md` §5). Bump `versions.yaml` in the same PR so
  new nodes match.
- `disk[0]` is the boot disk because the static `disk` block comes before the dynamic data
  disk. Proven on the L1 Proxmox fixture (2026-10-21, `just lab-pve-plan --keep`, then
  `versions.yaml` bumped v1.14.4 to v1.14.3 in the scratch copy): the plan was "1 to add, 0 to
  change, 1 to destroy" (only `proxmox_download_file.talos`), the VMs showed no diff, and after
  apply VM 110/111 had identical disks (same `local-lvm` volumes and sizes) and a second plan was
  clean.

## The two things that need real verification (lab / cutover)

1. **Cloud-init user-data.** With `machine_config_delivery = "talosctl"` the Proxmox
   cloud-init drive still carries a *generated* `user-data`. Talos's `nocloud` platform
   reads `user-data` as machine config, so a generated (non-Talos) `user-data` must be
   confirmed harmless (node boots to maintenance mode) in the L1 lab fixture.
   `TODO(L1)`. If it is not harmless, use `"cloud-init-snippet"` (machine config as
   user-data, the documented manual flow) or the `metal` image with DHCP + `talosctl`.

2. **The QEMU guest agent.** The repo schematic (`talos/schematic.yaml`, id
   `2ed2e4794ba4c5fff3e18307516a15accd3c0d992408c0c9522d2d457a79429f`) includes
   `siderolabs/qemu-guest-agent` (and `kata-containers`). The module still defaults
   `qemu_guest_agent_enabled` to `false`, because with an image *without* the extension Proxmox would wait for an
   agent that never starts. The Proxmox root sets it to `true` (`talos_qemu_guest_agent_enabled`), which the new
   image needs: the extension's Talos service waits for the virtio agent channel, which only exists when the VM
   has the agent enabled. `TODO(GATE 4)`.
