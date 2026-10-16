# Kubernetes (Flux GitOps)

Declarative cluster state. **Flux is the only thing that applies anything here** — no manual `kubectl apply`
except for bootstrapping Flux itself.

## Layout

```text
kubernetes/
  clusters/homelab/          # Flux entrypoints for THIS cluster (the reconciliation roots)
    infrastructure.yaml        # -> ./kubernetes/infrastructure            (controllers)
    infrastructure-configs.yaml# -> ./kubernetes/infrastructure/configs    (CRs; needs CRDs)
    apps.yaml                  # -> ./kubernetes/apps                      (workloads)
    flux-system/               # created by `flux bootstrap` (not committed) + SOPS age key
  infrastructure/            # cluster-wide controllers/sources (CNI, MetalLB, ingress, DNS, certs, storage)
    configs/                   # custom resources that need CRDs from the controllers above
  apps/                      # user-facing workloads
```

Reconciliation order is expressed with `dependsOn`:
**infrastructure (controllers) → infrastructure-configs (CRs) → apps.**

Splitting controllers from configs is not cosmetic: a `ClusterIssuer` or `IPAddressPool` sits in the same
Kustomization as the HelmRelease that installs its CRD, and Flux dry-runs the whole set before any of it
exists. The lab caught exactly that (`no matches for kind "ClusterIssuer"`) — see
`docs/runbooks/phase-reports/`.

## Versions

`versions.yaml` at the repo root is the single source of truth; this table is a convenience view.
Every chart version below was verified against its upstream index or registry on **2026-10-16**.

| Component | Chart | Version | Source |
|---|---|---|---|
| Cilium (CNI) | `cilium` | 1.20.3 | `https://helm.cilium.io` |
| MetalLB | `metallb` | 0.16.1 | `https://metallb.github.io/metallb` |
| Traefik | `traefik` | 42.0.0 | `https://traefik.github.io/charts` |
| cert-manager | `cert-manager` | 1.21.2 | `https://charts.jetstack.io` |
| Technitium DNS | `technitium-dnsserver` | 1.13.4 | `https://charts.obeone.cloud` |
| Monitoring | `kube-prometheus-stack` | 92.10.0 | `https://prometheus-community.github.io/helm-charts` |
| NFS CSI driver | `csi-driver-nfs` | 4.13.5 | `https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts` |
| Node-local storage | `local-path-provisioner` (OCI) | 0.0.37 | `oci://ghcr.io/rancher/local-path-provisioner/charts/local-path-provisioner` |
| Immich | `immich` (OCI) | 0.13.4 | `oci://ghcr.io/immich-app/immich-charts/immich` |
| Audiobookshelf | `audiobookshelf` | 2.5.1 | `https://charts.christianhuth.de` |

Renovate/Dependabot should keep these current (see `.github/dependabot.yml` and `docs/PROJECT-PLAN.md`).

## Environment-specific values — decided, but NOT yet parameterized

The address plan is decided (`docs/decisions.md` §2), yet some manifests still carry placeholders or
**lab** values, because no per-environment overlay exists yet. This table is the gap, not a wish list:

| Value in the tree | Where | Intended production value |
|---|---|---|
| `192.0.2.240–250` (TEST-NET-1) | `infrastructure/configs/metallb-pool.yaml` | `10.20.0.100–199` on the K8s VLAN |
| NAS NFS server `10.99.100.10` | `infrastructure/storage/release.yaml` | `10.99.0.2` over the 10 GbE storage link |

**Consequence:** applying this tree to production as it stands would advertise a non-routable TEST-NET-1
range and mount NFS from the lab NAS. The environment-overlay workstream closes this; until it lands,
production must not be applied from this tree.

## Secrets

SOPS-encrypted manifests are decrypted by Flux with an `age` key stored **outside** this repo in a
`sops-age` Secret in `flux-system`. See `docs/secrets-and-state.md`. **Never** commit plaintext secrets or the
age private key.

## Status

The tree is **lab-verified in kind**: Flux reconciles it and cert-manager, MetalLB and Traefik install
cleanly. Nothing has been applied to the real hosts, and no Talos cluster exists yet, so every `HelmRelease`
here is verified by render + schema only. Validate locally with `just k8s-validate` and `just render-strict`.
