# Cloudflare root configuration

Manages the Cloudflare Tunnel for public share links and the public DNS records that point at it
(`docs/decisions.md` §5.13, `docs/runbooks/public-shares.md`).

**Status:** validated offline only (`tofu validate`). It has never been planned or applied against the real account.

## What it manages

| Resource | What |
|---|---|
| `random_bytes.tunnel_secret` | The 32-byte tunnel secret |
| `cloudflare_zero_trust_tunnel_cloudflared.homelab` | The tunnel, `config_src = "local"`: its ingress rules are in git (`kubernetes/apps/cloudflared/tunnel-config.yaml`), not in Cloudflare |
| `cloudflare_dns_record.tunnel["files.ardw.be"]`, `["photos.ardw.be"]` | Proxied CNAMEs to `<tunnel-id>.cfargotunnel.com` |

Out of scope: the zone itself, every other record in `ardw.be`, the cert-manager token, and any Access or WAF config.
The root creates only these objects and never imports existing ones. If a record with the same name already exists,
the apply fails. Remove the old record by hand first; don't import it.

## API token

Create a **separate** custom token (dashboard > My Profile > API Tokens > Create Custom Token). Never reuse
cert-manager's DNS-01 token: that one lives in the cluster, this one stays on the workstation.

| Permission | Scope |
|---|---|
| Zone > DNS > Edit | Include > Specific zone > `ardw.be` |
| Account > Cloudflare Tunnel > Edit | Include > the one account |

Store it in `~/.config/homelab/cloudflare.env` (mode 600), outside the repo:

```sh
TF_VAR_cloudflare_api_token=...
```

Account and zone IDs go in `terraform.tfvars` (gitignored), copied from `terraform.tfvars.example`.

## Usage

The owner runs these. The wrapper sources the env file, runs `init -backend=false` once, and refuses `-auto-approve`:

```sh
cp infrastructure/environments/homelab/cloudflare/terraform.tfvars.example \
   infrastructure/environments/homelab/cloudflare/terraform.tfvars   # then fill in the IDs
just plan-cloudflare
just apply-cloudflare
```

Then build the cloudflared credentials file from the sensitive output, straight into a mode-600 file and
without printing it, as described in `docs/runbooks/public-shares.md` (Owner steps).

## State

State is local and gitignored (`*.tfstate`) until the backend is chosen (`docs/secrets-and-state.md` §5).
**It contains the tunnel secret in clear text** (`random_bytes.tunnel_secret` and the tunnel's `tunnel_secret`).
Anyone holding the state can run a connector for this tunnel and serve `files.ardw.be` and `photos.ardw.be`.
Treat the state file like the credentials file: mode 600, never in git or CI, and back it up encrypted.

To rotate, run `tofu apply -replace=random_bytes.tunnel_secret` through the wrapper. Read the plan first: if the tunnel
gets replaced, it comes back with a new ID and the CNAMEs follow. Then rebuild the Secret (see the runbook).

## Why the tunnel lives here

Provider v5 handles a locally managed tunnel cleanly (`config_src = "local"`, `tunnel_secret` set by us). That leaves
nothing to do in the dashboard or with `cloudflared tunnel create`/`login`, and the CNAMEs reference the tunnel ID
directly instead of a hand-copied variable. The cost is the secret in state (above).
