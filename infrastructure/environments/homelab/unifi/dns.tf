# ADDITIVE-ONLY (README.md, docs/architecture.md D2). This file only creates a new DNS record.
#
# Forward Domain on the UDM: every lookup under lab.ardw.be goes to the cluster's Technitium, which answers
# *.lab.ardw.be with the Traefik IP. New apps need nothing here. The household DHCP DNS is not changed: the
# UDM keeps answering everything else, so the house keeps working when the cluster is down.
#
# A record's name is the domain itself, so the `hl-` prefix cannot apply. lab.ardw.be is used only by the homelab.

locals {
  lab_domain = "lab.ardw.be"

  # TECHNITIUM_LB_IP in kubernetes/clusters/homelab/cluster-settings.yaml.
  technitium_lb_ip = cidrhost(local.k8s_cidr, 101)
}

# record_type NS is what the provider calls a UniFi Forward Domain: the value is the DNS server's IP.
resource "unifi_dns_record" "lab" {
  name        = local.lab_domain
  record_type = "NS"
  value       = local.technitium_lb_ip
}
