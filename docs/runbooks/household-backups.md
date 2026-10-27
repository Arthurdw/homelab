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
| (d) Mac, photo drives (FreeFileSync) | the NAS only (the TrueNAS root applied, with `tier1_jolien_quota_gib` set). No cluster. |

Pre-checks: the TrueNAS root (`infrastructure/environments/homelab/truenas`, `backups.tf`) is applied, which
needs a NAS on TrueNAS >= 25.04 (see its README). Nothing here has run against the real NAS yet.

## (a) Mac: Time Machine (needs the NAS only)

Owner steps on the NAS, once, **before** the first `tofu apply` of the TrueNAS root:

1. The `jolien` account (SMB on, shell `nologin`, its own primary group) is created by the root
   (`users.tf`), not by hand. Pick a strong password, put it in the password manager, and export it
   without echo: `read -rs TF_VAR_user_jolien_password && export TF_VAR_user_jolien_password`. The root
   creates `dunia` the same way, from `TF_VAR_user_dunia_password`.
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
   kopia repository connect server --url https://kopia.lab.ardw.be:443 \
     --override-username <user> --override-hostname <machine>
   ```

   Keep the `:443`: without a port the client dials `kopia.lab.ardw.be:` and fails with `missing port after
   port-separator colon`. The same URL goes into KopiaUI.

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
4. Take the first snapshot and schedule it. KopiaUI runs the schedule while it is open. With the CLI on
   Linux, from this repo, `just kopia-timer --run-now` installs a daily systemd user timer
   (`scripts/kopia/client-timer.sh`, units in `scripts/kopia/systemd/`) running `kopia snapshot create --all`
   and starts the first snapshot right away. `just kopia-timer --status` shows the next run, the last result
   and the snapshots; `journalctl --user -u kopia-snapshot` has the log. Elsewhere, `kopia snapshot create ~`
   from cron or Task Scheduler does the same.

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
in `kubernetes/apps/authentik/blueprints.yaml`); an Authentik user is created in Seafile on first login. Seafile keys the
account on Authentik's stable `sub` (the Authentik provider uses `hashed_user_id`) and keeps the email as the contact
address, so a changed email does not orphan the account; Seahub shows the internal id as `<hash>@auth.local`. Local login stays on, so the admin account always works, and the admin can still create accounts
in the Seafile admin panel.

Seahub itself calls Authentik's token and userinfo endpoints from inside the cluster, so `auth.<domain>` must
resolve and be trusted from the Seafile pod. In production it resolves through public DNS and carries a publicly
trusted certificate, so nothing extra is needed there, provided the pod can reach that address (hairpin through
the router or the split-horizon record to Traefik). Verify that from the pod before relying on it. The lab has
neither (its zone lives only on Technitium and its certificates come from the internal CA), so the lab overlay
(`kubernetes/overlays/lab/apps/seafile-lab-trust.yaml` and the patch in its `kustomization.yaml`) adds a
`hostAliases` entry to Traefik and mounts the internal CA as `REQUESTS_CA_BUNDLE`.

Proven in the lab 2026-10-21 with a throwaway Authentik user, driven with curl: `/oauth/login/` 302 to the
authorize endpoint, the flow executor (identification, password) completed, authorize 302 to
`/oauth/callback/`, callback 302 to `/`, and `/api2/account/info/` returned 200 with the user's name and
`contact_email`. The user row carried the hashed `sub` as the social-auth uid. The test user was deleted from both
sides.

The clients keep their own tokens either way (decisions §5.8). Seafile is for files you want everywhere. It is
not a device backup: keep the Kopia or Time Machine job running as well.

## (d) Photo drives: FreeFileSync (needs the NAS only)

jolien's photo work (RAWs, project files) lives on external drives that Time Machine does not cover
(decisions §5.17). FreeFileSync copies each drive to its own folder on the `jolien` share, and RealTimeSync
re-runs that copy when a drive changes or is plugged in. Both are free and open source (freefilesync.org).

Owner steps on the NAS, once:

1. Add `tier1_jolien_quota_gib` to `terraform.tfvars` (10240 = 10 TiB; it covers the archive and its
   snapshots). Export the API key and the household passwords as for the first apply (part (a), step 1), then
   `tofu plan` and `tofu apply` in `infrastructure/environments/homelab/truenas`.
2. Check: Shares, Windows (SMB) shows `jolien` (default purpose); Datasets shows `main/tier1/jolien/photos`
   with record size 1M and a quota on `main/tier1/jolien`.

On the Mac:

1. Finder, Go, Connect to Server, `smb://hercules-nas.<domain>/jolien`, sign in as `jolien` and save the
   password to the keychain. It mounts at `/Volumes/jolien`. Create `photos/drives/` in it.
2. To mount it at login: System Settings, General, Login Items, add the mounted `jolien` volume.
3. Install FreeFileSync (it ships RealTimeSync). System Settings, Privacy & Security, Full Disk Access: add
   both apps, or macOS blocks them from reading external drives and the share.
4. Give every drive a unique name (Finder, rename the volume). The name becomes the folder on the NAS, so two
   drives called `Untitled` would land in the same folder. Write the names down.
5. A drive encrypted with Samsung Magician: unlock it first. FreeFileSync only sees it while it is unlocked
   and mounted; a locked drive is skipped, not emptied, on the NAS.
6. In FreeFileSync, one folder pair per drive: left `/Volumes/<drive>`, right
   `/Volumes/jolien/photos/drives/<drive>`. Synchronization settings (green gear): **Update** (the `>` arrow
   variant), never Mirror or Two way. Exclude `.Spotlight-V100`, `.fseventsd`, `.Trashes` and
   `.TemporaryItems` (FreeFileSync excludes most of these by default).
7. Run it once by hand: Compare, check the totals, Synchronize. The first copy of several terabytes takes
   a day or more over the network; keep the Mac awake, on power and wired if possible.
8. File, Save as batch job: tick **Auto-close** and set error handling to **Ignore** (a drive that is not
   plugged in then just fails its pair and the rest carries on). Save it, for example
   `~/Documents/photo-backup.ffs_batch`.
9. Open RealTimeSync, File, Open, the `.ffs_batch` file: it fills in the drive folders to watch and the
   command. Set the idle time to a few minutes (300 s), so a long import finishes before the copy starts.
   Start it, then add RealTimeSync to Login Items so it runs after every restart. It also runs the job when
   a watched drive is plugged in.

Verify: the menu-bar RealTimeSync icon shows it is watching; copy a test file onto a drive and it shows up on the
share after the idle time. FreeFileSync's logs (Tools, Show log folder) list each run and its errors. Nothing
on the NAS alerts on a stopped sync yet: look at the share's newest files now and then.

Test a restore once: copy a folder from `/Volumes/jolien/photos/drives/<drive>` back to a scratch location and
open a few RAWs and a project. An older version of a file that was overwritten: on the NAS, Datasets,
`main/tier1/jolien`, Snapshots, or browse the read-only copies under `/mnt/main/tier1/jolien/photos/.zfs/snapshot/`
as root (30 days back).

Keep the old drives until there is an offsite copy (decisions §5.5, §5.17): until then the NAS is the only
second copy. Deletes on the drives never reach the NAS; to free space, delete on the share by hand.

Rollback or remove: quit RealTimeSync and remove it from Login Items. The data on the NAS stays until the
dataset is deleted by hand (the IaC refuses to destroy it).
