output "vm_id" {
  description = "Proxmox VMID of the created VM."
  value       = proxmox_virtual_environment_vm.this.vm_id
}

output "name" {
  description = "VM name (Talos hostname)."
  value       = proxmox_virtual_environment_vm.this.name
}

output "ipv4_addresses" {
  description = "IPv4 addresses reported by the QEMU guest agent. EMPTY unless qemu_guest_agent_enabled = true."
  value       = proxmox_virtual_environment_vm.this.ipv4_addresses
}

output "mac_addresses" {
  description = "MAC addresses of the VM's NICs."
  value       = proxmox_virtual_environment_vm.this.mac_addresses
}

output "qemu_guest_agent_enabled" {
  description = "Whether the QEMU guest agent was enabled for this VM."
  value       = var.qemu_guest_agent_enabled
}
