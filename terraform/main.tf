module "dns" {
  source = "./modules/dns"

  providers = {
    cloudflare = cloudflare
  }
}

module "vm" {
  source = "./modules/vm"

  providers = {
    proxmox = proxmox
  }
}
