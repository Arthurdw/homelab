# Runbook: Proxmox and TrueNAS UIs through Traefik

The Proxmox and TrueNAS web UIs are proxied by Traefik, so they get the trusted `*.lab.ardw.be` wildcard
certificate and need no port (`docs/decisions.md` §5.12). Manifests: `kubernetes/apps/host-proxies/`
(homelab only; the lab overlay does not include it).

| URL | Backend | Pinned cert / `serverName` | Break-glass (direct, no cluster) |
|---|---|---|---|
| `https://pve.lab.ardw.be/` | `10.10.1.1:8006` | poseidon's node leaf, expires 2028-10-19 / `poseidon` | `https://poseidon.lab.ardw.be:8006/` |
| `https://nas.lab.ardw.be/` | `10.10.1.10:443` | TrueNAS self-signed, expires **2027-11-22** / `localhost` | `https://hercules-nas.lab.ardw.be/` |

Each backend is a selector-less Service plus an EndpointSlice, a Traefik `ServersTransport` and an
`IngressRoute` on `websecure`. Backend TLS is verified: the ServersTransport trusts only the pinned
certificate in the `<name>-pinned-cert` ConfigMap (public certificates, no keys) and checks `serverName`
against its SANs. There is no Authentik forward-auth: both UIs have their own login (Proxmox also has the
Authentik OpenID realm, `sso.md`).

The host names `poseidon.lab.ardw.be` and `hercules-nas.lab.ardw.be` stay direct A records (`HOST_RECORDS`):
they are the SSH names and the way in when Traefik, MetalLB or the cluster are down (`break-glass.md`).

## Pre-checks

- [ ] The cluster VLAN `10.20.0.0/24` can reach `10.10.1.1:8006` and `10.10.1.10:443` (Traefik's traffic
      leaves from the nodes). Test from a node's network, e.g. a debug pod on the owner's side:
      `curl -sk -o /dev/null -w '%{http_code}\n' https://10.10.1.1:8006/`. If it times out, the owner adds a
      UniFi firewall rule allowing VLAN 20 -> those two host:port pairs (additive only).
- [ ] `pve.lab.ardw.be` and `nas.lab.ardw.be` resolve to the Traefik VIP (wildcard; they must NOT be added
      to `HOST_RECORDS`).

## What goes through the proxy

- Proxmox: the UI, the API, the noVNC and xterm.js consoles (WebSockets), ISO/template uploads. Uploads are
  bounded by websecure's `readTimeout` of 30m (`kubernetes/infrastructure/traefik/release.yaml`); for a very
  large upload on a slow link use the break-glass URL.
- Proxmox **SPICE** does not: the `.vv` file points `remote-viewer` at poseidon's own SPICE proxy
  (`:3128`), not at Traefik. Use it from a machine that reaches poseidon directly.
- TrueNAS: the UI and its WebSocket API.

## Refresh a pinned certificate

Needed after a host reinstall, a certificate rotation, or before the expiry in the table. Symptom: the
proxied URL returns **502 Bad Gateway** / Traefik logs a `x509` error, while the break-glass URL still works.

1. Fetch the current certificate (read-only):

   ```sh
   openssl s_client -connect 10.10.1.1:8006 -showcerts </dev/null | openssl x509 > pve.pem      # Proxmox
   openssl s_client -connect 10.10.1.10:443 -showcerts </dev/null | openssl x509 > nas.pem      # TrueNAS
   openssl x509 -in nas.pem -noout -subject -issuer -enddate -ext subjectAltName
   ```

   Confirm on the host's own console (or the break-glass UI) that this is really its certificate before
   trusting it.
2. Paste the PEM into `ca.crt` of `proxmox-pinned-cert` (`proxmox.yaml`) or `truenas-pinned-cert`
   (`truenas.yaml`) and update the expiry comment. If the SAN changed, set the ServersTransport's
   `serverName` to one of the new SANs.
3. Commit; Flux applies it. Traefik picks up the ConfigMap change without a restart.

Proxmox renews its node certificate by itself before expiry, so the Proxmox pin breaks at each renewal. To
avoid that, pin the PVE cluster CA instead: copy `/etc/pve/pve-root-ca.pem` from poseidon (a public
certificate, valid about 10 years) into `ca.crt`; `serverName` stays `poseidon`. pveproxy does not send that
CA in its chain, which is why the leaf is pinned today.

## Verification

- `https://pve.lab.ardw.be/` and `https://nas.lab.ardw.be/` load with a valid certificate and no warning.
- Proxmox login with the **authentik** realm returns to `pve.lab.ardw.be`; a noVNC console opens.
- `kubectl -n host-proxies get ingressroute,serverstransport,endpointslice` lists both backends.

## Rollback

Remove `../../../apps/host-proxies` from `kubernetes/overlays/homelab/apps/kustomization.yaml` and commit;
Flux prunes the namespace. The break-glass URLs are unaffected throughout.
