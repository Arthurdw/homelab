# Arthur's Homelab

## Terraform Proxmox setup notes

On a fresh install of Proxmox, use a extra network interface (it is temporary,
so can be through a USB adapter). This is because we are setting up the network
and therefore can't overwrite itself. So make sure the only present Linux Bridge
or Linux VLAN is the external/temporary one.

Then run the terraform, and all should be good to go (might have to toggle the
Gateway off temporary and manually switch it)
