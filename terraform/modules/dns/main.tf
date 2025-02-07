terraform {
  required_version = "1.10.5"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "5.0.0"
    }
  }
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

resource "cloudflare_dns_record" "local_infra_dns_record" {
  zone_id = "1e119aa0991cd3d408deea8b4e264feb"
  comment = "Local infra generic DNS record"
  content = "10.10.1.3"
  name    = "*.local.infra.ardw.be"
  proxied = false
  ttl     = 3600
  type    = "A"
}
