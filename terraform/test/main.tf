terraform {
  required_version = "1.10.2"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.70.0"
    }
  }
}

provider "proxmox" {
  endpoint = "https://poseidon.local.infra.ardw.be"

  username = "root@pam"
  password = "<passwd>"

  ssh {
    agent = true
  }
}

variable "talos" {
  type = object({
    version = string
    arch    = string
  })
  default = {
    version = "v1.9.3"
    arch    = "amd64"
  }
}

resource "proxmox_virtual_environment_download_file" "talos_cloud_image" {
  content_type = "iso"
  datastore_id = "hercules"
  node_name    = "proxmox"
  url          = "https://factory.talos.dev/image/376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba/${var.talos.version}/metal-${var.talos.arch}.iso"
  file_name    = "talos-metal-amd64.iso"
}

resource "proxmox_virtual_environment_vm" "talos_vm" {
  name            = "test-talos"
  node_name       = "proxmox"
  stop_on_destroy = true

  disk {
    datastore_id = "hercules"
    file_id      = proxmox_virtual_environment_download_file.talos_cloud_image.id
    interface    = "virtio0"
    iothread     = true
    discard      = "on"
    size         = 20
  }
}
