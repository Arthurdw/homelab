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
  infrastructure/            # cluster-wide controllers/sources (Flux, MetalLB, ingress, DNS, certs)
    configs/                   # custom resources that need CRDs from the controllers above
  apps/                      # user-facing workloads
```

Reconciliation order is expressed with `dependsOn`:
**infrastructure (controllers) → infrastructure-configs (CRs) → apps.**

Splitting controllers from configs is not cosmetic: a `ClusterIssuer` or `IPAddressPool` sits in the same
Kustomization as the HelmRelease that installs its CRD, and Flux dry-runs the whole set before any of it
exists. The lab caught exactly that (`no matches for kind "ClusterIssuer"`) — see
`docs/runbooks/phase-reports/`.

Reconciliation order is expressed with `dependsOn`: controllers before configs, infrastructure before apps.

## Placeholders (replace at GATE 0)

These are deliberate RFC-placeholder values so nothing resembles a real address/domain:

| Placeholder | Meaning |
|---|---|
| `homelab.internal` | internal domain — TBD |
| `192.0.2.0/24` (TEST-NET-1) | MetalLB address pool — TBD |
| `*.example` chart versions/values | pin/verify before first apply |

## Versions

Chart versions below were the latest on Artifact Hub as of **2026-10-16**:

| Component | Chart | Version | Source |
|---|---|---|---|
| MetalLB | `metallb` | 0.16.1 | `https://metallb.github.io/metallb` |
| Traefik | `traefik` | 42.0.0 | `https://traefik.github.io/charts` |
| cert-manager | `cert-manager` | 1.21.2 | `https://charts.jetstack.io` |
| Technitium DNS | `technitium-dnsserver` | 1.13.4 | `https://charts.obeone.cloud` |
| Immich | `immich` (OCI) | 0.13.2 | `oci://ghcr.io/immich-app/immich-charts/immich` |
| Audiobookshelf | `audiobookshelf` | 2.5.1 | `https://charts.christianhuth.de` |

Renovate/Dependabot should keep these current (see `.github/dependabot.yml` and `docs/PROJECT-PLAN.md`).

## Secrets

SOPS-encrypted manifests are decrypted by Flux with an `age` key stored **outside** this repo in a
`sops-age` Secret in `flux-system`. See `docs/secrets-and-state.md`. **Never** commit plaintext secrets or the
age private key.

## Status

Scaffold. Nothing here has been applied to a live cluster. Validate locally with `just k8s-validate`.
