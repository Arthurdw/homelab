terraform {
  required_version = "1.10.5"
}

module "dns" {
  source               = "./modules/dns"
  cloudflare_api_token = var.cloudflare_api_token
}
