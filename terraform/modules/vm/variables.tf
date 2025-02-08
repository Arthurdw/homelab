variable "proxmox" {
  type = object({
    name    = string
    storage = string
  })
  default = {
    name    = "proxmox"
    storage = "hercules"
  }
}
