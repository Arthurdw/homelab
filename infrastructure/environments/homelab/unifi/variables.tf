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
