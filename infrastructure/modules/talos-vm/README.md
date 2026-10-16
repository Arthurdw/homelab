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
| `cpu_type` | `string` | `"x86-64-v2-AES"` | CPU model. Meets Talos's x86-64-v2 requirement and allows migration; `host` is faster but blocks migration. |
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

## The two things that need real verification (lab / cutover)

1. **Cloud-init user-data.** With `machine_config_delivery = "talosctl"` the Proxmox
   cloud-init drive still carries a *generated* `user-data`. Talos's `nocloud` platform
   reads `user-data` as machine config, so a generated (non-Talos) `user-data` must be
   confirmed harmless (node boots to maintenance mode) in the L1 lab fixture.
   `TODO(L1)`. If it is not harmless, use `"cloud-init-snippet"` (machine config as
   user-data, the documented manual flow) or the `metal` image with DHCP + `talosctl`.

2. **The QEMU guest agent.** The vanilla Image Factory schematic
   (`customization: {}`, id `376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba`)
   does **not** include the `siderolabs/qemu-guest-agent` extension, so
   `qemu_guest_agent_enabled` defaults to `false` — enabling it would make Proxmox wait
   for an agent that never starts. To enable the agent, build a schematic with that
   extension at <https://factory.talos.dev>, put its id in `talos_image_schematic_id`
   (root) and set `talos_qemu_guest_agent_enabled = true`. `TODO(GATE 4)`.
