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
