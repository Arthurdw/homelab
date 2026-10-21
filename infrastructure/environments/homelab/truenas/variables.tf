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
