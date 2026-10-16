output "talos_nodes" {
  description = "The Talos VMs, keyed by node name. Guest-agent fields are empty while the agent is disabled."
  value = {
    for name, m in module.talos : name => {
      vm_id          = m.vm_id
      name           = m.name
      mac_addresses  = m.mac_addresses
      ipv4_addresses = m.ipv4_addresses
    }
  }
}

output "talos_requested_ipv4" {
  description = "Static IPv4 addresses this root asked Proxmox's cloud-init to apply (network-config)."
  value       = { for name, n in local.talos_nodes : name => "${n.ipv4}/${var.k8s_prefix_length}" }
}

output "talos_guest_memory_mb" {
  description = "Total RAM committed to the Talos guests (MiB) — used by the host headroom check."
  value       = local.talos_guest_memory_mb
}
