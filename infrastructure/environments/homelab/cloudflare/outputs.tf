output "tunnel_id" {
  description = "Tunnel UUID. Goes in the cloudflared-tunnel Secret as tunnel-id (docs/runbooks/public-shares.md)."
  value       = cloudflare_zero_trust_tunnel_cloudflared.homelab.id
}

output "tunnel_credentials_json" {
  description = "cloudflared credentials file (AccountTag, TunnelID, TunnelSecret). Sensitive: write it straight to a mode-600 file with `tofu output -raw`, never print it (docs/runbooks/public-shares.md)."
  value = jsonencode({
    AccountTag   = cloudflare_zero_trust_tunnel_cloudflared.homelab.account_tag
    TunnelID     = cloudflare_zero_trust_tunnel_cloudflared.homelab.id
    TunnelSecret = random_bytes.tunnel_secret.base64
  })
  sensitive = true
}
