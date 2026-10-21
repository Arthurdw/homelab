# UniFi root configuration

Manages UniFi network resources for the homelab.

**Status:** one new network and the two host fixed IPs written. Against the L1 fixture, a self-hosted
controller in Docker (`just lab-unifi up`, then `just lab-unifi-plan`; see `docs/lab.md`), the plan creates only
`hl-k8s` and the two listed clients, the apply takes over the two pre-seeded client records, the re-plan is clean,
and a targeted destroy of one reservation leaves the client on the controller.
It has **not** been planned against the real UDM Pro, and the API-key login is untested (the fixture uses a local admin).

> ⚠️ **Additive-only, plan-only.** The homelab shares this UniFi controller with **house appliances and
> other people's networks**. Rules:
>
> - **Never** modify or delete objects we did not create; **never** import existing objects.
> - **Add** new objects with names prefixed `hl-`; wire them in explicitly.
> - Always review a `plan` and treat **any** update/destroy to an unowned object as a stop-and-ask event.
> - **One narrow exception, asked for by the owner:** the host fixed IPs (`host-reservations.tf`) take over
>   the existing client records of exactly the MACs listed in `host_reservations`, and nothing else. See below.
> - Applies are gated; never `-auto-approve`.
>
> ⚠️ The API key is **full-access** (no read-only key available). It is handled as enforced least privilege
> by process (`docs/secrets-and-state.md` §4, risk R19). Keep it in the environment, never in the repo.

## Usage

```sh
cd infrastructure/environments/homelab/unifi

export TF_VAR_unifi_api_key='...'

cp terraform.tfvars.example terraform.tfvars   # then edit; tfvars is gitignored
tofu init -backend=false
tofu validate
tofu plan                                      # review carefully
```

## What it manages

| Resource | What | Source |
|---|---|---|
| `unifi_network.k8s` | `hl-k8s`: VLAN 20, `10.20.0.0/24`, gateway `10.20.0.1`, purpose corporate, IPv6 off, DHCP `.200-.249` (proposal); `prevent_destroy` | decisions §2, network-plan |

| `data.unifi_network.server` | the **existing** server network (VLAN 4, `10.10.0.0/16`), read-only, by `server_network_name` (default `server`); a postcondition checks VLAN and subnet | network-plan |
| `unifi_client.host["poseidon"]` | fixed IP `10.10.1.1` on the server network for poseidon's MAC; takes over the existing client | host-network-bootstrap §1 |
| `unifi_client.host["hercules-nas"]` | fixed IP `10.10.1.10` on the server network for hercules-nas's MAC; takes over the existing client | host-network-bootstrap §1 |

A precondition rejects a DHCP pool that overlaps the nodes (`.11-.29`) or MetalLB (`.100-.199`).
The firewall zone is left to the controller default. Any inter-zone policy is a later, additive change.

**The storage link is not a UniFi object.** `10.99.0.0/30` (Proxmox `.1`, NAS `.2`, MTU 9000) is a
direct 10 GbE point-to-point cable between the Proxmox dual-port NIC and the NAS. It never touches a
UniFi switch or the UDM, so this root creates nothing for it.

### Host fixed IPs: the additive-only exception

A fixed IP is a field on a UniFi client record, and both hosts are already known clients, so a reservation
cannot be a new object. The owner asked for these two reservations explicitly, so `host-reservations.tf`
takes over the existing records (`allow_existing = true`). The scope is narrow:

- Only the MACs in `host_reservations` (keys `poseidon` and `hercules-nas`) are touched. An empty map,
  the default, manages nothing. The IPs are fixed in the file, from the network plan; only the MACs are
  inputs, and they live in the gitignored `terraform.tfvars` only. Validation rejects malformed or
  upper-case MACs, the `00:00:00:00:00:00` placeholder, duplicates and unknown hosts; preconditions
  reject an IP outside `10.10.0.0/16` (or the network, gateway or broadcast address) and duplicate IPs.
- Only `mac`, `fixed_ip` and `network_id` are set. `name`, `note` and the rest are left unset, so the
  controller keeps what it has. In 0.59.0 `name` is optional; setting it would rename a client the owner
  already sees in the UI, which is a visible change for no gain (the fixture proves name and note survive).
- The server network is read by a data source and is never managed or imported.
- `skip_forget_on_destroy = true`: removing a reservation (or a destroy) only drops it from state. The
  controller keeps the client, **and its fixed IP**. To clear the reservation, set it to `""` and apply
  before removing it, or clear it in the UI.

**Reading the plan:** the take-over shows as `+ create` for `unifi_client.host[...]` (OpenTofu does not know
the record exists); the apply updates the existing record in place. The plan must list only those clients
(and any new `hl-` objects). Anything else is a stop-and-ask event.

The provider sends `network_id` as the client's *virtual network override*
(`virtual_network_override_id`), which is how 10.6 stores it. That is what the fixture shows. On the real
UDM, check in the UI after the first apply that the override to the server network doesn't change how
the wired hosts get their VLAN.

### TODO(GATE 4)

- Confirm VLAN 20 is unused on the controller (from the configuration export) before the first plan.
- The DHCP range is a proposal: the decisions don't fix one. Use `k8s_dhcp.enabled = false` if all
  guests are static.
- Confirm the server network's name (`server_network_name`, default `server`) from the export. The data
  source's postcondition fails the plan if the named network is not VLAN 4 / `10.10.0.0/16`.
- The switch-port profile/tagging that carries VLAN 20 to poseidon touches existing port objects.
  It is not expressed here (additive-only); configure it by hand or as a new `hl-` profile once decided.

### CI

The API key is full-access and is never placed in CI (`docs/secrets-and-state.md` §4), so this root
is excluded from the dormant `tofu-plan` workflow. Plans run on the owner's machine only.

## Notes

- Provider: `ubiquiti-community/unifi` pinned to the stable **0.59.0** (validated against OpenTofu 1.13.1). Supports API-key auth. Resources are written against the 0.59.0 schema (flat `ipv6_*` attributes, flat `dhcp_server.dns_*`).
- Migration is incremental and additive (`docs/PROJECT-PLAN.md`, decision D2).
