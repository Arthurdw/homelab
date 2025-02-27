variable "proxmox" {
  type = object({
    name    = string
    storage = string
  })
}
