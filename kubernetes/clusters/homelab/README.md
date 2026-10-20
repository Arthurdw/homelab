# Cluster: homelab — PRODUCTION

Flux entrypoints for the `homelab` cluster, **the real Talos cluster**. These `Kustomization`
objects are the *roots* Flux reconciles; everything under `kubernetes/infrastructure` and
`kubernetes/apps` is pulled in from them.

`cluster-settings.yaml` holds this environment's values (`METALLB_POOL` = `10.20.0.100-10.20.0.199`,
`NFS_SERVER` = `10.99.0.2`). Each Kustomization reads it via `postBuild.substituteFrom`. The lab
counterpart is `../lab/`; keep the two key sets identical — `scripts/ci/check-cluster-settings.sh`
enforces that.

## Bootstrap

Flux is installed once with `flux bootstrap` (see `docs/PROJECT-PLAN.md`), which creates `flux-system/`
(`gotk-components.yaml`, `gotk-sync.yaml`) **inside this directory on the cluster branch**. Those
generated files are not hand-written here.

```sh
# Illustrative — run only at the appropriate gated step:
flux bootstrap github \
  --owner=<owner> --repository=homelab \
  --path=kubernetes/clusters/homelab --personal
```

After bootstrap, add the SOPS age key Secret out-of-band (never committed):

```sh
kubectl -n flux-system create secret generic sops-age \
  --from-file=age.agekey="$HOME/.config/sops/age/keys.txt"
```

`cluster-settings.yaml` is a normal committed manifest, applied by the cluster's root
Kustomization along with these files. (There is deliberately no committed root
`kustomization.yaml`: `flux bootstrap` generates the `flux-system/` scope, and kustomize-controller
auto-generates the root one from the plain manifests here. See `kubernetes/README.md`.)

## Order

- `infrastructure.yaml` → `./kubernetes/infrastructure` (controllers, DNS, ingress, certs)
- `infrastructure-configs.yaml` → `./kubernetes/infrastructure/configs` (`dependsOn: infrastructure`)
- `apps.yaml` → `./kubernetes/apps` (`dependsOn: infrastructure-configs`)
