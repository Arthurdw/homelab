terraform {
  required_version = ">= 1.13.0"

  required_providers {
    truenas = {
      source  = "truenas/truenas"
      version = "1.5.14"
    }
  }

  # State backend: TBD (see docs/secrets-and-state.md §5). Backend disabled for validation:
  #   tofu init -backend=false
}
