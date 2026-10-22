# Secrets & State Management

> Design document. Only the lab key and SOPS tooling exist; nothing here is applied to live systems.
> Rule zero: **no secret ever enters the repository, CI, or any committed file.**

## 1. What must never be committed

API keys, tokens, passwords, private SSH keys, Talos machine secrets, kubeconfigs, unencrypted OpenTofu
state, plan files with sensitive values, production `.env` files, private certificate keys, offsite-backup
credentials or recovery keys, and private addresses/hostnames you don't intend to publish.

## 2. Approach

- **Encrypted secrets at rest in repo:** SOPS + **age** (chosen), for any secret that must live alongside
  config (e.g. Flux `Secret` manifests). Only ciphertext is committed.
- **Age private key:** stored **outside** the repo and **outside** the infrastructure it protects
  (password manager + an offline copy). Losing it loses the ability to decrypt — documented recovery.
- **Runtime credentials (API keys):** supplied via **environment variables** from files outside the repo,
  e.g. `~/.config/homelab/<system>.env` (`chmod 600`). Never in committed `.tfvars`.
- **Never** put secrets in resource attributes, shell history, logs, CI artifacts, or plan output.

## 3. Credential handling per system

| System | Credential | Notes |
|---|---|---|
| Proxmox | API token (`root@pam!…` or dedicated user) | scope to a dedicated automation user; `--privsep` tokens |
| TrueNAS | API key | dedicated user; TrueNAS 24.10+ API |
| UniFi | **full-access API key (cannot be read-only)** | see §4 — highest risk |
| Cloudflare | DNS-01 token | narrowly scoped to the required zone(s) |
| Cloudflare (OpenTofu) | separate API token | Zone DNS:Edit on `ardw.be` + Account Cloudflare Tunnel:Edit; workstation only (`cloudflare.env`) |
| Offsite backup | dedicated backup identity | least privilege; cannot erase all history |

## 4. UniFi full-access key — mitigations (important)

A UniFi API key inherits **full admin rights** on the UDM Pro; it can change VLANs, DHCP, DNS, and firewall
rules. A leak or a mistaken `apply` can take the house offline. Because we cannot limit it by permission, we
limit it by **process and tooling**:

1. **Storage:** password manager + `~/.config/homelab/unifi.env` (mode 600), outside the repo. Never in CI,
   never in the cluster, never in `docs/private/`.
2. **Use only from the owner's trusted workstation**, only when doing UniFi work.
3. **Default to plan-only.** The `unifi` OpenTofu root is never applied by automation; applies are manual,
   reviewed, and performed with the owner present.
4. **Additive-only, enforced in code.** The root may only *create new* objects, plus `data` lookups of
   existing ones. Add a resource denylist/`prevent_destroy` guard where the provider supports it, and never
   reference objects that serve current house devices.
5. **Export before change.** Always take a fresh UniFi config export first; keep the previous one until the
   change is validated.
6. **Rotate** the key after sensitive work or on suspicion. Check the UniFi audit log for unexpected changes.
7. **Revisit least privilege:** if the UDM Pro UI offers a limited/viewer **local admin**, generate the key
   for *that* user instead. (Reported as not available today — re-check after firmware updates.)

> This is a **process control, not a permission control.** The network it lives on and the machine that holds
> it must be trusted. Documented in the risk register (R19).

## 5. OpenTofu state

- **One state per system**: `unifi`, `proxmox`, `truenas` (+ `talos` only if justified). No giant single state.
- **Backend:** **TBD.** Options: (a) encrypted remote object storage with locking; (b) local encrypted state
  with strict permissions + independent encrypted backups. Whichever is chosen must document: initialization,
  locking, access control, backup/restore, recovery when the backend is unavailable, safe migration.
- **Never** store state in the Kubernetes cluster that the state is required to rebuild.
- State is treated as a secret (it can contain sensitive values).
- The `cloudflare` root's state holds the **Cloudflare Tunnel secret** in clear text. Anyone holding it can run a
  connector for the public hostnames (`infrastructure/environments/homelab/cloudflare/README.md`, State).

## 6. Rotation & recovery

- Document a rotation procedure per credential and how to recover if one **expires** or is lost.
- Keep break-glass access independent of Authentik, DNS, and the cluster.
- Recovery materials (age key, backup destination creds) must be reachable **without** the homelab.

## 7. Open items

- Choose the state backend (§5).
- Confirm whether a limited UniFi local admin becomes available (eliminates R19's process-only mitigation).
- Decide where the age key is escrowed (offline copy, sealed password manager).
