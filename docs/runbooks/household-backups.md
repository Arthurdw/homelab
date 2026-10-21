# Runbooks: Household device backups

Setup for the three household backup paths (decisions §5.9): Time Machine for jolien's Mac, Kopia for
dunia (Windows) and arthur (Linux), Seafile for anywhere-access. Read it top to bottom once, then use the
section for the device you are on.

**What needs what**

| Part | Needs |
|---|---|
| (a) Mac, Time Machine | the NAS only (the TrueNAS root applied). No cluster. |
| (b) Windows and Linux, Kopia | **the cluster live**: Kopia server up at `https://kopia.lab.ardw.be`, a client account created by the server admin |
| (c) Seafile | **the cluster live**: `seafile.lab.ardw.be` |

Pre-checks: the TrueNAS root (`infrastructure/environments/homelab/truenas`, `backups.tf`) is applied, which
needs a NAS on TrueNAS >= 25.04 (see its README). Nothing here has run against the real NAS yet.

## (a) Mac: Time Machine (needs the NAS only)

Owner steps on the NAS, once, **before** the first `tofu plan` of `backups.tf` (the plan looks the account up
and fails if it is missing):

1. TrueNAS UI, Credentials, Local Users, Add: username `jolien` (or whatever `timemachine_jolien_user` says),
   a strong password, **SMB access on**, shell `nologin`, create a new primary group. Put the password in
   the password manager.
2. Services, SMB, Edit: tick **Enable Apple SMB2/3 Protocol Extensions** and save. TrueNAS refuses the
   Time Machine share without it. It is NAS-wide, so the OpenTofu root does not manage it.
3. Set `timemachine_jolien_quota_gib` in `terraform.tfvars` (2x the Mac's disk is the usual rule) and apply the
   root. Check: Shares, Windows (SMB) shows `timemachine-jolien` with the Time Machine purpose.

On the Mac:

1. Finder, Go, Connect to Server, `smb://hercules-nas.<domain>/timemachine-jolien`, sign in as `jolien`
   and let it save the password to the keychain. (The address is a placeholder: use the NAS's name or
   address as the Mac knows it.)
2. System Settings, General, Time Machine, Add Backup Disk, choose `timemachine-jolien`.
3. **Tick "Encrypt backup"** and set a passphrase. Store it in the password manager. Without it
   the backup cannot be restored.
4. Let the first backup run to completion (hours; keep the Mac awake and on power).

Verify: Time Machine shows a "Latest backup" time. Test a restore once: enter Time Machine, pick a file
from a past date, restore it to the Desktop. A full-disk restore is Migration Assistant from the Time Machine disk.

Rollback or remove: Time Machine, remove the disk. The data on the NAS stays until the dataset is deleted
by hand (the IaC refuses to destroy it).

## (b) Windows and Linux: Kopia (needs the cluster live)

The server admin first creates one account per device on the Kopia server, `<user>@<machine>` (for
example `arthur@laptop`), and hands over the password. An account is one key in the `kopia-users` Secret,
named `<user>_<machine>`, whose value is the password; the server adds or updates the accounts when it starts
(`kubernetes/apps/kopia/server.yaml`, header). The server's repository password is a separate secret that
clients never see.

1. Install: KopiaUI (GUI, Windows or Linux) or the `kopia` CLI, from kopia.io. Use the same major version
   as the server.
2. Connect. The `*.lab.ardw.be` certificate is from a public CA, so no fingerprint is needed:

   ```sh
   kopia repository connect server --url https://kopia.lab.ardw.be \
     --override-username <user> --override-hostname <machine>
   ```

   It asks for the account password; for an unattended connect, set it in `KOPIA_PASSWORD` instead (the
   `--password` flag doesn't reach the repository open). On the lab, whose certificate comes from the
   internal CA, add `--server-cert-fingerprint <sha256>` of the certificate Traefik serves. KopiaUI:
   Repository, Kopia Server.
3. Set the policy for the home directory (adjust the path; on Windows `C:\Users\<user>`):

   ```sh
   kopia policy set ~ \
     --add-ignore '.cache' --add-ignore 'Downloads' --add-ignore 'node_modules' \
     --add-ignore '.local/share/Trash' --add-ignore 'AppData/Local/Temp' \
     --snapshot-interval 24h \
     --keep-latest 7 --keep-daily 14 --keep-weekly 8 --keep-monthly 12 --keep-annual 3 \
     --compression zstd
   ```

   Also exclude anything that is already elsewhere (VM images, game libraries, the Seafile folder if it
   syncs the same files). Keep photos, documents, dotfiles and keys.
4. Take the first snapshot and schedule it: `kopia snapshot create ~`. KopiaUI runs the schedule
   while it is open; on a headless Linux box use a systemd timer or cron running
   `kopia snapshot create ~` daily.

Verify, and test a restore (do this once per machine, then after any change):

```sh
kopia snapshot list ~
kopia snapshot restore <snapshot-id> /tmp/restore-test     # a scratch directory, never over live data
diff -r ~/Documents /tmp/restore-test/Documents | head
```

**Disaster restore without the cluster.** The repository is a plain Kopia repository on
`main/backups/kopia`. (Until the `TODO(storage)` in `kubernetes/apps/kopia/server.yaml` is closed, it lives in
the PVC's subdirectory of `main/k8s` instead.) Mount the dataset (or copy it) on any machine and run
`kopia repository connect filesystem --path <dir>`, with the repository password from the secrets store.

## (c) Seafile (needs the cluster live)

Install the Seafile client (desktop or mobile) from seafile.com, server `https://seafile.lab.ardw.be`, and
sign in. On the web login page, "Single Sign-On" signs in through Authentik (the `seafile` application, declared
in `kubernetes/apps/authentik/blueprints.yaml`); an Authentik user is created in Seafile on first login, by
email address. Local login stays on, so the admin account always works, and the admin can still create accounts
in the Seafile admin panel.
The clients keep their own tokens either way (decisions §5.8). Seafile is for files you want everywhere. It is
not a device backup: keep the Kopia or Time Machine job running as well.
