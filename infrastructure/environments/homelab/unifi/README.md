# UniFi root configuration

Manages UniFi network resources for the homelab.

**Status:** one new network written. It plans, applies and re-plans cleanly (1 resource, no drift) against the
L1 fixture, a self-hosted controller in Docker (`just lab-unifi up`, then `just lab-unifi-plan`; see `docs/lab.md`).
It has **not** been planned against the real UDM Pro, and the API-key login is untested (the fixture uses a local admin).

> ⚠️ **Additive-only, plan-only.** The homelab shares this UniFi controller with **house appliances and
> other people's networks**. Rules:
>
> - **Never** modify or delete objects we did not create; **never** import existing objects.
> - **Add** new objects with names prefixed `hl-`; wire them in explicitly.
> - Always review a `plan` and treat **any** update/destroy to an unowned object as a stop-and-ask event.
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

A precondition rejects a DHCP pool that overlaps the nodes (`.11-.29`) or MetalLB (`.100-.199`).
The firewall zone is left to the controller default. Any inter-zone policy is a later, additive change.

**The storage link is not a UniFi object.** `10.99.0.0/30` (Proxmox `.1`, NAS `.2`, MTU 9000) is a
direct 10 GbE point-to-point cable between the Proxmox dual-port NIC and the NAS. It never touches a
UniFi switch or the UDM, so this root creates nothing for it.

### TODO(GATE 4)

- Confirm VLAN 20 is unused on the controller (from the configuration export) before the first plan.
- The DHCP range is a proposal: the decisions don't fix one. Use `k8s_dhcp.enabled = false` if all
  guests are static.
- The switch-port profile/tagging that carries VLAN 20 to poseidon touches existing port objects.
  It is not expressed here (additive-only); configure it by hand or as a new `hl-` profile once decided.

### CI

The API key is full-access and is never placed in CI (`docs/secrets-and-state.md` §4), so this root
is excluded from the dormant `tofu-plan` workflow. Plans run on the owner's machine only.

## Notes

- Provider: `ubiquiti-community/unifi` pinned to the stable **0.59.0** (validated against OpenTofu 1.13.1). Supports API-key auth. Resources are written against the 0.59.0 schema (flat `ipv6_*` attributes, flat `dhcp_server.dns_*`).
- Migration is incremental and additive (`docs/PROJECT-PLAN.md`, decision D2).
