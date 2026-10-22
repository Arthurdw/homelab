# Future work

Work that is agreed but deliberately not started, with what blocks it. `docs/PROJECT-PLAN.md` tracks the
current phases; this file holds what waits on something outside the repo. When an item starts, move it into
the plan and delete it here.

## Offsite backup target

**Blocked on:** hardware or a provider; the owner has none available yet (`docs/decisions.md` §5.5,
deferred 2026-10-16, reconfirmed 2026-10-21).

Production has no offsite copy today (`docs/decisions.md` §6.2), so this is the largest open risk.

Already in place, so the target only has to be plugged in:

- `scripts/backup/` — restic backup, check, restore-diff and freshness scripts, systemd units and timers, and
  the failure mails. Proven in the lab against a throwaway repository (`scripts/backup/README.md`).
- The design is target-agnostic: S3-compatible or a restic REST server both work, with no provider assumed.

To do once a target exists:

1. Choose the mechanism, ZFS replication or restic (`docs/PROJECT-PLAN.md` phase 2).
2. Create the repository with its own key, stored outside both the NAS and the target (`docs/backup-policy.md`).
3. Follow the install in `scripts/backup/README.md`: alert test mail first, then the timers, and the freshness
   timer only after the first success.
4. Run the first backup and a restore test against the real target (phase 8, gate 8).

## Telegram alerts

**Blocked on:** a bot token. SMTP is the baseline path and stays (`docs/decisions.md` §5.1); Telegram is an
added Alertmanager receiver.

## Forgejo mirror and CI runner

**Blocked on:** nothing since production went live (2026-10-22); it waits for the owner to start it, and for
CPU headroom (the host runs at about 92%). Forgejo is a read-only mirror of GitHub (§5.4, §5.6). Its runner
executes untrusted build jobs in Kata microVMs (§3.5); the Talos image already carries the `kata-containers`
extension and the `kata` RuntimeClass exists.
