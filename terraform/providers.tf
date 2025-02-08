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
  endpoint  = "https://10.10.1.1:8006"
  api_token = "${var.proxmox_api_token_user}@pam!terraform=${var.proxmox_api_token}"
  insecure  = true # Self signed certificate

  ssh {
    agent       = true
    username    = var.proxmox_api_token_user
    private_key = file("~/.ssh/id_ed25519")
  }
}
