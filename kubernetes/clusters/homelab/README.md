# Cluster: homelab

Flux entrypoints for the `homelab` cluster. These `Kustomization` objects are the *roots* Flux reconciles;
everything under `kubernetes/infrastructure` and `kubernetes/apps` is pulled in from them.

## Bootstrap

Flux is installed once with `flux bootstrap` (see `docs/PROJECT-PLAN.md`), which creates `flux-system/`
(`gotk-components.yaml`, `gotk-sync.yaml`) **inside this directory on the cluster branch**. Those generated
files are not hand-written here.

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

## Order

- `infrastructure.yaml` → `./kubernetes/infrastructure` (controllers, DNS, ingress, certs)
- `apps.yaml` → `./kubernetes/apps` (`dependsOn: infrastructure`)
