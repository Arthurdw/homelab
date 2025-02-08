variable "proxmox" {
  type = object({
    name    = string
    storage = string
  })
}

variable "image" {
  type = object({
    version = string
    arch    = string
  })
}
