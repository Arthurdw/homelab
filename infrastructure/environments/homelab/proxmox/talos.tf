# Talos node VMs — the decided topology in one file (docs/decisions.md §3.1).
#
# Review order:
#   1. locals.talos_nodes      — the two guests, their sizing and addresses
#   2. proxmox_download_file   — the Talos image and how it gets here
#   3. module.talos            — one VM per table row
#
# Everything that differs between environments (bridge, VLAN, addressing, datastore,
# image) is a variable, not a literal, so the same code can target the lab later.

locals {
  # versions.yaml is the single source of truth for the Talos pin (kubernetes.talos).
  # Parsed here so the artifact URL can never drift from the pin.
  versions_yaml = file("${path.module}/../../../../versions.yaml")
  talos_version = regex("(?m)^  talos: \"(v[0-9]+\\.[0-9]+\\.[0-9]+)\"", local.versions_yaml)[0]

  # Talos Image Factory artifact. `nocloud` is the Proxmox platform: Proxmox's cloud-init
  # drive is a NoCloud datasource that Talos reads for network-config (see
  # docs.siderolabs.com/talos > platform-specific-installations/cloud-platforms/nocloud).
  # Verified 2026-10-16 with `curl -sI`: HTTP 200, application/octet-stream, 231366805 bytes.
  talos_image_url = format(
    "https://factory.talos.dev/image/%s/%s/%s-amd64.raw.%s",
    var.talos_image_schematic_id,
    local.talos_version,
    var.talos_image_platform,
    var.talos_image_compression,
  )

  # The decided topology (docs/decisions.md §3.1). Sizing is the decision and lives
  # here; addresses are environment inputs (variables) so the lab can differ.
  # The worker is intentionally larger: it runs the CNI and the workloads.
  # `data_disk_gb` is the dedicated, non-system disk that a Talos user volume is
  # provisioned on for the node-local `local-path` StorageClass (docs/decisions.md
  # §3.4, §4.3); the control plane gets none (null).
  talos_nodes = {
    "talos-cp-1" = {
      vm_id        = var.talos_cp_vmid
      cpu_cores    = 2
      memory_mb    = 2048
      disk_gb      = 20
      data_disk_gb = null
      ipv4         = var.talos_cp_ipv4
      role         = "controlplane"
    }
    "talos-wk-1" = {
      vm_id        = var.talos_wk_vmid
      cpu_cores    = 3
      memory_mb    = 16384
      disk_gb      = 80
      data_disk_gb = 100
      ipv4         = var.talos_wk_ipv4
      role         = "worker"
    }
  }

  talos_guest_memory_mb = sum([for n in local.talos_nodes : n.memory_mb])
}

# Warn (do not fail) if the guests would starve the host. The i5-7400 has 4c/4t and
# 46 GiB usable (docs/hardware.md); reserve headroom for the hypervisor and a
# non-Kubernetes VM rather than RAM-saturating the host (the current 42/46 GiB is an
# outlier, not a target — docs/architecture.md §3).
check "proxmox_host_memory_headroom" {
  assert {
    condition     = local.talos_guest_memory_mb + var.proxmox_host_memory_reserve_mb <= var.proxmox_host_memory_mb
    error_message = "Talos guests need ${local.talos_guest_memory_mb} MiB; reserving ${var.proxmox_host_memory_reserve_mb} MiB exceeds the host's ${var.proxmox_host_memory_mb} MiB. Reduce guest RAM or the reserve."
  }
}

# One shared image for every node: download once (Proxmox fetches it directly), import
# per VM. The factory serves a compressed raw disk; Proxmox decompresses it, so the
# file is stored with .img and passed to the module as `file_id` (compressed images
# cannot use `import_from`). It lives on `local`; the VM disks live on `local-lvm`.
resource "proxmox_download_file" "talos" {
  content_type            = "iso"
  datastore_id            = var.talos_image_datastore_id
  node_name               = var.proxmox_node_name
  url                     = local.talos_image_url
  file_name               = "talos-${local.talos_version}-${var.talos_image_platform}-amd64.img"
  decompression_algorithm = var.talos_image_compression
  # Immutable, version-pinned artifact: never re-download because an upstream size moved.
  overwrite = false

  # No checksum: the factory does not expose a simple .sha256 sidecar for this path
  # (verified 2026-10-16 — the .sha256 URL returns HTTP 402). TODO(GATE 4): add a
  # checksum if/when the factory publishes one, or pin the installer image instead.
}

# One VM per row of the topology table.
module "talos" {
  source   = "../../../modules/talos-vm"
  for_each = local.talos_nodes

  name      = each.key
  vm_id     = each.value.vm_id
  node_name = var.proxmox_node_name
  description = format(
    "Talos %s node %s — VM lifecycle by OpenTofu; coordinates by the node's own config (talos/v1.14, K8s v1.37).",
    each.value.role,
    each.key,
  )
  tags = concat(var.talos_vm_tags, [each.value.role])

  cpu_cores           = each.value.cpu_cores
  memory_dedicated_mb = each.value.memory_mb
  disk_size_gb        = each.value.disk_gb

  # Worker-only data disk for the Talos user volume behind the node-local `local-path`
  # StorageClass (docs/decisions.md §3.4, §4.3). Null on the control plane, so it gets
  # only its boot disk. The interface/datastore default in the module.
  data_disk = each.value.data_disk_gb == null ? null : {
    size_gb = each.value.data_disk_gb
  }

  disk_datastore_id = var.talos_disk_datastore_id
  os_image_file_id  = proxmox_download_file.talos.id

  bridge      = var.vm_bridge
  vlan_id     = var.k8s_vlan_id
  mac_address = lookup(var.talos_macs, each.key, null)

  ip_address = "${each.value.ipv4}/${var.k8s_prefix_length}"
  ip_gateway = var.k8s_gateway

  qemu_guest_agent_enabled  = var.talos_qemu_guest_agent_enabled
  machine_config_delivery   = var.talos_machine_config_delivery
  machine_config_snippet_id = var.talos_machine_config_snippet_id
}
