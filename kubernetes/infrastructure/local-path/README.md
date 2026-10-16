# local-path — node-local dynamic PVs for latency-sensitive databases

Rancher's `local-path-provisioner`, installed as a single Flux `HelmRelease` in the `local-path`
namespace (official upstream OCI chart; see `source.yaml` and `release.yaml`). It provides the
StorageClass **`local-path`** that the database manifests already name
(`kubernetes/apps/immich/postgres.yaml`, `kubernetes/apps/audiobookshelf/release.yaml`).

## Which class do I use?

| Class | Backing | Use for |
|---|---|---|
| `nas-nfs` | NAS over NFS (`main/k8s` export) | Bulk/application data that can tolerate network latency (kubernetes/infrastructure/storage). |
| `local-path` | **Node SSD**, Talos user volume `/var/mnt/local-path-provisioner` | **Latency-sensitive databases** — `docs/decisions.md` §4.3. No replication. |

Neither class is the cluster default on purpose, so a PVC that forgets to name one fails loudly
instead of landing somewhere wrong.

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: example-db
spec:
  storageClassName: local-path
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 20Gi
```

## Read this before trusting the data — Talos + no-HA

- **The data path is a Talos user volume, not a directory on `/var`.** `/var` is the wipeable
  `EPHEMERAL` partition; the chart's default `/opt/local-path-provisioner` is on Talos' read-only
  rootfs and cannot be written at all. We point `nodePathMap` at `/var/mnt/local-path-provisioner`.
  See `release.yaml` for the full evidence trail and URLs.
- **This release is INERT until a machine-config change exists.** The `/var/mnt/local-path-provisioner`
  mount comes from a Talos `UserVolumeConfig` on the worker, backed by a **dedicated data disk**.
  Until `talos/**` + `infrastructure/**` (another workstream) add that disk and document, PVCs will
  provision under the path but nothing guarantees the mount is a persistent partition. Required
  change is spelled out in `release.yaml`.
- **No HA.** One worker, one host (`docs/decisions.md` §3.1). Rebuild the node, destroy the VM, or
  wipe its data disk and the Local PVs are gone. There is no replica. The only recovery path is the
  scheduled logical database dumps on the NAS — this class protects *latency*, not *durability*.
- **`reclaimPolicy: Retain`** — deleting a PVC leaves the directory and a `Released` PV behind.
  Clean both up deliberately when you mean to.

## Validation

```sh
kubectl kustomize kubernetes/infrastructure/local-path | kubeconform -strict -ignore-missing-schemas
scripts/ci/render-helm-releases.sh          # renders this HelmRelease too
```
