# The Tesla P4 (docs/hardware.md): a Proxmox cluster PCI resource mapping, and which Talos VM gets it.
#
# Why a mapping and not `hostpci = 0000:01:00.0` on the VM: a raw host address needs root@pam, while a
# mapping works with the API token (privilege Mapping.Use, docs/runbooks/launch.md section 1). It also
# makes the card movable: `gpu_passthrough.vm` picks the Talos VM, and a non-Talos VM can take it later
# by dropping `vm` here and adding `hostpci0: mapping=tesla-p4` to that VM. Only ONE running VM can hold
# the card; Proxmox refuses to start a second one that names it.
#
# The passthrough VM cannot live-migrate and has all of its memory pinned (ballooning is already 0).
# Adding the card to a running VM needs a restart, which the provider may do during apply: drain first.
#
# Before the first apply, remove any hand-made passthrough of the card from other VMs (risk R14,
# docs/risk-register.md). If the mapping was already made by hand, adopt it instead of creating it:
#   tofu import 'proxmox_hardware_mapping_pci.gpu[0]' tesla-p4
# Inside the guest, Talos loads the NVIDIA driver from the schematic's nonfree extensions
# (talos/schematic.yaml, talos/patches/gpu-worker.yaml).

resource "proxmox_hardware_mapping_pci" "gpu" {
  count = var.gpu_passthrough == null ? 0 : 1

  name    = var.gpu_passthrough.mapping_name
  comment = "NVIDIA Tesla P4 - managed by OpenTofu (infrastructure/environments/homelab/proxmox/gpu.tf)"
  map = [{
    id           = var.gpu_passthrough.device_id
    node         = var.proxmox_node_name
    path         = var.gpu_passthrough.pci_path
    iommu_group  = var.gpu_passthrough.iommu_group
    subsystem_id = var.gpu_passthrough.subsystem_id
  }]

  lifecycle {
    precondition {
      condition     = var.gpu_passthrough.vm == null || contains(keys(local.talos_nodes), coalesce(var.gpu_passthrough.vm, "-"))
      error_message = "gpu_passthrough.vm must be null or one of the Talos VMs: ${join(", ", keys(local.talos_nodes))}."
    }
  }
}
