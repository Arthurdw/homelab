provider "proxmox" {
  endpoint = var.proxmox_endpoint
  insecure = var.proxmox_insecure

  # Credentials are supplied via environment variables — NEVER committed:
  #   PROXMOX_VE_API_TOKEN="user@realm!tokenid=secret"
  #   (or PROXMOX_VE_USERNAME / PROXMOX_VE_PASSWORD for password auth)
  #
  # Some operations (ISO/file upload) also use SSH:
  ssh {
    agent    = true
    username = var.proxmox_ssh_username
  }
}
