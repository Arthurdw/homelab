resource "cloudflare_dns_record" "local_infra_dns_record" {
  zone_id = "1e119aa0991cd3d408deea8b4e264feb"
  comment = "Local infra generic DNS record"
  content = "10.10.1.3"
  name    = "*.local.infra.ardw.be"
  proxied = false
  ttl     = 3600
  type    = "A"
}
