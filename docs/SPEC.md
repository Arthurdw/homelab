# Canonical Project Brief (governing specification)

> **Source:** provided by the owner (produced with another AI model) and reproduced here as the
> **governing specification** for this project.
>
> **Redaction:** this repository is public, so the one internal RFC1918 resolver address in
> §3.3 has been replaced with `<INTERNAL_RESOLVER_IP>`. Everything else is unchanged.
>
> **Precedence:** where this brief and `docs/PROJECT-PLAN.md` differ, this brief governs unless the
> deviation is explicitly recorded in the plan's decision log (§9 of the plan).

---

# Project: Fully Reproducible, Open-Source Homelab Infrastructure

## 1. Mission

Design, implement, document, and validate a secure, maintainable, fully reproducible homelab infrastructure using Infrastructure as Code (IaC) and GitOps.

The goal is to manage as much of the infrastructure as reasonably possible through version-controlled, open-source tooling. Rebuilding the environment from scratch should be a documented, repeatable process rather than a collection of manual configuration steps.

The project covers:

- Proxmox infrastructure and virtual machines.
- TrueNAS configuration, storage, and backup architecture.
- UniFi network configuration.
- Talos Linux and Kubernetes.
- Flux CD and GitOps.
- Application deployment and persistent storage.
- Local and offsite backups.
- CI/CD, testing, security, upgrades, and disaster recovery.

Act as a senior infrastructure engineer and SRE. Investigate the existing environment, challenge assumptions, identify risks, and make evidence-based architectural decisions.

Do not blindly follow this specification if you identify a materially better approach. Explain your reasoning and document any proposed deviations.

The priorities, in order, are:

1. Data safety and recoverability.
2. Security.
3. Correctness and reproducibility.
4. Maintainability and operational simplicity.
5. Efficient use of hardware and money.
6. Automation and convenience.

## 2. Mandatory operating principles

### 2.1 Audit before implementation

Begin by inspecting the existing repository, infrastructure, configuration, and available documentation.

Before making changes:

1. Inventory what already exists.
2. Identify systems and data that must be preserved.
3. Identify dependencies between services.
4. Determine which configuration is already managed declaratively.
5. Identify undocumented state and potential sources of drift.
6. Propose a target architecture and migration plan.
7. Explain risks, trade-offs, and decisions that require user input.

Do not start by installing software or modifying live systems.

If a necessary detail is unknown, investigate it using available read-only commands or ask a focused question. Never invent hardware details, disk identities, API capabilities, network addresses, provider resources, or backup requirements.

### 2.2 No destructive actions without approval

Treat the existing environment as production, even if it is a homelab.

Never perform any of the following without explicit approval for the specific operation:

- Destroy or recreate a Proxmox VM, container, storage pool, dataset, or filesystem.
- Repartition, format, wipe, or repurpose a physical disk.
- Create, destroy, or fundamentally change a ZFS pool.
- Reinstall TrueNAS or Proxmox.
- Change live UniFi network, VLAN, firewall, DHCP, or DNS configuration in a way that could disconnect management access.
- Run an OpenTofu apply that destroys or replaces existing resources.
- Delete persistent application data or backups.
- Rotate credentials in a way that could lock out administrators or break existing services.
- Perform an untested migration that removes the working source before the destination has been verified.
- Enable automatic deletion or pruning on a backup destination before retention and deletion-protection behavior have been tested.

A successful command is not proof that an operation is safe.

For potentially destructive changes, present the proposed actions, affected resources, expected impact, backup requirements, and rollback plan. Wait for approval.

Do not use `tofu apply -auto-approve` against live infrastructure.

### 2.3 Verify claims

Distinguish clearly between:

- Implemented.
- Validated statically.
- Tested in an isolated environment.
- Tested against live infrastructure.
- Documented but not implemented.
- Planned for a future phase.

Never claim a deployment, test, backup, restore, or recovery procedure succeeded without evidence.

Prefer current official documentation and maintained provider documentation. Verify provider versions, resource availability, API compatibility, and OpenTofu compatibility before implementing integrations.

### 2.4 Keep changes reviewable

Work in small, logical increments. Produce understandable diffs, reusable modules, explicit dependency relationships, and clear documentation.

Do not introduce a large, complicated platform merely because it is possible. Every component should have a clear purpose and a reasonable operational burden.

---

## 3. Existing environment and constraints

Use the following as the initial inventory. Verify details against the actual environment before relying on them.

### 3.1 Proxmox

- Hostname: `poseidon`.
- CPU: Intel Core i5-7400, 4 physical cores and 4 logical CPUs.
- RAM: approximately 48 GiB.
- Proxmox system storage: approximately 525 GB Crucial SSD.
- A Tesla P4 GPU is available for selected workloads, subject to hardware compatibility and passthrough requirements.

The existing Proxmox host has had temporary workloads and data-export activity. Do not use temporary memory usage as the basis for steady-state sizing.

The single SSD is a potential failure point. Account for it in backup and recovery planning.

### 3.2 TrueNAS

There is a separate TrueNAS server with a dedicated 10 GbE fiber connection to Proxmox.

Its current physical disks, ZFS pool layout, datasets, network interfaces, operating-system version, and data-preservation requirements must be inventoried before any rebuild or reconfiguration.

The user is considering rebuilding TrueNAS configuration and potentially reinstalling its operating system. This is not permission to wipe disks or destroy pools.

Treat the current TrueNAS storage and any VM exports being migrated as valuable data until explicitly confirmed otherwise.

The existing main pool has previously been reported as approximately 29.1 TB in capacity, with 17.8 TB allocated and 11.3 TB free. Recheck the actual state and units before planning storage.

Do not assume that all allocated data is important or that all free capacity is available for additional redundancy or snapshots.

### 3.3 Networking

- Network equipment: UniFi UDM Pro.
- The current network includes custom DNS configuration.
- The current DNS configuration has included `<INTERNAL_RESOLVER_IP>` as a primary resolver and `1.1.1.1` as a secondary resolver. Verify current configuration before using these addresses.
- UniFi has warned that IPv6 DNS settings can bypass custom IPv4 DNS settings.
- Proxmox and TrueNAS have a dedicated 10 GbE fiber link.
- An external Dokploy server has an existing Tailscale route to the NAS.

The external Dokploy server and its Tailscale backup path are outside this project's scope. Do not migrate, replace, reconfigure, or make the new cluster dependent on them.

### 3.4 Offsite backup destination

The user is considering hosting an offsite backup machine at a family member's home, specifically their sister's home.

Evaluate this as a potential low-cost, low-power backup destination.

The remote hardware, available capacity, network speed, power availability, physical security, and remote access method are not yet confirmed.

Do not assume the destination already exists or is ready for use.

The objective is to back up important data only, not the entire TrueNAS pool.

### 3.5 General constraints

- Keep the repository public and open source where possible.
- Never commit private credentials, API keys, private keys, generated secrets, unencrypted state, kubeconfigs, or sensitive infrastructure information.
- The environment has limited CPU capacity. Favor simple, efficient designs.
- Prefer established, maintained, open-source technologies.
- Keep management interfaces private.
- Preserve the ability to administer and recover the infrastructure even when Kubernetes is unavailable.
- Minimize ongoing operational work and unnecessary recurring costs.

---

## 4. Target architecture

Evaluate and implement the following architecture, adjusting it when justified by actual hardware and operational constraints.

### 4.1 Infrastructure layer

- Proxmox VE for VM hosting.
- OpenTofu for declarative infrastructure management.
- UniFi API/provider integration for supported network configuration.
- Proxmox provider integration for VM and supported infrastructure lifecycle management.
- TrueNAS API/provider integration for supported storage configuration.
- Talos Linux for Kubernetes nodes.
- A dedicated infrastructure state and credential-management strategy independent of the Kubernetes cluster.

### 4.2 Kubernetes layer

- Talos Linux.
- Kubernetes.
- Flux CD for GitOps reconciliation.
- Helm and Kustomize where appropriate.
- A clearly separated bootstrap process.
- Separate infrastructure and application configuration.
- Explicit version pinning and upgrade procedures.

### 4.3 Application layer

Potential workloads include:

- Technitium DNS.
- Traefik ingress.
- cert-manager.
- Cloudflare DNS-01 certificate issuance.
- Immich.
- Audiobookshelf.
- A suitable private cloud/files application, after choosing between Nextcloud and Seafile.
- Authentik for web-based single sign-on.
- Stremio/debrid-related local workloads where appropriate.
- Forgejo in a later phase.
- Additional services only when they have a clear purpose.

Do not assume every application must run in Kubernetes. Recommend a VM or another deployment model if that is materially safer or simpler.

Do not deploy Jellyfin as part of this project; it is not needed for the proposed setup.

---

## 5. Infrastructure as Code

### 5.1 OpenTofu ownership

OpenTofu should own infrastructure resources that are supported by reliable provider integrations.

Investigate and validate:

- Proxmox VE provider, including `bpg/proxmox` or a better-maintained alternative.
- UniFi provider, including available `ubiquiti-community/unifi` or `BadgerOps/unifi` integrations, subject to verification.
- Official TrueNAS provider, `truenas/truenas`, subject to verification of its current release status, resource coverage, and OpenTofu compatibility.
- Talos-related providers or resources where they provide a clear benefit without making cluster lifecycle management fragile.

Do not assume a Terraform provider is fully compatible with OpenTofu simply because it installs. Test it with the intended OpenTofu version and document limitations.

For every provider, record:

- Source and documentation.
- Exact pinned version.
- OpenTofu compatibility.
- Supported resources and data sources.
- API and minimum server-version requirements.
- Known limitations.
- Whether imports and safe adoption of existing resources are supported.
- How upgrades are reviewed and tested.

Do not use an unmaintained provider for critical infrastructure without explicitly documenting the risk and considering alternatives.

### 5.2 Separate state boundaries

Create separate OpenTofu root configurations and state boundaries for independently managed systems.

A reasonable starting point is:

- `unifi`: network settings and supported UniFi configuration.
- `proxmox`: VMs and supported Proxmox resources.
- `truenas`: supported TrueNAS configuration.
- `talos`: node bootstrap/configuration resources if useful and safe.

Adjust these boundaries based on dependency cycles and actual provider behavior.

Do not place all infrastructure into one giant state file.

Do not let OpenTofu and Flux both own the same Kubernetes resource. OpenTofu manages infrastructure; Flux manages Kubernetes platform and application resources, apart from clearly documented bootstrap exceptions.

### 5.3 Existing-resource adoption

Determine how to import or adopt existing resources into OpenTofu without replacing them.

Before adopting a resource:

1. Inspect the live configuration.
2. Define the corresponding resource.
3. Import it where supported.
4. Run a plan.
5. Explain every proposed change.
6. Resolve unexpected differences before applying anything.

Avoid recreating working resources merely to make the repository look clean.

### 5.4 State management

State must be stored securely and separately from the public repository.

Choose a backend that is practical for this environment, with locking and recovery appropriate to the chosen backend. If a remote backend is not initially practical, use a documented local-state arrangement with strict permissions and independent encrypted backups, and explain the limitations.

Do not store state in the Kubernetes cluster that the state itself is required to rebuild.

Document:

- State initialization.
- Locking behavior.
- Access control.
- State backup and restoration.
- Recovery if the backend is unavailable.
- Safe state migration.
- Provider credentials and environment-variable handling.

Never commit state files, state backups, plan files containing sensitive values, or local provider caches.

---

## 6. TrueNAS architecture and rebuild

TrueNAS must be treated as a first-class part of the infrastructure project, not an undocumented appliance configured manually.

### 6.1 Establish the current state

Before making changes, produce an inventory containing:

- TrueNAS edition and exact version.
- Physical disks, serial numbers, capacities, and device identifiers.
- Existing ZFS pools and their topology.
- Datasets, mount points, quotas, reservations, and relevant properties.
- Snapshot and replication configuration.
- SMB, NFS, and other shares.
- Users, groups, permissions, ACLs, and service accounts.
- Network interfaces, addresses, routes, DNS, and MTU.
- Proxmox storage integrations and mount configuration.
- Kubernetes storage consumers, if any.
- Existing backup and replication destinations.
- Current configuration-export and restore capabilities.

Use read-only methods where possible. Clearly distinguish confirmed facts from assumptions.

Identify which disks or datasets contain VM exports or other data that must be preserved. Do not infer disk identities from `/dev/sdX` names alone.

### 6.2 Separate OS installation from configuration management

Do not assume OpenTofu can safely automate every aspect of a TrueNAS rebuild.

Separate the process into:

1. Operating-system installation and initial access.
2. Physical disk identification and pool creation or import.
3. API enablement and authentication.
4. Declarative configuration management.
5. Validation and service activation.
6. Backup and recovery verification.

The initial OS installation, physical disk selection, and first pool creation may require manual steps or separately verified automation.

Never automate a disk wipe or pool creation merely because a configuration file specifies the desired pool layout.

Prefer importing and preserving an existing pool when that meets the goal. Rebuilding a pool is a separate, explicitly approved operation.

### 6.3 Use the TrueNAS API and OpenTofu where supported

Investigate the official TrueNAS provider, `truenas/truenas`, and compare it with maintained alternatives if resource coverage is insufficient.

Verify the exact supported TrueNAS release, API version, and OpenTofu compatibility.

Prefer the currently supported versioned TrueNAS API rather than building new automation on a deprecated interface.

Manage supported resources declaratively, potentially including:

- Datasets and dataset properties.
- Shares.
- Users and groups.
- Permissions and ACL configuration, where reliably supported.
- Network configuration, only with safe access and recovery procedures.
- Supported services and related settings.
- Snapshot and replication configuration, if the provider supports the required operations.

This list is a target for investigation, not a claim that every resource is supported.

If a required resource is not supported, document the gap and choose the safest alternative: a maintained API integration, a small idempotent script, or a controlled manual procedure. Avoid hiding untracked imperative configuration inside OpenTofu provisioners.

### 6.4 Protect storage operations

Treat pool and dataset destruction as high-risk operations.

Use lifecycle protections where supported, explicit destruction safeguards, clear resource naming, and plan review.

Do not rely on a lifecycle flag alone to protect against every destructive action. Verify the provider's actual destroy and replacement semantics.

Never automatically destroy or replace a pool, dataset, or disk to resolve drift.

Before a major storage change:

- Verify a recoverable backup exists.
- Verify the backup is independent of the target pool.
- Record the pool topology and disk serials.
- Confirm the target disks and intended data loss.
- Produce a step-by-step recovery plan.
- Obtain explicit approval.

### 6.5 TrueNAS storage design

Use local Proxmox SSD storage for VM boot disks where practical, and TrueNAS for persistent data that benefits from centralized storage.

Evaluate NFS and suitable Kubernetes CSI integration based on actual workload requirements.

Do not blindly place all databases on network storage. Consider latency, synchronous-write behavior, failure semantics, backup consistency, and application support.

Avoid adding Ceph or Longhorn merely for redundancy. Evaluate whether their operational and hardware requirements are justified in a single-Proxmox-host environment.

Document which data lives on Proxmox and which lives on TrueNAS, including the recovery implications of each.

---

## 7. Tiered backup architecture

This is a core requirement. Do not back up the entire TrueNAS pool offsite by default.

Design a selective, encrypted, versioned backup system that prioritizes data according to its importance and replaceability.

The backup system must be independent of the primary TrueNAS pool and must remain recoverable if the primary homelab is completely lost.

### 7.1 Classify all data

Classify datasets and workloads into the following tiers.

#### Tier 1 — Critical, irreplaceable data

Examples:

- Personal photos and videos.
- Important documents and personal records.
- Irreplaceable project files and source material that exist nowhere else.
- Other data that would be impossible or very costly to recreate.

Requirements:

- Encrypted offsite backup.
- Versioned recovery, not merely a current mirror.
- Daily backups where appropriate.
- Retention sufficient to recover from accidental deletion or unnoticed corruption.
- Restore tests.
- Monitoring and alerts for failed or stale backups.

#### Tier 2 — Important operational data

Examples:

- TrueNAS configuration exports.
- OpenTofu state and necessary recovery materials.
- Important application databases.
- Application configuration that would be costly to reconstruct.
- Kubernetes and GitOps configuration.
- Essential encrypted secrets and recovery materials.
- Important personal projects and local files that cannot easily be regenerated.

Requirements:

- Offsite backup where appropriate.
- Frequent backup after meaningful changes or on a scheduled basis.
- Secure handling of encryption keys and API credentials.
- A documented restoration procedure.
- Independent access to the data even if Kubernetes is down.

Do not assume that every item of configuration needs to be backed up as a binary file. Some configuration is better recovered from Git, while state and secrets may need independent protected copies.

#### Tier 3 — Replaceable bulk data

Examples:

- Movies and shows that can be downloaded again.
- Linux ISOs.
- Replaceable downloaded media.
- Container images.
- Caches or data that can be regenerated from authoritative sources.
- Other large, replaceable downloads.

Requirements:

- Keep locally according to the user's needs.
- Do not include in offsite backups by default.
- Consider local snapshots only if their recovery value justifies the space.
- Allow explicit per-dataset or per-directory exceptions for data that turns out to be irreplaceable.

#### Tier 4 — Disposable data

Examples:

- Temporary files.
- Build caches.
- Transient downloads.
- Regeneratable thumbnails or derived data.
- Temporary processing output.

Requirements:

- Exclude from local and offsite backups where safe.
- Verify that exclusions do not remove the only copy of important application data.
- Document any application-specific regeneration steps.

Classify data based on recovery cost and importance, not simply its size.

### 7.2 Produce a backup matrix

Create a documented matrix for every important dataset and workload.

Include:

- Dataset or workload name.
- Classification tier.
- Estimated size.
- Whether the data is irreplaceable.
- Authoritative source of truth.
- Local snapshot policy.
- Offsite backup inclusion.
- Backup mechanism.
- Schedule.
- Retention policy.
- Encryption method.
- Restore procedure.
- Monitoring method.
- Reason for inclusion or exclusion.

Use the actual inventory where possible. Clearly label estimates and unknown values.

A newly created dataset must not silently be assumed to be backed up. Require an explicit policy or make unclassified datasets visible in a report.

### 7.3 Local snapshots

Design sensible local ZFS snapshot schedules and retention policies based on:

- Importance.
- Change rate.
- Dataset size.
- Available capacity.
- Recovery requirements.

Use longer history for important datasets where appropriate and avoid wasting capacity on disposable data.

Monitor snapshot growth and pool capacity. Do not let snapshots silently consume all available storage.

Snapshots are useful for local recovery but are not a substitute for independent offsite backups.

### 7.4 Evaluate offsite backup methods

Evaluate two primary approaches.

**Option A: Remote ZFS-capable backup server**

Use a remote machine with suitable disks and ZFS, if practical. Investigate encrypted and authenticated ZFS replication, including incremental replication of selected datasets.

Advantages may include efficient transfer of ZFS snapshots, fast restoration, and predictable storage costs.

Assess the consequences of dataset replication, snapshot retention, and destination deletion semantics. A simple mirror can replicate accidental deletion or malicious changes; ensure retained recovery points remain available.

**Option B: Encrypted, deduplicating file-level backup**

Use a suitable maintained tool such as Restic or Borg, provided it meets the chosen TrueNAS environment and operational requirements.

Advantages may include selective backup, encrypted deduplication, independent retention, and flexibility over which directories or files are included.

Verify the chosen tool's support for the actual TrueNAS edition, execution environment, file permissions, ACLs, extended attributes, and required restore behavior.

Compare:

- Initial backup size.
- Incremental storage growth.
- CPU and memory requirements.
- Bandwidth and transfer duration.
- Ongoing destination capacity.
- Restore speed.
- Ease of management.
- Retention and deletion protection.
- Encryption and key recovery.
- Compatibility with TrueNAS and the destination.

Choose one primary method or a justified hybrid. Do not add multiple systems without a clear benefit.

### 7.5 Offsite machine at a family member's home

Evaluate a low-power remote backup machine at the sister's home as the first potential destination before defaulting to paid cloud storage.

Do not assume the hardware or network has already been provisioned.

Assess:

- Required usable storage capacity.
- Number and type of disks.
- Disk redundancy versus independent backup copies.
- Idle power draw.
- Expected power consumption and electricity cost.
- Internet upload and download bandwidth at both locations.
- Initial seeding time.
- Remote administration.
- Physical security.
- Failure monitoring.
- Remote recovery if the machine stops responding.
- Whether the destination has enough capacity for retained historical versions.
- Whether the backup still works after source credentials are compromised.

A RAID or ZFS mirror at the destination improves availability but is not itself another independent backup.

#### Low-power operation

Investigate scheduled startup and shutdown where supported:

- BIOS/RTC scheduled power-on.
- Wake-on-LAN where reliable.
- A controlled backup window.
- Graceful shutdown after successful completion.
- Disk spin-down only if appropriate for the drive type and workload.
- Monitoring and alerts for missed backup windows.

Do not assume that frequent disk spin-up and spin-down is beneficial. Evaluate actual hardware behavior, reliability, and energy savings.

Ensure the backup job has enough time to finish and that the system does not shut down during a transfer or verification operation.

Do not make the existing external Dokploy/Tailscale backup route a dependency of this design.

### 7.6 Security and deletion protection

The offsite destination must not blindly trust deletion requests from the primary NAS.

Use an appropriate combination of:

- Encrypted transport.
- Encryption at rest or client-side encryption.
- Dedicated backup credentials.
- Least-privilege destination access.
- Versioned retention.
- Protected snapshots or other immutable recovery points where practical.
- Separate administrative credentials.
- Monitoring of unexpected deletions or large changes.

The backup source should not have unrestricted authority to erase every retained historical recovery point.

Validate actual tool and destination semantics rather than assuming a configuration option provides immutability.

Store encryption keys and recovery materials separately from both the source and destination systems. Ensure the user can recover them if the primary homelab is lost.

### 7.7 Backup consistency

Databases and application state must be backed up consistently.

Do not assume copying live database files produces a valid backup.

Use application-supported database dumps, supported backup mechanisms, or a coordinated snapshot procedure.

For Immich, treat the database and media as related recovery components. Document the correct restoration order and consistency requirements.

For OpenTofu state, protect confidentiality and integrity, and ensure a known-good state can be recovered without depending on the Kubernetes cluster.

### 7.8 Monitoring and restore tests

Monitor:

- Last successful backup.
- Last successful verification.
- Backup duration.
- Backup size and growth.
- Destination availability.
- Remaining destination capacity.
- Failed or skipped jobs.
- Unexpected changes in the amount of data being backed up.
- Age of the most recent usable recovery point.

Alert when a backup fails or becomes stale.

Perform non-destructive restore tests for representative files and configuration, and test database restoration where relevant.

A backup is not verified merely because the job reports success.

Record what was restored, where it was restored, what was checked, and any limitations.

Do not test destructive disaster scenarios against the only live copy of important data.

### 7.9 Backup acceptance criteria

The backup system is not complete until:

- The backup matrix is documented.
- Critical datasets have an explicit offsite policy.
- Replaceable media is excluded by default.
- Important operational data has a justified backup strategy.
- Encryption keys are recoverable independently.
- Retention behavior has been tested.
- Failed and stale backups are detectable.
- Representative restore tests have succeeded.
- Full-source-loss recovery steps are documented.
- The offsite system can be maintained without relying on the primary Kubernetes cluster.

---

## 8. Proxmox and VM lifecycle

Use OpenTofu to manage supported Proxmox resources, including VM creation, hardware configuration, networks, disks, and lifecycle settings.

Design a repeatable VM template or provisioning workflow for Talos nodes.

Document:

- VM IDs and naming.
- CPU and RAM allocation.
- Boot disk and storage placement.
- Network interfaces and VLANs.
- Cloud-init or equivalent configuration, where applicable.
- Talos image acquisition and version pinning.
- Resource dependencies.
- How existing VMs can be imported.
- How a VM can be safely replaced or recovered.

Do not allocate more resources than the host can reliably support. Account for Proxmox itself, storage services, CPU contention, memory pressure, and application workloads.

The host has only four physical CPU cores. A three-control-plane Kubernetes cluster on a single physical host does not provide physical-host high availability and may introduce unnecessary overhead.

Recommend a practical initial topology based on measured workload requirements. Make topology and resource sizes configurable rather than scattering hard-coded values through the repository.

Do not claim hardware-level high availability when all Kubernetes nodes depend on one physical Proxmox host.

---

## 9. Network architecture and UniFi automation

### 9.1 Declarative network configuration

Use OpenTofu to manage UniFi resources where the selected provider reliably supports them.

Investigate management of:

- DHCP reservations.
- Supported network and VLAN definitions.
- DNS settings.
- Firewall or traffic-management rules, where supported.
- Other relevant UniFi configuration.

Do not assume all settings exposed by the UniFi UI are exposed by the provider.

For unsupported settings, document a safe manual procedure or a separately tested API integration.

### 9.2 Network plan

Produce a clear network plan documenting:

- Existing LAN and management subnet.
- Proxmox management access.
- TrueNAS management access.
- Kubernetes node network.
- Kubernetes service and pod CIDRs.
- DNS addresses and fallback behavior.
- Optional VLAN boundaries.
- Dedicated storage subnet and interface assignments.
- DHCP ranges and reservations.
- Firewall rules and trust boundaries.

Do not invent the existing network topology. Discover it first.

Evaluate a dedicated storage subnet for the Proxmox-to-TrueNAS 10 GbE link. A private `/24` could be used with static addresses and no default gateway on the storage-only interface. The actual subnet and addresses must be chosen after inspecting the current configuration.

Ensure storage traffic follows the dedicated link when intended, and verify routing, MTU, interface binding, and throughput.

### 9.3 Safe application of network changes

Before applying network changes:

1. Export or record the current configuration.
2. Verify a local or out-of-band recovery method.
3. Separate low-risk and high-risk changes.
4. Plan the order of operations.
5. Validate DHCP, routing, DNS, and management reachability after each relevant change.
6. Provide rollback instructions.

Never combine a network overhaul with an unrelated storage migration unless there is a compelling reason.

### 9.4 DNS architecture

Evaluate Technitium as the primary internal DNS service.

If deployed in Kubernetes, use a stable LAN address and an appropriate service mechanism such as MetalLB, provided the network design supports it.

DNS must not be a circular dependency for cluster recovery. Kubernetes bootstrap, Proxmox, TrueNAS, and management interfaces must remain recoverable if the cluster-hosted DNS service is down.

Document a temporary fallback resolver and a procedure for restoring DNS.

Ensure IPv6 DNS behavior is intentional and does not accidentally bypass the desired internal resolver.

Do not make the entire homelab dependent on a DNS service that only works after the homelab has already bootstrapped.

---

## 10. Talos Linux and Kubernetes lifecycle

### 10.1 Bootstrap

Use Talos Linux for Kubernetes nodes.

Create a reproducible bootstrap procedure that covers:

- Obtaining and pinning Talos images.
- VM creation.
- Machine configuration generation.
- Secure handling of generated secrets.
- Initial control-plane bootstrap.
- Node readiness checks.
- Kubernetes API access.
- CNI installation.
- GitOps bootstrap.
- Recovery of a partially completed bootstrap.

Keep bootstrap configuration separate from normal application deployment.

Do not commit generated Talos secrets, machine secrets, client credentials, or kubeconfig files.

### 10.2 Cluster topology

Evaluate whether one control-plane node is the best initial option for the available hardware. If multiple control-plane nodes are recommended, explain the resource costs and limitations of hosting all of them on one physical server.

Make the design expandable if additional physical nodes are introduced later.

Keep topology, VM IDs, resource sizing, and version settings configurable.

### 10.3 Talos upgrades

Do not let an ordinary OpenTofu apply unexpectedly upgrade Talos or Kubernetes.

Create a separate, explicit upgrade workflow.

It should:

1. Check the current Talos and Kubernetes versions.
2. Verify release compatibility and supported upgrade paths.
3. Pin the intended target version.
4. Verify cluster health and available capacity.
5. Check that configuration and recovery materials are backed up.
6. Upgrade nodes in the documented safe order.
7. Upgrade sequentially where appropriate.
8. Verify node readiness, API availability, networking, and workloads.
9. Stop on failure rather than blindly continuing.
10. Provide a recovery procedure for a failed upgrade.

Use supported Talos tooling and documented upgrade mechanisms. Do not assume rolling back a Talos upgrade is always safe or supported.

Require explicit approval before production upgrades.

### 10.4 Kubernetes resource ownership

Define ownership boundaries:

- OpenTofu: supported infrastructure and VM lifecycle.
- Talos tooling: Talos bootstrap, configuration, and OS upgrade lifecycle.
- Flux: ongoing Kubernetes infrastructure, platform, and application reconciliation.
- Dedicated migration or recovery procedures: exceptional operations not safely represented by ordinary reconciliation.

Avoid resource ownership overlap. Document any necessary exceptions.

---

## 11. GitOps with Flux

Use Flux to manage Kubernetes configuration from the repository.

Organize the repository so infrastructure dependencies are reconciled before dependent applications.

Separate:

- Bootstrap resources.
- Cluster infrastructure.
- Networking and ingress.
- Storage integrations.
- Security and secrets.
- Shared platform services.
- Individual applications.
- Environment-specific configuration.

Use clear dependency ordering and health checks.

Pin Helm chart versions, image versions, and other critical dependencies. Avoid uncontrolled `latest` tags.

Keep configuration reusable without overengineering a single-cluster setup.

Ensure the cluster can be bootstrapped from a clean state without relying on an application that is only available after the cluster is already healthy.

---

## 12. Application architecture

Implement applications incrementally, not all at once.

For each application, document:

- Deployment method.
- Version-pinning strategy.
- Ingress and access policy.
- Persistent data requirements.
- Storage location.
- Authentication.
- Secret requirements.
- Resource requests and limits.
- Backup and restore strategy.
- Health checks.
- Upgrade and rollback limitations.
- Whether it should be publicly accessible.

### 12.1 Traefik and certificates

Evaluate Traefik for ingress and cert-manager for certificate lifecycle management.

Use Cloudflare DNS-01 where appropriate, with narrowly scoped API credentials stored securely.

Do not expose management interfaces, the Kubernetes API, Proxmox, TrueNAS, or sensitive administrative services publicly.

Evaluate Cloudflare Tunnel for selected applications rather than exposing the entire cluster.

### 12.2 Authentication

Use Authentik for web SSO where appropriate.

Do not assume Authentik is a general-purpose RADIUS server. If UniFi integration requires LDAP, RADIUS, or another protocol, assess that requirement separately.

Ensure identity-provider failure does not prevent emergency infrastructure access.

Maintain independent break-glass administrative credentials.

### 12.3 Immich

Plan for Immich's media, database, cache, and machine-learning requirements.

Keep persistent photo and video data on suitable TrueNAS storage where appropriate.

Use a consistent database backup procedure and document the relationship between database state and media files.

Evaluate Tesla P4 passthrough for machine-learning workloads, but verify compatibility before implementation.

Do not assume GPU passthrough is possible or stable without checking the actual host, GPU, driver, VM, and workload requirements.

Personal media should be classified as Tier 1 if it is irreplaceable. It must have an explicit offsite backup policy.

### 12.4 Audiobookshelf

Deploy Audiobookshelf if it fits the intended use case.

Document media storage, persistent application configuration, authentication, and external-access policy.

Classify downloaded or purchased media according to replaceability, licensing, and the user's preferences. Do not automatically assume all media belongs in offsite backup.

### 12.5 Private cloud/files application

Evaluate Nextcloud and Seafile before choosing one.

Compare features, resource use, operational complexity, client support, backup requirements, and suitability for the user's actual workflows.

Document the decision rather than deploying both by default.

### 12.6 Stremio and debrid-related services

Keep these services local-only unless a specific, justified external-access requirement is established.

Avoid unnecessary ingress, public exposure, or additional infrastructure.

### 12.7 Forgejo and CI runners

Consider Forgejo in a later phase.

If runners are added, separate trusted infrastructure jobs from untrusted repository code. Use ephemeral or isolated runners where practical, restrict secrets and permissions, and prevent untrusted jobs from gaining access to the homelab management plane.

Evaluate GitHub Actions and Forgejo runner integration separately rather than coupling the entire deployment system to a single CI provider.

---

## 13. Repository structure

Start with a structure similar to the following and adapt it when justified.

```text
homelab/
├── README.md
├── CONTRIBUTING.md
├── SECURITY.md
├── LICENSE
├── versions.yaml
├── docs/
│   ├── architecture.md
│   ├── hardware.md
│   ├── network-plan.md
│   ├── storage.md
│   ├── backup-policy.md
│   ├── backup-matrix.md
│   ├── security.md
│   ├── secrets-and-state.md
│   ├── upgrades.md
│   ├── disaster-recovery.md
│   └── runbooks/
├── infrastructure/
│   ├── modules/
│   └── environments/
│       └── homelab/
│           ├── unifi/
│           ├── proxmox/
│           ├── truenas/
│           └── talos/
├── kubernetes/
│   ├── bootstrap/
│   ├── infrastructure/
│   ├── security/
│   ├── platform/
│   └── apps/
├── scripts/
├── tests/
└── .github/
    └── workflows/
```

Use separate OpenTofu root configurations and states for independently managed infrastructure.

Avoid putting secrets or live private configuration into reusable public examples. Use clearly named example files and a documented mechanism for supplying private environment-specific values.

Do not create empty abstractions or generic modules that add complexity without reuse.

---

## 14. Secrets and security

### 14.1 Secret handling

Never commit:

- API keys.
- Passwords.
- Private SSH keys.
- Talos machine secrets.
- Kubeconfig credentials.
- Unencrypted SOPS data keys or private age keys.
- Unencrypted OpenTofu state.
- Sensitive plan files.
- Production `.env` files.
- Private certificate keys.
- Unencrypted offsite-backup credentials or recovery keys.

Use an appropriate secret-management approach, such as SOPS with age, where suitable.

Keep the age private key and recovery credentials outside the public repository and outside the sole infrastructure they are needed to recover.

Do not assume encrypted secrets are recoverable without a separately protected decryption key.

Avoid putting secrets into resource attributes, shell history, logs, command output, CI artifacts, or generated files unnecessarily.

Mark sensitive values appropriately, while recognizing that sensitive flags do not necessarily prevent values from being stored in state.

### 14.2 API credentials

Use dedicated service accounts and narrowly scoped API credentials wherever supported.

Separate credentials by system and purpose.

Avoid reusing an administrator's personal API key for all automation.

Document how to rotate credentials safely and recover if a credential expires.

### 14.3 Backup credentials and keys

Use dedicated backup identities.

Do not give the primary NAS unrestricted authority to erase all remote historical backups.

Store backup encryption keys, recovery codes, and destination administration credentials separately from the primary TrueNAS system.

Ensure the user can access the offsite backup and restore data even if the entire homelab, identity provider, and primary password manager are unavailable.

### 14.4 Public repository hygiene

Before publishing or updating the public repository:

- Scan for secrets.
- Check for accidental state files and generated configuration.
- Check for private addresses and hostnames that the user does not intend to disclose.
- Check documentation and examples for leaked credentials.
- Verify `.gitignore` and CI artifact rules.
- Verify that historical commits do not expose newly added secrets.

Do not treat `.gitignore` as sufficient protection for files already tracked in Git.

### 14.5 Network security

Keep management endpoints private and restrict access using network boundaries and firewall policy.

Use TLS for management APIs where supported.

Avoid exposing the Proxmox UI, TrueNAS UI, Kubernetes API, or runner control interfaces to the public internet.

Document the administrative access path and emergency recovery path.

---

## 15. CI/CD and quality gates

Create GitHub Actions workflows that validate the repository automatically.

PR validation must not apply infrastructure changes to the live environment.

### 15.1 OpenTofu validation

For every OpenTofu root configuration, run applicable checks such as:

- `tofu fmt -check -recursive`.
- Initialization without accessing or modifying live infrastructure, using an appropriate backend-disabled validation setup.
- `tofu validate`.
- TFLint.
- Security and misconfiguration scanning using Trivy, Checkov, or a justified equivalent.
- Module tests where useful.
- Formatting and validation of example configurations.

Test commands against the selected OpenTofu version and actual repository structure. Do not assume a command works identically across versions.

Do not require production credentials for ordinary pull-request validation.

### 15.2 Kubernetes and GitOps validation

Validate applicable configuration with:

- YAML syntax checks.
- Kustomize builds.
- Helm linting and rendering.
- Kubernetes schema validation, for example with kubeconform.
- Policy checks using a suitable tool such as Conftest, OPA, or Kyverno CLI.
- Flux configuration validation.
- Detection of unpinned or unsafe image references.
- Secret scanning.
- Dependency and vulnerability scanning.

Use versioned schemas and tool versions where practical. Document any intentional exceptions.

### 15.3 Scripts and documentation

Run applicable:

- Shell linting.
- Shell formatting.
- Markdown linting.
- YAML linting.
- JSON validation.
- Link checks, where reliable.
- Tests for helper scripts.

Use strict typing for any TypeScript or other typed helper code introduced.

### 15.4 Workflow separation

Create separate workflows or clearly isolated jobs for:

1. Pull-request static validation.
2. Main-branch validation.
3. Dependency update checks.
4. Optional isolated integration tests.
5. Manual infrastructure planning.
6. Approved infrastructure application.
7. Talos and Kubernetes upgrades.
8. Backup validation and monitoring where appropriate.
9. Recovery or maintenance procedures, if automation is appropriate.

Production plans and applies must use least-privilege credentials and protected GitHub environments.

Require approval for sensitive deployment operations.

Inspect and communicate destructive changes before application. Do not automatically approve a plan merely because CI succeeded.

Protect against untrusted fork pull requests accessing secrets or privileged runners.

Pin third-party GitHub Actions to reviewed immutable commit SHAs where practical, and maintain a process for safely updating those pins.

Do not run privileged backup-destination commands from untrusted pull requests.

---

## 16. Upgrade and dependency management

Pin important tool, provider, operating-system, chart, and application versions.

Maintain a central version inventory where it improves consistency.

Document how versions are updated, tested, and rolled out.

Separate ordinary dependency updates from changes that require infrastructure maintenance or data migration.

Do not let dependency automation automatically apply a new Talos version, Kubernetes version, provider major version, or storage migration to production.

For significant upgrades:

1. Read upstream release notes.
2. Verify compatibility and upgrade order.
3. Run CI validation.
4. Inspect the plan or rendered configuration.
5. Test in isolation when feasible.
6. Back up relevant data and configuration.
7. Obtain approval where required.
8. Deploy incrementally.
9. Verify service health.
10. Document recovery limitations.

---

## 17. Disaster recovery

A reproducible infrastructure definition is not a backup.

Design a complete recovery strategy covering infrastructure configuration, application data, secrets, and identity access.

### 17.1 Required backup coverage

Evaluate and document backups for:

- Proxmox configuration.
- VM definitions and critical VM data.
- OpenTofu state and backend recovery materials.
- TrueNAS configuration.
- ZFS datasets and snapshots.
- Important application databases.
- Immich media and database consistency.
- Application configuration and persistent volumes.
- Talos bootstrap and recovery materials.
- Flux repository and required secrets.
- Authentication configuration.
- TLS and certificate-related recovery needs.
- Critical external service configuration.
- Offsite backup destination configuration and recovery materials.

Classify each item according to the tiered backup policy in Section 7. Not every item must be copied offsite if it is readily reproducible and nonessential.

### 17.2 Independence

Backups must not all depend on the same physical host, pool, credentials, network, or cluster.

Provide an independent encrypted backup copy for critical data, with a documented destination and retention policy.

Do not modify the existing external Dokploy/Tailscale backup route as part of this project.

### 17.3 Recovery documentation

Write practical recovery runbooks for scenarios including:

- Proxmox host failure.
- Proxmox boot SSD failure.
- TrueNAS operating-system failure.
- TrueNAS pool import or recovery.
- Accidental dataset deletion.
- Loss of Kubernetes control-plane state.
- Failed Talos upgrade.
- Loss of OpenTofu state.
- Loss of cluster-hosted DNS.
- Loss of Authentik.
- Loss of the SOPS/age decryption key or another critical credential.
- Loss of the primary NAS and recovery from the offsite destination.
- Loss or failure of the offsite destination.
- Accidental deletion or corruption replicated to the destination.

Document recovery dependencies in the correct order. DNS, credentials, storage, and infrastructure state may need to be restored before Kubernetes workloads.

### 17.4 Test restores

Perform non-destructive restore tests where feasible.

A backup is not verified merely because the backup job reports success.

Record what was restored, where it was restored, what was checked, and any limitations.

Do not test destructive disaster scenarios against the only live copy of important data.

---

## 18. Implementation phases

Work through these phases in order. At the end of each phase, report the results and wait for approval whenever the next phase requires risky live changes.

### Phase 0 — Audit and architecture

- Inspect the repository and current environment.
- Inventory Proxmox, TrueNAS, UniFi, storage, network, and existing workloads.
- Identify data that must be preserved.
- Verify provider/API capabilities.
- Produce the target architecture.
- Produce a migration plan, risk register, and list of decisions requiring input.
- Identify assumptions that cannot yet be verified.

Do not modify live infrastructure.

### Phase 1 — Repository foundation

- Establish repository structure.
- Add architecture and operational documentation.
- Establish formatting, linting, and validation tools.
- Configure CI.
- Add secret-scanning and repository-hygiene rules.
- Establish version pinning and dependency-management policy.
- Establish a safe state-storage strategy.

Validate the repository locally and through CI where possible.

### Phase 2 — TrueNAS inventory and backup design

- Inventory all disks, pools, datasets, shares, and services.
- Confirm which data must be retained.
- Identify VM exports and other important data.
- Verify the current TrueNAS version and API.
- Test the official provider and any necessary alternatives.
- Define the intended storage and dataset hierarchy.
- Classify datasets into backup tiers.
- Produce the backup matrix.
- Evaluate the offsite machine's likely storage, network, power, and operational requirements.
- Compare candidate backup approaches.
- Document recovery and migration procedures.

Do not wipe disks, create pools, reinstall the operating system, or change production storage yet.

### Phase 3 — Infrastructure IaC

- Implement UniFi, Proxmox, and TrueNAS OpenTofu configurations.
- Add modules only where reuse is justified.
- Support import/adoption of existing resources where possible.
- Validate provider versions and resource behavior.
- Establish safe state storage.
- Add CI validation and reviewable plans.

Start with non-destructive adoption and low-risk resources. Do not apply destructive plans.

### Phase 4 — Approved infrastructure and TrueNAS changes

Once the inventory and plan have been reviewed:

- Obtain approval for each required live change.
- Rebuild TrueNAS only to the extent explicitly authorized.
- Preserve existing pools and data unless a separate destructive operation is approved.
- Configure storage, shares, permissions, and networking.
- Create or adapt Proxmox VMs through OpenTofu.
- Configure supported UniFi resources.
- Validate management access and storage connectivity.
- Configure local snapshots and the approved backup strategy.
- Validate that exclusions do not include irreplaceable data.

Do not bundle unrelated high-risk operations together.

### Phase 5 — Talos and Kubernetes bootstrap

- Pin Talos and Kubernetes versions.
- Create the VM provisioning process.
- Bootstrap the cluster.
- Validate node health and networking.
- Install and validate the selected CNI.
- Establish the cluster bootstrap procedure.
- Secure all generated secrets and access credentials.

### Phase 6 — Flux and platform services

- Bootstrap Flux.
- Establish the GitOps structure.
- Deploy core networking and storage integrations.
- Configure DNS with an independent recovery path.
- Configure ingress, certificates, and secret decryption.
- Validate ordering and health checks.

### Phase 7 — Applications

Deploy selected applications incrementally.

Start with the core platform and then proceed to the user's chosen workloads. Validate persistence, backups, access controls, resource usage, and recovery before treating an application as complete.

### Phase 8 — Backup automation and verification

- Implement the approved offsite backup mechanism.
- Configure encryption, retention, and deletion protection.
- Implement scheduled jobs and low-power operation if using a remote machine.
- Configure monitoring and alerts.
- Verify the first backup and its contents.
- Perform representative restore tests.
- Document destination recovery and key recovery.
- Measure initial backup duration and incremental transfer behavior.

Do not claim the backup system is complete until restore tests provide evidence.

### Phase 9 — Upgrade and operations automation

- Implement documented Talos upgrade procedures.
- Add explicit approval and health checks.
- Implement dependency-update workflows.
- Add operational scripts and runbooks.
- Verify ordinary infrastructure plans do not unexpectedly upgrade the operating system.

### Phase 10 — Disaster recovery validation

- Back up required infrastructure and data.
- Verify access to state and secrets outside the cluster.
- Perform safe restore tests.
- Test the documented bootstrap procedure in isolation where possible.
- Record gaps and required manual actions.
- Produce a final recovery checklist.

Do not claim the system is fully reproducible until the relevant recovery procedures have actually been tested.

---

## 19. Definition of done

### Infrastructure

- Infrastructure configuration is version controlled.
- Provider and tool versions are pinned.
- Supported UniFi, Proxmox, and TrueNAS resources are declaratively managed.
- Existing resources are safely adopted or intentionally recreated with approval.
- Infrastructure states are separated, protected, and recoverable.
- The configuration does not depend on undocumented manual changes.

### TrueNAS

- Current disks and pool topology are documented.
- Data-preservation requirements are explicit.
- Supported configuration is managed declaratively where practical.
- Unsupported configuration has a documented safe procedure.
- Storage and share access are verified.
- Dataset classifications and backup policies are explicit.
- No destructive storage operation has occurred without explicit approval.

### Backup and recovery

- The backup matrix is documented.
- Critical, irreplaceable data is backed up offsite.
- Replaceable bulk media is excluded by default.
- Important operational data has a justified backup strategy.
- Encryption keys are recoverable independently.
- Retention and deletion-protection behavior have been tested.
- Failed and stale backups are detectable.
- Representative restore tests have succeeded.
- Full-source-loss recovery steps are documented.
- Offsite power optimization has been considered if a remote machine is used.
- Backup cost, capacity, and initial transfer requirements are estimated using actual data where possible.

### Kubernetes

- Talos bootstrap is reproducible.
- Versions are pinned.
- Flux manages ongoing Kubernetes configuration.
- Resource ownership boundaries are clear.
- Upgrade and recovery procedures are documented.
- DNS and authentication failures do not make recovery impossible.

### Security

- No secrets are exposed in the public repository.
- State and recovery keys are protected.
- Management interfaces remain private.
- CI permissions are restricted.
- Untrusted pull requests cannot access production secrets or privileged infrastructure.

### CI/CD

- Pull requests run relevant static validation.
- Infrastructure changes are planned and reviewed before application.
- Production applies require appropriate approval.
- Talos upgrades use a dedicated workflow.
- Tests are reproducible and their actual results are reported.

---

## 20. Final reporting requirements

At the end of each phase, report:

1. What was inspected.
2. What changed.
3. Why the design was chosen.
4. Which files were created or modified.
5. Which validations and tests were run.
6. The actual results of those tests.
7. Any risks or unresolved issues.
8. Any manual actions still required.
9. Whether a live change occurred.
10. What approval or information is needed next.

At project completion, provide:

- Final architecture overview.
- Repository map.
- Hardware and resource allocation.
- Network and storage plan.
- Infrastructure state and secret-management design.
- Bootstrap instructions.
- Day-to-day operating instructions.
- Upgrade procedures.
- Backup matrix and retention policy.
- Offsite destination design and expected cost.
- Restore and disaster-recovery runbooks.
- CI/CD overview.
- Known limitations and untested assumptions.
- A list of actions actually completed versus those that remain planned.

Do not optimize for the appearance of completeness. Optimize for an infrastructure system that can be understood, safely operated, recovered, and rebuilt.

## 21. First action

**Do not make changes yet.**

Start with Phase 0 and produce an evidence-based audit of the current repository and infrastructure.

If direct infrastructure access is unavailable, inspect the repository and clearly identify the information that must be collected manually. Prefer read-only discovery commands and explain what each command establishes.

The first deliverable must include:

1. A proposed target architecture.
2. An inventory of known and unknown facts.
3. A TrueNAS data-preservation plan.
4. A dataset and storage design.
5. A tiered backup matrix.
6. An evaluation of an offsite backup machine at the family member's home.
7. A risk register.
8. A phased implementation plan.
9. A list of decisions requiring user input.

Wait for approval before moving into risky implementation or changing live systems.
