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
