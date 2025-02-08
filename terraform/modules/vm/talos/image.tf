resource "proxmox_virtual_environment_download_file" "talos_cloud_image" {
  node_name    = var.proxmox.name
  datastore_id = var.proxmox.storage
  content_type = "iso"
  file_name    = "talos-${var.image.version}-${var.image.arch}.iso"
  url          = "https://factory.talos.dev/image/376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba/${var.image.version}/metal-${var.image.arch}.iso"
}
