module "talos" {
  source = "./talos"

  providers = {
    proxmox = proxmox
  }

  proxmox = var.proxmox

  image = {
    version = "v1.9.3"
    arch    = "amd64"
  }
}
