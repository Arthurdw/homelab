# module "talos" {
#   source = "./talos"
#
#   providers = {
#     proxmox = proxmox
#   }
#
#   proxmox = var.proxmox
#
#   cluster = {
#     gateway = "10.10.0.1"
#   }
#
#   image = {
#     version = "v1.9.3"
#     arch    = "amd64"
#   }
# }
