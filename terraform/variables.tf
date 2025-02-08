# Cloudflare:

variable "cloudflare_api_token" {
  description = "The Cloudflare API token to use for authentication"
  type        = string
}

# Proxmox:

variable "proxmox_api_token" {
  description = "The Proxmox API token to use for authentication"
  type        = string
}

variable "proxmox_api_token_user" {
  description = "The proxmox user to use for authentication"
  type        = string
  default     = "root"
}
