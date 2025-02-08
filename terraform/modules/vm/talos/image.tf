resource "talos_image_factory_schematic" "schematic" {
  schematic = file("${path.module}/schematic.yaml")
}

resource "proxmox_virtual_environment_download_file" "talos_cloud_image" {
  node_name    = var.proxmox.name
  datastore_id = var.proxmox.storage
  content_type = "iso"
  file_name    = "talos-${var.image.version}-${var.image.arch}.iso"
  url          = "https://factory.talos.dev/image/${talos_image_factory_schematic.schematic.id}/${var.image.version}/metal-${var.image.arch}.iso"
}
