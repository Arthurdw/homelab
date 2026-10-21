variable "unifi_api_url" {
  description = "UniFi controller URL, e.g. https://<host>"
  type        = string
}

variable "unifi_api_key" {
  description = "UniFi API key. Prefer TF_VAR_unifi_api_key (env). Full-access key — see docs/secrets-and-state.md §4."
  type        = string
  sensitive   = true
}

variable "unifi_site" {
  description = "UniFi site name"
  type        = string
  default     = "default"
}

variable "unifi_allow_insecure" {
  description = "Skip TLS verification (only for a self-signed cert on a trusted network)"
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# Kubernetes VLAN (docs/decisions.md §2)
# -----------------------------------------------------------------------------

variable "k8s_dhcp" {
  description = "DHCP pool on hl-k8s as host offsets in 10.20.0.0/24. Nodes are statically addressed (.11-.29) and MetalLB owns .100-.199; a precondition rejects overlaps. TODO(GATE 4): the decisions do not fix a DHCP range. .200-.249 is a proposal (for maintenance-mode/rescue boots); set enabled = false if every guest on the VLAN is static."
  type = object({
    enabled = bool
    first   = number
    last    = number
  })
  default = {
    enabled = true
    first   = 200
    last    = 249
  }

  validation {
    condition     = var.k8s_dhcp.first >= 2 && var.k8s_dhcp.last <= 254 && var.k8s_dhcp.first <= var.k8s_dhcp.last
    error_message = "k8s_dhcp must be a range within .2-.254 with first <= last."
  }
}

# -----------------------------------------------------------------------------
# Host fixed IPs on the server network (host-reservations.tf)
# -----------------------------------------------------------------------------

variable "server_network_name" {
  description = "Name of the EXISTING server network (VLAN 4, 10.10.0.0/16) on the controller. Read with a data source only, never managed. TODO(GATE 4): confirm the real name from the controller export."
  type        = string
  default     = "server"
}

variable "host_reservations" {
  description = "MAC per host for the fixed-IP reservations, keyed by host name (poseidon, hercules-nas). The IPs come from the plan (locals in host-reservations.tf). MACs are private: set them in the gitignored terraform.tfvars only. Only the clients listed here are touched (taken over with allow_existing); an empty map manages nothing."
  type = map(object({
    mac = string
  }))
  default = {}

  validation {
    condition     = alltrue([for h in keys(var.host_reservations) : contains(["poseidon", "hercules-nas"], h)])
    error_message = "host_reservations keys must be poseidon and/or hercules-nas (the hosts with a planned IP)."
  }

  validation {
    condition     = alltrue([for r in values(var.host_reservations) : can(regex("^([0-9a-f]{2}:){5}[0-9a-f]{2}$", r.mac))])
    error_message = "Each MAC must be lowercase, colon-separated (aa:bb:cc:dd:ee:ff), as the controller stores it."
  }

  validation {
    condition     = alltrue([for r in values(var.host_reservations) : r.mac != "00:00:00:00:00:00"])
    error_message = "A MAC is still the 00:00:00:00:00:00 placeholder from terraform.tfvars.example."
  }

  validation {
    condition     = length(distinct([for r in values(var.host_reservations) : r.mac])) == length(var.host_reservations)
    error_message = "Two hosts share a MAC."
  }
}
