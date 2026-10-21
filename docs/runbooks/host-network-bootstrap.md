# Runbook: host network bootstrap (Proxmox and TrueNAS)

Owner-executed, at the console, after a fresh install of `poseidon` (Proxmox VE) or `hercules-nas` (TrueNAS
SCALE). It gets each host onto its management address on VLAN 4 so the IaC can take over. None of the IaC
roots manage host interfaces or management IPs, so this step is manual and happens once per install.

Addresses come from `docs/network-plan.md`:

| Host | Interface | Address | Gateway | DNS |
|---|---|---|---|---|
| `poseidon` | VLAN 4 on `vmbr0` | `10.10.1.1/16` | `10.10.0.1` | `10.10.0.1` |
| `hercules-nas` | VLAN 4 on the 1 GbE NIC | `10.10.1.10/16` | `10.10.0.1` | `10.10.0.1` |
| `poseidon` | 10 GbE storage port | `10.99.0.1/30`, MTU 9000 | none | — |
| `hercules-nas` | 10 GbE storage port | `10.99.0.2/30`, MTU 9000 | none | — |

`10.10.0.1` is the UDM's own address on VLAN 4. Never give it to a host. `10.10.1.53` is a dead resolver
(`docs/decisions.md` §6.1); don't configure it.

## Why the install address is temporary

The hosts sit behind an **unmanaged** switch whose uplink is a UniFi port with HOME (`10.0.0.0/16`) as its
native network. Untagged traffic lands in HOME, so the installer's DHCP lease is a `10.0.x` address. A host
that sends untagged frames with a `10.10.x` address is in the wrong broadcast domain: nothing answers its ARP,
and a HOME gateway such as `10.0.0.1` is outside a `10.10.0.0/16` subnet, so it is unreachable too. The fix is
to **tag** the management traffic with VLAN 4, on the host and on the UniFi port.

Install with the DHCP address the installer offers, then follow the steps below.

## 1. Pre-checks

- Console access (monitor and keyboard, or IPMI). The network change can cut SSH; the console is the
  rollback path.
- **UniFi, on the port the unmanaged switch plugs into** (UniFi Network → Devices → the switch → Ports → that
  port): native network stays **HOME**; tagged networks allow **VLAN 4 (server)** and **VLAN 20 (K8S)**. VLAN
  20 carries the Talos VMs (`k8s_vlan_id` in `infrastructure/environments/homelab/proxmox/`); it exists once
  the UniFi root is applied. This changes an existing port, so it is a UI step, not IaC (UniFi is
  additive-only, `docs/PROJECT-PLAN.md` §4.4).
- **UniFi fixed IPs** on the server network: `10.10.1.1` for `poseidon`'s MAC and `10.10.1.10` for
  `hercules-nas`'s. The server network's DHCP range covers both addresses, so without a reservation DHCP could
  hand them to another client. These are managed by the UniFi root
  (`infrastructure/environments/homelab/unifi/host-reservations.tf`): put the two MACs in its gitignored
  `terraform.tfvars` as `host_reservations`, then plan (it must show only those two clients) and apply (README
  there). Until the root is applied, set them by hand as a fallback: UniFi Network → Client Devices → the host →
  Settings → Fixed IP Address, on the server network. The root takes over a hand-set reservation without
  change.
- Not every unmanaged switch passes 802.1Q-tagged frames. If step 2's verification fails with the config
  right, plug the host into a UniFi port directly to rule the switch out.

## 2. Proxmox (`poseidon`)

1. Find the 1 GbE management NIC: `ip -br link`. On PVE 9 it is `nic0`
   (`enp0s31f6` on PVE 8, see `docs/hardware.md`); the commands below use that name.
2. Back up the current config: `cp /etc/network/interfaces /etc/network/interfaces.install`.
3. Write `/etc/network/interfaces`. `vmbr0` becomes VLAN-aware with no address of its own; the host address
   moves to `vmbr0.4`; `vmbr1` is the storage link:

   ```text
   auto lo
   iface lo inet loopback

   iface nic0 inet manual

   auto vmbr0
   iface vmbr0 inet manual
       bridge-ports nic0
       bridge-stp off
       bridge-fd 0
       bridge-vlan-aware yes
       bridge-vids 2-4094

   auto vmbr0.4
   iface vmbr0.4 inet static
       address 10.10.1.1/16
       gateway 10.10.0.1

   iface nic2 inet manual
       mtu 9000

   auto vmbr1
   iface vmbr1 inet static
       address 10.99.0.1/30
       bridge-ports nic2
       bridge-stp off
       bridge-fd 0
       mtu 9000
   ```

   The fibre to hercules-nas is on `nic2` (found 2026-10-21 by bringing both ports up and checking for `LOWER_UP` /
   `/sys/class/net/<nic>/carrier`; `nic1` is unused). If the cable is ever moved, re-check the same way.
   Leave `vmbr1` out until the NAS end
   exists if you prefer; it doesn't affect management.
4. Hostname and `/etc/hosts`: if the installer left the default `pve`, run `hostnamectl set-hostname poseidon`.
   Then replace the installer's line in `/etc/hosts` with `10.10.1.1 poseidon.<your-domain> poseidon`.
   Proxmox resolves its own name to pick the cluster address, and a stale `10.0.x` or a name mismatch here
   breaks the web UI.
5. `/etc/resolv.conf`: `nameserver 10.10.0.1`.
6. Apply from the console: `ifreload -a`.
7. Nested virtualisation, for the Kata runtime (`docs/decisions.md` §3.5). The CPU is Intel:

   ```sh
   echo 'options kvm-intel nested=Y' > /etc/modprobe.d/kvm-intel.conf
   ```

   It takes effect after a reboot (or `modprobe -r kvm_intel && modprobe kvm_intel` with no VMs running).
   Check with `cat /sys/module/kvm_intel/parameters/nested`, which should print `Y`.

**Verification:**

- `ip -br addr` shows `10.10.1.1/16` on `vmbr0.4`.
- `ping -c3 10.10.0.1` works (the gateway on VLAN 4), and `ping -c3 1.1.1.1` works (routing).
- `getent hosts deb.debian.org` resolves.
- From a PC on HOME: `https://10.10.1.1:8006` loads. If the host reaches the gateway and the internet but the
  PC can't reach the host, a UniFi firewall rule between HOME and the server network is blocking it. That's a
  policy decision, not a host problem.

**Rollback:** from the console, `cp /etc/network/interfaces.install /etc/network/interfaces && ifreload -a`
puts the host back on its DHCP address. Restore `/etc/hosts` the same way.

## 3. TrueNAS SCALE (`hercules-nas`)

From the web UI, at the install's DHCP address:

1. **Network → Interfaces → Add.** Type **VLAN**, parent interface the 1 GbE NIC, VLAN tag **4**, add an
   alias `10.10.1.10/16`. Leave DHCP off.
2. **Network → Global Configuration:** IPv4 default gateway `10.10.0.1`, nameserver 1 `10.10.0.1`, hostname
   `hercules-nas`.
3. Remove DHCP from the parent interface, so the host doesn't keep a second address on HOME.
4. Optional, once `poseidon`'s `vmbr1` is up: edit the 10 GbE port, alias `10.99.0.2/30`, MTU 9000.
5. **Test Changes.** TrueNAS rolls back by itself after 60 seconds unless you confirm. Open
   `https://10.10.1.10` in a new tab, and press **Save Changes** in the old one only once the new address
   loads.

The console menu's "Configure network interfaces" option does the same if the web UI isn't reachable.

**Verification:**

- The web UI loads at `https://10.10.1.10` from a PC on HOME (subject to the firewall note above).
- From `poseidon`: `ping -c3 10.10.1.10`, and over the storage link
  `ping -c3 -M do -s 8972 10.99.0.2`. The second proves MTU 9000 end to end: 8972 bytes of payload plus 28 of
  headers is 9000.

**Rollback:** let Test Changes expire, or use the console menu to reset the network configuration.

## 4. After the bootstrap

- The TrueNAS root needs SCALE 25.04 or later (`infrastructure/environments/homelab/truenas/README.md`).
- How the Talos nodes reach `10.99.0.2` for NFS is still open (`truenas/variables.tf`,
  `k8s_nfs_allowed_networks`), and so is the provisional storage subnet (`docs/decisions.md` §2.2). Measure
  throughput over the link before settling either.
- Continue with the Proxmox root, then `docs/runbooks/talos-bootstrap.md`.
