# The NAS end of the 10 GbE storage link to poseidon (docs/decisions.md §2.2, docs/hardware.md).
#
# Creates a one-port FAILOVER bond (bond1) on the NAS's 10 GbE port and gives it 10.99.0.2/30 at MTU
# 9000, no DHCP, so poseidon's vmbr1 (10.99.0.1/30, proxmox root storage-link.tf) can reach it.
#
# Why a bond: the port itself is PHYSICAL, and this provider can only import PHYSICAL interfaces,
# never configure them (type = "PHYSICAL" is rejected at validate time; allowed: BRIDGE,
# LINK_AGGREGATION, VLAN). On the lab fixture a BRIDGE did not propagate its MTU to the member port
# (jumbo ping lost 100%), while a LINK_AGGREGATION does. So nothing is imported here.
#
# What it does NOT touch: the management interface (never listed here) and the global network
# config (default gateway, DNS, hostname). A wrong setting on the management port would cut this
# provider's own connection, so only the storage port is bonded. The port must not already carry an
# address or be in use.
#
# On a real apply TrueNAS stages the change and commits it with an auto-rollback window; the provider
# handles the commit. If the NAS cannot be reached afterwards it reverts by itself. Untested on the
# real 25.10.7 box.
resource "truenas_network_interface" "storage_link" {
  name         = var.storage_link_name
  type         = "LINK_AGGREGATION"
  lag_protocol = "FAILOVER"
  lag_ports    = [var.storage_link_interface]

  ipv4_dhcp = false
  ipv6_auto = false
  mtu       = var.storage_link_mtu

  aliases = [{
    address = var.storage_link_address
    netmask = var.storage_link_prefix_length
    type    = "INET"
  }]
}
