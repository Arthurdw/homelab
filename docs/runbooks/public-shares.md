# Public share links (Seafile and Immich through a Cloudflare Tunnel)

What this sets up (`docs/decisions.md` §5.13):

| Public name | Goes to | What outsiders can reach |
|---|---|---|
| `files.ardw.be` | cloudflared -> Seafile (`seafile.seafile.svc:80`) | Share links and upload links only, through an anchored path allowlist (`kubernetes/apps/cloudflared/tunnel-config.yaml`). Everything else gets a 404 |
| `photos.ardw.be` | cloudflared -> immich-public-proxy (`immich.svc:3000`) | Shared albums and assets (`/share/<key>`). Immich itself is never reached |

Never exposed: Seafile login, OAuth, `/api2/`, most of `/api/v2.1/`, `/sys/` admin, WebDAV; Immich's UI, API
and admin; Authentik; every other `*.lab.ardw.be` name. There is no inbound port (§5.2): cloudflared dials out.

Only the homelab cluster runs cloudflared (`kubernetes/overlays/homelab/apps/kustomization.yaml`). The
`files.ardw.be` ingress, certificate, redirect and immich-public-proxy also render in the lab, where they are
harmless.

## Pre-checks

- The homelab cluster is up and Flux is reconciling; Seafile and Immich work at their internal names.
- You are logged in to the Cloudflare account that owns `ardw.be`.
- `dig +short files.ardw.be` and `dig +short photos.ardw.be` return nothing. If either already has a record,
  delete it in the dashboard first: the OpenTofu root never imports existing records and its apply fails.
- The production age key is set up (`docs/runbooks/secrets.md`).

## Owner steps

The order matters: the Secret needs the tunnel, and Immich's links should point at the proxy only once it serves.

0. **LAN DNS, before the first push of the §5.13 commit.** That push makes `files.ardw.be` Seafile's only host
   and redirects `seafile.lab.ardw.be` there. Until the UDM forwards `files.ardw.be` to Technitium, LAN clients
   resolve the public Cloudflare record instead: no answer before step 2, and only the share-link allowlist
   after it, so login and sync break. The forward is additive (`unifi_dns_record.files`) and harmless early,
   because nothing uses the name before the push:

   ```sh
   just plan-unifi
   just apply-unifi
   ```

   After the push, Technitium's zone CronJob creates the `files.ardw.be` zone within 15 minutes; until then the
   name does not resolve on the LAN. Check with `dig +short files.ardw.be` (the Traefik IP) before using it.
   `photos.ardw.be` needs no forward: the proxy is its only origin, so the LAN uses the tunnel as well.

1. **Cloudflare token and IDs.** Create the dedicated API token and fill in
   `infrastructure/environments/homelab/cloudflare/terraform.tfvars` and `~/.config/homelab/cloudflare.env` as in
   that root's `README.md`. Never reuse cert-manager's DNS-01 token.

2. **Tunnel and DNS.** Read the plan: it should only create one `random_bytes`, one tunnel and two CNAMEs.

   ```sh
   just plan-cloudflare
   just apply-cloudflare
   ```

3. **Credentials file**, straight into a private file without printing it (`tofu output` reads the local state
   and needs no token):

   ```sh
   umask 077; d="$(mktemp -d)"
   tofu -chdir=infrastructure/environments/homelab/cloudflare output -raw tunnel_credentials_json >"$d/credentials.json"
   jq -e 'has("AccountTag") and has("TunnelID") and has("TunnelSecret")' "$d/credentials.json" >/dev/null && echo ok
   ```

4. **SOPS Secret.** Writes `kubernetes/overlays/homelab/apps/cloudflared-tunnel.sops.yaml` (keys
   `credentials.json` and `tunnel-id`) and adds it to that kustomization. Every other Secret is kept:

   ```sh
   HOMELAB_CLOUDFLARED_CREDENTIALS_FILE="$d/credentials.json" just secrets-gen-homelab
   rm -rf "$d"
   ```

   Check `git diff` shows only the new `.sops.yaml` and its kustomization line, then commit and push. Flux
   starts the two cloudflared pods. Until this Secret exists the pods wait in `ContainerCreating` and nothing
   else is affected.

5. **Seafile settings in the database.** The share-link rules (password required, 12 characters, strength 2,
   expiry 1/7/90 days) are set in `seahub_settings.py`, but values saved on Seafile's *System Admin > Settings*
   page live in the database and win. Open that page once as admin at `https://files.ardw.be/sys/settings/`
   from the LAN and check nothing there overrides them.

6. **Re-point Seafile clients.** `seafile.lab.ardw.be` now redirects to `files.ardw.be` in browsers, but desktop
   and mobile sync clients do not follow redirects reliably. Change each client's server URL to
   `https://files.ardw.be`. Authentik keeps the old redirect URI as well, so logins keep working meanwhile.

7. **Immich share links.** Make Immich generate `https://photos.ardw.be/share/...` links. Needs an admin API key
   with `systemConfig.read` and `systemConfig.update`:

   ```sh
   just immich-external-domain --dry-run
   just immich-external-domain
   ```

8. **Optional, Cloudflare dashboard:**
   - A cache rule *Bypass cache* for `photos.ardw.be/share/video/*`, or shared videos may not play (IPP docs).
   - A rate-limiting rule on `files.ardw.be` for `POST` to `/f/*` and `/d/*` (for example 10 requests per minute
     per IP). Seafile does not throttle share-link password guesses itself.

## Verification

From **outside** the house (phone on mobile data with Tailscale off, or any host off the LAN):

```sh
curl -sI https://files.ardw.be/accounts/login/   # 404
curl -sI https://files.ardw.be/api2/auth-token/  # 404
curl -sI https://files.ardw.be/sys/              # 404
curl -sI https://files.ardw.be/                  # 404
curl -sI https://photos.ardw.be/                 # 404 (showHomePage is off)
curl -s  https://photos.ardw.be/share/healthcheck
curl -sI https://immich.lab.ardw.be/             # no answer: internal only
```

Then, as a user:

- Create a Seafile share link for a file and for a folder (with a password). Open both from outside: the
  password page, preview, download, folder listing and *Download all* (zip) work.
- Create an upload link and upload a file from outside. Also try one over 100 MB: Cloudflare caps a single
  request at 100 MB, and the Seafile web uploader should split the upload into chunks below that. If it fails,
  note it in the risk register.
- Share an Immich album, open the link from outside: photos, a video and, if allowed on the share, the
  download work. The link previews in a chat app with an image (og:image).
- On the LAN: `https://files.ardw.be` shows the normal Seafile login (Traefik, internal CA), and
  `https://seafile.lab.ardw.be` redirects to it.
- The tunnel shows *Healthy* with two connectors (dashboard > Zero Trust > Networks > Tunnels).

## What Tailscale clients see

- With split DNS for `lab.ardw.be` and `files.ardw.be` pointing at Technitium (or the UDM), a Tailscale client
  behaves like the LAN: the full Seafile UI and `immich.lab.ardw.be`.
- Without it, `files.ardw.be` resolves to Cloudflare, so the client goes through the tunnel and sees only the
  share-link allowlist: the Seafile login page is a 404. Sync clients there fail until split DNS is added.
  `photos.ardw.be` behaves the same everywhere.

## Rollback

Fastest first; each step on its own stops public access.

1. **Stop the tunnel:** remove `- ../../../apps/cloudflared` from
   `kubernetes/overlays/homelab/apps/kustomization.yaml` and push. Flux prunes the namespace, both public names
   answer Cloudflare error 1033 within a minute. In a hurry, the dashboard's tunnel page can also delete the
   connectors, but they reconnect unless the pods are gone.
2. **Remove the public names and the tunnel:** `tofu destroy` on the cloudflare root through the owner's own
   shell (the wrapper allows only plan and apply), or delete the two CNAMEs in the dashboard. Delete
   `cloudflared-tunnel.sops.yaml` and its kustomization line.
3. **Immich links back to internal:** `just immich-external-domain --domain https://immich.lab.ardw.be`.
4. **Seafile back to `seafile.lab.ardw.be`:** revert the Seafile, blueprint, issuer and homepage changes of the
   §5.13 commit. Share links already handed out stop working either way once the tunnel is gone.

## Risks and notes

- **Password guessing on share links:** no throttling in Seafile; mitigated by the 12-character minimum, expiry
  and the optional Cloudflare rate limit.
- **Cloudflare sees the traffic:** TLS ends at Cloudflare, so shared content passes through it in clear.
- **Client IPs in Seafile's logs** come from `X-Forwarded-For`, which a visitor can pre-fill. Do not rely on them.
- **The allowlist follows Seahub 14.** A Seafile major upgrade can move share-link routes; re-check the path
  rules (`tunnel-config.yaml` header) and repeat the verification above after every Seafile major.
- **cloudflared updates** are never automerged (`renovate.json5`): it is internet-facing.
