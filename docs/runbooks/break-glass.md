# Runbook: Break-glass access

How to reach and administer every layer when the conveniences are down: in-cluster DNS (Technitium),
SSO (Authentik), the ingress (Traefik) or the LoadBalancer IPs (MetalLB). Every path below uses an **IP
address and a local credential**, never a `*.lab.ardw.be` name or an SSO login
(`docs/secrets-and-state.md` §6, `docs/architecture.md`).

Addresses not fixed by `docs/decisions.md` are placeholders: `<CONTROL_PLANE_IP>`, `<WORKER_IP>`,
`<PROXMOX_IP>`, `<NAS_IP>`, `<UDM_IP>`. Write the real values into the offline store next to the
credentials, not into this repo. Ranges: K8s VLAN 20 is `10.20.0.0/24`, nodes `10.20.0.11–29`, UDM gateway
`10.20.0.1` (`docs/decisions.md` §2.1); the lab uses `10.99.100.0/24` (§2.4).

## Pre-checks

- [ ] You are on a trusted machine on the LAN, or on Tailscale (the remote path; no inbound ports exist,
      `docs/decisions.md` §5.2).
- [ ] You can reach the offline store: the restorable off-box copy of `talos/out/` (`talosconfig`,
      `kubeconfig`, machine configs — `docs/runbooks/talos-bootstrap.md`, `docs/disaster-recovery.md` §2) and
      the password manager holding the Proxmox/TrueNAS/UniFi credentials (`docs/secrets-and-state.md` §3).
- [ ] You know which layer is broken. Work bottom-up: network → hypervisor → Talos → Kubernetes → app.

## 1. Client-side DNS fallback

Technitium is a workload in the cluster, so it is never a dependency for reaching the cluster
(`docs/network-plan.md`, "DNS must not be a bootstrap circular dependency"). The UDM stays the
DHCP-advertised fallback resolver.

- **Only `*.lab.ardw.be` names break** when Technitium is down; public names keep resolving through the UDM.
- If a client is stuck on a dead primary resolver, point it at the UDM by IP (`<UDM_IP>`, the VLAN gateway)
  for the session, or simply use the IPs below. Do not "fix" it by publishing internal names in the public
  Cloudflare zone — that breaks the split horizon (`docs/decisions.md` §5.7).
- Need a lab hostname to work over HTTPS while DNS is down? Pin it locally instead:
  `curl --resolve auth.lab.ardw.be:443:<TRAEFIK_LB_IP> https://auth.lab.ardw.be/`, or a temporary
  `/etc/hosts` line you remove afterwards.

## 2. Network gear — UDM

- Web UI: `https://<UDM_IP>/` with the **local** UniFi admin account (password manager). Do not depend on a
  cloud/SSO UniFi login for recovery.
- Take a fresh configuration export before changing anything; the UniFi policy is additive-only
  (`docs/secrets-and-state.md` §4).

## 3. Hypervisor — Proxmox

- Web UI: `https://<PROXMOX_IP>:8006/` as `root@pam` (password manager). The API token used by OpenTofu is
  for automation, not for break-glass.
- SSH: `ssh root@<PROXMOX_IP>`.
- From there: VM consoles (noVNC / `qm terminal <vmid>` if a serial console is configured), `qm start|stop`,
  snapshots. A Talos node has no shell; its console only shows status.

## 4. Storage — TrueNAS

- Web UI: `https://<NAS_IP>/` with the local admin account (password manager). The API key is for
  automation.
- SSH, if enabled: `ssh <admin-user>@<NAS_IP>`. Tailscale already runs on the NAS (`docs/decisions.md`
  §5.2), so the Tailscale address works remotely.

## 5. Talos — `talosctl` by node IP

Use the `talosconfig` from the offline store and give the endpoint and node explicitly, so nothing depends
on a name or on the config's saved endpoints:

```sh
export TALOSCONFIG=/path/to/offline/talos/out/talosconfig
talosctl --endpoints <CONTROL_PLANE_IP> --nodes <CONTROL_PLANE_IP> version
talosctl --endpoints <CONTROL_PLANE_IP> --nodes <CONTROL_PLANE_IP> health
talosctl --endpoints <CONTROL_PLANE_IP> --nodes <CONTROL_PLANE_IP>,<WORKER_IP> services
talosctl --endpoints <CONTROL_PLANE_IP> --nodes <CONTROL_PLANE_IP> logs kubelet
talosctl --endpoints <CONTROL_PLANE_IP> --nodes <CONTROL_PLANE_IP> dmesg
```

The Talos API (port 50000) runs outside Kubernetes, so this works even when the API server, the CNI or
every pod is down.

## 6. Kubernetes — `kubectl` against the control-plane IP

Point at the control-plane **IP**, not a DNS name or a VIP:

```sh
export KUBECONFIG=/path/to/offline/talos/out/kubeconfig
kubectl --server https://<CONTROL_PLANE_IP>:6443 get nodes -o wide
```

If the kubeconfig is lost or its credentials have expired, mint a fresh admin one through Talos (written to
the gitignored `talos/out/`; treat it like the machine secrets):

```sh
talosctl --endpoints <CONTROL_PLANE_IP> --nodes <CONTROL_PLANE_IP> kubeconfig talos/out/kubeconfig --force
```

Talos puts the node IPs in the API server certificate, so `--server https://<CONTROL_PLANE_IP>:6443`
verifies without `--insecure-skip-tls-verify`.

## 7. In-cluster UIs without Traefik — `kubectl port-forward`

Port-forwarding goes through the API server, not through MetalLB or Traefik, and logs in with the app's
**local** admin, not Authentik.

| UI | Command | Then open | Local credential |
|---|---|---|---|
| Grafana | `kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80` | `http://127.0.0.1:3000` | Secret `grafana-admin` (`monitoring`), keys `admin-user`/`admin-password` |
| Technitium | `kubectl -n technitium port-forward svc/technitium 5380:5380` | `http://127.0.0.1:5380` | Secret `technitium-admin` (`technitium`), key `password`; user `admin` |
| Kopia | `kubectl -n kopia port-forward svc/kopia 51515:51515` | `https://127.0.0.1:51515` (self-signed) | Secret `kopia-server` (`kopia`), keys `username`/`password` |
| Audiobookshelf | `kubectl -n audiobookshelf port-forward svc/audiobookshelf 8080:8080` | `http://127.0.0.1:8080` | `root`, password chosen at the first visit (`sso.md`) |
| Authentik | `kubectl -n authentik port-forward svc/authentik-server 9000:80` | `http://127.0.0.1:9000` | `akadmin` / local recovery (below) |

Read a local admin password from its Secret only when you need it, and never into shell history or logs:
`kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo`.

If Authentik itself is the problem, a one-time recovery link for a local user comes from inside the pod:
`kubectl -n authentik exec deploy/authentik-server -- ak create_recovery_key 10 akadmin`
(prints a path to append to the URL; valid for the given number of minutes).

## 8. When MetalLB or Traefik is down

Nothing above needs them. To diagnose:

```sh
kubectl -n metallb get pods
kubectl -n metallb logs deploy/metallb-controller
kubectl -n traefik get pods,svc
kubectl get svc -A --field-selector spec.type=LoadBalancer   # EXTERNAL-IP <pending> = MetalLB not assigning
kubectl get ipaddresspools,l2advertisements -A
```

- **MetalLB down:** LoadBalancer IPs (`TRAEFIK_LB_IP`, `TECHNITIUM_LB_IP`) stop answering, so both the
  ingress and in-cluster DNS disappear at once. Use port-forward (§7) and the UDM resolver (§1).
- **Traefik down:** every `*.lab.ardw.be` UI is gone but the apps are fine; use port-forward (§7).
- Flux reconciles both from git. A fix is a commit to GitHub (the canonical remote, `docs/decisions.md`
  §5.6) — the self-hosted mirror is in the cluster and may be down with it.

## Rollback

This runbook only reads state and opens temporary tunnels. Undo anything temporary you added: `/etc/hosts`
pins, a manually set resolver, port-forwards, and any freshly minted kubeconfig you copied off the store.

## Verification

- [ ] `talosctl ... health` passes against `<CONTROL_PLANE_IP>`.
- [ ] `kubectl --server https://<CONTROL_PLANE_IP>:6443 get nodes` lists every node `Ready`.
- [ ] After the fix: `*.lab.ardw.be` resolves through Technitium again and the UIs answer through Traefik.
- [ ] Rehearse this runbook in the lab (`docs/lab.md`) with Technitium, Traefik and Authentik scaled to zero.
