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
| Kopia, Technitium | Own login, link only: neither supports OIDC | n/a |
| Proxmox, TrueNAS, UniFi | Own login, link only | n/a |

Immich and Audiobookshelf keep their OIDC settings in their own database. Immich *can* read a config file, but
then every system setting is locked in its UI, so it isn't used. Only the Authentik side (provider, client
secret, redirect URIs) is in git.

Local logins stay as the fallback when Authentik is down: Grafana's `grafana-admin`, Immich's and
Audiobookshelf's first admin, Seafile's `seafile-admin` (`break-glass.md`).

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

with `<app>` = `immich` or `audiobookshelf`.

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

## Verification

- Open the app in a private window, click **Login with Authentik**, sign in: you land in the app as your user.
- Authentik's dashboard shows the tile and it opens the app.
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
