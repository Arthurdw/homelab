variable "cloudflare_api_token" {
  description = "Cloudflare API token. Prefer TF_VAR_cloudflare_api_token (env, ~/.config/homelab/cloudflare.env). Scopes: Zone > DNS > Edit on ardw.be, and Account > Cloudflare Tunnel > Edit. Separate from cert-manager's token (README.md)."
  type        = string
  sensitive   = true
}

variable "account_id" {
  description = "Cloudflare account ID (dashboard > ardw.be > Overview, right column). Goes in terraform.tfvars, not in git."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{32}$", var.account_id))
    error_message = "account_id must be the 32-character hex account ID."
  }
}

variable "zone_id" {
  description = "Zone ID of ardw.be (dashboard > ardw.be > Overview). Goes in terraform.tfvars, not in git."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{32}$", var.zone_id))
    error_message = "zone_id must be the 32-character hex zone ID."
  }
}

variable "tunnel_name" {
  description = "Name of the Cloudflare Tunnel (shown in the Zero Trust dashboard)."
  type        = string
  default     = "homelab"
}

variable "public_hostnames" {
  description = "Public hostnames routed to the tunnel (proxied CNAMEs). Must match the ingress rules in kubernetes/apps/cloudflared/tunnel-config.yaml (docs/decisions.md §5.13)."
  type        = set(string)
  default     = ["files.ardw.be", "photos.ardw.be"]

  validation {
    condition     = alltrue([for h in var.public_hostnames : endswith(h, ".ardw.be") && !endswith(h, ".lab.ardw.be")])
    error_message = "Public hostnames must be in ardw.be and outside lab.ardw.be (which stays internal)."
  }
}
