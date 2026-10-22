# Runbook: Stremio streaming server

The Stremio streaming server runs in the cluster at `https://stremio.lab.ardw.be` (`docs/decisions.md` §5.15).
Manifests: `kubernetes/apps/stremio/`, in both overlays (no Secret, nothing homelab-specific).

## What lives where

- **In the cluster:** the streaming server only. It fetches torrents or debrid HTTP streams and serves them to
  your Stremio app, with ffmpeg for transcoding. Its cache is an `emptyDir` capped at 12Gi; a restart empties it
  and resets the server settings.
- **In your Stremio account, not the cluster:** addons, library, watch history and debrid keys (Real-Debrid,
  AllDebrid, …). Nothing here needs backing up and no secret is committed.

## Why it is local-only

SPEC §12.6 keeps Stremio and debrid-related services local. The host is not in the Cloudflare tunnel's ingress
(only `files.ardw.be` and `photos.ardw.be` are), has no public DNS record and sits behind no Authentik login,
because the apps cannot do one. The gate is internal DNS plus the absent tunnel route. The Traefik `ipAllowList`
(RFC1918 and Tailscale ranges) is a backstop; Traefik may see client addresses SNATed to the cluster's own, so
it cannot tell household devices apart. **Never add a tunnel route or a public record for this host.**

## Pre-checks

- [ ] `stremio.lab.ardw.be` resolves to the Traefik VIP (Technitium's wildcard; do NOT add it to a public zone).
- [ ] `kubectl -n stremio get pods` shows `stremio` Ready.

## Point the Stremio apps at it

1. Stremio desktop, Android/iOS, TV: Settings, Streaming, then **Streaming Server URL**, and enter
   `https://stremio.lab.ardw.be/`.
2. Browser: open `https://stremio.lab.ardw.be/`. Traefik redirects it to the Stremio web shell with the HTTPS
   streaming server URL filled in (the `root-redirect` Middleware; the server's own redirect would pass
   `http://`). Or set the same URL in Settings, Streaming. The HTTPS URL is required: the page is HTTPS and the
   browser blocks an `http://` server.
3. Devices must be on the home LAN, the lab VLANs or Tailscale; elsewhere the name does not resolve or the
   allowlist rejects it.

## Verification

- `curl -s https://stremio.lab.ardw.be/settings` from a LAN machine returns JSON with `serverVersion`.
- Play something in the app with the URL set; the server pod logs show the stream request.
- Not done at the time of writing: no Stremio client has been pointed at it yet.

## Operations

- **Cache size:** pick it in the app (Settings, Streaming, Caching). It resets to 2 GB after a pod restart. The
  `emptyDir` ceiling is 12Gi; past it Kubernetes evicts the pod, which comes back empty.
- **Upgrade:** Renovate opens a PR for the digest-pinned image (`versions.yaml`, `app_images.stremio`); no
  automerge.
- **Transcoding on a GPU:** not used. If the NVIDIA T400 is later passed through for Immich, it could be shared
  with this pod; that is a separate change.

## Rollback

Remove `stremio` from `kubernetes/apps/kustomization.yaml`; Flux prunes the namespace. There is no data to keep.
