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
| DNS (NAS) | configured primary `10.10.1.53` — but **nothing listens there** (refused on UDP and TCP, verified 2026-10-16 from the workstation). It silently falls back to **`1.1.1.1`**. The UDM Pro (`10.10.0.1`, dnsmasq) is what actually answers on the server VLAN. The earlier claim that "the internal resolver is in use" was **wrong** — see `docs/decisions.md` §6.1 |
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

## Resolved

1. **What answers `<INTERNAL_RESOLVER_IP>`?** Nothing — `10.10.1.53` is dead and the NAS was silently using
   `1.1.1.1`. The UDM answers on the server VLAN. (`docs/decisions.md` §6.1)
2. **Pod/service CIDRs and reserved ranges** — pods `10.244.0.0/16`, services `10.96.0.0/12`; never-use ranges
   are listed in `docs/decisions.md` §2.4.
3. **Storage subnet** — moves to `10.99.0.0/30` over the 10 GbE link (provisional; §2.2).
4. **IPv6** — disabled on the new K8s and storage segments; the house LAN is untouched (§2.5).

## Still open

5. **Management VLAN tag**, and whether the NAS/Proxmox VLAN mismatch is cosmetic or real — needs the UniFi
   configuration export (the full-access key is approved but not yet captured).

## Target address plan (decided — rationale in `docs/decisions.md` §2)

| Purpose | Subnet | Contents |
|---|---|---|
| House LAN | `10.0.0.0/16` | existing, untouched |
| Server mgmt (VLAN 4) | `10.10.0.0/16` | `poseidon` `10.10.1.1`, `hercules-nas` `10.10.1.10` — unchanged |
| K8s (VLAN 20, new) | `10.20.0.0/24` | UDM gw `10.20.0.1`; nodes `10.20.0.11–29`; MetalLB `10.20.0.100–199` |
| Storage p2p (10 GbE) | `10.99.0.0/30` | Proxmox `10.99.0.1`, NAS `10.99.0.2`; no gateway; MTU 9000 |
| Pods | `10.244.0.0/16` | identical in every environment |
| Services | `10.96.0.0/12` | identical in every environment |
| Lab nodes/VIPs | `10.99.100.0/24` | MetalLB `10.99.100.100–199`; local libvirt lab only |
| Lab storage link | `10.99.101.0/30` | local libvirt lab only |
