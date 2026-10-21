variable "truenas_endpoint" {
  description = "TrueNAS JSON-RPC endpoint, e.g. wss://<host>/api/current (provider 1.5.14 requires TrueNAS >= 25.04). Or set TRUENAS_ENDPOINT."
  type        = string
}

variable "truenas_api_key" {
  description = "TrueNAS API key. Prefer TF_VAR_truenas_api_key (env) over a tfvars file."
  type        = string
  sensitive   = true
}

variable "truenas_insecure" {
  description = "Skip TLS verification (only for self-signed certs on a trusted network)"
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# Kubernetes NFS export (docs/decisions.md §4.1, §4.2)
# -----------------------------------------------------------------------------

variable "k8s_dataset_name" {
  description = "Dataset for the csi-driver-nfs export. The pool name `main` is a contract with kubernetes/infrastructure/storage/release.yaml (share /mnt/main/k8s). TODO(GATE 4): the pool is preserved or rebuilt at cutover (decisions.md §1.4); the name must stay `main` or both sides move together."
  type        = string
  default     = "main/k8s"
}

variable "k8s_nfs_allowed_networks" {
  description = "CIDRs allowed to mount the k8s export. Defaults to the storage link (decisions.md §2). TODO(GATE 4): the Talos nodes live on 10.20.0.0/24, not on the 10.99.0.0/30 link (Proxmox .1, NAS .2). Decide how node traffic reaches 10.99.0.2 (Proxmox routing/NAT shows source 10.99.0.1, or a node NIC on the link) and set this to match. Never 0.0.0.0/0."
  type        = list(string)
  default     = ["10.99.0.0/30"]

  validation {
    condition     = length(var.k8s_nfs_allowed_networks) > 0 && alltrue([for n in var.k8s_nfs_allowed_networks : can(cidrhost(n, 0)) && !endswith(n, "/0")])
    error_message = "Give at least one valid, non-/0 CIDR; an unrestricted export is not allowed."
  }
}

variable "k8s_nfs_maproot_user" {
  description = "User that client root maps to (no_root_squash when `root`). csi-driver-nfs needs root writes."
  type        = string
  default     = "root"
}

variable "k8s_nfs_maproot_group" {
  description = "Group that client root maps to. TODO(GATE 4): confirm the group name on the upgraded NAS (`root` on SCALE; `wheel` on CORE)."
  type        = string
  default     = "root"
}

# -----------------------------------------------------------------------------
# Household backups (docs/decisions.md §5.9; docs/runbooks/household-backups.md)
# -----------------------------------------------------------------------------

variable "timemachine_jolien_quota_gib" {
  description = "Quota for jolien's Time Machine dataset, in GiB. No default: it depends on the Mac's disk. Twice the Mac's used-plus-free disk size is the usual rule. TODO(owner): ask jolien for the disk size."
  type        = number

  validation {
    condition     = var.timemachine_jolien_quota_gib >= 1 && floor(var.timemachine_jolien_quota_gib) == var.timemachine_jolien_quota_gib
    error_message = "Give a whole number of GiB, at least 1. A quota of 0 (unlimited) is not allowed."
  }
}

variable "timemachine_jolien_user" {
  description = "Existing TrueNAS local user (SMB enabled) that is the only account allowed on jolien's Time Machine share. The owner creates it in the UI; this root only looks it up."
  type        = string
  default     = "jolien"
}

variable "timemachine_jolien_share_name" {
  description = "SMB share name Time Machine connects to (smb://<nas>/<name>)."
  type        = string
  default     = "timemachine-jolien"
}

# -----------------------------------------------------------------------------
# Storage link to poseidon (docs/decisions.md §2.2; docs/runbooks/host-network-bootstrap.md)
# -----------------------------------------------------------------------------

variable "storage_link_name" {
  description = "Name of the single-port failover bond created over the 10 GbE port (TrueNAS names bonds bondN)."
  type        = string
  default     = "bond1"
}

variable "storage_link_interface" {
  description = "Name of the NAS's 10 GbE physical port, as TrueNAS lists it (Network > Interfaces, or `interface.query`). TODO(GATE 4): not known until the NAS is looked at; it is NOT the management port. No default on purpose, so a wrong guess can never touch the management interface."
  type        = string

  validation {
    condition     = length(var.storage_link_interface) > 0
    error_message = "Name the 10 GbE port; there is no default."
  }
}

variable "storage_link_address" {
  description = "The NAS's address on the storage link (poseidon's vmbr1 is 10.99.0.1/30). Provisional with the rest of the storage subnet, decisions.md §2.2; keep it inside k8s_nfs_allowed_networks."
  type        = string
  default     = "10.99.0.2"

  validation {
    condition     = can(cidrhost("${var.storage_link_address}/32", 0))
    error_message = "Give a plain IPv4 address, not a CIDR."
  }
}

variable "storage_link_prefix_length" {
  description = "Prefix length of the storage link subnet (a /30 point to point link)."
  type        = number
  default     = 30

  validation {
    condition     = var.storage_link_prefix_length >= 8 && var.storage_link_prefix_length <= 30
    error_message = "Use a prefix length between 8 and 30."
  }
}

variable "storage_link_mtu" {
  description = "MTU of the storage port. Jumbo frames need both ends, the switch-less link and the Proxmox side (storage_link_mtu there) to match."
  type        = number
  default     = 9000

  validation {
    condition     = var.storage_link_mtu >= 1280 && var.storage_link_mtu <= 9216
    error_message = "MTU must be between 1280 and 9216."
  }
}
