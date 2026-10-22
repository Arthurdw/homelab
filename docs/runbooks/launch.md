# Runbook: launch on the real hosts

The owner's ordered go-live checklist for `poseidon` (Proxmox VE 9.2.2, `10.10.1.1:8006`) and `hercules-nas`
(TrueNAS 25.10.7, `10.10.1.10`). Everything here was proven on the lab fixtures; **nothing has run against the
real hosts yet**. Every apply is gated: the owner is present, reads the plan, and approves it.

This runbook orders the work and gives the checks. The detailed procedures stay in their own runbooks, linked
at each step; follow those, don't copy them.

Rules for every step:

- Run `tofu plan`, read all of it, then `tofu apply`. **Never `-auto-approve`.**
- A secret is never pasted into a chat, a file in the repo, or a command line you keep in history. Export it in
  your own shell (`export NAME='...'`, and `set +o history` first if you want it out of history). Close the
  shell afterwards.
- Stop and ask if a plan shows anything you didn't expect, especially an update or destroy on an object the
  repo doesn't own (`docs/secrets-and-state.md` §4, risk R19).
- Only the steps' own commands touch the hosts. The lab VMs are separate (`docs/lab.md`).

## Order

| # | Step | Gate (it must pass before the next) |
|---|---|---|
| 0 | Pre-flight: data | restore paths are known and the data is safe |
| 1 | Credentials | three credentials exist, nothing in the repo |
| 2 | UniFi root | plan is additive plus the two host-reservation clients |
| 3 | Host network bootstrap | both hosts answer on VLAN 4; the 10 GbE link passes its test |
| 4 | TrueNAS root | pool and datasets as planned, NFS and SMB serve |
| 5 | Proxmox root | the Talos VMs exist |
| 6 | Talos bootstrap | the nodes are Ready |
| 7 | Flux bootstrap | the tree is Ready |

## 0. Pre-flight: data

The first install wiped the pool once already (risk R18). Before any step that can touch storage, confirm
what is still needed and where it can be restored from:

- Read `docs/disaster-recovery.md` §6 (restore without Kubernetes) and the §7 final checklist.
- Read `docs/backup-policy.md` and `docs/backup-matrix.md`; confirm every dataset that holds data you care
  about has a copy that is not on the NAS. The offsite target is still open (`docs/decisions.md` §5.5).
- Confirm the age key, the Talos secrets and the Kopia repository password are held outside the homelab
  (`docs/runbooks/secrets.md` §2 and §6). A rebuilt cluster can't decrypt anything without the age key.

Expected: you can name, for each dataset, where its restore comes from. If you can't, stop here.

Rollback: nothing has changed yet.

## 1. Credentials

Create each one on the real host, then export it in the shell you will run the roots from. The names below
are what the roots read. The `terraform.tfvars` files are already written and gitignored; they carry no
secrets.

**Proxmox (user, role, token).** In a root shell on poseidon (console or `ssh root@10.10.1.1`). The
privileges are the ones proven on the fixture (`scripts/lab/pve-fixture.sh`); PVE 9 has no `VM.Monitor`, so
don't add it. `VM.GuestAgent.Audit` (its PVE 9 replacement) lets the provider read the nodes' addresses from
the guest agent; without it the apply warns with a 403 and the address outputs stay empty. On a host
whose role already exists: `pveum role modify TofuTalos -privs VM.GuestAgent.Audit -append 1`. The three
`Mapping.*` privileges let the proxmox root manage the GPU's cluster resource mapping and attach it to a VM
(`gpu.tf`); on an existing role: `pveum role modify TofuTalos -privs 'Mapping.Audit Mapping.Modify Mapping.Use' -append 1`.

```sh
pveum role add TofuTalos -privs 'Datastore.Allocate Datastore.AllocateSpace Datastore.AllocateTemplate Datastore.Audit Pool.Allocate Sys.Audit Sys.Console Sys.Modify SDN.Use VM.Allocate VM.Audit VM.Clone VM.Config.CDROM VM.Config.CPU VM.Config.Cloudinit VM.Config.Disk VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options VM.GuestAgent.Audit VM.Migrate VM.PowerMgmt Mapping.Audit Mapping.Modify Mapping.Use'
pveum user add terraform@pve
pveum acl modify / --users terraform@pve --roles TofuTalos
pveum user token add terraform@pve tofu --privsep 0
```

The last command prints the token secret once. Read it into your shell without echoing it or leaving it in
the shell history, and paste `terraform@pve!tofu=<secret>` at the prompt:

```sh
read -rs PROXMOX_VE_API_TOKEN && export PROXMOX_VE_API_TOKEN
```

The provider also uses SSH for a few operations (uploading images and snippets), through an ssh-agent only.
`just apply proxmox` uses the key already in your agent; if there is none, it loads `PROXMOX_SSH_KEY` from
`~/.config/homelab/proxmox.env` (default `~/.ssh/id_ed25519`) into a temporary agent for that run. Check root
accepts the key: `ssh -F /dev/null -i <key> root@10.10.1.1 true`.

**Tag colours (optional, once).** Proxmox derives a tag's colour from a hash of its name, and `homelab` and
`kubernetes` land on the same one. The provider cannot set the datacenter tag style, so pin the colours by
hand on the node (or Datacenter → Options → Tag Style → Color Overrides). This replaces the whole tag-style
setting, so check `pvesh get /cluster/options` first and keep any `shape` or `ordering` already there:

```sh
pvesh set /cluster/options --tag-style 'color-map=homelab:6e7781;kubernetes:326ce5;talos:ff7300;controlplane:2da44e;worker:d29922'
```

**TrueNAS API key.** In the web UI at `https://10.10.1.10`: top-right user menu, **API Keys**, **Add**, name it
`opentofu`, create it, copy the key shown once. Then:

```sh
read -rs TF_VAR_truenas_api_key && export TF_VAR_truenas_api_key
```

**UniFi API key.** In the UniFi Network UI on the UDM: **Settings**, **Control Plane**, **Integrations**,
create an API key. Upstream offers no read-only key, so this one has full admin rights; treat it accordingly
(`docs/decisions.md` §5.3). Then:

```sh
read -rs TF_VAR_unifi_api_key && export TF_VAR_unifi_api_key
```

Expected: `env | grep -c 'PROXMOX_VE_API_TOKEN\|TF_VAR_truenas_api_key\|TF_VAR_unifi_api_key'` prints 3, and
`git status` shows no new files.

Rollback: delete the token (`pveum user token remove terraform@pve tofu`, then `pveum user delete
terraform@pve` and `pveum role delete TofuTalos`), delete the TrueNAS key under API Keys, and revoke the
UniFi key under Integrations.

## 2. UniFi root

Needs the two host MACs and the server network name in the gitignored `terraform.tfvars` (open inputs below).

```sh
cd infrastructure/environments/homelab/unifi
tofu init -backend=false
tofu validate
tofu plan
```

Expected: only additions. The VLAN 20 network `hl-k8s` and the two host-reservation clients (`poseidon`
`10.10.1.1`, `hercules-nas` `10.10.1.10`, taken over from any record that already exists). Anything else,
above all an update or destroy of a house appliance, a network or a firewall rule, is a stop. Read
`infrastructure/environments/homelab/unifi/README.md` first.

Then `tofu apply` (type `yes` yourself), and run `tofu plan` again.

Expected: "No changes".

Rollback: `hl-k8s` has `prevent_destroy`. To undo, remove it by hand in the UI after checking nothing uses
VLAN 20. A reservation is cleared by setting it to `""` and applying (README, host reservations).

## 3. Host network bootstrap

Follow `docs/runbooks/host-network-bootstrap.md` for both hosts, at the console. Its pre-checks include the
UniFi switch-port tagging (HOME native; VLAN 4 and 20 tagged), a UI step.

- **Hostname.** The Proxmox install is still named `pve`. Either rename it to `poseidon` (step 2.4 of that
  runbook: `hostnamectl set-hostname poseidon` and fix `/etc/hosts`, while there are no guests) or leave it and
  set `proxmox_node_name = "pve"` in the Proxmox root's `terraform.tfvars`. Pick one before step 5.
- **Interfaces.** `nic0` (1 GbE) is `vmbr0` carrying VLAN 4. `nic1` and `nic2` are the 10 GbE X520. The direct
  fibre is on `nic2` (carrier seen 2026-10-21); `nic1` is unused. Only `nic2`'s `mtu 9000` stanza is set by
  hand; `vmbr1` itself is created by the Proxmox root (step 5).
- **Direct 10 GbE link.** `10.99.0.0/29`: poseidon `.1` (on `vmbr1`), hercules-nas `.2`, talos-cp-1 `.3`,
  talos-wk-1 `.4` and talos-wk-2 `.5` (each VM's second NIC on `vmbr1`), MTU 9000, no gateway (`docs/decisions.md` §2.2, decided
  2026-10-21; MTU provisional). poseidon sees carrier on `nic2`; the NAS side
  is not configured yet and nothing has been pinged or measured on the real link. Both ends are OpenTofu
  resources (`storage-link.tf` in the Proxmox and TrueNAS roots, proven on the lab fixtures only), so this
  ping and iperf3 test runs after those applies; `host-network-bootstrap.md` has the order.

Verify, from poseidon:

```sh
ping -c 3 10.10.1.10                  # management path
ping -M do -s 8972 -c 3 10.99.0.2     # MTU 9000 end to end, no fragmentation
iperf3 -s                             # on hercules-nas (TrueNAS shell); then on poseidon:
iperf3 -c 10.99.0.2 -P 4              # poseidon to NAS
iperf3 -c 10.99.0.2 -P 4 -R           # NAS to poseidon
```

Expected: no loss on the pings; both iperf3 directions near line rate for 10 GbE (about 9 Gbit/s). Record the
numbers; they settle the MTU. How the nodes reach the NAS is settled: their own NIC on the link (§2.2).

Rollback: the console is the way back; each host's section in that runbook says how to restore the old
address. Take the DHCP lease address again if VLAN tagging breaks the path.

## 4. TrueNAS root

Only after step 3 passes and the data check in step 0 is done: this root can create and change datasets.

The root creates the `jolien` and `dunia` accounts, so export their initial passwords first (no echo; put
both in the password manager):

```sh
read -rs TF_VAR_user_jolien_password && export TF_VAR_user_jolien_password
read -rs TF_VAR_user_dunia_password && export TF_VAR_user_dunia_password
cd infrastructure/environments/homelab/truenas
tofu init -backend=false
tofu validate
tofu plan
```

Expected: additions only (datasets, the NFS and SMB shares, snapshot tasks, the `jolien` and `dunia`
accounts, the user-facing pieces in its README), plus the storage-link bond (`bond1`, a one-port failover
bond on `storage_link_interface`, which must be set first). Your own `arthur` account shows as
`truenas_user.arthur will be imported` and nothing else: no `~` lines under it. Any change to `arthur` is a
stop, because it is the admin login. The pool `main` itself is not managed here; it already exists. Any
destroy or in-place change to an existing dataset is a stop. Needs the Time Machine quota and the two
password variables (open inputs below). `k8s_nfs_allowed_networks` defaults to the `/29` storage link
(`docs/decisions.md` §2.2); the bond's alias is `10.99.0.2/29`.

Then `tofu apply`, then `tofu plan` again.

Expected: "No changes". Then check from the NAS UI that the shares are up, and follow
`docs/runbooks/household-backups.md` for the Time Machine and Kopia clients.

Rollback: `tofu destroy` is not a rollback here. Datasets can hold data. Remove a share or task by hand, or
change the config and apply a reviewed plan.

## 5. Proxmox root

```sh
cd infrastructure/environments/homelab/proxmox
tofu init -backend=false
tofu validate
tofu plan
```

Expected: the Talos control-plane and worker VMs (each with a second NIC, `net1`, on `vmbr1` at MTU 9000), the
Talos image download, the storage-link bridge `vmbr1` (`nic2` must already carry `mtu 9000`), and nothing else. If the node
is still `pve`, `proxmox_node_name = "pve"` must be set. Read `infrastructure/environments/homelab/proxmox/README.md`.

Then `tofu apply`, then `tofu plan` again.

Expected: "No changes". The VMs are in the Proxmox UI, running, on VLAN 20.

Rollback: `tofu destroy` removes the VMs only; the Talos nodes hold no data yet. Check the plan lists nothing
but the VMs and the image.

## 6. Talos bootstrap

Follow `docs/runbooks/talos-bootstrap.md` end to end, owner present: fill `talos/inputs.env`
(no `192.0.2.1` placeholder left), `scripts/talos/gen-configs.sh`, `talosctl apply-config --insecure`,
`scripts/talos/bootstrap.sh --node <CP_IP> --confirm`, `scripts/talos/kubeconfig.sh ... --confirm`, then
`scripts/talos/install-cni.sh` (Cilium is installed by hand first, and Flux adopts it later).

Expected: `kubectl get nodes` shows both nodes Ready (the runbook's §8).

Rollback: the runbook's §9 and §10. Wiping and re-applying the machine config is allowed until the cluster
holds data you care about. `--force` changes the cluster identity: never use it once a node runs the config.
A patch change on a running cluster is `just talos-regen` plus `just talos-upgrade-config` (runbook §11).

## 7. Flux bootstrap

First the production secrets key ceremony (`docs/runbooks/secrets.md` §2, "Production"): the production age
recipient in `.sops.yaml` is still a placeholder, and the production Secrets listed in
`kubernetes/overlays/homelab/README.md` must be encrypted to it. Then follow
`kubernetes/clusters/homelab/README.md`: the `flux bootstrap` command for this repo, then create the
`sops-age` Secret in `flux-system` from the private key, without it touching a file in the repo.

Expected: `flux get kustomizations` and `flux get helmreleases -A` show everything Ready. The apps that need
a Secret (Alertmanager, Authentik, Seafile) come up only once their production Secrets are in place.

Rollback: `flux suspend kustomization --all` stops reconciling. Remove the cluster as in `docs/disaster-recovery.md`
§5 if you need to start over. Git is the source of truth, so a rebuild is a re-bootstrap.

## Open owner inputs

| Input | What is open | Blocks step |
|---|---|---|
| hercules-nas MAC | goes into the UniFi root's gitignored `terraform.tfvars` (`host_reservations`); the poseidon MAC too | 2 |
| UDM URL | `unifi_api_url` in the same `terraform.tfvars` | 2 |
| VLAN 4 network name | `server_network_name`, to be confirmed from the controller (default `server`) | 2 |
| 10 GbE cable and link test | cable between poseidon and the NAS, then the ping and iperf3 test above | 3, 4 |
| NAS 10 GbE port name | `storage_link_interface` in the TrueNAS root's `terraform.tfvars` (no default; read it in the TrueNAS UI under Network) | 4 |
| Time Machine quota | `timemachine_jolien_quota_gib` (2x the Mac's disk is the rule of thumb) | 4 |
| `jolien` and `dunia` passwords | export `TF_VAR_user_jolien_password` and `TF_VAR_user_dunia_password` before the plan (no default, never in a file); OpenTofu creates both accounts | 4 |
| SMTP password | relay `mail.a-line.be`, user `homelab@lab.ardw.be` (`docs/decisions.md` §5.1); set at the key ceremony | 7 |
| Cloudflare token | the DNS-01 certificate token ( `docs/secrets-and-state.md`) | 7 |
| Offsite backup target | deferred, `docs/decisions.md` §5.5; offsite backups stay dormant until chosen | after 7 |
| CI runner | the self-hosted `homelab` runner for the dormant plan workflow (`docs/PROJECT-PLAN.md`) | after 7 |
| mDNS | reflection across zones, only if IOT devices move (`docs/decisions.md` §2.6, `docs/network-plan.md`) | after 7 |
| UPS and NUT | SLOG has no PLP, `docs/decisions.md` §4.4; not bought yet | after 4 |
