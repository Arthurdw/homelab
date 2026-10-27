terraform {
  required_version = ">= 1.13.0"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "5.28.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.9.1"
    }
  }

  # State backend: TBD (see docs/secrets-and-state.md §5). Until then the state is local and gitignored
  # (*.tfstate). It holds the tunnel secret (main.tf), so treat the state file as a secret.
  # Backend disabled for validation:
  #   tofu init -backend=false
}
