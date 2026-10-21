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

## 2. Addressing

### 2.1 — A new K8s VLAN, not a slice of the server VLAN — *decided*

`10.20.0.0/24` on VLAN 20. UDM gateway `10.20.0.1`; nodes `10.20.0.11–29`; MetalLB pool `10.20.0.100–199`.

**Why:** keeps cluster traffic off the management segment, and adding a VLAN is purely additive to the
existing UDM configuration (the UniFi policy is additive-only).

### 2.2 — The storage point-to-point link moves off link-local — *provisional*

Today: `169.254.10.20` ↔ `169.254.10.10` (link-local) over the 10 GbE direct link. Target: `10.99.0.0/30`
(Proxmox `.1`, NAS `.2`, no gateway, MTU 9000).

**Provisional** until throughput and MTU are actually measured at cutover. Link-local *works*; the reason to
change is that it is unconventional and easy to misdiagnose.

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

### 3.1 — 1 control plane + 1 worker — *provisional*

| Guest | vCPU | RAM | Disk |
|---|---|---|---|
| `talos-cp-1` | 2 | 4 GiB | 20 GiB |
| `talos-wk-1` | 3 | 16 GiB | 80 GiB boot **+ 100 GiB data** |

5 vCPU on 4 threads is a 1.25× overcommit — normal, because idle control planes use very little.
**No HA claim**: one physical host means host loss is cluster loss. Provisional until the lab measures
real usage. The worker's data disk is explained in §3.4.

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
(20 + 80 GiB) and the capacity reserve for the hypervisor / a non-Kubernetes VM.

**Replaces:** the implicit §3.1 assumption that each VM has exactly one disk (boot only).

### 3.5 — Untrusted CI build jobs run in Kata microVMs; one Talos schematic for every node — *decided 2026-10-21*

The future Forgejo runner (SPEC §12.7) executes repository code it does not trust. Build pods use
`runtimeClassName: kata` (`kubernetes/infrastructure/runtime-classes`): each pod gets its own guest kernel in
a microVM, so a build escape lands in a VM, not on the node. The handlers (`kata` = Cloud Hypervisor,
`kata-qemu` = QEMU) come from the Talos `siderolabs/kata-containers` extension, which needs no machine-config
patch. Builds stay on the worker (the control plane is tainted).

**Schematic:** `talos/schematic.yaml` is the single schematic for production (`nocloud`) and the lab (`metal`);
only the installer platform differs. It holds `siderolabs/kata-containers` and `siderolabs/qemu-guest-agent`
(id in `talos/inputs.env`; it must equal `talos_image_schematic_id` in the Proxmox environment). The agent
extension waits forever for the virtio channel, so with this image `talos_qemu_guest_agent_enabled` (Proxmox)
and the libvirt `org.qemu.guest_agent.0` channel (lab) must be on.

**Nested virtualisation is required:** the Talos VMs use CPU type `host` (`talos_cpu_type`, which blocks live
migration; this is a single host) **and** nested KVM must be enabled on the PVE host. The latter is
owner-gated at cutover.

**Build storage** follows §3.4, §4.2 and §4.3. Workspaces and caches are ephemeral: an `emptyDir` or a
`local-path` PVC on the worker's data disk, thrown away with the job. NFS (`nas-nfs`) is only for what must
persist. Build pods get no `hostPath` and no container-runtime socket; images are built rootless
(for example `buildkit` rootless inside the Kata pod), never with a privileged Docker-in-Docker.

## 4. Storage

### 4.1 — Tiered dataset hierarchy with per-dataset recursive snapshot policies — *decided*

| Dataset | Protocol | Snapshots | Offsite |
|---|---|---|---|
| `main/tier1/{arthur,jolien,dunia}` | SMB | hourly / 30 d | yes |
| `main/apps/{immich,audiobookshelf,seafile}` | NFS | hourly / 14 d | yes |
| `main/k8s` (PVC backing) | NFS export | daily / 14 d | yes |
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

## 6. Findings that changed the plan

### 6.1 — The NAS has pointed at a dead resolver — *found 2026-10-16, read-only*

TrueNAS is configured with `nameserver1 = 10.10.1.53`, but **nothing listens there** (connection refused on
both UDP and TCP, verified from the workstation). It has been silently falling back to `1.1.1.1`. The UDM Pro
(`10.10.0.1`, dnsmasq) is what actually answers on the server VLAN. Proxmox points at the UDM directly.

So there is no working internal resolver today: Technitium fills a gap rather than replacing a service. Per 1.2 this is recorded, not fixed.

### 6.2 — Production has no offsite copy and its snapshots are non-recursive — *confirmed*

~12 T on a single RaidZ3 with no second copy, and child datasets unsnapshotted. This is a
**recorded risk**, and it is the owner's cutover prerequisite (1.3) rather than something we change now.
