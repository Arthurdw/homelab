# talos-vm — one Talos Linux VM on Proxmox VE.
#
# Every environment-specific value (addressing, bridge, VLAN, datastore, image) is an
# input so the same module provisions production and lab. What is NOT here is the
# Talos machine configuration: by decision (docs/architecture.md §7) Talos tooling
# owns machine config and bootstrap, not OpenTofu — see `machine_config_delivery`.

# ---------------------------------------------------------------------------
# Identity
# ---------------------------------------------------------------------------

variable "name" {
  description = "VM name / Talos hostname (must be a valid DNS name)."
  type        = string
}

variable "vm_id" {
  description = "Proxmox VM identifier (VMID)."
  type        = number
}

variable "node_name" {
  description = "Proxmox VE node to place the VM on (the PVE node name, e.g. the host hostname)."
  type        = string
}

variable "description" {
  description = "Proxmox VM description (shown in the UI; good place to note the owning root)."
  type        = string
  default     = "Talos Linux node — managed by OpenTofu (infrastructure/environments/homelab/proxmox)."
}

variable "tags" {
  description = "Proxmox tags. Proxmox sorts tags, so an unsorted list reports drift; keep it sorted."
  type        = list(string)
  default     = ["homelab", "kubernetes", "talos"]
}

# ---------------------------------------------------------------------------
# Compute
# ---------------------------------------------------------------------------

variable "cpu_cores" {
  description = "Number of vCPUs."
  type        = number

  validation {
    condition     = var.cpu_cores >= 1
    error_message = "cpu_cores must be at least 1."
  }
}

variable "cpu_type" {
  description = <<-EOT
    Emulated CPU type. `x86-64-v2-AES` is the smallest type that satisfies Talos's
    x86-64-v2 requirement and keeps live migration possible. Use `host` for maximum
    performance (Talos recommends it) and for nested virtualization (Kata Containers),
    accepting that `host` blocks live migration.
  EOT
  type        = string
  default     = "x86-64-v2-AES"
}

variable "memory_dedicated_mb" {
  description = "Dedicated guest RAM in MiB."
  type        = number

  validation {
    condition     = var.memory_dedicated_mb >= 2048
    error_message = "Talos requires at least 2048 MiB of RAM."
  }
}

variable "memory_floating_mb" {
  description = <<-EOT
    Ballooning ceiling in MiB. Keep 0 (the default): Talos does not support memory
    hotplug, and ballooning stops Talos from seeing all of its RAM. This variable
    exists only to make that decision explicit.
  EOT
  type        = number
  default     = 0

  validation {
    condition     = var.memory_floating_mb == 0
    error_message = "Leave memory_floating_mb = 0: Talos does not support memory ballooning."
  }
}

# ---------------------------------------------------------------------------
# Firmware
# ---------------------------------------------------------------------------

variable "bios" {
  description = "Firmware: `ovmf` (UEFI, Talos-recommended; adds a 4 MiB EFI disk) or `seabios`."
  type        = string
  default     = "ovmf"

  validation {
    condition     = contains(["ovmf", "seabios"], var.bios)
    error_message = "bios must be \"ovmf\" or \"seabios\"."
  }
}

variable "machine_type" {
  description = "QEMU machine type. `q35` is Talos-recommended; `pc` (i440fx) is the Proxmox default. `q35,viommu=...` is also accepted."
  type        = string
  default     = "q35"

  validation {
    condition     = can(regex("^(pc|q35)", var.machine_type))
    error_message = "machine_type must start with \"pc\" or \"q35\"."
  }
}

variable "os_type" {
  description = "Proxmox guest OS type hint."
  type        = string
  default     = "l26"
}

# ---------------------------------------------------------------------------
# Boot disk
# ---------------------------------------------------------------------------

variable "disk_size_gb" {
  description = "Boot disk size in GiB."
  type        = number

  validation {
    condition     = var.disk_size_gb >= 10
    error_message = "disk_size_gb must be at least 10 (Talos needs room for the OS + ephemeral partition)."
  }
}

variable "disk_datastore_id" {
  description = "Datastore for the boot disk. Decided: `local-lvm` (the host SSD), never the NAS — docs/decisions.md §3.2."
  type        = string
  default     = "local-lvm"
}

variable "disk_interface" {
  description = "Disk bus/interface, e.g. `scsi0` or `virtio0`. Use scsi (not `virtio-scsi-single`, which hangs Talos bootstrap)."
  type        = string
  default     = "scsi0"
}

variable "disk_file_format" {
  description = "Image format of the boot disk (`raw` or `qcow2`). Raw is preferred for the Talos image."
  type        = string
  default     = "raw"

  validation {
    condition     = contains(["raw", "qcow2", "vmdk"], var.disk_file_format)
    error_message = "disk_file_format must be raw, qcow2 or vmdk."
  }
}

variable "disk_discard" {
  description = "Pass TRIM/discard to the SSD (on/ignore). On for the host SSD."
  type        = string
  default     = "on"

  validation {
    condition     = contains(["on", "ignore"], var.disk_discard)
    error_message = "disk_discard must be \"on\" or \"ignore\"."
  }
}

variable "disk_ssd" {
  description = "Advertise SSD emulation to the guest (true on the host SSD)."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# Data disk  (optional — additional to the boot disk)
# ---------------------------------------------------------------------------

variable "data_disk" {
  description = <<-EOT
    Optional ADDITIONAL disk (a second `disk` block), separate from the boot disk.
    Null (the default) means the VM has only its boot disk.

    This exists because Talos has nowhere on the boot disk to put a
    `UserVolumeConfig`: the `EPHEMERAL` partition spans the system disk and consumes
    its free space, so a user volume can only be provisioned on a non-system disk. A
    dedicated disk also isolates an application's I/O from the OS disk. The worker
    gets one to back the node-local `local-path` StorageClass
    (docs/decisions.md §3.4 and §4.3; kubernetes/infrastructure/local-path).

    `interface` must not collide with `disk_interface` (the boot disk's bus slot).
    Everything not set here is inherited from the boot disk (`disk_datastore_id`,
    `disk_file_format`, `disk_discard`, `disk_ssd`), so the data disk stays on the
    same datastore with the same SSD/TRIM behaviour.
  EOT
  type = object({
    size_gb      = number
    interface    = optional(string, "scsi1")
    datastore_id = optional(string)
  })
  default = null

  validation {
    condition     = var.data_disk == null || var.data_disk.size_gb >= 1
    error_message = "data_disk.size_gb must be at least 1 GiB."
  }

  validation {
    condition     = var.data_disk == null || var.data_disk.interface != var.disk_interface
    error_message = "data_disk.interface must differ from disk_interface (the boot disk's bus slot)."
  }

  validation {
    condition     = var.data_disk == null || var.data_disk.interface != var.cloud_init_interface
    error_message = "data_disk.interface must differ from cloud_init_interface (used by the NoCloud drive)."
  }

  validation {
    condition     = var.data_disk == null || can(regex("^(scsi|virtio|sata|ide)[0-9]+$", var.data_disk.interface))
    error_message = "data_disk.interface must be a bus slot such as scsi1, virtio1, sata1 or ide1."
  }
}

# ---------------------------------------------------------------------------
# OS image source  (exactly one of file_id / import_from)
# ---------------------------------------------------------------------------

variable "os_image_file_id" {
  description = <<-EOT
    ID of a *compressed / iso* image to import as the boot disk, e.g.
    `local:iso/talos-v1.14.4-nocloud-amd64.img`. Take it from
    `proxmox_download_file.<x>.id`. Use this for the Talos Image Factory `.raw.zst`
    artifact (compressed images cannot use `os_image_import_from`).
  EOT
  type        = string
  default     = null
}

variable "os_image_import_from" {
  description = <<-EOT
    ID of an *uncompressed* image of `import` content type, e.g.
    `local:import/talos-nocloud-amd64.raw`. Alternative to `os_image_file_id`; the
    module accepts exactly one of the two.
  EOT
  type        = string
  default     = null
}

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------

variable "bridge" {
  description = "Proxmox Linux bridge to attach the NIC to (e.g. `vmbr0`). Host-specific — verify at cutover."
  type        = string
}

variable "vlan_id" {
  description = "802.1Q VLAN tag for the NIC. Set null on a flat/lab bridge. K8s VLAN is 20 in production (docs/decisions.md §2.1)."
  type        = number
  default     = null

  validation {
    condition     = var.vlan_id == null || (var.vlan_id >= 1 && var.vlan_id <= 4094)
    error_message = "vlan_id must be null or between 1 and 4094."
  }
}

variable "mac_address" {
  description = "Optional fixed MAC (deterministic addressing / DHCP reservation). Null lets Proxmox generate one."
  type        = string
  default     = null

  validation {
    condition     = var.mac_address == null || can(regex("^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$", var.mac_address))
    error_message = "mac_address must be null or a colon-separated MAC, e.g. BC:24:11:00:00:11."
  }
}

variable "network_model" {
  description = "NIC model. `virtio` is recommended by Talos."
  type        = string
  default     = "virtio"
}

variable "storage_network_device" {
  description = "Optional second NIC (Proxmox net1) on an untagged bridge such as the storage link: no VLAN, no MAC, no cloud-init ip_config. `mtu` should match the bridge. Null leaves the VM with one NIC."
  type = object({
    bridge   = string
    mtu      = optional(number, 1500)
    firewall = optional(bool, false)
  })
  default = null

  validation {
    condition     = var.storage_network_device == null || try(var.storage_network_device.mtu >= 576 && var.storage_network_device.mtu <= 65520, false)
    error_message = "storage_network_device.mtu must be between 576 and 65520."
  }
}

variable "hostpci" {
  description = "PCI devices passed through to the VM (Proxmox hostpci0, hostpci1, ... in list order), each by the name of a Proxmox cluster resource mapping. A raw host address would need root@pam, which the API token is not. Proxmox starts the VM only while no other running VM holds the device, and the VM can no longer live-migrate. `pcie` needs the q35 machine type."
  type = list(object({
    mapping = string
    pcie    = optional(bool, true)
    rombar  = optional(bool, true)
  }))
  default = []

  validation {
    condition     = length(var.hostpci) <= 16
    error_message = "Proxmox supports at most 16 hostpci devices."
  }
}

variable "network_firewall" {
  description = "Enable the Proxmox firewall on this NIC. Off by default; the management segment stays private (docs/decisions.md §5.2)."
  type        = bool
  default     = false
}

variable "ip_address" {
  description = <<-EOT
    Static IPv4 address in CIDR form (e.g. `10.20.0.11/24`) delivered through Proxmox's
    cloud-init `network-config`. Talos's `nocloud` platform reads that file
    (docs.siderolabs.com/talos > cloud-platforms/nocloud), which is how the node gets a
    stable address in maintenance mode. Null = DHCP.
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.ip_address == null || can(cidrhost(var.ip_address, 0))
    error_message = "ip_address must be null or an IPv4 CIDR such as 10.20.0.11/24."
  }
}

variable "ip_gateway" {
  description = "Default gateway for ip_address. Null when DHCP or on an unrouted link."
  type        = string
  default     = null

  validation {
    condition     = var.ip_gateway == null || can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}$", var.ip_gateway))
    error_message = "ip_gateway must be null or a dotted-quad IPv4 address."
  }
}

# ---------------------------------------------------------------------------
# Cloud-init disk
# ---------------------------------------------------------------------------

variable "cloud_init_datastore_id" {
  description = "Datastore for the generated cloud-init (NoCloud) disk. This drive is how the nocloud image receives network-config."
  type        = string
  default     = "local-lvm"
}

variable "cloud_init_interface" {
  description = "Interface for the cloud-init drive. Default `ide2`; must not collide with disk_interface."
  type        = string
  default     = "ide2"
}

# ---------------------------------------------------------------------------
# QEMU guest agent
# ---------------------------------------------------------------------------

variable "qemu_guest_agent_enabled" {
  description = <<-EOT
    Enable the Proxmox QEMU guest agent.

    Leave false unless the Talos image includes the `siderolabs/qemu-guest-agent`
    system extension (the repo schematic, talos/schematic.yaml, does): enabling the
    agent without it makes Proxmox wait (and time out) for an agent that never
    appears. See the module README.
  EOT
  type        = bool
  default     = false
}

variable "qemu_guest_agent_timeout" {
  description = "How long Proxmox waits for the guest agent (only meaningful when the agent is enabled)."
  type        = string
  default     = "15m"
}

# ---------------------------------------------------------------------------
# Machine-config delivery
# ---------------------------------------------------------------------------

variable "machine_config_delivery" {
  description = <<-EOT
    How the Talos machine configuration reaches the node.

      "talosctl" (default)  — the VM boots the nocloud image in maintenance mode and
                              `talosctl apply-config` delivers the config. This is the
                              only mode consistent with docs/architecture.md §7
                              (Talos tooling owns machine config + bootstrap).
      "cloud-init-snippet"  — inject a machine-config snippet as cloud-init user-data
                              (the manual Proxmox/nocloud flow). Lab/dev only: it makes
                              OpenTofu deliver Talos config, which violates §7.
  EOT
  type        = string
  default     = "talosctl"

  validation {
    condition     = contains(["talosctl", "cloud-init-snippet"], var.machine_config_delivery)
    error_message = "machine_config_delivery must be \"talosctl\" or \"cloud-init-snippet\"."
  }
}

variable "machine_config_snippet_id" {
  description = "ID of the snippet holding the machine config (e.g. `local:snippets/talos-cp-1.yaml`). Required when machine_config_delivery = \"cloud-init-snippet\"."
  type        = string
  default     = null
}

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

variable "on_boot" {
  description = "Start the VM when the Proxmox host boots."
  type        = bool
  default     = true
}

variable "started" {
  description = "Start the VM immediately after creation."
  type        = bool
  default     = true
}

variable "stop_on_destroy" {
  description = "Stop (not shut down) the VM on destroy. Required with the guest agent disabled, otherwise destroy can hang."
  type        = bool
  default     = true
}

variable "serial_console" {
  description = "Attach a serial device so early boot logs are visible in the Proxmox console (recommended by the Talos Proxmox guide)."
  type        = bool
  default     = true
}
