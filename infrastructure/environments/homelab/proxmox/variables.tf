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
  description = "IPv4 address of the worker node. Production: within 10.20.0.11–29 (docs/decisions.md §2.1). Lab: 10.99.100.x (§2.4)."
  type        = string
  default     = "10.20.0.12"
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
  description = "Proxmox VMID for the worker VM. TODO(GATE 4): confirm at cutover."
  type        = number
  default     = 111
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
    Talos Image Factory schematic id. The default is the official vanilla schematic
    (customization: {}), which does NOT include the qemu-guest-agent extension. Build a
    new schematic at https://factory.talos.dev to add extensions, then pass its id here.
    The URL built from this id was verified (curl -sI) for the pinned Talos version.
  EOT
  type        = string
  default     = "376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba"
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
  description = "Enable the QEMU guest agent on the nodes. Only valid with an image that includes the siderolabs/qemu-guest-agent extension (see the module README). TODO(GATE 4)."
  type        = bool
  default     = false
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
  description = "Status of a machine-config snippet (e.g. local:snippets/talos-cp-1.yaml). Required only when talos_machine_config_delivery = \"cloud-init-snippet\"."
  type        = string
  default     = null
}
