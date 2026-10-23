# Decisions

> Append-only record of the decisions that shape the build: **what**, **why**, and **what it replaces**.
> Status values: **decided** · **provisional** (accepted now, revisit with evidence) · **open**.
> Phase tracking lives in `docs/PROJECT-PLAN.md`; this file is the reasoning.

## 1. Scope and target environment

### 1.1 — The platform is built and proven as VMs on the workstation — *decided 2026-10-16*

Everything (Proxmox, a NAS stand-in, Talos, Kubernetes, Flux, apps) is developed and validated in local
**libvirt / virt-manager** guests. Nested virtualisation is available on this machine (`vmx`,
`kvm_intel nested=Y`, 22 threads), which is what makes this practical.

**Why:** the owner wants test-driven development of the whole stack with zero risk to production data.
The physical hosts are never the test bed.

### 1.2 — The physical servers are read-only reference until an owner-executed cutover — *decided*

`poseidon` (Proxmox) and `hercules-nas` (TrueNAS) receive **no writes of any kind** — not even additive ones.
This replaces the earlier model of "the owner wipes, then an agent reconfigures".

**Corollary:** findings about production are *recorded*, not fixed. See §6.

### 1.3 — Cutover is owner-executed ISO installs; everything after that is IaC — *decided*

The owner will, in this order: (1) make sure **all** data is properly backed up, (2) manually install Proxmox VE
and TrueNAS **from ISO**, (3) apply this repo's IaC. Everything after the ISO install must come from the repo —
any hand-made configuration is a defect to be fixed in IaC, not a shortcut.

### 1.4 — Nothing is wiped without an explicit, per-operation go-ahead — *decided*

Supersedes any earlier text implying a wipe. Consequently the fate of the `main` RaidZ3 pool
(preserve/import vs rebuild) is **deferred to cutover**, once the owner's backups are verified — it is not a
decision we can make in advance, and we will not make it for them.

**Outcome, 2026-10-21:** the owner chose to rebuild, and wiped and recreated the pool by hand. `main` is now one
**RAIDZ2** vdev of all 8× 4 TB disks (two-disk redundancy, about 21.8 TiB of data space before ZFS overhead), with
the 1 TB NVMe as a single-device **log (SLOG)** instead of L2ARC. Ashift and compression are the TrueNAS defaults.
The name `main` is kept, so the `/mnt/main/k8s` contract (`infrastructure/environments/homelab/truenas/README.md`)
still holds. Why:

- RAIDZ2 over RAIDZ3: two-disk redundancy is enough for 8× 4 TB with backups, and it gives one more disk of space.
- RAIDZ2 over dRAID2: dRAID pays off with many disks and distributed spares. With 8 disks and no spare, it only
  adds fixed-width stripes that waste space on small blocks.
- SLOG over L2ARC: the NAS serves sync writes (NFS for Kubernetes, SMB Time Machine), which a log speeds up. With
  32 GiB of RAM, an L2ARC mostly took RAM away from the ARC. The P3 Plus has no power-loss protection, so it
  speeds up sync writes but doesn't make them safer than the pool alone. A second NVMe can be added later as a
  mirror (Extend in the UI). Accepted risk: §4.4.

## 2. Addressing

### 2.1 — A new K8s VLAN, not a slice of the server VLAN — *decided*

`10.20.0.0/24` on VLAN 20. UDM gateway `10.20.0.1`; nodes `10.20.0.11–29`; MetalLB pool `10.20.0.100–199`.

**Why:** keeps cluster traffic off the management segment, and adding a VLAN is purely additive to the
existing UDM configuration (the UniFi policy is additive-only).

### 2.2 — The storage link moves off link-local, to a /29 the Talos nodes join — *decided 2026-10-21* (MTU provisional)

Today: `169.254.10.20` ↔ `169.254.10.10` (link-local) over the 10 GbE direct link. Target: `10.99.0.0/29`, no
gateway, MTU 9000:

| Address | Host | Where it is set |
|---|---|---|
| `10.99.0.1` | poseidon (`vmbr1`) | proxmox root `storage-link.tf` |
| `10.99.0.2` | hercules-nas (`bond1`) | truenas root `storage-link.tf`; `NFS_SERVER` |
| `10.99.0.3` | talos-cp-1, second NIC (`net1` on `vmbr1`) | `talos/patches/network-controlplane.yaml` |
| `10.99.0.4` | talos-wk-1, second NIC | `talos/patches/node-talos-wk-1.yaml` |
| `10.99.0.5` | talos-wk-2, second NIC | `talos/patches/node-talos-wk-2.yaml` |

**Why a /29 (2026-10-21):** the cluster mounts NFS from the NAS (§4.2), and the Talos nodes live on
`10.20.0.0/24`, off the old `/30`. A NIC on the link gives them a direct path: no routing or NAT on poseidon, the
NAS sees each node's own address, and the exports allow `10.99.0.0/29` only. The node's kubelet and etcd
addresses stay pinned to `10.20.0.0/24`.

Link-local *works*; the reason to leave it is that it is unconventional and easy to misdiagnose. MTU 9000 stays
**provisional** until throughput is measured at cutover.

### 2.3 — Container CIDRs are identical in every environment — *decided*

Pods `10.244.0.0/16`, Services `10.96.0.0/16`. They are cluster-internal and never routed, so keeping them
identical between lab and production keeps manifests portable and stops "works in lab" divergences.

Services were the Talos default `10.96.0.0/12` until 2026-10-20, when the first lab bring-up flagged it
(Talos diagnostic `address-overlap`). A /12 spans `10.96.0.0–10.111.255.255` and so covers `10.99.x`, the lab
network and storage link, which means a ClusterIP could land on a node address. The /16 is pinned in
`talos/patches/common.yaml` and keeps `10.96.0.1` (API) and `10.96.0.10` (CoreDNS).

### 2.4 — Lab addressing is disjoint from production addressing — *decided*

Lab nodes/VIPs `10.99.100.0/24` (MetalLB `10.99.100.100–199`); lab storage link `10.99.101.0/30`.

Never use: `10.0.0.0/16` (house LAN), `10.10.0.0/16` (server VLAN 4), `169.254.0.0/16` (link-local),
`172.16.0.0/12` (NAS Docker bridges), `100.64.0.0/10` (Tailscale).

### 2.5 — IPv6 disabled on the new segments; the house LAN is left alone — *decided*

UniFi warns that IPv6 DNS can bypass custom IPv4 DNS. Leaving that implicit is precisely how the stale-resolver
problem in §6.1 stayed invisible for as long as it did.

### 2.6 — Zone model: two existing segments kept, three new ones added — *decided*

Zones exist to separate trust levels, not to look tidy. The two live segments already provide most of that
separation, so they are **kept exactly as they are**: renumbering them would touch every existing client and
risk locking us out of the interfaces we manage from.

| VLAN | Zone | Subnet | Status |
|---|---|---|---|
| 1 | HOME | `10.0.0.0/16` | existing; household devices, untouched |
| 4 | MGMT | `10.10.0.0/16` | existing; management interfaces, untouched (name clarified only) |
| 20 | K8S | `10.20.0.0/24` | new — the cluster (§2.1) |
| 30 | SERVERS | `10.30.30.0/24` | new — workload VMs, separated from management |
| 40 | IOT | `10.30.40.0/24` | new — smart-home and consumer devices |
| 60 | GUEST | `10.30.60.0/24` | new — visitors: internet only |

The third octet of every new zone **is its VLAN ID** (`10.30.<vlan>.0/24`), so the numbering is
self-describing and cannot collide with `10.0/16`, `10.10/16`, `10.20/24`, `10.99.x`, pods or services.

**HOME stays on VLAN 1 and is not converted.** Moving household devices to a new VLAN would mean re-connecting
every phone and laptop — precisely the friction this project refuses to create. Household devices keep their
addresses and keep working; the new zones are purely additive.

**Migration is per device and optional.** Nothing is forced. The IOT move is the risky one: Google/Nest
devices may need re-pairing, and mDNS/Bonjour discovery (casting, printers, AirPlay) **does not cross VLANs
without an mDNS reflector**. An IOT pilot must include that reflector and move one device at a time.

### 2.7 — No BACKUP VLAN; backups are controlled by policy, not by segmentation — *decided*

Heavy backup traffic does not traverse the house LAN: NAS↔Proxmox traffic uses the dedicated 10 GbE
point-to-point link (§2.2), and offsite is restic over Tailscale. Household PCs backing up to the NAS are
HOME→SERVERS traffic, governed by **the firewall policy between those zones** — a VLAN would not change it.

A backup VLAN would also buy no bandwidth isolation (it shares the same switch and links) and would not stop
the threat that actually matters — a compromised PC deleting its own backups — because it must reach the NAS
to back up at all. The controls that work are: an append-only repo and/or NAS-side snapshots the client
**cannot** delete, per-client credentials without delete rights, an offsite copy, and a firewall rule
restricting HOME→NAS to the backup service ports only.

A backup zone earns its complexity only with a **dedicated backup appliance**, or a storage protocol that
must not share a broadcast domain (e.g. iSCSI). Neither exists here.

## 3. Compute and Kubernetes

### 3.1 — 1 control plane + 2 workers — *provisional*

| Guest | vCPU | RAM | Disk |
|---|---|---|---|
| `talos-cp-1` | 2 | 4 GiB | 20 GiB |
| `talos-wk-1` | 3 | 16 GiB | 80 GiB boot **+ 100 GiB data** |
| `talos-wk-2` | 3 | 12 GiB | 40 GiB boot **+ 100 GiB data** |

8 vCPU on 4 threads is a 2× overcommit — acceptable, because idle control planes and an idle second worker
use very little. 32 GiB of guest RAM leaves the 8 GiB hypervisor reserve inside the 46 GiB host. **No HA
claim**: one physical host means host loss is cluster loss. Provisional until the lab measures real usage.
The data disks are explained in §3.4; the second worker in §3.6.

The control plane was 2 GiB until the lab measured it (2026-10-21): 2 GiB thrashed, and 3 GiB with 2 vCPU
still crash-looped MetalLB on a cold boot. It runs every DaemonSet as well as the API server and etcd. 4 GiB
costs little on a 46 GiB host (`docs/lab.md`).

### 3.2 — All VM disks live on `local-lvm` (the host SSD) — *decided*

The current 3 TB qcow2 sitting on the NAS over SMB is **not** carried forward: it couples VM I/O to both the
network and the NAS. The SSD is a single point of failure; that is accepted here and recorded in
`docs/risk-register.md`, not hidden.

### 3.3 — CNI: Cilium with kube-proxy replacement — *provisional*

Chosen for **NetworkPolicy** support (a security requirement, not a nice-to-have) and because replacing
kube-proxy saves resources on a 4-thread host. If RAM/CPU proves insufficient in the lab, the fallback is
Flannel, recorded as a deviation with the evidence.

### 3.4 — The worker gets a dedicated data disk for node-local databases — *decided 2026-10-16*

Amends §3.1: `talos-wk-1` gains a **100 GiB data disk** in addition to its 80 GiB boot disk. The control
plane gets none. Sizing lives in `infrastructure/environments/homelab/proxmox/talos.tf`
(`local.talos_nodes["talos-wk-1"].data_disk_gb`); the module
(`infrastructure/modules/talos-vm`, variable `data_disk`) attaches the second disk and inherits the boot
disk's datastore/SSD/TRIM settings.

**Why:** §4.3 places latency-sensitive databases on a node-local `local-path` PV
(`kubernetes/infrastructure/local-path`). On Talos that PV must be backed by a **user volume**
(`talos/patches/worker.yaml`, a `UserVolumeConfig` named `local-path-provisioner`, fixed at 90 GiB and
mounted at `/var/mnt/local-path-provisioner`). A user volume cannot live on the system disk: the boot
disk's `EPHEMERAL` partition spans the disk and consumes its free space. A dedicated disk also isolates
database I/O from the OS disk, and is cleaner than re-partitioning the boot disk.

**Honest limits:** the disk is **node-local and NOT replicated** — this is not HA. Losing the worker, or
recreating it from OpenTofu, loses the Local PVs; the only recovery path is the scheduled logical dumps to
the NAS in §4.3. The +100 GiB still fits the host SSD's `local-lvm` (360 GiB) after both boot disks
(20 + 80 GiB) and the capacity reserve for the hypervisor / a non-Kubernetes VM. (With `talos-wk-2`, see the
disk budget in §3.6.)

**Replaces:** the implicit §3.1 assumption that each VM has exactly one disk (boot only).

**Amended 2026-10-22 (§3.6):** `talos-wk-2` gets the same 100 GiB data disk and user volume. Existing
`local-path` PVs stay on `talos-wk-1`, and their pods follow them there; moving a stateful app to
`talos-wk-2` is a separate, deliberate change (dump, recreate the PVC, restore).

### 3.5 — Untrusted CI build jobs run in Kata microVMs; a base Talos schematic and a GPU one — *decided 2026-10-21, amended 2026-10-23*

The future Forgejo runner (SPEC §12.7) executes repository code it does not trust. Build pods use
`runtimeClassName: kata` (`kubernetes/infrastructure/runtime-classes`): each pod gets its own guest kernel in
a microVM, so a build escape lands in a VM, not on the node. The handlers (`kata` = Cloud Hypervisor,
`kata-qemu` = QEMU) come from the Talos `siderolabs/kata-containers` extension, which needs no machine-config
patch. Builds stay on the worker (the control plane is tainted).

**Schematic:** `talos/schematic.yaml` is the schematic for production (`nocloud`) and the lab (`metal`);
only the installer platform differs. It holds `siderolabs/kata-containers` and `siderolabs/qemu-guest-agent`
(id `TALOS_SCHEMATIC` in `talos/inputs.env`). `talos-wk-1` alone gets `talos/schematic-gpu.yaml`, the same plus
the NVIDIA pair for the Tesla P4 (`siderolabs/nonfree-kmod-nvidia-lts`, `siderolabs/nvidia-container-toolkit-lts`:
the 580 LTS branch, the last NVIDIA driver series that supports Pascal; `talos/patches/gpu-worker.yaml` loads the
driver; id `GPU_TALOS_SCHEMATIC`, which must equal `talos_image_schematic_id` in the Proxmox environment).
*Amended 2026-10-23:* this was one shared schematic, but on a node without the card `ext-nvidia-persistenced`
waits forever for the driver, the boot never completes, and Talos reboots the node when its 70-minute boot
timeout runs out. `talos-wk-2` rebooted every ~70 minutes until it moved to the base schematic. The agent
extension waits forever for the virtio channel, so with this image `talos_qemu_guest_agent_enabled` (Proxmox)
and the libvirt `org.qemu.guest_agent.0` channel (lab) must be on.

**Nested virtualisation is required:** the Talos VMs use CPU type `host` (`talos_cpu_type`, which blocks live
migration; this is a single host) **and** nested KVM must be enabled on the PVE host. The latter is
owner-gated at cutover.

**Build storage** follows §3.4, §4.2 and §4.3. Workspaces and caches are ephemeral: an `emptyDir` or a
`local-path` PVC on the worker's data disk, thrown away with the job. NFS (`nas-nfs`) is only for what must
persist. Build pods get no `hostPath` and no container-runtime socket; images are built rootless
(for example `buildkit` rootless inside the Kata pod), never with a privileged Docker-in-Docker.

### 3.6 — A second worker without the GPU; GPU pods stay on `talos-wk-1` — *decided 2026-10-22*

`talos-wk-2` (3 vCPU / 12 GiB, 40 GiB boot + 100 GiB data, storage link `10.99.0.5`) joins as a second worker.
The Tesla P4 can be passed through to one VM only, and sharing it across VMs needs NVIDIA vGPU licensing,
which this project does not use. So `talos-wk-1` keeps the card and `talos-wk-2` has none.

- **Per-node machine configs.** `scripts/talos/gen-configs.sh` derives `talos/out/worker-talos-wk-1.yaml` and
  `worker-talos-wk-2.yaml` from the shared `worker.yaml` with `talos/patches/node-talos-wk-*.yaml` (the
  node's storage-link address). Only `talos-wk-1` gets `talos/patches/gpu-worker.yaml`; on a node without
  the card the NVIDIA module load would fail. The base `worker.yaml` is never applied in production.
- **GPU pods land on `talos-wk-1`.** They request `nvidia.com/gpu`, which only that node offers, and the
  `nvidia` RuntimeClass pins them there with a nodeSelector (`kubernetes/infrastructure/runtime-classes`).
- **Ordinary pods prefer `talos-wk-2`.** `talos-wk-1` carries a soft taint,
  `nvidia.com/gpu=present:PreferNoSchedule`, so the scheduler keeps it free for GPU work and uses it for
  other pods only when `talos-wk-2` is full. A hard `NoSchedule` would strand the pods whose `local-path`
  PVs live on `talos-wk-1` (§3.4).

**Disk budget:** the five disks provision 340 GiB of the 360 GiB `local-lvm` thin pool (cp 20, wk-1 80 + 100,
wk-2 40 + 100). That is why `talos-wk-2`'s boot disk is 40 GiB rather than 80: it holds only the OS and
ordinary images, while the CUDA images live on `talos-wk-1`. A non-Kubernetes VM then needs the thin pool's
real usage, not its provisioned size, to leave room; check `lvs` before adding one.

**Honest limits:** still one host, so still no HA. The second worker adds capacity and lets a worker drain
for maintenance, but a pod with a `local-path` PV cannot move while its node is down. Talos sets the taint
only when a node registers, so the existing `talos-wk-1` needs it once by hand (`docs/runbooks/talos-bootstrap.md`).

### 3.7 — Pods rebalance after a worker returns; Traefik runs on both workers — *decided 2026-10-23*

The scheduler places a pod once and never moves it. After `talos-wk-2` rebooted on 2026-10-23, every pod that
had moved off it stayed on `talos-wk-1`: 33 pods there (77 % of its CPU requested), `talos-wk-2` empty. And
Traefik, the one way into every app, ran as a single pod, so losing its worker took every Ingress down until the
pod was rescheduled.

- **Descheduler** (`kubernetes/infrastructure/descheduler`), a CronJob every 10 minutes running only the
  balance plugins: `LowNodeUtilization` (pod requests, not live usage: a node under 20 % on CPU, memory and pod
  count is underused, one over 50 % on any is overused), `RemoveDuplicates` and
  `RemovePodsViolatingTopologySpreadConstraint` (soft spreads included). At most 5 evictions per node per run,
  only pods older than 30 minutes, and only when another node can take the pod (`nodeFit`).
- **What never moves:** pods with a `local-path` PVC (their data is on one node's disk, §3.4), DaemonSet pods,
  bare pods, system-critical pods, and anything in `kube-system` or `flux-system`. Pods on the NAS (`nas-nfs`)
  and pods with an emptyDir may move. PodDisruptionBudgets are respected.
- **Traefik: 2 replicas,** a hard hostname spread and a PDB with `maxUnavailable: 1`. cloudflared uses the
  same spread. The spread is `DoNotSchedule` with `nodeTaintsPolicy: Honor`. A down worker carries the
  unreachable NoSchedule taint, so it drops out of the count and both pods run on the other worker. Once it
  returns, the descheduler moves one back. The first version used a soft spread (`ScheduleAnyway`), and the
  scheduler put each evicted pod straight back on the emptier `talos-wk-2`. Both apps got a pointless restart
  every 30 minutes until this was fixed (2026-10-23).

**Honest limits:** a moved single-replica app restarts, so it is down for that restart (seconds; longer for
a slow starter such as Authentik). The balance is by requests, so a pod with no or low requests counts for
little. The soft taint on `talos-wk-1` (§3.6) is a scheduler preference that `nodeFit` does not see, so a pod
evicted from `talos-wk-2` may land on it again; the 30-minute age floor and the per-node cap keep that from
looping fast. Still one host, still no HA (§3.6).

## 4. Storage

### 4.1 — Tiered dataset hierarchy with per-dataset recursive snapshot policies — *decided*

| Dataset | Protocol | Snapshots | Offsite |
|---|---|---|---|
| `main/tier1/{arthur,jolien,dunia}` | SMB | hourly / 30 d | yes |
| `main/apps/{immich,audiobookshelf,seafile}` | NFS | hourly / 14 d | yes |
| `main/k8s` (PVC backing) | NFS export | daily / 14 d | yes |
| `main/backups/timemachine/<mac>` (§5.9) | SMB (Time Machine) | daily / 7 d | no |
| `main/backups/kopia` (§5.9) | NFS export | daily / 14 d | yes |
| `main/media` (Tier-3) | SMB/NFS | weekly / 4 w | no |
| `main/scratch` (Tier-4) | — | none | no |

Replaces the single **non-recursive** daily task, under which child datasets such as `main/ix-apps/...` are
not snapshotted at all.

### 4.2 — Proxmox keeps VM disks local; the NAS is for backups and ISOs — *decided*

NAS storage over **NFS**, content `backup`/`iso` only, prune 7 d / 4 w / 6 m. Never VM disks. SMB remains the
protocol for user shares; NFS is for Linux consumers.

### 4.3 — Latency-sensitive databases stay off the network — *provisional*

Databases run on a `local-path` PV on the worker's data disk (§3.4, on the host SSD), with scheduled **logical dumps** to the NAS.
That keeps DB latency independent of the network while still giving consistent, restorable copies. Revisit only
with measurements (spec §6 explicitly warns against DB-on-network-storage without evidence).

### 4.4 — SLOG without power-loss protection is accepted — *decided 2026-10-21*

The `main` pool (RAIDZ2, 8x 4 TB) has a 1 TB Crucial P3 Plus NVMe as SLOG, and that drive has no PLP (§1.4).
Accepted, because ZFS is copy-on-write: a power cut cannot corrupt the pool. The worst case is losing the last
few seconds of sync writes that were already acknowledged (NFS from Kubernetes, SMB Time Machine), not the pool.

- Mitigation: a UPS with NUT for a clean shutdown. **Not bought yet; owner follow-up.**
- Never set `sync=disabled` on any dataset to "fix" speed. It removes the sync guarantee for every writer.
- Later upgrade, if the risk stops being acceptable: a mirrored SLOG (second NVMe, Extend in the UI) or a drive
  with PLP.

### 4.5 — No HDD spin-down — *decided 2026-10-21*

The Seagate IronWolf drives are rated for 24/7 operation, and the NAS is never idle for long: the hourly tier1
snapshot tasks (`infrastructure/environments/homelab/truenas/tiers.tf`), NFS from Kubernetes, Kopia and Time
Machine would wake them all the time. Frequent spin cycles cost drive wear for roughly 30-40 W saved. TrueNAS
HDD standby stays at "Always On".

This settles the "disk spin-down only if appropriate" line in `docs/SPEC.md` (Low-power operation): for this
hardware and workload it is not appropriate. Revisit only if the snapshot and backup schedule changes to leave
long idle windows.

### 4.6 — Keep steady small writers off the HDD pool; `zfs_txg_timeout` stays at 5 s — *decided 2026-10-23*

With no real activity the 8 HDDs still clicked and seeked every few seconds. The cause was a trickle of about
11 KB/min to `main/k8s` (Seafile writing its log files to the NFS share). ZFS commits a transaction group every
`zfs_txg_timeout` seconds (default 5) whenever anything is dirty, and every commit rewrites metadata and the
uberblocks on all disks, so a few log lines kept every drive busy. An empty transaction group is not written.

- Fix at the source: Seafile logs to stdout, and its leftover log files go to an emptyDir
  (`kubernetes/apps/seafile/seafile.yaml`). New apps follow the same rule: logs, caches and other chatty
  scratch data never go on `nas-nfs`.
- Considered and not done: raising `zfs_txg_timeout` to 30 s (a TrueNAS Post Init script). It would batch the
  remaining writes into fewer commits, but a power cut could lose up to 30 s of async writes instead of 5 s,
  and the setting would live outside OpenTofu. With the writer gone the gain is small, so the default stays.
  Revisit if another steady writer turns up that cannot be moved.

This does not change §4.5: the drives keep spinning.

## 5. Operations

### 5.1 — Alerts: SMTP now, Telegram later — *decided*

Alertmanager receivers. SMTP is the baseline path; Telegram is added once a bot token exists. Alert classes:
backup failures/staleness, disk and pool health, node/pod down, certificate expiry, capacity.

**Relay (owner, 2026-10-21):** `mail.a-line.be` on port 465 with implicit TLS (587 doesn't answer), one login
`homelab@lab.ardw.be` for every sender. Each app has its own From address, so a mail says where it came from
and can be filtered:

| Sender | From | Password Secret |
|---|---|---|
| Alertmanager | `alertmanager@lab.ardw.be` | `monitoring/alertmanager-smtp` |
| Authentik | `auth@lab.ardw.be` | `authentik/authentik-smtp` |
| Seafile | `seafile@lab.ardw.be` | `seafile/seafile-smtp` |
| Grafana | `grafana@lab.ardw.be` | `monitoring/alertmanager-smtp` (env `GF_SMTP_PASSWORD`) |
| Immich | `immich@lab.ardw.be` | none: Immich, set in its admin UI (`docs/runbooks/sso.md`) |
| Backup alerts on the NAS | `backups@lab.ardw.be` | `/etc/homelab/alert.netrc`, outside git |

The relay must let `homelab@lab.ardw.be` send as each of these. The password is the same in every Secret and is
set at the production key ceremony; the lab uses random dummies and never reaches the relay. Alerts go to
`dev@arthurdw.com` until the owner names other recipients.

### 5.2 — No DMZ and no inbound ports — *decided*

Remote administration stays on **Tailscale** (already running on the NAS). Publishing SSH to the internet is
explicitly rejected.

### 5.3 — UniFi: full-access API key under process guardrails — *decided*

Upstream offers no read-only key. Accepted with: plan-only applies, additive-only changes, key kept off-repo,
and a UI configuration export captured as the pre-change baseline. Also fixed by 1.2: no writes at all before
cutover.

### 5.4 — Self-hosted git: HTTPS for the public mirror; SSH over LAN/Tailscale — *decided*

A read-only, anonymous **HTTPS** mirror (`git.lab.ardw.be`) via a Flux-managed `cloudflared`, for
GitHub-outage resilience and fast LAN clones. It mirrors public content only and is never the bootstrap source.

Clone transports for the mirror:

| Transport | What it gives | What each client needs |
|---|---|---|
| LAN (VLAN 20 / server VLAN) | plain `ssh` port 22 to the MetalLB VIP | **nothing special** — plain `git@host:path` with an SSH key |
| Tailscale | plain `ssh`, from anywhere, no open ports | nothing beyond Tailscale itself |
| Cloudflare Tunnel | port 22 carried *through* the tunnel | `cloudflared` on **every** client + `ProxyCommand cloudflared access ssh`, or WARP/Access — never anonymous |

So `git clone git@git.lab.ardw.be:arthur/repo.git` **does** work over the LAN and over Tailscale with an SSH
key. It does **not** work as a plain public endpoint from an arbitrary machine; a public IP + port-forward +
DMZ is explicitly rejected (§5.2).

### 5.5 — Offsite backup target — *deferred*

To be purchased or built. Until it exists, the backup design stays target-agnostic (encrypted, versioned,
restic-style) so the mechanism does not change when the hardware arrives.
No vendor or target is chosen (deferred by the owner, 2026-10-16): S3-compatible or self-hosted REST,
restic-shaped either way. Nothing downstream may assume a specific provider.

### 5.6 — Canonical git remote: GitHub; the self-hosted git is a read-only mirror — *decided 2026-10-16*

**GitHub stays canonical** and is what Flux tracks. Forgejo (self-hosted, in-cluster) is a **read-only
mirror**, used for fast LAN clones and GitHub-outage resilience. The owner pushes to GitHub over SSH.

**Why not writable:** the git server lives *in* the cluster it deploys, so it can never be the bootstrap
source. A writable mirror would mean two copies to keep aligned, and a remote that is unreachable precisely
when the cluster is down — which is when a remote is most useful. Cloning over SSH does not require the mirror
to be writable.

Clone transports (SSH over LAN/Tailscale, anonymous HTTPS for public reads) are in §5.4.

### 5.7 — Internal application zone and certificates — *decided 2026-10-16*

Internal applications are reached at **`<app>.lab.ardw.be`** — a subdomain of a domain already owned, and the
same parent as the git mirror (`git.lab.ardw.be`). Technitium serves those names internally; they are never
resolvable from the internet.

Certificates come from **Let's Encrypt via DNS-01 through Cloudflare**, with a token scoped to `Zone → DNS →
Edit` on the `ardw.be` zone only. Cloudflare hosts `ardw.be`, not a separate `lab.ardw.be` zone, and a token
can only be scoped to a zone it hosts; the issuers' solver selector still limits challenges to `lab.ardw.be`.

**DNS-01 is forced, not preferred:** nothing here is reachable from the internet (§5.2 — no inbound ports, no
DMZ), so HTTP-01 has no path by which the ACME server could reach the host.

**Split horizon — the part that actually protects us:** the public Cloudflare zone carries **only** ACME
challenge TXT records, no A or AAAA records whatsoever. The internal A records pointing at MetalLB VIPs exist
only in Technitium. So neither the application hostnames nor the internal addresses are published, and nothing
becomes externally reachable.

**Shape:** a single wildcard `*.lab.ardw.be` certificate, so adding an application does not mean issuing
another certificate or widening the token.

**Fallback, not default:** the internal CA (`internal-ca`, already scaffolded) remains available for anything
that must not depend on Cloudflare. It is not the default because every household device would need our root
certificate installed or it shows warnings — exactly the friction this project refuses to create (§2.6).

### 5.8 — Private cloud: Seafile, not Nextcloud — *decided 2026-10-21*

The private cloud slot in the application order is **Seafile**, chosen by the owner. The job is file sync
and sharing, which is what Seafile does; Nextcloud's groupware suite is not wanted and would be more to
patch and back up.

What follows from it:

- Its data lives on `main/apps/seafile` over NFS (§4.1). Seafile stores libraries as content-addressed
  blocks, not plain files, so that dataset is not browsable over SMB. A restore goes through Seafile.
- Its database follows §4.3 (node-local, with a logical dump to the NAS like Immich and Authentik). A
  restore needs both the dump and the data dataset from the same point in time.
- Web sign-in at `seafile.lab.ardw.be` (§5.7) goes through Authentik. The desktop and mobile
  clients keep their own tokens.

### 5.9 — Household device backups: Time Machine for the Mac, Kopia for Windows and Linux, Seafile for anywhere-access — *decided 2026-10-21*

The owner chose one mechanism per kind of device:

- **jolien's Mac: Time Machine** to an SMB share on `main/backups/timemachine/jolien`, one account, with a quota.
- **dunia (Windows) and arthur (Linux): Kopia.** The clients back up to a Kopia repository server
  (`kopia.lab.ardw.be`, in the cluster) whose repository is the NFS dataset `main/backups/kopia`.
- **Anywhere-access: Seafile** (§5.8), data on `main/apps/seafile` over NFS.

Why:

- Time Machine is the native Mac client. It restores through Migration Assistant, which nothing third-party
  matches, and it needs no software on the Mac.
- Kopia is open source, runs on Windows and Linux with one tool, encrypts on the client and deduplicates
  across snapshots, so the NAS never sees plain data and incrementals stay small.
- The repository is a plain Kopia repository on the NAS. It restores with the `kopia` CLI from any
  machine that can read the files and has the repository password, **with no Kubernetes involved**. The
  server is a convenience (shared access, per-user accounts), not a dependency of the data.

Consequences:

- The Kubernetes side is `kubernetes/apps/kopia`; the TrueNAS side is
  `infrastructure/environments/homelab/truenas/backups.tf`. Both mount over the storage link like
  `main/k8s` (`k8s_nfs_allowed_networks`). The NFS-from-Talos routing question is resolved (2026-10-21): the
  nodes have their own NIC on the `/29` (§2.2).
- The Kopia repository password is the only key to those backups. It lives in the secrets store, with an
  offline copy (`docs/secrets-and-state.md`); losing it loses the repository.
- Time Machine needs one TrueNAS SMB account per Mac, created by hand (its password stays out of
  OpenTofu). A Mac's quota is the owner's number (`timemachine_jolien_quota_gib`, no default).
- Snapshots follow §4.1. Time Machine and Kopia both keep their own version history, so ZFS snapshots are
  a second line against a damaged or deleted bundle or repository: daily, 7 d and 14 d. They do not
  replace offsite.
- **Offsite** (§5.5, deferred): *Kopia yes*. It is the only copy of the Windows and Linux backups, it is
  already encrypted, and Kopia can sync a repository to S3-compatible storage later. *Seafile yes*. *Time
  Machine no*: it is itself a copy of a device that holds the original, and the bundle is large and slow to
  ship. Revisit if the Mac becomes the only holder of anything irreplaceable (put it in Seafile).
- Kopia and Time Machine protect devices; neither is a file-sharing tier. Documents that more than one
  person needs live in Seafile (§5.8) or `main/tier1` (§4.1).

### 5.10 — Dependency updates: Renovate, automerge only where a merge applies nothing — *decided 2026-10-22*

**Renovate replaces Dependabot.** Dependabot cannot read Flux HelmReleases, OCIRepositories or the pins in
`versions.yaml`, which is where most of the versions in this repo live. Renovate reads all of them
(`renovate.json5`). It also groups each `versions.yaml` pin with its manifest, so the two never drift apart.

**Automerge is narrow.** A merge to `main` is a deploy: Flux applies it within minutes. There are no
pre-upgrade snapshots, and the databases are node-local with nightly dumps only. So automerge covers
changes whose merge touches nothing live: GitHub Actions, CI and workstation tools, and OpenTofu providers,
because the owner runs `tofu` by hand. It also covers patch releases of the stateless infrastructure
charts. Majors, stateful apps, the CNI, DNS, SSO, Flux and Talos/Kubernetes always wait for the owner.
The list and the reasons are in `docs/runbooks/upgrades.md` §8.

**14-day minimum release age.** No update is proposed until the release is two weeks old. That gives
upstreams time to yank broken releases, and it matches the rule already used for Homepage in
`versions.yaml`. ghcr.io is the exception: Renovate gets release dates only from Docker Hub, so ghcr.io
updates are proposed at once, and they never automerge, so that the owner's review replaces the wait.

### 5.11 — No overcommit alerts: the cluster cannot survive a node loss anyway — *decided 2026-10-22*

kube-prometheus-stack's **`KubeCPUOvercommit` and `KubeMemoryOvercommit` are off**
(`kubernetes/infrastructure/monitoring/release.yaml`, `defaultRules.disabled`). They fire when the pods' requests
would not fit on the cluster minus its largest node. Here that is the worker alone or the control plane alone
(§3.1): one physical host, no HA claim, so losing a node is an outage whatever the requests say. The alerts would
fire permanently and teach everyone to ignore mail from Alertmanager (§5.1).

What stays on: `KubeQuotaOvercommit` and the per-node pressure and pod-scheduling alerts, which catch a node that
is really full. Revisit if the cluster ever gets a second host.

### 5.12 — Proxmox and TrueNAS UIs through Traefik, backend TLS verified against pinned certificates — *decided 2026-10-22*

**`pve.lab.ardw.be` and `nas.lab.ardw.be` are Traefik routes** to `10.10.1.1:8006` and `10.10.1.10:443`
(`kubernetes/apps/host-proxies/`, homelab only). They fall under the `*.lab.ardw.be` wildcard, so the browser
gets the Let's Encrypt certificate (§5.7) and no port. The direct host records `poseidon` and `hercules-nas`
stay as they are: SSH names and the break-glass path when the cluster is down.

**Backend TLS is verified, not skipped.** Each route has a ServersTransport whose only trusted root is the
host's own certificate, pinned in a ConfigMap, with `serverName` set to one of its SANs (`poseidon`,
`localhost`). `insecureSkipVerify` would let anything on the path answer for the host. The cost is a refresh
when a host's certificate changes (`docs/runbooks/host-proxies.md`); pinning the PVE cluster CA instead of the
node leaf would remove that for Proxmox.

**No Authentik forward-auth** on these routes: both UIs have their own login, and Proxmox already logs in
through Authentik OIDC (the blueprint allows both the proxied and the `:8006` origin).

**websecure `readTimeout` is 30m**, up from Traefik v3's 60s default, so large uploads (ISOs to Proxmox)
finish. Not unlimited, so a trickling client still gets cut off eventually. Everything else stays at the
chart defaults; no global Traefik setting (cross-namespace references, ExternalName Services) was needed.

### 5.13 — Public share links through a Cloudflare Tunnel, nothing else — *decided 2026-10-22*

Seafile and Immich share links must open for people outside the house. They go through an **outbound-only
Cloudflare Tunnel** (`kubernetes/apps/cloudflared/`, homelab only, opt-in), so §5.2 still holds: no inbound port,
no DMZ.

- **`files.ardw.be`** becomes Seafile's canonical host. The tunnel passes only an **anchored path allowlist**
  of share-link routes (`/f/`, `/d/`, `/u/d/`, their thumbnails, zip and upload endpoints, `/seafhttp/` token
  URLs and `/media/` assets). Everything else, including login, OAuth, the APIs and admin, gets a 404 from the
  tunnel's last rule. On the LAN and Tailscale (with split DNS) the UDM forwards the name to Technitium, which
  answers with the Traefik IP, so the full UI keeps working there. `seafile.lab.ardw.be` redirects to it.
- **`photos.ardw.be`** goes only to **immich-public-proxy**, which serves shared albums anonymously and never
  holds an API key. Immich itself stays at `immich.lab.ardw.be`, internal only.
- **Authentik is never exposed.** Share links need no login.
- **Seafile hardening:** a share-link password is optional, but when one is set it needs 12 characters minimum,
  strength 2. Expiry is optional too, with no default and no maximum. *Revised 2026-10-22:* both were forced
  (password always, expiry 1-90 days, 7 by default). The owner made them a per-link choice for the sharer.
- **Cloudflare objects in OpenTofu** (`infrastructure/environments/homelab/cloudflare/`): the tunnel, its
  config-less credentials and the two proxied CNAMEs. Origins and paths stay in the Git-tracked cloudflared
  config, so a rule change is a reviewed commit, not a dashboard click.

Accepted risks: a link without a password opens for anyone holding its URL, and one without expiry stays open
until the sharer deletes it; Seafile does not rate-limit share-link password guesses (a Cloudflare rate-limit
rule is the mitigation); Cloudflare terminates TLS and sees shared content; uploads through the tunnel are capped at
100 MB per request. Owner steps: `docs/runbooks/public-shares.md`.

### 5.15 — Stremio streaming server: local-only, protected by DNS and routing rather than by a login — *decided 2026-10-22*

**`stremio.lab.ardw.be` runs the official `stremio/server` image** (`kubernetes/apps/stremio/`), pinned by digest.
Addons, library and debrid keys stay in the user's Stremio account; the pod holds no Secret and no debrid service
runs in the cluster. SPEC §12.6 keeps it local-only, so there is no public DNS record and no Cloudflare tunnel
route (the tunnel's ingress lists only `files.ardw.be` and `photos.ardw.be`).

**No Authentik forward-auth.** The Stremio apps call the server cross-origin and without a browser session, so a
login redirect would break them. The server has no login of its own.

**The boundary is internal DNS plus no tunnel route.** A Traefik `ipAllowList` limits sources to RFC1918 and the
Tailscale range, but it is defence in depth: Traefik's Service uses `externalTrafficPolicy: Cluster` (read from
the live cluster), so a client may arrive SNATed to a node or pod address, and an in-cluster caller such as
cloudflared would be a private address too. The list therefore only turns away a stray non-private source; it
does not tell household devices apart. Switching the Service to `Local` would preserve client addresses but
changes every app's path through MetalLB, so it is not done for one app.

**Traefik terminates TLS and speaks plain HTTP to the pod.** web.stremio.com is an HTTPS page and refuses an
`http://` server, so the HTTPS host is required; the image's own HTTPS port needs a stremio.com certificate and is
unused. The pod runs as uid 1000 on a read-only root, with an `emptyDir` for the cache (`sizeLimit` 12Gi). The
cache is disposable; settings reset on a restart. A self-hosted stremio-web was not added: web.stremio.com
works against the HTTPS server.

## 6. Findings that changed the plan

### 6.1 — The NAS has pointed at a dead resolver — *found 2026-10-16, read-only*

TrueNAS is configured with `nameserver1 = 10.10.1.53`, but **nothing listens there** (connection refused on
both UDP and TCP, verified from the workstation). It has been silently falling back to `1.1.1.1`. The UDM Pro
(`10.10.0.1`, dnsmasq) is what actually answers on the server VLAN. Proxmox points at the UDM directly.

So there is no working internal resolver today: Technitium fills a gap rather than replacing a service. Per 1.2 this is recorded, not fixed.

### 6.2 — Production has no offsite copy and its snapshots are non-recursive — *confirmed*

~12 T on a single RaidZ3 with no second copy, and child datasets unsnapshotted. This is a
**recorded risk**, and it is the owner's cutover prerequisite (1.3) rather than something we change now.

Update 2026-10-21: that pool is gone; the owner rebuilt it as RAIDZ2 (1.4). There is still no offsite copy (§5.5),
so the risk stands for whatever lands on the new pool.
