# Household accounts on the NAS (decisions.md §5.9, §4.1).
#
#   jolien  created here  SMB, own primary group, no shell, no sudo  (Time Machine, backups.tf)
#   dunia   created here  SMB, own primary group, no shell, no sudo
#   arthur  ADOPTED       already exists and is the owner's admin login; imported, never changed
#
# Passwords are write-only on truenas_user: the provider sends them to the NAS and never stores them in
# state. The variables are ephemeral as well, so they are not kept in a saved plan file either. They are
# only needed on the apply that creates the account. Changing one later does not show up in a plan
# (write-only values are not compared), so a password change is done in the UI, not here.
#
# home is set because the provider sends an empty string when it is unset, which the API refuses on
# create (seen on the fixture); /var/empty is TrueNAS's own "no home directory" value.
#
# Every account carries prevent_destroy: deleting one would orphan the ACLs keyed on its UID, and a
# re-created account gets a new UID.

resource "truenas_user" "jolien" {
  username     = "jolien"
  full_name    = "Jolien"
  password     = var.user_jolien_password
  group_create = true
  smb          = true
  shell        = "/usr/sbin/nologin"
  home         = "/var/empty"

  lifecycle {
    prevent_destroy = true
  }
}

resource "truenas_user" "dunia" {
  username     = "dunia"
  full_name    = "Dunia"
  password     = var.user_dunia_password
  group_create = true
  smb          = true
  shell        = "/usr/sbin/nologin"
  home         = "/var/empty"

  lifecycle {
    prevent_destroy = true
  }
}

# arthur is imported, not created. The provider imports a user by its numeric TrueNAS id (the database
# row, not the UID), which is not known in advance and differs per NAS. OpenTofu accepts an expression
# in an import block's id, so the data source below looks the id up by name during plan: the owner's first
# plan shows "will be imported" with no manual `tofu import`, and a plan on a NAS without `arthur` fails
# plainly at the lookup instead of creating a second admin. After the import the block is a no-op.
data "truenas_user" "arthur" {
  username = "arthur"
}

import {
  to = truenas_user.arthur
  id = tostring(data.truenas_user.arthur.id)
}

# Only username is set, because it must match. Everything that decides whether the owner can still log
# in (builtin_administrators in `groups`, sudo, shell, password, home, lock state, UID) is ignored, so no
# plan can ever change it, even if the attribute is later added here by mistake. The rest is left
# unset: an unset optional attribute keeps the imported value and never shows a diff.
resource "truenas_user" "arthur" {
  username = "arthur"

  lifecycle {
    prevent_destroy = true
    ignore_changes = [
      uid,
      group,
      group_create,
      groups,
      password,
      password_disabled,
      locked,
      shell,
      home,
      home_mode,
      sudo_commands,
      sudo_commands_nopasswd,
      sshpubkey,
      ssh_password_enabled,
      smb,
    ]
  }
}
