# One Talos Linux VM. See variables.tf for inputs and README.md for the rationale.
#
# Deliberately absent: any Talos machine configuration. Per docs/architecture.md §7,
# OpenTofu owns the VM lifecycle and Talos tooling owns machine config/bootstrap; the
# default `machine_config_delivery = "talosctl"` keeps that boundary. The one exception
# is opt-in and documented (`cloud-init-snippet`).

resource "proxmox_virtual_environment_vm" "this" {
  name            = var.name
  vm_id           = var.vm_id
  node_name       = var.node_name
  description     = var.description
  tags            = var.tags
  bios            = var.bios
  machine         = var.machine_type
  on_boot         = var.on_boot
  started         = var.started
  stop_on_destroy = var.stop_on_destroy

  lifecycle {
    # The boot image only seeds the disk at creation. A Talos version (or schematic) bump in
    # versions.yaml changes the caller's image file id. Without this, `tofu apply` would
    # rewrite the boot disk or replace the VM, which is a silent OS reinstall. Upgrades go through
    # `talosctl upgrade` (docs/runbooks/upgrades.md §5; docs/architecture.md §6, §7).
    # See README "Talos version bumps cannot upgrade or replace nodes".
    ignore_changes = [
      disk[0].file_id,
      disk[0].import_from,
    ]

    precondition {
      condition     = var.machine_config_delivery != "cloud-init-snippet" || var.machine_config_snippet_id != null
      error_message = "machine_config_snippet_id is required when machine_config_delivery = \"cloud-init-snippet\"."
    }

    precondition {
      condition     = (var.os_image_file_id != null) != (var.os_image_import_from != null)
      error_message = "Set exactly one of os_image_file_id (compressed/iso image) or os_image_import_from (uncompressed import image)."
    }
  }

  # OVMF (UEFI) needs an EFI vars disk or the boot entries are lost on every power cycle.
  dynamic "efi_disk" {
    for_each = var.bios == "ovmf" ? [1] : []
    content {
      datastore_id = var.disk_datastore_id
      type         = "4m"
      # Secure Boot is out of scope; leave keys unenrolled as the Talos guide advises.
      pre_enrolled_keys = false
    }
  }

  cpu {
    cores = var.cpu_cores
    type  = var.cpu_type
  }

  memory {
    dedicated = var.memory_dedicated_mb
    # 0 disables the balloon device. Talos cannot use ballooned memory.
    floating = var.memory_floating_mb
  }

  disk {
    datastore_id = var.disk_datastore_id
    interface    = var.disk_interface
    # Exactly one of these is non-null (enforced above). `file_id` is the path for
    # compressed images (e.g. the Image Factory `.raw.zst`); `import_from` for plain
    # `import`-type images.
    file_id     = var.os_image_file_id
    import_from = var.os_image_import_from
    file_format = var.disk_file_format
    size        = var.disk_size_gb
    discard     = var.disk_discard
    ssd         = var.disk_ssd
  }

  # Optional second disk (see var.data_disk).
  dynamic "disk" {
    for_each = var.data_disk == null ? [] : [var.data_disk]
    content {
      datastore_id = coalesce(disk.value.datastore_id, var.disk_datastore_id)
      interface    = disk.value.interface
      size         = disk.value.size_gb
      # Inherited from the boot disk so the data disk stays on the same datastore with
      # the same format/SSD/TRIM behaviour (docs/decisions.md §3.2).
      file_format = var.disk_file_format
      discard     = var.disk_discard
      ssd         = var.disk_ssd
    }
  }

  network_device {
    bridge      = var.bridge
    model       = var.network_model
    firewall    = var.network_firewall
    vlan_id     = var.vlan_id
    mac_address = var.mac_address
  }

  # Optional second NIC (Proxmox net1) on an untagged bridge, e.g. the storage link. No ip_config
  # block for it, so the NoCloud network-config never mentions it and Talos machine config owns
  # its address. No MAC: Proxmox generates one.
  dynamic "network_device" {
    for_each = var.storage_network_device == null ? [] : [var.storage_network_device]
    content {
      bridge   = network_device.value.bridge
      model    = var.network_model
      firewall = network_device.value.firewall
      mtu      = network_device.value.mtu
    }
  }

  # Always present: the NoCloud cloud-init drive is how the nocloud image is seeded
  # (network-config, and optionally user-data = machine config).
  initialization {
    datastore_id = var.cloud_init_datastore_id
    interface    = var.cloud_init_interface

    dynamic "ip_config" {
      for_each = var.ip_address != null ? [1] : []
      content {
        ipv4 {
          address = var.ip_address
          gateway = var.ip_gateway
        }
      }
    }

    # OpenTofu delivers machine config ONLY when explicitly asked to (see the variable).
    user_data_file_id = var.machine_config_delivery == "cloud-init-snippet" ? var.machine_config_snippet_id : null
  }

  agent {
    enabled = var.qemu_guest_agent_enabled
    timeout = var.qemu_guest_agent_timeout
  }

  dynamic "serial_device" {
    for_each = var.serial_console ? [1] : []
    content {}
  }

  operating_system {
    type = var.os_type
  }
}

# A warning (not an error) if the caller asked for cloud-init delivery but gave no snippet.
check "machine_config_delivery_consistency" {
  assert {
    condition     = var.machine_config_delivery != "cloud-init-snippet" || var.machine_config_snippet_id != null
    error_message = "machine_config_delivery = \"cloud-init-snippet\" requires machine_config_snippet_id."
  }
}
