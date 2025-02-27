# Cloudflare:

variable "cloudflare_api_token" {
  description = "The Cloudflare API token to use for authentication"
  type        = string
}

# Proxmox:

variable "proxmox" {
  type = object({
    name    = string
    host    = string
    storage = string
    api = object({
      user  = string
      name  = string
      token = string
    })
  })

}
