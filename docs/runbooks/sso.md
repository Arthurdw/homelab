# SSO: Authentik as the login portal

Authentik (`kubernetes/apps/authentik/`) is the homelab's front door: its user dashboard,
`https://auth.lab.ardw.be/if/user/`, lists every UI, grouped as **Apps** and **Infrastructure**. All of it is
declared in `kubernetes/apps/authentik/blueprints.yaml`; nothing is clicked together in the Authentik UI.

| Application | Sign-in | Configured where |
|---|---|---|
| Seafile | OIDC, client `seafile` | Git: `kubernetes/apps/seafile/seafile.yaml` (`OAUTH_*`) |
| Grafana | OIDC, client `grafana` | Git: `kubernetes/infrastructure/monitoring/release.yaml` (`grafana.ini`) |
| Immich | OIDC, client `immich` | Immich's admin UI, once (below) |
| Audiobookshelf | OIDC, client `audiobookshelf` | Audiobookshelf's admin UI, once (below) |
| Proxmox | OIDC, client `proxmox` (realm `authentik`) | Proxmox, once with `pveum` (below) |
| Technitium | OIDC, client `technitium` | Technitium's admin UI, once (below) |
| Homepage | Forward-auth (embedded outpost) | Git: `kubernetes/apps/authentik/forward-auth.yaml`, `blueprints.yaml` (`home.yaml`) |
| Kopia, TrueNAS, UniFi | Own login, link only: no generic OIDC login | n/a |

Immich, Audiobookshelf, Proxmox and Technitium keep their OIDC settings in their own configuration. Immich
*can* read a config file, but then every system setting is locked in its UI, so it isn't used. Only the
Authentik side (provider, client secret, redirect URIs) is in git.

Local logins stay as the fallback when Authentik is down: Grafana's `grafana-admin`, Immich's and
Audiobookshelf's first admin, Seafile's `seafile-admin`, Proxmox's `root@pam`, Technitium's `admin`
(`break-glass.md`). Homepage has no local login: with Authentik down it is unreachable, and every app it links
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

*Settings → Authentication*, enable **OpenID Connect Authentication**:

| Field | Value |
|---|---|
| Issuer URL | `https://auth.lab.ardw.be/application/o/audiobookshelf/`, then **Auto-populate** (fills the authorize, token, userinfo, JWKS and logout URLs) |
| Client ID | `audiobookshelf` |
| Client Secret | `authentik-audiobookshelf-oidc` (above) |
| Signing algorithm | `RS256` |
| Allowed mobile redirect URIs | keep the default `audiobookshelf://oauth` |
| Subfolder for redirect URLs | none |
| Button text | `Login with Authentik` |
| Match existing users by | `Email` |
| Auto register | on |
| Auto launch | off (keeps the local login reachable) |

Authentik allows the callbacks `https://audiobookshelf.lab.ardw.be/auth/openid/callback` and
`.../auth/openid/mobile-redirect`; nothing else to set.

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
**authentik**. Proxmox sends `https://poseidon.lab.ardw.be:8006` as the redirect URI; the blueprint allows it
with and without a trailing slash. Roll back with `pveum realm delete authentik` (`root@pam` is unaffected).

## Technitium

*Administration → SSO* (Technitium 15.x). The `DNS_SERVER_SSO_*` env vars only apply on a first start without a
config, so set it here:

| Field | Value |
|---|---|
| Authority / Issuer | `https://auth.lab.ardw.be/application/o/technitium/` |
| Client ID | `technitium` |
| Client Secret | `authentik-technitium-oidc` (above) |
| Scopes | `openid email profile` |
| Callback | fixed at `https://dns.lab.ardw.be/sso/callback`, already allowed in the blueprint |
| Group Map | Authentik group `authentik Admins` → Technitium group `Administrators` |

Keep the local `admin` login enabled as the fallback.

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

- Open the app in a private window, click **Login with Authentik**, sign in: you land in the app as your user.
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
  non-immutable Secret, not one pair. After a rotation paste the new value into Immich/Audiobookshelf; Grafana and
  Seafile read theirs from their own Secret, which must get the same value as Authentik's.
