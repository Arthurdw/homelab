provider "unifi" {
  api_url        = var.unifi_api_url
  api_key        = var.unifi_api_key
  site           = var.unifi_site
  allow_insecure = var.unifi_allow_insecure
}
