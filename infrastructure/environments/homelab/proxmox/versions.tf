terraform {
  required_version = ">= 1.13.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.116.1"
    }
  }

  # State backend: TBD (see docs/secrets-and-state.md §5). Backend disabled for validation:
  #   tofu init -backend=false
}
