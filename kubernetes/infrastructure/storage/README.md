# storage — dynamic NFS storage for application PVCs

Backed by the NAS over NFS. Deployed as a single Flux `HelmRelease`
(`csi-driver-nfs`) in the `storage` namespace; see `release.yaml` for the full rationale.

## Which class do I use?

| Class | Backing | Use for |
|---|---|---|
| `nas-nfs` | NAS over NFS (`main/k8s` export) | Bulk/application data: media libraries, documents, caches — anything that can tolerate network latency. |
| `local-path` | node SSD (a Talos user volume) | **Latency-sensitive databases** — `docs/decisions.md` §4.3. Provided by `kubernetes/infrastructure/local-path`. |

Neither class is the cluster default, so a PVC that forgets to name a class does not silently
land anywhere. Databases must name `local-path` explicitly; do not point them at `nas-nfs`.

`local-path` is **node-local and not replicated**: it buys latency, not durability. With one
worker and no HA, losing that node loses those volumes — the logical database dumps on the NAS
are the recovery path, not this class.

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: example
spec:
  storageClassName: nas-nfs
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 10Gi
```

## Operational notes

- **Each PV is a sub-directory**, not a ZFS dataset: `<export>/<namespace>/<pvc-uid>`.
  The NAS owns the data; there is nothing to restore outside ZFS (`docs/architecture.md` §7).
- **`reclaimPolicy: Retain`** — deleting a PVC leaves the directory and a `Released` PV behind.
  Remove both deliberately (`kubectl delete pv <name>` and the directory) when you mean to.
- **Snapshots are the NAS's job** (`docs/decisions.md` §4.1, recursive per-dataset policy on
  `main/k8s`). Kubernetes `VolumeSnapshot` is not wired up on purpose.
- **NAS prerequisite:** the export must allow root writes (`no_root_squash`), or provisioning
  and `fsGroup` mounts fail. Recorded, not fixed, until the NAS build (`docs/decisions.md` §1.2).
- **Sizing:** `accessModes` must be `ReadWriteOnce` or `ReadWriteMany`; NFS has no real size
  enforcement, so `storage: NGi` is a quota-of-intent, not a hard limit. Capacity is whatever
  the `main` pool has left.

## Validation

```sh
kubectl kustomize kubernetes/infrastructure/storage | kubeconform -strict -ignore-missing-schemas
scripts/ci/render-helm-releases.sh          # renders this HelmRelease too
```
