# Network Plan

> Current state **discovered** 2026-10-16 (read-only). Sanitized for the public repo — exact addresses
> and hostnames live in `docs/private/`. The target plan was decided at GATE 0
> (`docs/decisions.md` §2); nothing has been applied.

## Current topology (as found)

| Element | Finding |
|---|---|
| Gateway / router | UniFi **UDM Pro** is the LAN gateway |
| Management network | VLAN-tagged ("server" VLAN on the Proxmox side); Proxmox and NAS both have management interfaces there |
| NAS management NIC | **1 GbE** |
| Proxmox management NIC | **1 GbE** |
| Dedicated storage link | **10 GbE confirmed at both ends** (Proxmox dual-port NIC ↔ NAS `enp1s0f0`); point-to-point; addresses use **link-local (`169.254.0.0/16`)** |
| Storage protocol over that link | **SMB/CIFS** (Proxmox mounts the NAS `proxmox` share). Target: NFS, backups/ISOs only (`docs/decisions.md` §4.2) |
| VLAN naming | mismatch observed between the Proxmox side and the NAS side for the management VLAN — verify tags |
| DNS (NAS) | configured primary `10.10.1.53` — but **nothing listens there** (refused on UDP and TCP, verified 2026-10-16 from the workstation). It silently falls back to **`1.1.1.1`**. The UDM Pro (`10.10.0.1`, dnsmasq) is what actually answers on the server VLAN (`docs/decisions.md` §6.1) |
| DNS (Proxmox) | points at the gateway |
| IPv6 | present on the LAN (link + global addresses); UniFi warns IPv6 DNS can bypass custom IPv4 DNS — must be made intentional |

## Standing constraints

- **Management access stays private**; the emergency path is Tailscale (no DMZ, no inbound ports).
- **UniFi policy: additive-only** (`docs/PROJECT-PLAN.md` §4.4). New VLANs/subnets are fine; existing objects
  that serve house devices are never modified by IaC.
- **DNS must not be a bootstrap circular dependency:** Technitium gets a stable address and the UDM stays the
  fallback resolver.

## Resolved

1. **What answers `<INTERNAL_RESOLVER_IP>`?** Nothing — `10.10.1.53` is dead and the NAS was silently using
   `1.1.1.1`. The UDM answers on the server VLAN. (`docs/decisions.md` §6.1)
2. **Pod/service CIDRs and reserved ranges** — pods `10.244.0.0/16`, services `10.96.0.0/16`; never-use ranges
   are listed in `docs/decisions.md` §2.4.
3. **Storage subnet** — `10.99.0.0/29` over the 10 GbE link, with the Talos nodes on it for NFS (2026-10-21;
   MTU provisional; §2.2).
4. **IPv6** — disabled on the new K8s and storage segments; the house LAN is untouched (§2.5).
5. **Management VLAN tag** — VLAN 4, `10.10.0.0/16`, gateway `10.10.0.1` (the owner read it from the UniFi
   controller, 2026-10-21). Both hosts are being reinstalled, so the old Proxmox/NAS naming mismatch goes away;
   `docs/runbooks/host-network-bootstrap.md` puts them on VLAN 4 behind the unmanaged switch.

## Still open

6. **A read-only UniFi inventory** — the owner is handing over the full-access API key (held outside the
   repo). The inventory is the required baseline for anything additive in the zone model below.
7. **The NAS's LAN-facing NIC speed.** This document records 1 GbE for the management NIC, while the
   interface list shows a possibly-10G `enp4s0` behind the management VLAN. It decides whether household
   PC→NAS backups are capped at ~110 MB/s and contend with everything else — the 10 GbE link is
   point-to-point (Proxmox↔NAS), so household devices cannot use it.
8. **An mDNS reflector for the IOT zone** — required before any smart-home device moves, or casting,
   printers and AirPlay break (`docs/decisions.md` §2.6).
9. **A Cloudflare token scoped to `Zone → DNS → Edit` on the `ardw.be` zone** — needed for the DNS-01 certificates
   (`docs/decisions.md` §5.7). Until it exists, applications stay on the internal-CA fallback and household
   devices will warn.

## Target address plan (decided — rationale in `docs/decisions.md` §2)

| Zone / purpose | VLAN | Subnet | Contents |
|---|---|---|---|
| HOME | 1 | `10.0.0.0/16` | existing household devices — **untouched** |
| MGMT | 4 | `10.10.0.0/16` | `poseidon` `10.10.1.1`, `hercules-nas` `10.10.1.10` — **unchanged** |
| K8S | 20 | `10.20.0.0/24` | UDM gw `10.20.0.1`; nodes `10.20.0.11–29`; MetalLB `10.20.0.100–199` |
| SERVERS | 30 | `10.30.30.0/24` | workload VMs, separated from management — new |
| IOT | 40 | `10.30.40.0/24` | smart-home and consumer devices — new |
| GUEST | 60 | `10.30.60.0/24` | visitors, internet only — new |
| Storage link (10 GbE) | — | `10.99.0.0/29` | Proxmox `10.99.0.1`, NAS `10.99.0.2`, talos-cp-1 `10.99.0.3`, talos-wk-1 `10.99.0.4`, talos-wk-2 `10.99.0.5`; no gateway; MTU 9000 |
| Pods | — | `10.244.0.0/16` | identical in every environment |
| Services | — | `10.96.0.0/16` | identical in every environment |
| Lab nodes/VIPs | — | `10.99.100.0/24` | MetalLB `10.99.100.100–199`; local lab only |
| Lab storage link | — | `10.99.101.0/30` | local lab only |

The third octet of each new zone is its VLAN ID (`10.30.<vlan>.0/24`), so the scheme is self-describing and
cannot collide with the live `10.0/16` and `10.10/16`, the K8s VLAN, the `10.99.x` links, pods or services.

**There is deliberately no BACKUP VLAN** — household PC→NAS backups are controlled by firewall policy,
append-only repos and NAS-side snapshots instead (`docs/decisions.md` §2.7).

## Internal names (`lab.ardw.be`, served by Technitium)

The zone-bootstrap CronJob (`kubernetes/infrastructure/technitium/bootstrap-zone.yaml`) keeps these A records:

| Name | Points at | Notes |
|---|---|---|
| `lab.ardw.be`, `*.lab.ardw.be` | Traefik VIP (`TRAEFIK_LB_IP`) | every app, e.g. `dns.lab.ardw.be` (Technitium web console) |
| `pve.lab.ardw.be` | Traefik VIP (wildcard) | Proxmox UI through Traefik, no port (`docs/runbooks/host-proxies.md`) |
| `nas.lab.ardw.be` | Traefik VIP (wildcard) | TrueNAS UI through Traefik (`docs/runbooks/host-proxies.md`) |
| `poseidon.lab.ardw.be` | `10.10.1.1` | Proxmox, UI on `:8006`; SSH name and break-glass UI |
| `hercules-nas.lab.ardw.be` | `10.10.1.10` | TrueNAS; SSH name and break-glass UI |
| `unifi.lab.ardw.be` | `10.0.0.1` | UDM Pro |

Host names come from `HOST_RECORDS` in each cluster's `cluster-settings.yaml` (the lab has only
`lab-nas.lab.ardw.be` -> `10.99.100.10`). A specific record wins over the wildcard. The names are the machines'
own hostnames, unique across sites, so other sites' hosts can be added later without renaming. Proxmox, TrueNAS
and UniFi keep their self-signed certificates, so the browser warns on these names. `pve` and `nas` are not
host records: they fall under the wildcard, so Traefik serves the Let's Encrypt certificate and proxies to the
host with its pinned certificate verified. The host names stay direct, so the UIs are reachable without the
cluster.

**Public share names (`docs/decisions.md` §5.13):** `files.ardw.be` is its own Technitium zone, created by the
same CronJob (`APEX_ZONES`) with an A record to the Traefik VIP; the UDM forwards it to Technitium
(`infrastructure/environments/homelab/unifi/dns.tf`), so the LAN gets the full Seafile UI. Public DNS points
it at the Cloudflare Tunnel, which passes only share links. `photos.ardw.be` exists only in public DNS: its sole
origin is the share proxy, so the LAN uses the tunnel too.

**Cluster nodes' DNS:** the Talos nodes resolve via the UDM gateway `10.20.0.1` only (a `ResolverConfig` in
`talos/patches/network-*.yaml`; cloud-init sets no nameserver, so Talos would default to `1.1.1.1`). The UDM's
Forward Domain sends `lab.ardw.be` to Technitium, and CoreDNS forwards to the host resolver, so pods can resolve
`lab.ardw.be` names (e.g. Grafana reaching `auth.lab.ardw.be`). No public fallback, which would answer NXDOMAIN.
