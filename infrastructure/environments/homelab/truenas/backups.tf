# Household device backups and Seafile (decisions.md §5.9, §5.8, §4.1).
#
#   Time Machine  jolien's Mac -> SMB share on main/backups/timemachine/jolien (one user, quota)
#   Kopia         dunia (Windows) and arthur (Linux) -> repository server in Kubernetes
#                 (kubernetes/apps/kopia, kopia.lab.ardw.be) -> NFS export of main/backups/kopia
#   Seafile       anywhere-access -> NFS export of main/apps/seafile (decisions.md §5.8)
#
# Same additive-only rule as k8s.tf: new objects under the existing pool, nothing imported, no
# destroy. The accounts, including the one imported admin, are in users.tf. Every dataset and share
# carries prevent_destroy; they hold other people's backups.

# -----------------------------------------------------------------------------
# Time Machine for jolien's Mac (SMB)
# -----------------------------------------------------------------------------

resource "truenas_dataset" "backups" {
  name     = "main/backups"
  comments = "Managed by OpenTofu (infrastructure/environments/homelab/truenas): parent of the household backup targets"

  lifecycle {
    prevent_destroy = true
  }
}

resource "truenas_dataset" "timemachine" {
  name     = "main/backups/timemachine"
  comments = "Managed by OpenTofu: Time Machine targets, one child dataset per Mac"

  share_type = "SMB"

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [truenas_dataset.backups]
}

# One dataset per Mac, so each Mac has its own quota and its own snapshots. Time Machine fills a disk to
# 100 %, so the quota is the only thing that stops one Mac from taking the pool. The size is the owner's
# call (var.timemachine_jolien_quota_gib), hence no default.
resource "truenas_dataset" "timemachine_jolien" {
  name     = "main/backups/timemachine/jolien"
  comments = "Managed by OpenTofu: Time Machine sparsebundle for jolien's Mac"

  share_type = "SMB"
  quota      = var.timemachine_jolien_quota_gib * 1024 * 1024 * 1024

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [truenas_dataset.timemachine]
}

# The SMB account is truenas_user.jolien in users.tf, created by this root with its own primary group.

# The Mac writes as this user over SMB, so the dataset belongs to it. The SMB preset gives the dataset an
# NFSv4 ACL, so this sets the ACL (a plain mode is refused while an ACL is present): the owner has full
# control, inherited by new files, and no other entry exists, so nobody else on the NAS can read a bundle.
resource "truenas_filesystem_acl" "timemachine_jolien" {
  path = "/mnt/${truenas_dataset.timemachine_jolien.name}"
  uid  = truenas_user.jolien.uid

  entries = jsonencode([
    {
      tag   = "owner@"
      id    = null
      type  = "ALLOW"
      perms = { BASIC = "FULL_CONTROL" }
      flags = { BASIC = "INHERIT" }
    },
  ])
}

# purpose = TIMEMACHINE_SHARE is the SCALE "Time Machine" preset (the legacy `timemachine` flag is not
# used). It turns on the Apple extensions, advertises the share over mDNS and keeps each Mac inside
# its quota. It is refused unless the SMB service has "Apple SMB2/3 protocol extensions" on. That is a
# NAS-wide setting (truenas_smb_config is a singleton that already exists and serves the other shares), so it is
# a manual prerequisite, like the NFS service settings in README.md, not managed here. auto_snapshot is off because the periodic task below already snapshots daily.
resource "truenas_smb_share" "timemachine_jolien" {
  name    = var.timemachine_jolien_share_name
  path    = "/mnt/${truenas_dataset.timemachine_jolien.name}"
  comment = "Managed by OpenTofu: Time Machine for jolien's Mac"
  enabled = true
  purpose = "TIMEMACHINE_SHARE"

  options = {
    timemachine_quota = var.timemachine_jolien_quota_gib
    auto_snapshot     = false
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [truenas_filesystem_acl.timemachine_jolien]
}

# Share-level access for exactly one account. TrueNAS's default entry is "everyone", which this replaces.
resource "truenas_smb_share_acl" "timemachine_jolien" {
  share_name = truenas_smb_share.timemachine_jolien.name

  share_acl = [
    {
      # By UID: a name lookup needs the SMB service (winbind) running, an ID does not.
      ae_who_id = { id_type = "USER", id = truenas_user.jolien.uid }
      ae_perm   = "FULL"
      ae_type   = "ALLOWED"
    },
  ]
}

# Time Machine keeps its own hourly/daily/weekly history inside the sparsebundle, so ZFS snapshots only
# guard against the bundle itself being damaged or deleted. Daily / 7 d is enough for that (decisions.md §4.1).
resource "truenas_periodic_snapshot_task" "timemachine" {
  dataset        = truenas_dataset.timemachine.name
  recursive      = true
  enabled        = true
  lifetime_value = 7
  lifetime_unit  = "DAY"
  naming_schema  = "auto-%Y-%m-%d_%H-%M"

  # 00:30 daily, clear of the 00:00 task on `main` and the 00:15 k8s task.
  schedule = {
    minute = "30"
    hour   = "0"
    dom    = "*"
    month  = "*"
    dow    = "*"
  }
}

# -----------------------------------------------------------------------------
# Kopia repository (NFS, mounted by the Kopia server in Kubernetes)
# -----------------------------------------------------------------------------

resource "truenas_dataset" "kopia" {
  name     = "main/backups/kopia"
  comments = "Managed by OpenTofu: Kopia repository for dunia and arthur"

  # Kopia writes content-addressed blobs as root inside its pod; NFS gives the matching POSIX ACL type.
  share_type = "NFS"

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [truenas_dataset.backups]
}

# Same restriction and root mapping as the k8s export: the repository server mounts it from the cluster.
resource "truenas_nfs_share" "kopia" {
  path    = "/mnt/${truenas_dataset.kopia.name}"
  comment = "Managed by OpenTofu: Kopia repository server"
  enabled = true

  networks = var.k8s_nfs_allowed_networks

  maproot_user  = var.k8s_nfs_maproot_user
  maproot_group = var.k8s_nfs_maproot_group

  security = ["SYS"]

  lifecycle {
    prevent_destroy = true
  }
}

# Kopia versions and deduplicates inside the repository, so a ZFS snapshot is a second line against
# repository corruption, not the history. Daily / 14 d (decisions.md §4.1).
resource "truenas_periodic_snapshot_task" "kopia" {
  dataset        = truenas_dataset.kopia.name
  recursive      = true
  enabled        = true
  lifetime_value = 14
  lifetime_unit  = "DAY"
  naming_schema  = "auto-%Y-%m-%d_%H-%M"

  # 00:45 daily.
  schedule = {
    minute = "45"
    hour   = "0"
    dom    = "*"
    month  = "*"
    dow    = "*"
  }
}

# -----------------------------------------------------------------------------
# Application data (NFS): main/apps/*
# -----------------------------------------------------------------------------

# Only seafile exists so far. immich and audiobookshelf (§4.1) get their own dataset and share when
# their manifests move onto NFS; they inherit the hourly task below as children of main/apps.
resource "truenas_dataset" "apps" {
  name     = "main/apps"
  comments = "Managed by OpenTofu: application data, one child dataset per app"

  lifecycle {
    prevent_destroy = true
  }
}

resource "truenas_dataset" "seafile" {
  name     = "main/apps/seafile"
  comments = "Managed by OpenTofu: Seafile libraries (content-addressed blocks, not browsable over SMB)"

  share_type = "NFS"

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [truenas_dataset.apps]
}

resource "truenas_nfs_share" "seafile" {
  path    = "/mnt/${truenas_dataset.seafile.name}"
  comment = "Managed by OpenTofu: Seafile data"
  enabled = true

  networks = var.k8s_nfs_allowed_networks

  maproot_user  = var.k8s_nfs_maproot_user
  maproot_group = var.k8s_nfs_maproot_group

  security = ["SYS"]

  lifecycle {
    prevent_destroy = true
  }
}

# Hourly / 14 d, recursive, for every app dataset (decisions.md §4.1).
resource "truenas_periodic_snapshot_task" "apps" {
  dataset        = truenas_dataset.apps.name
  recursive      = true
  enabled        = true
  lifetime_value = 14
  lifetime_unit  = "DAY"
  naming_schema  = "auto-%Y-%m-%d_%H-%M"

  schedule = {
    minute = "5"
    hour   = "*"
    dom    = "*"
    month  = "*"
    dow    = "*"
  }
}
