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

Neither class is the cluster default, so a PVC without a class stays Pending.

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

- **The data path is a Talos user volume.** The chart default `/opt/local-path-provisioner` is on
  Talos' read-only rootfs, and `/var` is the wipeable `EPHEMERAL` partition. `nodePathMap` points at
  `/var/mnt/local-path-provisioner`, the mount point of the worker's `UserVolumeConfig`
  (`talos/patches/worker.yaml`, on the 100 GiB data disk, `docs/decisions.md` §3.4). The volume name
  and `nodePathMap` must stay in sync. Not runtime-verified. The libvirt lab worker has no such
  volume, so there the path lives on EPHEMERAL.
- **No HA.** One worker (`docs/decisions.md` §3.1): if the node or its data disk is lost, the PVs
  are gone. Recovery is the scheduled logical database dumps on the NAS.
- **`reclaimPolicy: Retain`** — deleting a PVC leaves the directory and a `Released` PV behind.
  Clean both up deliberately when you mean to.

## Validation

```sh
kubectl kustomize kubernetes/infrastructure/local-path | kubeconform -strict -ignore-missing-schemas
scripts/ci/render-helm-releases.sh          # renders this HelmRelease too
```
