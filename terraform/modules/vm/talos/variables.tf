variable "proxmox" {
  type = object({
    name    = string
    storage = string
  })
}

variable "cluster" {
  type = object({
    gateway = string
  })
}

variable "image" {
  type = object({
    version = string
    arch    = string
  })
}
