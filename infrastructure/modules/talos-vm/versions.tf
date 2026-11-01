terraform {
  # Matches the repository pin (versions.yaml > iac.proxmox_ve / iac.providers). The
  # root module owns the provider *configuration*; this block only pins the version
  # so a review of the module alone still shows what it was written against.
  required_version = ">= 1.13.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.117.0"
    }
  }
}
