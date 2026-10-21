# NARROW EXCEPTION to the additive-only rule (README.md, docs/PROJECT-PLAN.md §4.3).
#
# A UniFi fixed IP (DHCP reservation) is a field on the client record, and poseidon and hercules-nas are
# already known clients on the controller. Managing their reservations therefore TAKES OVER existing
# client records (`allow_existing = true`). The owner asked for this explicitly (2026-10-21). The
# exception is scoped to exactly the clients whose MACs are listed in `var.host_reservations` (MACs live
# in the gitignored terraform.tfvars only) and to nothing else:
#
# - Only `mac`, `fixed_ip` and `network_id` are set. `name`, `note`, `blocked`, groups and the rest are
#   left unset, so the provider keeps whatever the controller already has (in 0.59.0 `name` is optional;
#   setting it would rename a client the owner already sees in the UI, a visible change for no gain).
# - The server network (VLAN 4) is only READ by a data source. It is never managed or imported.
# - `skip_forget_on_destroy = true`: removing a reservation from this root (or a destroy) releases the
#   record from state without telling the controller to forget the client. Proven on the L1 fixture
#   (scripts/lab/unifi-fixture-plan.sh). The fixed IP itself stays set on the controller until it is
#   cleared by hand or by setting it here first.
#
# A plan must show changes to ONLY these clients (one `unifi_client.host[...]` per listed host). Anything
# else updating or being destroyed is a stop-and-ask event, as everywhere in this root.

# -----------------------------------------------------------------------------
# Host fixed IPs on the server network (docs/network-plan.md, docs/runbooks/host-network-bootstrap.md)
# -----------------------------------------------------------------------------

locals {
  server_cidr = "10.10.0.0/16"
  server_vlan = 4

  # The addresses are fixed by the plan, so they live here and not in tfvars. Only the MACs are inputs.
  host_ips = {
    poseidon       = "10.10.1.1"
    "hercules-nas" = "10.10.1.10"
  }

  host_reservations = {
    for host, r in var.host_reservations : host => {
      mac = r.mac
      ip  = local.host_ips[host]
    }
  }

  # Guards (evaluated as preconditions below): every IP inside the server subnet, not the network,
  # broadcast or gateway address, and no IP used twice.
  reservation_ips = values(local.host_ips)
  reservation_ips_outside = [
    for host, ip in local.host_ips : host
    if cidrhost("${ip}/16", 0) != cidrhost(local.server_cidr, 0)
    || contains([cidrhost(local.server_cidr, 0), cidrhost(local.server_cidr, 1), cidrhost(local.server_cidr, -1)], ip)
  ]
}

# Read-only. TODO(GATE 4): confirm the real name of the VLAN 4 network from the controller export.
data "unifi_network" "server" {
  name = var.server_network_name

  lifecycle {
    postcondition {
      condition     = self.vlan == local.server_vlan && cidrhost(self.subnet, 0) == cidrhost(local.server_cidr, 0) && split("/", self.subnet)[1] == split("/", local.server_cidr)[1]
      error_message = "Network '${var.server_network_name}' is not VLAN ${local.server_vlan} / ${local.server_cidr} (got VLAN ${self.vlan}, subnet ${self.subnet}). Wrong server_network_name?"
    }
  }
}

resource "unifi_client" "host" {
  for_each = local.host_reservations

  mac        = each.value.mac
  fixed_ip   = each.value.ip
  network_id = data.unifi_network.server.id

  # Take over the existing client record for this MAC (it is already known to the controller) ...
  allow_existing = true
  # ... and never make the controller forget it when the reservation leaves this root.
  skip_forget_on_destroy = true

  lifecycle {
    precondition {
      condition     = length(local.reservation_ips_outside) == 0
      error_message = "Reserved IP(s) for ${join(", ", local.reservation_ips_outside)} are not usable host addresses in ${local.server_cidr}."
    }
    precondition {
      condition     = length(distinct(local.reservation_ips)) == length(local.reservation_ips)
      error_message = "Two hosts share a reserved IP."
    }
  }
}
