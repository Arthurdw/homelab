resource "proxmox_virtual_environment_vm" "talos" {
  node_name       = var.proxmox.name
  on_boot         = true
  stop_on_destroy = true

  machine       = "q35"
  scsi_hardware = "virtio-scsi-single"
  bios          = "seabios"

  name = "talos-test"

  agent {
    enabled = true
  }

  cpu {
    cores = 2
    type  = "host"
  }

  memory {
    dedicated = 2048
  }

  network_device {
    bridge = "vmbr0"
  }

  disk {
    datastore_id = var.proxmox.storage
    size         = 20
    interface    = "scsi0"
    discard      = "on"
    file_id      = proxmox_virtual_environment_download_file.talos_cloud_image.id
  }

  operating_system {
    type = "l26" # Linux Kernel 2.6 - 6.X.
  }

  initialization {
    datastore_id = var.proxmox.storage
    ip_config {
      ipv4 {
        address = "10.10.127.10/24"
        gateway = var.cluster.gateway
      }
    }
  }
}
