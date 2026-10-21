# Production Secrets (`homelab`)

**Blocked on the age key ceremony** (`docs/runbooks/secrets.md` §2). Until the production recipient replaces
the placeholder in `.sops.yaml`, encrypting any file under this directory fails, so no Secret can land here by
accident.

The cluster needs these Secrets. Each one becomes `<layer>/<name>.sops.yaml` and is added to that layer's
`kustomization.yaml`, the same way `scripts/secrets/gen-lab-secrets.sh` builds the lab overlay. Unlike the lab,
the values are real and are generated or chosen by the owner.

| Layer | Namespace / name | Keys | Used by | Notes |
|---|---|---|---|---|
| infrastructure | `cert-manager/cloudflare-api-token` | `api-token` | DNS-01 ClusterIssuers | Cloudflare token, `Zone:DNS:Edit` on the zone only |
| infrastructure | `monitoring/grafana-admin` | `admin-user`, `admin-password` | Grafana | |
| infrastructure | `monitoring/alertmanager-smtp` | `smtp-password` | Alertmanager, Grafana mails | SMTP relay login (`docs/decisions.md` §5.1) |
| infrastructure | `monitoring/grafana-oidc` | `client-secret` | Grafana's OIDC login | Same value as `authentik/authentik-grafana-oidc` (apps layer) |
| infrastructure | `technitium/technitium-admin` | `password` | Technitium, zone bootstrap CronJob | |
| apps | `immich/immich-db` | `username`, `password` | Immich and its PostgreSQL, `immich-db-dump` | |
| apps | `authentik/authentik-credentials` | `secret-key`, `postgres-password` | Authentik and its PostgreSQL, `authentik-db-dump` | `secret-key` must never change after the first install |
| apps | `authentik/authentik-smtp` | `smtp-password` | Authentik recovery mails | Same relay login as `alertmanager-smtp` |
| apps | `seafile/seafile-db` | `root-password`, `password` | Seafile's MariaDB, `seafile-db-dump` | `password` is the `seafile` DB user |
| apps | `seafile/seafile-admin` | `email`, `password` | First Seafile admin (created on first start only) | |
| apps | `seafile/seafile-smtp` | `smtp-password` | Seafile mails (`seafile@lab.ardw.be`) | Same relay login as `alertmanager-smtp` |
| apps | `seafile/seafile-jwt` | `jwt-private-key` | Seahub token signing | Must never change after the first install |
| apps | `authentik/authentik-seafile-oidc` and `seafile/seafile-oidc` | `client-secret` | Seafile's OIDC login: Authentik's blueprint and Seahub | The two Secrets must hold the same value |
| apps | `authentik/authentik-grafana-oidc` | `client-secret` | Grafana's OIDC login: Authentik's blueprint | Same value as `monitoring/grafana-oidc` (infrastructure layer) |
| apps | `authentik/authentik-immich-oidc`, `authentik/authentik-audiobookshelf-oidc` | `client-secret` | Immich's and Audiobookshelf's OIDC login: Authentik's blueprint | The apps keep the value in their own database, pasted once (`docs/runbooks/sso.md`) |
| apps | `kopia/kopia-repository` | `password` | Kopia repository encryption | The only key to the backups: keep an offline copy |
| apps | `kopia/kopia-server` | `username`, `password`, `control-username`, `control-password` | Kopia server UI/API and control login | |
| apps | `kopia/kopia-users` | one key `<user>_<host>` per device, e.g. `dunia_dunia-pc`, `arthur_arthur-pc` | Kopia client logins (`user@host`) | Add a key per device, see `kubernetes/apps/kopia/server.yaml` |

## What happens before they exist

`infrastructure` waits for health (`wait: true`). Without the Secrets, Grafana, Alertmanager and Technitium
don't become Ready, so `infrastructure` stalls and `infrastructure-configs` and `apps`, which depend on it,
never start. That is acceptable: without the `sops-age` Secret in `flux-system` the cluster can't decrypt
anything anyway. Create the Secrets and the age key together, before the first Flux bootstrap of production.

`infrastructure-configs` doesn't wait (`wait: false`), so a missing Cloudflare token leaves the ACME
ClusterIssuers not-Ready without blocking `apps`. Traefik serves its default certificate until the wildcard
Certificate is issued.

## Adding one

`scripts/secrets/gen-homelab-secrets.sh` (`just secrets-gen-homelab`) writes every Secret in the table and
adds it to the kustomization. It generates the passwords and keys, prompts (without echo) for the Cloudflare
token, the SMTP relay password, the Seafile admin email and the Kopia devices, or reads them from
`HOMELAB_CLOUDFLARE_API_TOKEN`, `HOMELAB_SMTP_PASSWORD`, `HOMELAB_SEAFILE_ADMIN_EMAIL` and
`HOMELAB_KOPIA_USERS` (comma-separated `<user>_<host>`). Existing files are kept; `--force` rewrites them,
except `authentik-credentials`, `seafile-jwt` and `kopia-repository`, which also need `--rotate-immutable`.
`--dry-run` lists what would be written. Read values back with `scripts/secrets/decrypt.sh`, and keep an offline
copy of the `kopia-repository` password.

To add or change a single Secret by hand:

```sh
# Plaintext only in a private temp dir; never in the repo.
tmp="$(mktemp -d)" && chmod 700 "$tmp"
$EDITOR "$tmp/grafana-admin.yaml"          # a plain v1 Secret with stringData
sops --config .sops.yaml encrypt \
  --filename-override kubernetes/overlays/homelab/infrastructure/grafana-admin.sops.yaml \
  "$tmp/grafana-admin.yaml" > kubernetes/overlays/homelab/infrastructure/grafana-admin.sops.yaml
rm -rf "$tmp"
# then list grafana-admin.sops.yaml under resources in infrastructure/kustomization.yaml
scripts/secrets/check.sh --check && just k8s-validate
```
