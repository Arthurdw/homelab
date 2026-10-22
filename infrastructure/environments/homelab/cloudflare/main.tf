# Public share links through a Cloudflare Tunnel (docs/decisions.md §5.13, docs/runbooks/public-shares.md).
#
# The tunnel is locally managed (config_src = "local"): its ingress rules live in git
# (kubernetes/apps/cloudflared/tunnel-config.yaml), not in Cloudflare. This root owns only the tunnel object
# and the public DNS records that point at it.

# 32 random bytes, the size `cloudflared tunnel create` uses. Kept in state (README.md, State).
resource "random_bytes" "tunnel_secret" {
  length = 32
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "homelab" {
  account_id    = var.account_id
  name          = var.tunnel_name
  config_src    = "local"
  tunnel_secret = random_bytes.tunnel_secret.base64
}

resource "cloudflare_dns_record" "tunnel" {
  for_each = var.public_hostnames

  zone_id = var.zone_id
  name    = each.value
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.homelab.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1 # automatic; required for proxied records
  comment = "Cloudflare Tunnel ${var.tunnel_name}, managed by OpenTofu (infrastructure/environments/homelab/cloudflare)"
}
