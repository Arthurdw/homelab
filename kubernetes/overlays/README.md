# Per-cluster overlays

The shared trees (`kubernetes/infrastructure`, `kubernetes/apps`) are identical for every cluster. What
differs per cluster is in two places:

- **Plain values** go in `kubernetes/clusters/<cluster>/cluster-settings.yaml` and reach the shared tree through
  Flux `postBuild.substituteFrom`.
- **Secrets** go here, because each cluster decrypts with its own age key. A Secret encrypted for the lab
  can't be read by production, so it can't live in the shared tree.

```text
overlays/<cluster>/infrastructure/   # Flux Kustomization `infrastructure` points here
overlays/<cluster>/apps/             # Flux Kustomization `apps` points here
```

Each overlay's `kustomization.yaml` lists the shared tree (`../../../<layer>`) plus that cluster's
`*.sops.yaml` Secrets. A Secret is applied in the same Flux apply as its namespace, so nothing waits on
ordering between Kustomizations. `infrastructure-configs` has no overlay, because it needs no secrets.

## Encryption

`.sops.yaml` picks the recipient by path:

| Path | Recipient |
|---|---|
| `overlays/lab/**.sops.yaml` | the lab key (`~/.config/homelab/lab-age.key`) |
| `overlays/homelab/**.sops.yaml` | production. This is a placeholder until the key ceremony, so encryption fails closed |

Only `data` and `stringData` are encrypted, so kustomize can still read `kind` and `metadata`. CI strips the
`sops:` metadata block before kubeconform.

- **Lab:** `scripts/secrets/gen-lab-secrets.sh` writes every lab Secret with random values and encrypts it.
  The values are disposable: if the lab key is lost, delete the files and rerun the script.
- **Production:** blocked on the age key ceremony (`docs/runbooks/secrets.md` §2). The Secrets the cluster
  needs are listed in `homelab/README.md`. Until they exist, the workloads that reference them stay pending.
