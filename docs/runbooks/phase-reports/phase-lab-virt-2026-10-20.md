# Phase report — local libvirt lab run

Date: 2026-10-20

## 1. What was inspected

- `docs/lab.md`, `docs/runbooks/talos-bootstrap.md`, `scripts/lab/virt/` (`up.sh`, `guests.tsv`, `lib.sh`).
- Guest state on the lab VMs only: `talosctl` (volumes, services, etcd), `kubectl` (nodes, pods, EndpointSlices,
  HelmReleases), pressure stall info inside the control plane guest, NAS listeners (`2049`, `445`).
- Host: read-only. No real host was touched.

## 2. What changed (with file paths)

- `scripts/lab/virt/` — NAS cloud-init seed attached as a read-only virtio disk; `talos_wait_installed` (waits for
  the `STATE` volume); `bootstrap` retried while Talos answers *not available yet*; static per-node network
  config (`STATIC_NET=1`, default); Image Factory installer; `LAB_DISK_CACHE` (default `unsafe`);
  `guests.tsv` control plane 3 GiB, worker 6 GiB.
- `talos/patches/common.yaml` — service CIDR `10.96.0.0/16`, pods `10.244.0.0/16`.
- `kubernetes/` — all 11 HelmReleases set install/upgrade remediation `retries: 3` (`kubernetes/README.md`).
- `kubernetes/overlays/lab/infrastructure/kustomization.yaml` — lab-only patch: local-path `nodePathMap` points at
  `/var/local-path-provisioner` (EPHEMERAL). The lab worker has no Talos user volume, so
  `/var/mnt/local-path-provisioner` was on a read-only filesystem and every local-path PVC stayed Pending. A second
  disk was ruled out: production's volume is 90 GiB, the lab worker disk is 40 GiB.
- `kubernetes/infrastructure/monitoring/release.yaml` — **production bug**: Prometheus crash-looped with
  `open /prometheus/queries.active: permission denied` (local-path hostPath volumes are root-owned and ignore
  `fsGroup`). Added a `init-data-permissions` chown initContainer (busybox, digest-pinned, `CHOWN` capability only).
- Authentik — **production bug**: the chart renders its own Secret named `authentik`, which collided with the SOPS
  Secret of the same name, so the secret key and PostgreSQL password went missing. The user Secret is now
  `authentik-credentials` in `kubernetes/apps/authentik/release.yaml`, `kubernetes/apps/authentik/backup.yaml`,
  `scripts/secrets/gen-lab-secrets.sh` and the lab overlay (new `authentik-credentials.sops.yaml`). Recovery was a
  one-off cluster action: suspend the HelmRelease, `helm uninstall`, delete the stale PostgreSQL PVC, resume.
- `docs/backup-matrix.md` — the Secret is named `authentik-credentials`.
- `docs/lab.md` — sizing note, status and known issues rewritten, long lines wrapped.
- `docs/PROJECT-PLAN.md` — lab items, Flux on 1.37.1, log row.
- `docs/runbooks/README.md` — index entry for this report.

## 3. Design rationale

- A Talos node's install state is the `STATE` volume, not the machine stage, so that is what `up.sh` waits for.
- `ghcr.io/siderolabs/installer` is not published for v1.14; the Image Factory installer is.
- The default `10.96.0.0/12` service CIDR overlaps the lab network `10.99.100.0/24` and the storage link, so it is
  narrowed to a `/16`. Pods stay on `10.244.0.0/16`.
- `cache='none'` made etcd fsyncs queue behind other heavy IO on the workstation NVMe (cargo builds). etcd timed
  out (*etcdserver: request timed out*), the API server dropped out and the kube-prometheus-stack install failed
  mid-CRD. The guests are disposable, so `cache='unsafe'` is acceptable.
- At 2 GiB the control plane ran its DaemonSets plus `csi-nfs-controller` (MetalLB `frr-k8s` and speaker, Cilium,
  `cilium-envoy`, `csi-nfs-node`) under memory pressure about 72% and CPU pressure about 94%.
  `kube-controller-manager` and `kube-scheduler` kept losing leader election, EndpointSlices were never
  populated, and Flux saw *no route to host* to `source-controller` and the Git server (Cilium rejects services
  with no endpoints). At 3 GiB memory pressure is about 0.
- Flux's default of 0 remediation retries meant a failed install never retried; `retries: 3` fixes that.

## 4. Validations/tests run

| Check | Command | Result |
|---|---|---|
| NAS reachable and configured | cloud-init seed as virtio disk; probe `2049`, `445` | NFS at `/mnt/main/k8s` and SMB serving |
| Talos install | `just lab-virt-up --only lab-talos-cp` | `STATE` ready, bootstrap succeeded |
| Worker join | `just lab-virt-up --only lab-talos-wk` | joined |
| Nodes | `kubectl get nodes` | both `Ready`, Talos v1.14.4 / K8s v1.37.1 |
| Flux wiring | `just lab-virt-flux` | Flux up; adopted bootstrap Cilium (`UpgradeSucceeded`) |
| HelmReleases | `flux get hr -A` | cilium, metallb, cert-manager, csi-driver-nfs, traefik, local-path Ready |
| Git server egress | `apk` install in the pod | works |
| Kustomizations | `flux get ks -A` at `clean-slate@f61c006` | `infrastructure`, `infrastructure-configs`, `apps` Ready |
| All pods | `kubectl get pods -A` | Running or Completed |
| NFS end to end | throwaway `nas-nfs` PVC and pod | bound to `10.99.100.10:/mnt/main/k8s`; file written and read |
| App PVCs | `kubectl get pvc -A` | audiobookshelf-library, immich-library, authentik-db-backups Bound on `nas-nfs` |
| Issuers | `kubectl get clusterissuer` | `internal-ca`, `selfsigned-bootstrap` Ready; `letsencrypt-*` not Ready (expected) |
| MetalLB | `kubectl get svc -A` | pool `10.99.100.100-199`; Traefik `.100`, `technitium-dns` `.101` |
| Technitium DNS | forward lookup and reverse of `1.1.1.1` against `10.99.100.101` | answers; reverse is `one.one.one.one` |
| Technitium zone bootstrap | CronJob result | `lab.ardw.be` zone with apex and wildcard A records to `10.99.100.100` |
| Apps | `flux get hr -A` | authentik (PostgreSQL, server, worker), immich (server, machine-learning, PostgreSQL, Valkey), audiobookshelf Ready |
| Markdown lint | `npx --yes markdownlint-cli2@0.23.3 "**/*.md"` | 0 issues |

## 5. Actual results

- The old *Talos install did not complete with DHCP* issue is resolved: the install completes, the control plane
  bootstraps and the worker joins. Both nodes are `Ready` on Talos v1.14.4 / Kubernetes v1.37.1.
- All 3 Kustomizations and all 11 HelmReleases are Ready at `clean-slate@f61c006`; every pod is Running or Completed. `source-controller` storage is an `emptyDir`, so after a node restart
  every HelmRelease is briefly `SourceNotReady` until artifacts are fetched again (benign).
- `letsencrypt-staging` and `letsencrypt-production` are not Ready (`secret "cloudflare-api-token" not found`).
  Expected: out-of-band production credential, and there is no ACME in an isolated lab.
- Not verifiable in the lab: the ACME issuers, the Technitium API login (the API endpoint responds; no admin
  password in the lab), the export inspected on `lab-nas` directly, and the Proxmox/UniFi fixtures.
- The worker did not need more memory: about 4.3 GiB free at 6 GiB.
- Markdown lint: `markdownlint-cli2@0.23.3 "**/*.md"`: 0 issues in 42 files.

## 6. Risks / unresolved issues

- **Production control-plane sizing.** `docs/decisions.md` and `docs/architecture.md` size `talos-cp-1` at
  2 GiB. The lab needed 3 GiB with the same stack. Recommend revisiting (3 GiB) before the cutover; the
  decisions are not changed here.
- `cache='unsafe'` drops the guests' flushes; a host crash can cost the lab disks. Lab only.
- `source-controller` on `emptyDir` re-fetches after any restart (benign in the lab).
- The Prometheus and Authentik fixes are production bugs found in the lab; the Authentik Secret rename must
  be reflected in the production SOPS Secret before the first production apply.
- The TrueNAS fixture status is in the 2026-10-21 addendum. The Proxmox and UniFi fixtures are built.

## 7. Manual actions still required

- None for the lab guests beyond running `just lab-virt-*`.
- Owner decision on the production control-plane RAM (section 9).

## 8. Live change made?

Lab VMs only (libvirt guests and networks on the workstation). No real host, cluster or network was changed.

## 9. Needed next (approval / info / gate)

- Decide whether `talos-cp-1` moves from 2 GiB to 3 GiB in `docs/decisions.md` and `docs/architecture.md`.
- Provide the production `cloudflare-api-token` out of band before the production issuers can become Ready.

## Addendum: UniFi fixture and backup proof (2026-10-20)

**UniFi fixture.** `just lab-unifi-plan` against a self-hosted Network Application 10.6.106 on `127.0.0.1`:
plan 1 add, apply, network checked on the controller, second plan "No changes", provider 0.59.0. Bug found and
fixed in production code: the network needed `setting_preference = "manual"`
(`infrastructure/environments/homelab/unifi/k8s-network.tf`). Unproven: the API-key path (a self-hosted
controller has no API keys), UDM gateway/zone behaviour, and the real VLAN 20 conflict gate.

**Backup proof.** Immich and Authentik dumps ran from CronJob-derived Jobs and restored with
`scripts/backup/db-restore-test.sh` into a throwaway postgres (71 and 230 tables, equal to the `pg_restore
--list` counts). restic backup, check and `restic-restore-diff.sh` were clean, and a corrupted copy made the diff
fail. Both size guards fired (dump: Job failed, `DatabaseBackupJobFailed` pending; restic: exit 1, stamp
unchanged), and the freshness check reported a stale stamp. Production bugs found and fixed: the Immich dump
`securityContext`, partial dumps left as the newest `.dump`, `restic-check.sh` running `rm -rf` on a non-empty
restore directory, and the `maxdepth` listing. Unproven: the real offsite target, installed systemd units, the
SMTP mail path, the real TrueNAS uid export.

## Addendum (2026-10-21)

**Proxmox fixture.** `just lab-pve-plan` against a nested Proxmox VE 8.4 guest (`lab-pve`, `10.99.100.20`), provider
`bpg/proxmox` 0.116.1: plan 3 to add, apply, second plan "No changes", destroy 3, run twice. Unproven: booting the
Talos VMs under Proxmox, and the real host's datastore, bridge, VLAN tag and token privileges.

**OS-upgrade proof.** On the Proxmox fixture, bumping the Talos version in `versions.yaml` (v1.14.4 to v1.14.3)
planned "1 to add, 0 to change, 1 to destroy": only `proxmox_download_file.talos`. After the apply the VM disks were
unchanged and a re-plan was clean. `infrastructure/modules/talos-vm/main.tf` ignores `disk[0].file_id` and
`disk[0].import_from`. The module README explains why a version bump cannot upgrade or replace nodes.

**TrueNAS fixture.** `just lab-truenas-plan` against TrueNAS SCALE 25.10.7 (`lab-truenas`, `10.99.100.21`), provider
`truenas/truenas` 1.5.14: plan 3 to add, apply, an API check (dataset `main/k8s`, NFS share `/mnt/main/k8s` with
`maproot root` and networks `["10.99.100.0/24"]`, a 14-day snapshot task), second plan "No changes". No destroy,
because of `prevent_destroy`. The plan script accepts only `wss://10.99.100.<n>/api/current`. Unproven: hercules-nas
itself (24.10.2.4, owner upgrade pending), 25.04, and a Talos node mounting the export.

**Technitium.** The DNS pod crash-looped after a restart (`NullReferenceException` in
`InspectAndFixZonePermissions`), and 15.6.1 did not save `auth.config`. Chart 1.13.5 (Technitium 15.6.2) fixes both
(TechnitiumSoftware/DnsServer#2233). After the bump: every HelmRelease Ready, and the DNS service answered with the
`10.99.100.100` record.

**Lab re-verified.** Dumps, restore tests, the NFS PVC and MetalLB addresses are fine on the current tree.

**Backup alert path.** `scripts/backup/test/alert-selftest.sh` (`just backup-selftest`, also in CI) runs
`backup-alert.sh` against local SMTP sinks with a throwaway cert. It delivers over smtps and STARTTLS with the netrc
login: the envelope has both recipients, and the subject and body name the unit. It fails a bad login (curl 67), an
untrusted cert (60), a server that offers no TLS (64, nothing sent in clear) and a missing URL (1). Fixed: the `To:`
header listed the recipients space-separated, which is not a valid RFC 5322 address list. `systemd-analyze verify`
passes on copies of all seven units with stub binaries. Unproven: a real SMTP provider.

**Prometheus to mail, in the lab.** A throwaway Job `immich/immich-db-dump-alerttest` (the dump template with
`/bin/false`, no volumes) failed at 09:02 UTC. `DatabaseBackupJobFailed` went pending at 09:02:48 and firing at
09:07:48 (`for: 5m`), and Alertmanager routed it to `email` at `critical`. With the HelmRelease suspended, the live
Alertmanager config was pointed at `smtp-sink.py` in a throwaway namespace (STARTTLS, AUTH with the password from the
mounted `alertmanager-smtp` Secret). It delivered `[FIRING:1] DatabaseBackupJobFailed immich (...)` with the summary
and the `kubectl logs` hint, and `[RESOLVED] ...` five minutes after the Job was deleted. Everything was restored and
the HelmRelease resumed; no repo change was needed. Also seen: the lab Git server pod comes back empty after the
guests are power-cycled, so Flux stays NotReady until `just lab-virt-flux` (as `docs/lab.md` says).

**Backup units on `lab-nas`.** The harness now gives `lab-nas` a lab-only SSH key (`just lab-nas-ssh`). The units
and scripts were installed per `scripts/backup/README.md` with restic 0.14 (Debian 12) against a local throwaway
repository. `homelab-backup` made a snapshot and passed retention and `restic check`; `homelab-backup-check` read 10%
of the packs with no errors; `homelab-backup-freshness` passed. With a `smtp-sink.py` sink in the guest (trusted via
`CURL_CA_BUNDLE`), a backup pointed at a missing repository triggered `OnFailure=` and mailed `[homelab]
homelab-backup.service failed on lab-nas...` with the restic error in the journal tail, and `BACKUP_MAX_AGE_HOURS=0`
mailed the freshness failure with the `STALE` line. All three timers were scheduled, and a drop-in moving the freshness
timer a minute ahead fired it on time. Fixed: under systemd restic had no `$HOME` and ran without a cache; both restic
services now set `CacheDirectory=homelab-restic` and `RESTIC_CACHE_DIR`. The timers are left disabled in the lab.

**Still owner-gated.** The offsite backup test (no target or credentials), the UniFi API-key path and UDM
behaviour, a real SMTP provider, and everything on poseidon and hercules-nas.
