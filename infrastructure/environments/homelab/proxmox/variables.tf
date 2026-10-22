variable "proxmox_endpoint" {
  description = "Proxmox VE API endpoint, e.g. https://<host>:8006/"
  type        = string
}

variable "proxmox_insecure" {
  description = "Skip TLS verification (only for self-signed certs on a trusted network)"
  type        = bool
  default     = false
}

variable "proxmox_ssh_username" {
  description = "SSH user on the Proxmox host (used for file uploads)"
  type        = string
  default     = "root"
}

# ---------------------------------------------------------------------------
# Proxmox host
# ---------------------------------------------------------------------------

variable "proxmox_node_name" {
  description = "Proxmox VE node the guests are placed on (the PVE node name, normally the host hostname)."
  type        = string
  # No default: the node name is host-specific and only known at cutover. TODO(GATE 4).
}

variable "proxmox_host_memory_mb" {
  description = "Usable RAM of the Proxmox host in MiB. i5-7400 host has 46 GiB (docs/hardware.md). Used only for the capacity check."
  type        = number
  default     = 47104
}

variable "proxmox_host_memory_reserve_mb" {
  description = "RAM in MiB kept for the hypervisor + at least one non-Kubernetes VM. The capacity check fails if the Talos guests would eat into this reserve."
  type        = number
  default     = 8192
}

# ---------------------------------------------------------------------------
# Networking (environment-specific — production here, lab overrides in tfvars)
# ---------------------------------------------------------------------------

variable "vm_bridge" {
  description = "Proxmox bridge for the node NICs (e.g. vmbr0). Host-specific; confirm bridge + VLAN-awareness at cutover."
  type        = string
  # No default: host networking is only settled at cutover. TODO(GATE 4).
}

variable "k8s_vlan_id" {
  description = "VLAN tag for the Kubernetes segment. Production 20 (docs/decisions.md §2.1); set null on a flat lab bridge."
  type        = number
  default     = 20

  validation {
    condition     = var.k8s_vlan_id == null || (var.k8s_vlan_id >= 1 && var.k8s_vlan_id <= 4094)
    error_message = "k8s_vlan_id must be null or between 1 and 4094."
  }
}

variable "k8s_gateway" {
  description = "Gateway for the Kubernetes segment. Production 10.20.0.1 (docs/decisions.md §2.1)."
  type        = string
  default     = "10.20.0.1"
}

variable "k8s_prefix_length" {
  description = "Prefix length of the Kubernetes segment (24 in production and lab)."
  type        = number
  default     = 24
}

variable "talos_cp_ipv4" {
  description = "IPv4 address of the control-plane node. Production: within 10.20.0.11–29 (docs/decisions.md §2.1). Lab: 10.99.100.x (§2.4)."
  type        = string
  default     = "10.20.0.11"
}

variable "talos_wk_ipv4" {
  description = "IPv4 address of the first worker, talos-wk-1 (the GPU worker). Production: within 10.20.0.11–29 (docs/decisions.md §2.1). Lab: 10.99.100.x (§2.4)."
  type        = string
  default     = "10.20.0.12"
}

variable "talos_wk2_ipv4" {
  description = "IPv4 address of the second worker, talos-wk-2 (no GPU). Production: within 10.20.0.11–29 (docs/decisions.md §2.1). Lab: 10.99.100.x (§2.4). TODO(GATE 4): confirm at cutover."
  type        = string
  default     = "10.20.0.13"
}

# ---------------------------------------------------------------------------
# Talos topology (VMIDs)
# ---------------------------------------------------------------------------

variable "talos_cp_vmid" {
  description = "Proxmox VMID for the control-plane VM. TODO(GATE 4): confirm at cutover; the temporary live VM uses 100."
  type        = number
  default     = 110
}

variable "talos_wk_vmid" {
  description = "Proxmox VMID for the talos-wk-1 VM. TODO(GATE 4): confirm at cutover."
  type        = number
  default     = 111
}

variable "talos_wk2_vmid" {
  description = "Proxmox VMID for the talos-wk-2 VM. TODO(GATE 4): confirm at cutover."
  type        = number
  default     = 112
}

variable "talos_macs" {
  description = "Optional fixed MAC addresses keyed by node name (for deterministic addressing / DHCP reservations). Empty = Proxmox-generated. TODO(GATE 4): assign when UniFi reservations are created."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# Storage
# ---------------------------------------------------------------------------

variable "talos_disk_datastore_id" {
  description = "Datastore for the VM boot disks. Decided: local-lvm (host SSD), never the NAS (docs/decisions.md §3.2)."
  type        = string
  default     = "local-lvm"
}

variable "talos_image_datastore_id" {
  description = "Datastore for the downloaded Talos source image. Needs 'iso' content enabled. TODO(GATE 4): confirm on the rebuilt host."
  type        = string
  default     = "local"
}

# ---------------------------------------------------------------------------
# Talos image (Image Factory artifact)
# ---------------------------------------------------------------------------

variable "talos_image_schematic_id" {
  description = <<-EOT
    Talos Image Factory schematic id. The default is talos/schematic.yaml (siderolabs/kata-containers,
    siderolabs/qemu-guest-agent, siderolabs/nonfree-kmod-nvidia-production and
    siderolabs/nvidia-container-toolkit-production). To change extensions edit that file, POST it to
    https://factory.talos.dev/schematics and pass the new id here and as TALOS_SCHEMATIC.
    The URL built from this id was verified (curl -sI) for the pinned Talos version.
  EOT
  type        = string
  default     = "a31c606a63e512b77145a19a7441828049b1567936ab8335f24bf8d28e831736"
}

variable "talos_image_platform" {
  description = "Image Factory platform. 'nocloud' is required for Proxmox (Proxmox provides a NoCloud cloud-init drive)."
  type        = string
  default     = "nocloud"
}

variable "talos_image_compression" {
  description = "Compression of the downloaded artifact (gz/lzo/zst/bz2). The factory serves the raw disk as .raw.zst."
  type        = string
  default     = "zst"

  validation {
    condition     = contains(["gz", "lzo", "zst", "bz2"], var.talos_image_compression)
    error_message = "talos_image_compression must be one of gz, lzo, zst, bz2."
  }
}

variable "talos_vm_tags" {
  description = "Base Proxmox tags applied to every Talos VM (the node role is appended per VM). Keep sorted."
  type        = list(string)
  default     = ["homelab", "kubernetes", "talos"]
}

# ---------------------------------------------------------------------------
# Talos node behaviour
# ---------------------------------------------------------------------------

variable "talos_qemu_guest_agent_enabled" {
  description = "Enable the QEMU guest agent on the nodes. The default schematic includes the extension, whose Talos service waits for the agent channel, so this defaults to true; set false only for an image without it. TODO(GATE 4)."
  type        = bool
  default     = true
}

variable "talos_cpu_type" {
  description = "Proxmox CPU type of the Talos VMs. `host` is required for Kata Containers (nested virtualization; the PVE host needs nested KVM enabled) and blocks live migration, which this single-host setup does not use."
  type        = string
  default     = "host"
}

variable "talos_machine_config_delivery" {
  description = "How Talos machine config reaches the nodes. 'talosctl' keeps the docs/architecture.md §7 boundary (Talos tooling owns config). 'cloud-init-snippet' is lab/dev only."
  type        = string
  default     = "talosctl"

  validation {
    condition     = contains(["talosctl", "cloud-init-snippet"], var.talos_machine_config_delivery)
    error_message = "talos_machine_config_delivery must be \"talosctl\" or \"cloud-init-snippet\"."
  }
}

variable "talos_machine_config_snippet_id" {
  description = "ID of a machine-config snippet (e.g. local:snippets/talos-cp-1.yaml). Required only when talos_machine_config_delivery = \"cloud-init-snippet\"."
  type        = string
  default     = null
}

# ---------------------------------------------------------------------------
# Sizing and power state (defaults are the production topology, docs/decisions.md §3.1;
# only the L1 fixture overrides them, so the guests fit a 4 GiB nested Proxmox)
# ---------------------------------------------------------------------------

variable "talos_cp_memory_mb" {
  description = "Control-plane VM RAM in MiB."
  type        = number
  default     = 4096
}

variable "talos_cp_disk_gb" {
  description = "Control-plane system disk in GiB."
  type        = number
  default     = 20
}

variable "talos_wk_cpu_cores" {
  description = "Worker VM vCPU cores."
  type        = number
  default     = 3
}

variable "talos_wk_memory_mb" {
  description = "Worker VM RAM in MiB."
  type        = number
  default     = 16384
}

variable "talos_wk_disk_gb" {
  description = "Worker system disk in GiB."
  type        = number
  default     = 80
}

variable "talos_wk_data_disk_gb" {
  description = "Worker data disk (Talos user volume for local-path) in GiB; null for none."
  type        = number
  default     = 100
  nullable    = true
}

variable "talos_wk2_cpu_cores" {
  description = "talos-wk-2 VM vCPU cores."
  type        = number
  default     = 3
}

variable "talos_wk2_memory_mb" {
  description = "talos-wk-2 VM RAM in MiB. Less than talos-wk-1, so the three guests fit beside the host reserve (docs/hardware.md)."
  type        = number
  default     = 12288
}

variable "talos_wk2_disk_gb" {
  description = "talos-wk-2 system disk in GiB. Smaller than talos-wk-1's so all five disks (340 GiB) fit the 360 GiB local-lvm thin pool (docs/decisions.md §3.6)."
  type        = number
  default     = 40
}

variable "talos_wk2_data_disk_gb" {
  description = "talos-wk-2 data disk (Talos user volume for local-path) in GiB; null for none."
  type        = number
  default     = 100
  nullable    = true
}

variable "talos_vm_started" {
  description = "Whether the Talos VMs are started. Production: true. The L1 fixture creates them stopped (a 4 GiB nested Proxmox cannot run them)."
  type        = bool
  default     = true
}

variable "talos_vm_on_boot" {
  description = "Whether the Talos VMs start with the Proxmox host."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# Storage link (10 GbE, point-to-point to hercules-nas) — docs/decisions.md §2.2
# ---------------------------------------------------------------------------

variable "storage_link_bridge" {
  description = "Name of the Linux bridge that carries the 10 GbE storage link."
  type        = string
  default     = "vmbr1"
}

variable "storage_link_port" {
  description = "Physical NIC on the bridge: the fibre port. nic2 on poseidon (docs/hardware.md); nic1 is unused. Confirm the name on the host (`ip -br link`)."
  type        = string
  default     = "nic2"
}

variable "storage_link_address" {
  description = "Proxmox end of the storage link, in CIDR form. The /29 (decisions.md §2.2) holds poseidon .1, the NAS .2 (truenas root), talos-cp-1 .3, talos-wk-1 .4 and talos-wk-2 .5 (talos/patches/network-controlplane.yaml, node-talos-wk-*.yaml), so the nodes mount NFS directly over the link, unrouted. Must match k8s_nfs_allowed_networks of the truenas root."
  type        = string
  default     = "10.99.0.1/29"

  validation {
    condition     = can(cidrhost(var.storage_link_address, 0))
    error_message = "storage_link_address must be an IPv4 address in CIDR form, e.g. 10.99.0.1/29."
  }
}

variable "storage_link_mtu" {
  description = "MTU of the bridge. 9000 (jumbo) on the 10 GbE link; the NIC must already be at least this (see storage-link.tf)."
  type        = number
  default     = 9000

  validation {
    condition     = var.storage_link_mtu >= 1280 && var.storage_link_mtu <= 9216
    error_message = "storage_link_mtu must be between 1280 and 9216."
  }
}

variable "talos_storage_link_nic" {
  description = "Give each Talos VM a second NIC (net1) on storage_link_bridge, untagged, at storage_link_mtu, with no cloud-init address: Talos machine config sets 10.99.0.3/.4/.5 on it (decisions.md §2.2). Adding it to running VMs is an in-place hotplug. Set false for a lab or fixture without the link."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# GPU passthrough (gpu.tf) — the Tesla P4, docs/hardware.md
# ---------------------------------------------------------------------------

variable "gpu_passthrough" {
  description = <<-EOT
    The host GPU as a Proxmox cluster PCI resource mapping, and the Talos VM it is passed to.
    `pci_path` and `device_id` (vendor:device) come from `lspci -nn -D` on the host; `iommu_group` from
    /sys/bus/pci/devices/<pci_path>/iommu_group. `vm` is a key of local.talos_nodes, or null to keep the
    mapping without giving the card to a Talos VM (e.g. while another VM uses it). Null for no mapping
    at all (the L1 fixture has no GPU).
  EOT
  type = object({
    mapping_name = optional(string, "tesla-p4")
    pci_path     = string
    device_id    = string
    subsystem_id = optional(string)
    iommu_group  = optional(number)
    vm           = optional(string)
  })
  default = {
    pci_path    = "0000:01:00.0"
    device_id   = "10de:1bb3"
    iommu_group = 2
    vm          = "talos-wk-1"
  }

  validation {
    condition     = var.gpu_passthrough == null || can(regex("^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\\.[0-7]$", var.gpu_passthrough.pci_path))
    error_message = "gpu_passthrough.pci_path must be a full PCI address such as 0000:01:00.0."
  }

  validation {
    condition     = var.gpu_passthrough == null || can(regex("^[0-9a-f]{4}:[0-9a-f]{4}$", var.gpu_passthrough.device_id))
    error_message = "gpu_passthrough.device_id must be vendor:device such as 10de:1bb3."
  }
}
