variable "truenas_endpoint" {
  description = "TrueNAS API endpoint, e.g. https://<host>"
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
