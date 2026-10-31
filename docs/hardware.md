# Hardware Inventory

> Verified **2026-10-16** by read-only discovery (SSH, no changes). Sanitized: no addresses,
> serials, or hostnames-sensitive values here — exact values live in `docs/private/`.
> Re-verify after any hardware change.

## Host 1 — Proxmox (`poseidon`)

| Item | Value | Notes |
|---|---|---|
| OS | Debian 13 (trixie), Proxmox VE 9 (pve-manager 9.2.2), kernel 7.0.2-6-pve | reinstalled by the owner on 2026-10-21; was PVE 8.4.11, kernel 6.8.12-13-pve at capture. Hostname is still `pve`; storage `local` (dir) + `local-lvm` (lvmthin), no guests |
| CPU | Intel Core i5-7400 — 4 cores / 4 threads @ 3.0 GHz | no SMT; limited parallelism |
| Board | ASUS PRIME B250M-PLUS | Super I/O NCT6793D (`nct6775` driver, hwmon `nct6793`; not loaded on boot without `/etc/modules-load.d`), no ACPI conflict |
| Fan headers | `pwm2` CPU_FAN · `pwm3` GPU fan · `pwm1` case-fan hub | all PWM mode; the controller drives `pwm3` only, the others stay on the BIOS curve. GPU fan measured 2026-10-31: ~1050 rpm at 30 %, ~2900 rpm at 100 % (box says 600–4000). Fan-to-card duct is printed PETG: the curve is at 100 % from 70 °C (`docs/decisions.md` §3.8) |
| RAM | 46 GiB usable | currently ~42 GiB consumed by one VM |
| Boot/root disk | 1× Crucial CT525MX300 SSD (~489 GiB) | **SPOF** — no mirror |
| Root layout | LVM: `pve-root` 96 G ext4 (7 % used), `pve-data` 360 G lvmthin (0 % used), 8 G swap | no ZFS on the host |
| GPU | 1× NVIDIA Tesla P4 (`GP104GL`, `10de:1bb3`) | for `talos-wk-1` (OpenTofu mapping `tesla-p4`, `gpu.tf`; Immich ML, `docs/apps/immich.md`), until applied still held by the hand-made passthrough to the `portainer` VM (R14); IOMMU on (`intel_iommu=on iommu=pt`); in IOMMU group 2 with its root port. Passive: cooled by a case fan on its own header, driven by the host from the card's temperature (`docs/runbooks/gpu-fan-control.md`) |
| NIC 1 | 1 GbE (`nic0`; `enp0s31f6` before the PVE 9 reinstall) | management VLAN bridge `vmbr0` (`vmbr0.4` up) |
| NIC 2 | dual-port 10 GbE X520 (`nic1`, `nic2`; were `enp2s0f0`/`enp2s0f1`) | storage fibre to the NAS is on `nic2` (carrier seen 2026-10-21); `nic1` unused; storage bridge `vmbr1` on `nic2` is managed by the Proxmox root (`storage-link.tf`), fixture-proven only; not applied or measured on the real host |
| Pending updates | **185 packages** | patch policy needed |
| SMART (root SSD) | PASSED | |

## Host 2 — TrueNAS (`hercules-nas`)

| Item | Value | Notes |
|---|---|---|
| OS | TrueNAS SCALE 25.10.7, reinstalled by the owner on 2026-10-21 | same version as the L1 fixture; was 24.10.2.4 at capture. Meets the TrueNAS root need of ≥ 25.04 |
| CPU | Intel Core i5-7400 — 4 cores | same class as host 1 |
| RAM | 32 GiB, **non-ECC** | affects reliability posture |
| Board | MSI MS-7A74 | |
| Boot disks | **3× PNY CS900 250 GB SSD in a 3-way mirror** | over-provisioned for boot |
| Data disks | **8× Seagate ST4000VN006 4 TB** (RAIDZ2, width 8) | 2-disk redundancy; RaidZ3 before the 2026-10-21 rebuild |
| Log | **1× Crucial P3 Plus 1 TB NVMe** as SLOG | sync-write log; was L2ARC before the rebuild (`docs/decisions.md` §1.4) |
| NIC 1 | 10 GbE (`enp1s0f0`) | storage link to Proxmox; the TrueNAS root bonds it (`storage_link_interface`, port name unconfirmed) as `10.99.0.2/29`, MTU 9000; fixture-proven only |
| NIC 2 | 1 GbE (`enp4s0`) | management VLAN |
| Boot environments | 5 at capture (`24.04.2.5` → `24.10.2.4`) | reset by the reinstall |
| Boot pool | 3-way mirror, 216 G raw, ~14 G used | |
| Data pool | `main`, rebuilt empty 2026-10-21 | before: 29.1 T raw / 17.8 T alloc, 61 %, frag 17 % |

## Dev workstation (lab host candidate)

| Item | Value | Notes |
|---|---|---|
| CPU | Intel Core Ultra 7 155H — 16 cores / 22 threads | |
| RAM | 30 GiB total, **~6.6 GiB free** | tight for heavy nested labs |
| Disk | btrfs, 952 G, **91 % full (~90 G free)** | needs cleanup/extra disk for VM images |
| Virt | `/dev/kvm` present, `kvm_intel nested=Y`, libvirt/qemu installed | can run nested PVE/NAS guests |
| Tooling present | tofu, kubectl, talosctl, helm, ansible, nix, docker (124 images) | at audit time; `just lab-tools` now installs kind, flux, etc. |

## Open hardware questions
- Why does the GPU fan top out at ~2900 rpm instead of the rated 4000? (an adapter in its cable, or the rating's small print)
- Is the Tesla P4 passthrough stable under load? Planned combo: `talos-wk-1`, Talos nonfree 580 LTS driver (`talos/schematic-gpu.yaml`).
- Any spare disks/NVMe available to reduce the workstation disk pressure for the lab?
- Is there a second machine available to host lab fixtures (so labs don't contend with prod)?
