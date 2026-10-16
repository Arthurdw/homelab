# Network Plan

> Current state **discovered** 2026-10-16 (read-only). Sanitized for the public repo — exact addresses
> and hostnames live in `docs/private/`. Target items are proposals, not applied changes.

## Current topology (as found)

| Element | Finding |
|---|---|
| Gateway / router | UniFi **UDM Pro** is the LAN gateway |
| Management network | VLAN-tagged ("server" VLAN on the Proxmox side); Proxmox and NAS both have management interfaces there |
| NAS management NIC | **1 GbE** |
| Proxmox management NIC | **1 GbE** |
| Dedicated storage link | **10 GbE confirmed at both ends** (Proxmox dual-port NIC ↔ NAS `enp1s0f0`); point-to-point; addresses use **link-local (`169.254.0.0/16`)** |
| Storage protocol over that link | **SMB/CIFS** (Proxmox mounts the NAS `proxmox` share) — *not* NFS |
| VLAN naming | mismatch observed between the Proxmox side and the NAS side for the management VLAN — verify tags |
| DNS (NAS) | primary = **`<INTERNAL_RESOLVER_IP>`, secondary = `1.1.1.1`** (matches the spec; the internal resolver **is** in use) |
| DNS (Proxmox) | points at the gateway |
| IPv6 | present on the LAN (link + global addresses); UniFi warns IPv6 DNS can bypass custom IPv4 DNS — must be made intentional |

## Target considerations (to be decided in Phase 0/2)

- **Storage link:** the spec suggests a **private `/24`, static, no default gateway** on the storage-only
  interface. Current use of link-local addressing works but is unconventional; decide whether to keep or
  renumber on rebuild. Verify MTU (9000?) and that traffic is bound to the 10 GbE path.
- **Kubernetes CIDRs:** choose node / pod / service CIDRs that do not collide with the existing LAN,
  the Docker bridges on the NAS, or future VLANs.
- **DNS:** Technitium as internal resolver with a **stable LAN address** (MetalLB only if the network
  design allows). Must not be a bootstrap circular dependency; document a fallback resolver and a restore
  procedure. Confirm IPv6 behaviour.
- **Management access stays private**; document the emergency/out-of-band path.
- **UniFi policy:** additive-only — see plan §4.4. New VLANs/subnets for new infra are fine; existing
  objects that serve house devices must not be modified by IaC.

## Open network questions
1. What answers at `<INTERNAL_RESOLVER_IP>` today (which service/host), and is it redundant?
2. Intended management VLAN tag, and whether the NAS/Proxmox mismatch is cosmetic or real?
3. Desired pod/service CIDRs, and any reserved ranges to avoid?
4. Storage subnet choice: keep link-local, or move to a private `/24` on rebuild?
5. IPv6 policy for the homelab (keep, disable, or intentional split)?
