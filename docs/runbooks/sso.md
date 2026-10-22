# SSO: Authentik as the login portal

Authentik (`kubernetes/apps/authentik/`) is the homelab's front door: its user dashboard,
`https://auth.lab.ardw.be/if/user/`, lists every UI, grouped as **Apps** and **Infrastructure**. All of it is
declared in `kubernetes/apps/authentik/blueprints.yaml`; nothing is clicked together in the Authentik UI.

| Application | Sign-in | Configured where |
|---|---|---|
| Seafile | OIDC, client `seafile` | Git: `kubernetes/apps/seafile/seafile.yaml` (`OAUTH_*`) |
| Grafana | OIDC, client `grafana` | Git: `kubernetes/infrastructure/monitoring/release.yaml` (`grafana.ini`) |
| Immich | OIDC, client `immich` | Immich's admin UI, once (below) |
| Audiobookshelf | OIDC, client `audiobookshelf` | `just audiobookshelf-oauth`, once (below) |
| Proxmox | OIDC, client `proxmox` (realm `authentik`) | Proxmox, once with `pveum` (below) |
| Technitium | OIDC, client `technitium` | `just technitium-sso`, once (below) |
| Homepage | Forward-auth (embedded outpost) | Git: `kubernetes/apps/authentik/forward-auth.yaml`, `blueprints.yaml` (`home.yaml`) |
| Kopia, TrueNAS, UniFi | Own login, link only: no generic OIDC login. Kopia keeps its basic auth, see [Kopia](#kopia) | n/a |

Immich, Audiobookshelf, Proxmox and Technitium keep their OIDC settings in their own configuration. Immich
*can* read a config file, but then every system setting is locked in its UI, so it isn't used. Only the
Authentik side (provider, client secret, redirect URIs) is in the repo. Immich, Audiobookshelf and Technitium
are switched on by a script that reads the client secret from the cluster and calls the app's API; Proxmox takes
one `pveum` command.

Local logins stay as the fallback when Authentik is down: Grafana's `grafana-admin`, Immich's and
Audiobookshelf's first admin, Seafile's `seafile-admin`, Proxmox's `root@pam`, Technitium's `admin`, Kopia's
basic-auth user (`break-glass.md`, and "Where are my local logins" below). Homepage has no local login: with Authentik down it is unreachable, and every app it links
still answers directly.

## Pre-checks

- Authentik is up and the blueprints applied: in Authentik, *Applications* lists Immich and Audiobookshelf, and
  *Customization → Blueprints* shows `Immich` and `Audiobookshelf` as successful.
- Your kube context reaches the cluster (`kubectl --context homelab -n authentik get pods`). Use `--context lab`
  for the lab.
- You are signed in to the app as its admin (local login).

## Read a client secret

The value only exists in the Secret (`scripts/secrets/gen-*-secrets.sh` generated it). Print it into your
clipboard, never into a ticket or chat:

```sh
kubectl --context homelab -n authentik get secret authentik-<app>-oidc -o jsonpath='{.data.client-secret}' | base64 -d
```

with `<app>` = `immich`, `audiobookshelf`, `proxmox` or `technitium`.

## Generate the Proxmox and Technitium client secrets (owner, once)

`authentik-proxmox-oidc` and `authentik-technitium-oidc` are new. Until they exist, Authentik still starts (the
env refs in `release.yaml` are optional), but the `Proxmox` and `Technitium` blueprints fail to apply. Run
`scripts/secrets/gen-homelab-secrets.sh` (and `gen-lab-secrets.sh` for the lab): it keeps every existing file,
writes the two new `.sops.yaml` files and adds them to the overlay's `kustomization.yaml`. Commit and push, then
restart `authentik-server` and `authentik-worker` so they read the new env vars.

## Immich

*Administration → Settings → OAuth Settings*, enable **Login with OAuth**:

| Field | Value |
|---|---|
| Issuer URL | `https://auth.lab.ardw.be/application/o/immich/` |
| Client ID | `immich` |
| Client Secret | `authentik-immich-oidc` (above) |
| Scope | `openid email profile` |
| Signing algorithm | `RS256` |
| Button text | `Login with Authentik` |
| Auto register | on (new Authentik users get an Immich account on first login) |
| Auto launch | off (keeps the local login reachable) |
| Mobile redirect URI override | off: Authentik accepts `app.immich:///oauth-callback` as is |

Existing Immich users are matched by email, so give the Authentik user the same email first.

*Administration → Settings → Notification Settings → Email* (Immich's SMTP, `docs/decisions.md` §5.1):

| Field | Value |
|---|---|
| Host | `mail.a-line.be` |
| Port | `465` (implicit TLS) |
| Username | `homelab@lab.ardw.be` |
| Password | the relay password: same value as `monitoring/alertmanager-smtp` key `smtp-password` |
| From address | `Immich <immich@lab.ardw.be>` |

Send the test mail from that page.

## Audiobookshelf

Audiobookshelf's only login is the `root` user made on the first visit to `https://audiobookshelf.lab.ardw.be`;
neither the repo nor the cluster holds its password. On homelab that first visit already happened (`/status`
answers `isInit: true`), so the form will not show again: if nobody knows the password, follow the reset under
"Where are my local logins" first. Then:

1. In Audiobookshelf: *Settings -> API Keys* (or any admin API token), create a key for an admin user.
2. `ABS_TOKEN=<key> just audiobookshelf-oauth --dry-run`, then without `--dry-run` (leave `ABS_TOKEN` unset for a
   silent prompt).
3. Click *Login with Authentik* once: ABS creates a new user of type *user* for you. Sign in as `root` and raise
   it to *admin* in *Settings -> Users* if you want it to manage the server. `root` stays the local break-glass
   login.

Existing ABS users are not matched: Authentik sends `email_verified: false`, which ABS refuses when matching by
email ("Unauthorized" after the Authentik login), and email matching would let anyone who can change their
Authentik email take over the ABS user with that address.

The script reads the client secret from `authentik-audiobookshelf-oidc`, PATCHes `/api/auth-settings` and reads
it back. It sets:

| Field | Value |
|---|---|
| Issuer URL | `https://auth.lab.ardw.be/application/o/audiobookshelf/` |
| Authorize / token / userinfo | `https://auth.lab.ardw.be/application/o/{authorize,token,userinfo}/` |
| JWKS / logout | `<issuer>jwks/` and `<issuer>end-session/` |
| Client ID / secret | `audiobookshelf` / `authentik-audiobookshelf-oidc` |
| Signing algorithm | `RS256` |
| Button text | `Login with Authentik` |
| Match existing users by | Do not match |
| Auto register | on |
| Auto launch | off (keeps the local login reachable) |
| Active methods | `local` and `openid` |
| Mobile redirect URIs | untouched (default `audiobookshelf://oauth`) |

Authentik allows the callbacks `https://audiobookshelf.lab.ardw.be/auth/openid/callback` and
`.../auth/openid/mobile-redirect`; nothing else to set. Fallback: the same fields by hand in *Settings ->
Authentication*. If the script reports that openid is not active, ABS dropped it because a required field is
missing; compare with `--dry-run`.

## Proxmox

Proxmox can't be configured from git: add the realm on poseidon as root, once. First check that poseidon
resolves and reaches Authentik (`curl -sI https://auth.lab.ardw.be/` on the host); the Let's Encrypt
certificate is trusted as is.

```sh
pveum realm add authentik --type openid \
  --issuer-url https://auth.lab.ardw.be/application/o/proxmox/ \
  --client-id proxmox --client-key '<authentik-proxmox-oidc>' \
  --username-claim username --scopes 'openid email profile' --autocreate 1
```

`--username-claim username` uses Authentik's `preferred_username`, so the Proxmox user is `<username>@authentik`.
Autocreated users have no permissions. Grant your own user what it needs, e.g.
`pveum acl modify / --users arthur@authentik --roles Administrator`. On the login page pick the realm
**authentik**. Proxmox sends the origin of the page as the redirect URI: `https://pve.lab.ardw.be` through Traefik
(`host-proxies.md`), or `https://poseidon.lab.ardw.be:8006` on the break-glass path. The blueprint allows both,
with and without a trailing slash. Roll back with `pveum realm delete authentik` (`root@pam` is unaffected).

## Technitium

`just technitium-sso --dry-run`, then `just technitium-sso`. The script logs in as the local `admin` with the
password from the Secret `technitium/technitium-admin`, reads `authentik-technitium-oidc`, calls
`/api/admin/sso/set` and logs out. Technitium restarts its web service afterwards (a few seconds). It sets:

| Field | Value |
|---|---|
| Authority / Issuer | `https://auth.lab.ardw.be/application/o/technitium/` |
| Client ID / secret | `technitium` / `authentik-technitium-oidc` |
| Scopes | `openid email profile` |
| Callback | fixed at `https://dns.lab.ardw.be/sso/callback`, already allowed in the blueprint |
| Group Map | Authentik group `authentik Admins` -> Technitium group `Administrators` (synced at each login) |
| Allow signup | on, only for users in a mapped group |

The `DNS_SERVER_SSO_*` env vars only apply on a first start without a config, so the API is used instead.
The local `admin` stays as the fallback. Authentik's integration page says the map's remote group is an
entitlement name; Technitium's code reads the `groups` claim, which the default scope mapping fills with group
names. If an `authentik Admins` member signs in but is refused or lands without admin rights, check the claims
in Authentik and adjust the map in *Administration -> SSO*.

## Kopia

Kopia has no OIDC; the UI and the API share one HTTP basic-auth check (`kopia-server` Secret), and client devices
authenticate to the same server as per-device users (`kopia-users`) over gRPC on the same host. Forward-auth in
front of the UI was evaluated and **not** done:

- Kopia serves its gRPC client protocol and its UI/API (`/api/v1/...`, the static UI) from one listener behind
  one authenticator. Splitting them needs an IngressRoute that routes by path and keeps the gRPC prefix away
  from the Authentik Middleware. Any path missed there breaks backups with a redirect to a login page, and the
  split could not be tested against the live server here.
- Forward-auth only gets the browser to the page; Kopia would still ask for basic credentials. Authentik's proxy
  provider can inject `Authorization: Basic` (`basic_auth_enabled`), but the password must live in Authentik
  (a blueprint `!Env` plus a new mounted Secret, or a per-user attribute set by hand) and be passed through a
  second Middleware with `Authorization` in `authResponseHeaders`. That is a second copy of the credential in
  Authentik and one more moving part next to the backups' path.
- Kopia's login is already per-user over TLS on the LAN only (`decisions.md` 5.7, 5.9).

So Kopia keeps its basic auth; Authentik's dashboard has a link-only tile for it (`portal.yaml`).

## Where are my local logins

Read-only commands; they print the value, so run them where nobody is watching and never into a log or chat.
Use `--context lab` for the lab.

| App | Where the login comes from | Read it |
|---|---|---|
| Technitium | user `admin`, password from the Secret | `kubectl --context homelab -n technitium get secret technitium-admin -o jsonpath='{.data.password}' \| base64 -d; echo` |
| Kopia UI | user and password from the Secret | `kubectl --context homelab -n kopia get secret kopia-server -o jsonpath='{.data.username}' \| base64 -d; echo`, and the same with `{.data.password}` |
| Kopia devices | one key per `<user>_<host>` | key names only: `kubectl --context homelab -n kopia get secret kopia-users -o json \| jq '.data \| keys'` |
| Audiobookshelf | `root`, password set by you at the first visit; not in the cluster | n/a |
| Grafana | `grafana-admin` | `break-glass.md` |

Audiobookshelf reset (forgot the root password, SSO down): sign in as another admin and change it in *Settings ->
Users*. With no other admin, the owner scales the Deployment to zero, removes the `root` user row from the
`users` table of `absdatabase.sqlite` on the config PVC (for example with a throwaway pod running `sqlite3`),
and scales it back up; the first-run form appears again. This is a write to a live app, so it is the owner's step.

## Forward-auth

Hosts without a login of their own (now: Homepage) sit behind Authentik's **embedded outpost**, which runs inside
`authentik-server`. Traefik asks it before every request through the shared Middleware `authentik/forward-auth`;
an unauthenticated browser is sent to `auth.lab.ardw.be` and back. Nothing to do by hand: the blueprint
`home.yaml` declares the proxy provider and puts it on the embedded outpost.

To protect another host `<app>.lab.ardw.be`:

1. In `blueprints.yaml`, add a `proxyprovider` (`mode: forward_single`, `external_host:
   https://<app>.lab.ardw.be`) and its application, and add the provider to the embedded outpost's `providers`
   list in `home.yaml` (the list is complete, not additive).
2. In `forward-auth.yaml`, add the host to the Ingress `authentik-outpost` (rule and TLS host).
3. On the app's Ingress, add the annotation
   `traefik.ingress.kubernetes.io/router.middlewares: authentik-forward-auth@kubernetescrd`.

Check: a private window on the host lands on the Authentik login, and after it on the app. If it loops, the
outpost Ingress is missing the host. If it answers 500, the Middleware can't reach `authentik-server`.

## Verification

- Open the app in a private window, click **Login with Authentik** (Technitium: the SSO button), sign in: you land in the app as your user.
- Authentik's dashboard shows the tile and it opens the app.
- Homepage: `https://home.lab.ardw.be` in a private window asks for the Authentik login first.
- Grafana: members of the Authentik group `authentik Admins` are Grafana org Admins, everyone else a Viewer.

## Rollback

Turn the OAuth/OpenID switch off in the app's settings: the local login is unaffected. To remove the provider,
delete its entries from `blueprints.yaml` (and the env var in `release.yaml`, the Secret in the overlays).

## Notes

- Lab: Grafana talks to `auth.lab.ardw.be` server-side (token, userinfo). Like Seafile
  (`kubernetes/overlays/lab/apps/seafile-lab-trust.yaml`), that needs the name to resolve inside the cluster and
  the lab's internal CA to be trusted; until then, Grafana's OIDC login fails in the lab and the local admin
  login still works. Immich and Audiobookshelf have the same server-side calls.
- Rotate a client secret by following `secrets.md` (add/rotate). The gen scripts' `--force` regenerates every
  non-immutable Secret, not one pair. After a rotation re-run `just audiobookshelf-oauth` / `just technitium-sso` and paste the new value into Immich; Grafana and
  Seafile read theirs from their own Secret, which must get the same value as Authentik's.
