# Tier datasets and their snapshot policy (decisions.md §4.1).
#
#   main/tier1/{arthur,jolien,dunia}   SMB       hourly / 30 d   (this file)
#   main/apps/{...}                    NFS       hourly / 14 d   (backups.tf: seafile today)
#   main/k8s                           NFS       daily  / 14 d   (k8s.tf)
#   main/backups/timemachine, kopia    SMB / NFS daily  / 7 d, 14 d (backups.tf)
#   main/media  (Tier-3)               SMB/NFS   weekly / 4 w    (this file)
#   main/scratch (Tier-4)              none      none            (this file)
#
# The "Offsite" column of §4.1 is not expressed anywhere in this root: the target is undecided
# (decisions.md §5.5).
#
# Same additive-only rule as k8s.tf: new objects under the existing pool, nothing imported. The pool was
# rebuilt empty on 2026-10-21 (decisions.md §1.4, docs/storage.md), so these datasets start empty.
#
# What §4.1 leaves open, and this file therefore does not decide: quotas and reservations, the SMB and NFS
# shares themselves (names, users, ACLs, allowed networks) and which person's data lands where. Each is a
# TODO(owner) below. Datasets without a share are not reachable by anything yet, which is the safe default.
# The one exception so far is jolien's share and photo archive (decisions.md §5.17), at the end of the Tier 1
# section. Compression, recordsize, encryption etc. are inherited from the pool on purpose, as in k8s.tf;
# only the photo archive sets its own recordsize.

# -----------------------------------------------------------------------------
# Tier 1: personal data (SMB), hourly / 30 d
# -----------------------------------------------------------------------------

resource "truenas_dataset" "tier1" {
  name     = "main/tier1"
  comments = "Managed by OpenTofu (infrastructure/environments/homelab/truenas): personal data, one child dataset per person"

  lifecycle {
    prevent_destroy = true
  }
}

# One dataset per person, so each has their own snapshots, and a quota can be set per person later.
# TODO(owner): quotas, the SMB share per person and its account/ACL for arthur and dunia are not in §4.1
# (jolien's are below, §5.17). Which existing data belongs to which tier is the owner's call too.
resource "truenas_dataset" "tier1_arthur" {
  name     = "main/tier1/arthur"
  comments = "Managed by OpenTofu: arthur's personal data (Tier 1)"

  share_type = "SMB"

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [truenas_dataset.tier1]
}

# The quota covers the photos child and the snapshots of both (decisions.md §5.17).
resource "truenas_dataset" "tier1_jolien" {
  name     = "main/tier1/jolien"
  comments = "Managed by OpenTofu: jolien's personal data (Tier 1)"

  share_type = "SMB"
  quota      = var.tier1_jolien_quota_gib * 1024 * 1024 * 1024

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [truenas_dataset.tier1]
}

resource "truenas_dataset" "tier1_dunia" {
  name     = "main/tier1/dunia"
  comments = "Managed by OpenTofu: dunia's personal data (Tier 1)"

  share_type = "SMB"

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [truenas_dataset.tier1]
}

# jolien's share and photo archive (decisions.md §5.17; docs/runbooks/household-backups.md, section d).
# FreeFileSync on her Mac copies each external drive to photos/drives/<drive name>/ over SMB. The tier1
# task below snapshots it hourly, so a file deleted or overwritten on the NAS stays restorable for 30 days.
#
# photos is its own dataset for three reasons:
# - its recordsize can differ: 1M suits multi-MB RAW and project files (less metadata, better compression),
#   and recordsize only applies to blocks written after it is set, so it has to be right from the start;
# - offsite replication and an Immich external library can later take the archive alone;
# - its usage shows up on its own in the UI.
resource "truenas_dataset" "tier1_jolien_photos" {
  name     = "main/tier1/jolien/photos"
  comments = "Managed by OpenTofu: jolien's photo archive, a FreeFileSync copy of her external drives (Tier 1)"

  share_type = "SMB"
  recordsize = "1M"

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [truenas_dataset.tier1_jolien]
}

# The same owner-only ACL as the Time Machine share (backups.tf): jolien owns both paths, and INHERIT
# passes it on to every file and folder she creates. photos gets its own ACL because a child dataset is a
# separate filesystem with its own root, created with the SMB preset's default ACL, not the parent's.
# The NAS admin (root) can still read everything for a restore.
resource "truenas_filesystem_acl" "tier1_jolien" {
  path = "/mnt/${truenas_dataset.tier1_jolien.name}"
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

resource "truenas_filesystem_acl" "tier1_jolien_photos" {
  path = "/mnt/${truenas_dataset.tier1_jolien_photos.name}"
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

# One share at the top of her dataset, so photos/ shows up as a folder in it. DEFAULT_SHARE is the
# plain-file preset; no per-purpose options are needed (Apple's SMB extensions are already on NAS-wide
# for Time Machine). Snapshots come from the tier1 task, not the share.
resource "truenas_smb_share" "tier1_jolien" {
  name    = var.tier1_jolien_share_name
  path    = "/mnt/${truenas_dataset.tier1_jolien.name}"
  comment = "Managed by OpenTofu: jolien's personal data and photo archive"
  enabled = true
  purpose = "DEFAULT_SHARE"

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [
    truenas_filesystem_acl.tier1_jolien,
    truenas_filesystem_acl.tier1_jolien_photos,
  ]
}

# Share-level access: jolien only, by UID like the Time Machine share.
resource "truenas_smb_share_acl" "tier1_jolien" {
  share_name = truenas_smb_share.tier1_jolien.name

  share_acl = [
    {
      ae_who_id = { id_type = "USER", id = truenas_user.jolien.uid }
      ae_perm   = "FULL"
      ae_type   = "ALLOWED"
    },
  ]
}

# Hourly / 30 d, recursive, so every person's dataset is covered (decisions.md §4.1).
resource "truenas_periodic_snapshot_task" "tier1" {
  dataset        = truenas_dataset.tier1.name
  recursive      = true
  enabled        = true
  lifetime_value = 30
  lifetime_unit  = "DAY"
  naming_schema  = "auto-%Y-%m-%d_%H-%M"

  # Minute 10 of every hour, clear of the apps task (minute 5) and the 00:00-00:45 daily tasks.
  schedule = {
    minute = "10"
    hour   = "*"
    dom    = "*"
    month  = "*"
    dow    = "*"
  }
}

# -----------------------------------------------------------------------------
# Tier 3: media (weekly / 4 w)
# -----------------------------------------------------------------------------

# §4.1 gives the protocol as "SMB/NFS" without saying which share goes where, so share_type is left unset
# (the pool default) and no share is created. TODO(owner): protocol, share definitions, quota.
resource "truenas_dataset" "media" {
  name     = "main/media"
  comments = "Managed by OpenTofu: media library (Tier 3, re-obtainable)"

  lifecycle {
    prevent_destroy = true
  }
}

resource "truenas_periodic_snapshot_task" "media" {
  dataset        = truenas_dataset.media.name
  recursive      = true
  enabled        = true
  lifetime_value = 4
  lifetime_unit  = "WEEK"
  naming_schema  = "auto-%Y-%m-%d_%H-%M"

  # Sundays 01:00 ("0" is how the TrueNAS UI stores Sunday).
  schedule = {
    minute = "0"
    hour   = "1"
    dom    = "*"
    month  = "*"
    dow    = "0"
  }
}

# -----------------------------------------------------------------------------
# Tier 4: scratch (no snapshots)
# -----------------------------------------------------------------------------

# §4.1: no snapshots, no offsite, and no protocol. There is deliberately no snapshot task for this dataset:
# a later "recursive snapshot of main" must not be added without excluding it. TODO(owner): quota (scratch
# is the dataset most likely to fill the pool), and whether anything shares it.
resource "truenas_dataset" "scratch" {
  name     = "main/scratch"
  comments = "Managed by OpenTofu: scratch space (Tier 4, never snapshotted, not backed up)"

  lifecycle {
    prevent_destroy = true
  }
}

# -----------------------------------------------------------------------------
# Household backup datasets (backups.tf) under the tier policy
# -----------------------------------------------------------------------------

# Every dataset in backups.tf is already covered, so no task is added here:
#   main/backups/timemachine/jolien  covered by the recursive `timemachine` task on main/backups/timemachine (daily / 7 d, §4.1)
#   main/backups/kopia               covered by the `kopia` task (daily / 14 d, §4.1)
#   main/backups                     holds no data of its own, only those two children, so a task on it would
#                                    duplicate theirs and break their different retention (7 d vs 14 d)
#   main/apps/seafile                covered by the recursive `apps` task on main/apps (hourly / 14 d, §4.1)
