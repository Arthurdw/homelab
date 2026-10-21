# Requires TrueNAS >= 25.04 (25.10 preferred). The pinned provider (truenas/truenas 1.5.14) speaks
# only the JSON-RPC API at /api/current. The owner reinstalled hercules-nas on SCALE 25.10.7 on
# 2026-10-21 (versions.yaml), which matches the lab fixture where this root was proven; the live
# apply is still owner-gated. See README.md.
#
# Additive-only. This root creates new objects under an existing pool. It never manages the pool
# itself or existing datasets/shares (`main`, `main/arthur`, `main/proxmox`, ...): docs/storage.md,
# docs/decisions.md §1.4.

# -----------------------------------------------------------------------------
# Kubernetes NFS export (decisions.md §4.1, §4.2)
# -----------------------------------------------------------------------------

# Parent dataset for csi-driver-nfs. Each PVC becomes a sub-directory (<namespace>/<name>), not
# a child dataset (kubernetes/infrastructure/storage/release.yaml). Compression, recordsize,
# encryption, acltype etc. are inherited from the pool on purpose: nothing here is decided.
resource "truenas_dataset" "k8s" {
  name     = var.k8s_dataset_name
  comments = "Managed by OpenTofu (infrastructure/environments/homelab/truenas): Kubernetes nas-nfs PVCs"

  # Create-only preset. NFS gives a POSIX ACL type that suits root-owned NFS writes.
  share_type = "NFS"

  lifecycle {
    # The dataset holds application PV data. Destroying it is irreversible data loss
    # (PROJECT-PLAN red line). Removing it takes a deliberate code change.
    prevent_destroy = true
  }
}

# The export csi-driver-nfs mounts as ${NFS_SERVER}:/mnt/main/k8s with nfsvers=4.1.
resource "truenas_nfs_share" "k8s" {
  path    = "/mnt/${truenas_dataset.k8s.name}"
  comment = "Managed by OpenTofu: csi-driver-nfs (StorageClass nas-nfs)"
  enabled = true

  # Restrict to the storage link only (10.99.0.0/29). The Talos nodes mount from their own link
  # NIC (.3/.4), not through a router (decisions.md §2.2).
  networks = var.k8s_nfs_allowed_networks

  # no_root_squash: the driver mkdirs and chowns each PVC directory as root. maproot (not mapall)
  # keeps client root as root and leaves other UIDs untouched, which is what pods need. The
  # provider makes mapall_* and maproot_* mutually exclusive.
  maproot_user  = var.k8s_nfs_maproot_user
  maproot_group = var.k8s_nfs_maproot_group

  security = ["SYS"]

  lifecycle {
    prevent_destroy = true
  }
}

# Daily recursive snapshots with 14-day retention (decisions.md §4.1, "main/k8s NFS export"). This is
# the point-in-time protection for nas-nfs PVCs (no CSI snapshotter is installed). Offsite
# backup of the same dataset is a separate decision (§5.5, undecided) and is not expressed here.
resource "truenas_periodic_snapshot_task" "k8s" {
  dataset        = truenas_dataset.k8s.name
  recursive      = true
  enabled        = true
  lifetime_value = 14
  lifetime_unit  = "DAY"
  naming_schema  = "auto-%Y-%m-%d_%H-%M"

  # 00:15 daily. The time is a choice, not a decision: it stays clear of the existing 00:00 task on `main`.
  schedule = {
    minute = "15"
    hour   = "0"
    dom    = "*"
    month  = "*"
    dow    = "*"
  }
}
