terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "5.0.0"
    }

    proxmox = {
      source  = "bpg/proxmox"
      version = "0.70.1"
    }

    talos = {
      source  = "siderolabs/talos"
      version = "0.7.1"
    }
  }
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

# TODO: migrate static values to variables
provider "proxmox" {
  endpoint  = var.proxmox.host
  api_token = "${var.proxmox.api.user}@pam!${var.proxmox.api.name}=${var.proxmox.api.token}"
  insecure  = true # Self signed certificate

  ssh {
    agent       = true
    username    = var.proxmox.api.user
    private_key = file("~/.ssh/id_ed25519")
  }
}
