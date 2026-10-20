# Hardware Inventory

> Verified **2026-10-16** by read-only discovery (SSH, no changes). Sanitized: no addresses,
> serials, or hostnames-sensitive values here — exact values live in `docs/private/`.
> Re-verify after any hardware change.

## Host 1 — Proxmox (`poseidon`)

| Item | Value | Notes |
|---|---|---|
| OS | Debian 12 (bookworm), PVE 8.4.11, kernel 6.8.12-13-pve | |
| CPU | Intel Core i5-7400 — 4 cores / 4 threads @ 3.0 GHz | no SMT; limited parallelism |
| RAM | 46 GiB usable | currently ~42 GiB consumed by one VM |
| Boot/root disk | 1× Crucial CT525MX300 SSD (~489 GiB) | **SPOF** — no mirror |
| Root layout | LVM: `pve-root` 96 G ext4 (7 % used), `pve-data` 360 G lvmthin (0 % used), 8 G swap | no ZFS on the host |
| GPU | 1× NVIDIA Tesla P4 (`GP104GL`, `10de:1bb3`) | **already passed through to a VM**; IOMMU on (`intel_iommu=on iommu=pt`); in IOMMU group 2 with its root port |
| NIC 1 | 1 GbE (`enp0s31f6`) | management VLAN bridge `vmbr0` |
| NIC 2 | dual-port (`enp2s0f0` down / `enp2s0f1` **10 GbE link up**) | storage bridge `vmbr1` → NAS |
| Pending updates | **185 packages** | patch policy needed |
| SMART (root SSD) | PASSED | |

## Host 2 — TrueNAS (`hercules-nas`)

| Item | Value | Notes |
|---|---|---|
| OS | TrueNAS SCALE **24.10.2.4**, kernel 6.6.44 | uptime 141 d at capture |
| CPU | Intel Core i5-7400 — 4 cores | same class as host 1 |
| RAM | 32 GiB, **non-ECC** | affects reliability posture |
| Board | MSI MS-7A74 | |
| Boot disks | **3× PNY CS900 250 GB SSD in a 3-way mirror** | over-provisioned for boot |
| Data disks | **8× Seagate ST4000VN006 4 TB** (RaidZ3) | 3-disk redundancy |
| Cache | **1× Crucial P3 Plus 1 TB NVMe** as L2ARC (~76 % full) | read cache |
| NIC 1 | 10 GbE (`enp1s0f0`) | storage link to Proxmox, link-local addressing |
| NIC 2 | 1 GbE (`enp4s0`) | management VLAN |
| Boot environments | 5 (`24.04.2.5` → `24.10.2.4`) | cleanup candidate |
| Boot pool | 3-way mirror, 216 G raw, ~14 G used | |
| Data pool | `main`, 29.1 T raw / 17.8 T alloc / 11.3 T free, 61 %, frag 17 % | healthy, 0 errors |

## Dev workstation (lab host candidate)

| Item | Value | Notes |
|---|---|---|
| CPU | Intel Core Ultra 7 155H — 16 cores / 22 threads | |
| RAM | 30 GiB total, **~6.6 GiB free** | tight for heavy nested labs |
| Disk | btrfs, 952 G, **91 % full (~90 G free)** | needs cleanup/extra disk for VM images |
| Virt | `/dev/kvm` present, `kvm_intel nested=Y`, libvirt/qemu installed | can run nested PVE/NAS guests |
| Tooling present | tofu, kubectl, talosctl, helm, ansible, nix, docker (124 images) | at audit time; `just lab-tools` now installs kind, flux, etc. |

## Open hardware questions
- Is the Tesla P4 passthrough stable under load, and which driver/VM combo is used?
- Any spare disks/NVMe available to reduce the workstation disk pressure for the lab?
- Is there a second machine available to host lab fixtures (so labs don't contend with prod)?
