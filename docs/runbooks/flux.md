# Runbook: seeing what Flux is doing

Flux has no UI of its own in the cluster, and none is deployed on purpose. Every admin page means another
login, another Ingress and another thing to patch. Use these three views instead:

- **Grafana:** dashboards that are always on. They are read-only and sit behind the existing Authentik login.
- **Alertmanager:** an email when something stays broken.
- **Capacitor:** a local UI on your PC, for poking around.

## What lives where

- **Grafana → Dashboards → "Flux Cluster Stats":** every Kustomization, HelmRelease and source, with its
  ready/suspended state and the revision it applied.
- **Grafana → Dashboards → "Flux Control Plane":** the controllers themselves: reconcile durations, queue
  depth, CPU and memory.
- **Where the dashboard JSON comes from:** `kubernetes/infrastructure/monitoring/dashboards/`, taken unchanged
  from fluxcd/flux2-monitoring-example.
- **Where the data comes from:**
  - `gotk_resource_info`, from kube-state-metrics' custom-resource config in
    `kubernetes/infrastructure/monitoring/release.yaml`.
  - The controllers' metrics, scraped by `kubernetes/infrastructure/configs/flux-podmonitor.yaml`.
- **`FluxReconciliationFailure` (warning):** fires when an object that is not suspended has been `Ready=False`
  for 15 minutes. It arrives by email like the other alerts. The cluster keeps running the last revision that
  applied, so nothing is down: new commits are simply not landing.

## Capacitor (local UI)

[Capacitor Next](https://github.com/gimlet-io/capacitor) is a single binary that runs on your PC. It serves a
web UI on localhost and talks to the cluster through your kubeconfig, so nothing runs in the cluster.

It has whatever rights the kubeconfig has. With the admin kubeconfig it can reconcile, suspend and resume
objects, and a click is a live write.

Install it once:

- with Homebrew: `brew install gimlet-io/capacitor/capacitor`
- or download `next-Linux-x86_64` from the project's GitHub releases and put it on your `PATH` as `next`

Run it with `kubectl config use-context homelab && next --port 3333`, then open `http://localhost:3333`.
Stop it with Ctrl-C.

## CLI equivalents

```bash
flux get all -A --status-selector ready=false   # anything not Ready
flux get kustomizations -A                      # the layer order: infrastructure → configs → apps
flux get helmreleases -A
flux events -A --types Warning                  # why something failed
flux logs --level error --since 1h
```

## Pre-checks

- [ ] `flux check` passes. A missing controller shows up here before it shows up anywhere else.
- [ ] Prometheus → Status → Targets: the `podMonitor/flux-system/flux-system` targets are UP (four of them,
      one per controller).
- [ ] Prometheus query `count by (customresource_kind) (gotk_resource_info)` returns Kustomization,
      HelmRelease, HelmRepository and GitRepository.

## Verification

- [ ] Both dashboards appear in Grafana under Dashboards and show data for the last hour.
- [ ] `FluxReconciliationFailure` shows as inactive under Alerts in Prometheus (`/alerts`).

## Rollback

All of this is read-only monitoring. To remove it, revert the commit that added it. Flux then prunes the
PodMonitor and the dashboard ConfigMap, and kube-state-metrics goes back to the chart defaults. Capacitor
leaves nothing behind on the cluster: delete the binary.
