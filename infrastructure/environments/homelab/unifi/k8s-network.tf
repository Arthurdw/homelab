# ADDITIVE-ONLY (README.md, docs/architecture.md D2). This file only creates a new `hl-` object.
# Never import, adopt, rename or edit an existing UniFi object here. A plan that shows an update or
# destroy of anything not in this file is a stop-and-ask event.
#
# The storage link (10.99.0.0/29, Proxmox <-> NAS) is a direct 10 GbE cable, not a UniFi object.
# There is nothing to manage on the controller for it (see README.md).

# -----------------------------------------------------------------------------
# Kubernetes VLAN (docs/decisions.md §2, docs/network-plan.md)
# -----------------------------------------------------------------------------

locals {
  k8s_cidr = "10.20.0.0/24"

  # Reserved host ranges inside the K8s subnet (decisions.md §2). The DHCP pool must avoid them.
  k8s_reserved = {
    nodes   = { first = 11, last = 29 }
    metallb = { first = 100, last = 199 }
  }

  k8s_dhcp_overlaps = [
    for name, r in local.k8s_reserved : name
    if var.k8s_dhcp.enabled && var.k8s_dhcp.first <= r.last && var.k8s_dhcp.last >= r.first
  ]
}

resource "unifi_network" "k8s" {
  name    = "hl-k8s"
  purpose = "corporate"
  # TODO(GATE 4): confirm VLAN 20 is unused on the controller (configuration export) before apply.
  vlan = 20
  # Gateway + prefix form: the UDM is 10.20.0.1.
  subnet = "${cidrhost(local.k8s_cidr, 1)}/${split("/", local.k8s_cidr)[1]}"

  internet_access = true

  # Explicit: left unset, provider 0.59.0 sends "" and the controller rejects it (InvalidPayload,
  # allowed values are auto|manual). Found by the L1 fixture (scripts/lab/unifi-fixture-plan.sh).
  setting_preference = "manual"

  dhcp_server = {
    enabled = var.k8s_dhcp.enabled
    start   = var.k8s_dhcp.enabled ? cidrhost(local.k8s_cidr, var.k8s_dhcp.first) : null
    stop    = var.k8s_dhcp.enabled ? cidrhost(local.k8s_cidr, var.k8s_dhcp.last) : null
  }

  # IPv6 is disabled on new segments (decisions.md §2.5).
  ipv6_interface_type = "none"

  # firewall_zone_id is left unset. The controller places the network in its default zone. Any
  # inter-zone policy is a separate, additive follow-up (unifi_firewall_zone/policy), not done here.

  lifecycle {
    # Deleting this network drops every K8s node and LoadBalancer IP off the LAN.
    prevent_destroy = true

    precondition {
      condition     = length(local.k8s_dhcp_overlaps) == 0
      error_message = "k8s_dhcp overlaps reserved range(s): ${join(", ", local.k8s_dhcp_overlaps)} (nodes .11-.29, MetalLB .100-.199)."
    }
  }
}
