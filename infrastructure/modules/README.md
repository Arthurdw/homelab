# OpenTofu modules (`infrastructure/modules`)

Reusable, single-purpose modules consumed by the environment roots in
`infrastructure/environments/<env>/<system>`. Each module is a plain local module
(`source = "../../../modules/<name>"`), pinned to the same provider version as the roots.

## `talos-vm`

Provisions **one Talos Linux VM on Proxmox VE** (`bpg/proxmox`). See
[`talos-vm/README.md`](talos-vm/README.md) for every variable, output and the full
rationale. In one line: it owns the VM's *lifecycle* (size, disk, NIC, addressing,
firmware, optional guest agent) and nothing beyond it.

### What it encodes

- **Boot disks on the host SSD (`local-lvm`), never the NAS** — `docs/decisions.md` §3.2.
- **Talos on Proxmox uses the `nocloud` platform**; the guest's address arrives through
  Proxmox's cloud-init `network-config`.
- **K8s traffic on its own VLAN** — `docs/decisions.md` §2.1 (tag is a variable).
- **The Proxmox firewall is off on the K8s NIC; management stays private** — §5.2.
- **No RAM ballooning** and **no `virtio-scsi-single`** — both from the Talos Proxmox
  guidance.
- **Talos tooling, not OpenTofu, owns machine config and bootstrap** —
  `docs/architecture.md` §7 (the module's default `machine_config_delivery = "talosctl"`).

### What is deliberately NOT encoded

- **Machine config, bootstrap, OS upgrades** — Talos tooling's job (`scripts/talos/`).
- **Topology / instance count / sizing** — the environment root decides.
- **The OS image download** — the root downloads once and passes a status in, so one
  artifact serves every node.
- **IP-allocation policy and the image's extensions** (e.g. `qemu-guest-agent`) — the root
  owns the schematic and the addresses.

## Conventions

- One resource kind per module; the root composes.
- Every environment-specific value is a variable; decided values are the only defaults.
- Anything undecided at cutover is either required (no default) or marked `TODO(GATE 4)`.
- README documents every variable and the decisions the module encodes.
