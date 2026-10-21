terraform {
  required_version = ">= 1.13.0"

  required_providers {
    unifi = {
      source  = "ubiquiti-community/unifi"
      version = "0.59.0"
    }
  }

  # State backend: TBD (see docs/secrets-and-state.md §5). Backend disabled for validation:
  #   tofu init -backend=false
}
