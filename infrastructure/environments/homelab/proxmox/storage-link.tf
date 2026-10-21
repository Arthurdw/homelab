# The 10 GbE storage link, Proxmox end (docs/decisions.md §2.2, docs/hardware.md). A point-to-point /30
# between poseidon (this end, 10.99.0.1) and hercules-nas (10.99.0.2, managed by the truenas root).
# It carries NFS and nothing else: no gateway, no VLAN, no route off the link.
#
# vmbr1 is a Linux bridge with the fibre NIC as its only port (a bridge, not a bare NIC address, so a
# later Proxmox storage-access VM or container could attach to the same link). The management bridge
# vmbr0 and nic0 are NOT touched here: OpenTofu reaches the host over that network, and a bad apply
# would cut its own access (docs/runbooks/host-network-bootstrap.md).
#
# Not expressible in this root: the physical NIC itself. Proxmox refuses a bridge whose MTU is above its
# port's, and bpg has no resource for a plain NIC, so the port's own `iface <nic> inet manual / mtu 9000`
# stanza is a one-line owner step BEFORE the first apply (docs/runbooks/launch.md section 5).
#
# If vmbr1 was already made by hand, adopt it instead of creating it:
#   tofu import proxmox_network_linux_bridge.storage_link <node>:<bridge>   # e.g. poseidon:vmbr1
# and the next plan shows no change when the address, MTU and port below match.

resource "proxmox_network_linux_bridge" "storage_link" {
  node_name = var.proxmox_node_name
  name      = var.storage_link_bridge
  address   = var.storage_link_address
  mtu       = var.storage_link_mtu
  ports     = [var.storage_link_port]
  autostart = true
}
