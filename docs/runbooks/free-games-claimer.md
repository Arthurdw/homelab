# Runbook: free-games-claimer

[free-games-claimer](https://github.com/vogler/free-games-claimer) claims the weekly free games on Epic Games,
Prime Gaming and GOG with a headed Chromium driven by Playwright (`docs/decisions.md` §5.16). The browser is
visible through noVNC at `https://free-games.lab.ardw.be`. Manifests: `kubernetes/apps/free-games-claimer/`, in
both overlays; the store logins are an optional Secret in the homelab overlay only.

## What lives where

- **In the cluster:** one pod. It runs the three claimers at start, then every 24 h. `/fgc/data` is a
  `local-path` volume on the node SSD and holds the Chromium profile (the store sessions), the claimed-games JSON
  (`epic-games.json`, `prime-gaming.json`, `gog.json`), screenshots and `TurboVNC.log`.
- **Not backed up** (`docs/backup-matrix.md`): losing the volume only means logging in to each store again.
- **Optional, in Git (SOPS):** the `free-games-claimer/free-games-claimer` Secret with store logins and a
  notification URL. Without it you log in once by hand in noVNC and the session cookies carry later runs.

## Why admins only

The noVNC page *is* the logged-in browser: whoever opens it can use the store accounts and any payment method on
file. It sits behind Authentik forward-auth bound to `authentik Admins` (`blueprints.yaml`, `home.yaml`),
internal DNS only, no tunnel route, no public record. Raw VNC (5900) has no password and is not in the Service.

## Pre-checks

- [ ] `free-games.lab.ardw.be` resolves to the Traefik VIP (Technitium's wildcard).
- [ ] `kubectl -n free-games-claimer get pods` shows `free-games-claimer` Ready.
- [ ] Authentik shows the **Free games** application (Infrastructure group) and the embedded outpost lists the
      `Free games` provider. If not, the blueprint has not been re-applied yet: restart the Authentik worker.

## First login

The claimers wait `LOGIN_TIMEOUT` (600 s in the manifest, waited twice: email/password, then 2FA) for a manual
login whenever a store session is missing.

1. `kubectl -n free-games-claimer rollout restart deploy/free-games-claimer` to start a fresh run.
2. Open `https://free-games.lab.ardw.be/`, sign in with an Authentik admin, click **Connect** in noVNC.
3. Log in to each store as the browser reaches it (Epic, then Prime, then GOG), including 2FA and captchas.
   Missed the window? Restart again; the stores already logged in stay logged in.
4. Follow the run in `kubectl -n free-games-claimer logs -f deploy/free-games-claimer`.

## Optional: the Secret

Every key becomes an environment variable (upstream's `src/config.js` lists them all). Useful ones:

| Key | Meaning |
|---|---|
| `NOTIFY` | An [apprise](https://github.com/caronc/apprise) URL for claim and error notifications |
| `EMAIL`, `PASSWORD` | Fallback login for every store |
| `EG_EMAIL`, `EG_PASSWORD`, `EG_OTPKEY`, `EG_PARENTALPIN` | Epic Games; `*_OTPKEY` is the TOTP seed, so 2FA runs unattended |
| `PG_EMAIL`, `PG_PASSWORD`, `PG_OTPKEY` | Prime Gaming (Amazon) |
| `GOG_EMAIL`, `GOG_PASSWORD`, `GOG_NEWSLETTER` | GOG |

Create it like any single homelab Secret (`kubernetes/overlays/homelab/README.md`, "To add or change a single
Secret by hand"): a plain v1 Secret named `free-games-claimer` in namespace `free-games-claimer`, encrypted to
`kubernetes/overlays/homelab/apps/free-games-claimer.sops.yaml` and listed in that kustomization. Then add a row to
the table in that README. The pod reads it at start, so restart the Deployment afterwards. Storing a TOTP seed
next to the password removes the second factor for that account; leave `*_OTPKEY` out if that matters more than
unattended 2FA.

## Verification

- The pod log ends each run with `Next run in 24 h`, after one block per store listing the games it found.
- `kubectl -n free-games-claimer exec deploy/free-games-claimer -- ls /fgc/data` shows the JSON files and
  `screenshots/`.
- The store's library shows the claimed game.
- Not done at the time of writing: the first production login.

## Operations

- **Run now:** `kubectl -n free-games-claimer rollout restart deploy/free-games-claimer`.
- **Epic captcha:** Epic often shows an hCaptcha to the container's browser (upstream issue #183). Solve it in
  noVNC during the run, or claim that week by hand. Upstream is semi-maintained; a store breaking until a new
  image lands is expected.
- **Container restarts:** `/tmp` is an `emptyDir` and survives a container restart, so the command removes the
  stale X socket (`/tmp/.X11-unix/X1`) before the image's entrypoint; otherwise TurboVNC refuses display :1 and
  the container exits. A pod deletion starts clean anyway.
- **Upgrade:** Renovate opens a PR for the digest of the `dev` tag (`versions.yaml`,
  `app_images.free_games_claimer`); no automerge. Upstream builds the Chromium image on `dev`; `latest` is still
  the old Firefox build.

## Rollback

Remove `free-games-claimer` from `kubernetes/apps/kustomization.yaml` and the Free games entries from the
Authentik blueprint, outpost Ingress and Homepage. Flux prunes the namespace. `local-path` is `Retain`, so a
`Released` PV and its directory stay behind on the node; nothing in it needs keeping, delete the PV to free it.
