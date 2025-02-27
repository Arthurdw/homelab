resource "proxmox_virtual_environment_network_linux_bridge" "vmbr0" {
  name      = "vmbr0"
  node_name = var.proxmox.name

  autostart  = true
  vlan_aware = true
  ports      = ["enp0s31f6"]

  comment = "Linux bridge for VMs"
}

resource "proxmox_virtual_environment_network_linux_vlan" "server_network" {
  depends_on = [proxmox_virtual_environment_network_linux_bridge.vmbr0]

  name      = "server"
  node_name = var.proxmox.name

  autostart = true
  interface = "vmbr0"
  vlan      = 4
  address   = "10.10.1.1/16"
  gateway   = "10.10.0.1"

  comment = "Server network (VLAN 4)"
}

resource "proxmox_virtual_environment_network_linux_bridge" "vmbr1" {
  name      = "vmbr1"
  node_name = var.proxmox.name

  autostart = true
  address   = "169.254.10.20/16"
  ports     = ["enp2s0f1"]

  comment = "Private fiber to Hercules NAS"
}
