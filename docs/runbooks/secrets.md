# Runbooks: Secrets (SOPS + age)

How encrypted secrets are created, stored, consumed and recovered in this repository.

- **Design:** `docs/secrets-and-state.md` (Phase 1 secret strategy).
- **Rules (recipients):** `.sops.yaml`.
- **Tooling:** `scripts/secrets/`.
- **Rule zero:** no plaintext secret ever enters the repository, CI, logs or plan
  output. Only **ciphertext** is committed; only **public** age recipients are committed.

## 1. Model — what lives where

| Artefact | Location | Committed? |
|---|---|---|
| Plaintext secret value | password manager / `~/.config/homelab/<system>.env` (mode 600) | **never** |
| Encrypted secret | repo, named `*.sops.yaml` (or `*.lab.sops.yaml` for the lab) | **yes** |
| age private identity | outside the repo (password manager + offline media) | **never** |
| Flux decryption key | cluster `Secret` `sops-age` in `flux-system` | **never** (created out-of-band) |

`.sops.yaml` holds two clearly separated creation rules:

1. **LAB** — recipient is the lab public key. Provenance: generated with `age-keygen`,
   private half at `~/.config/homelab/lab-age.key` (never committed); the public
   recipient in `.sops.yaml` was extracted with `age-keygen -y ~/.config/homelab/lab-age.key`.
   Path convention: `*.lab.sops.yaml`, or any SOPS file under a `lab/` segment.
2. **PRODUCTION** — currently a **placeholder** (`REPLACE_AT_GATE_4_WITH_PRODUCTION_AGE_RECIPIENT`).
   Encrypting a production secret **fails closed** until the GATE 4 ceremony fills it in.

The first matching rule wins, so the lab rule must stay above the production rule.

## 2. Key ceremony

### Lab (replaceable)

```sh
scripts/secrets/init-age.sh            # creates ~/.config/homelab/lab-age.key (mode 600), idempotent
scripts/secrets/init-age.sh --dry-run  # preview only
```

The lab key is disposable: if it is lost, delete the lab ciphertext, regenerate the
key and re-encrypt. The lab harness (`scripts/lab/lab-up.sh`) installs it into the lab
cluster as the `sops-age` Secret automatically.

### Production (offline, one-time) — TODO(GATE 4)

Do this on an **offline / air-gapped** machine, never on a networked host:

1. `scripts/secrets/init-age.sh --output /media/offline/prod-age.key --purpose production`
   (or `age-keygen -o prod-age.key` directly).
2. Escrow the **private** key in a password manager **and** on separate offline media.
   Keep the two copies in different places. It must be recoverable **without** the
   homelab being up.
3. Paste **only** the printed `age1...` public recipient into the production rule in
   `.sops.yaml`, and commit that.
4. Never copy the private key into the repo, CI, chat, logs, the cluster's git history,
   or a Talos machine config.

The private key line is the single non-comment line of the generated file. If you can
read pasted text and it looks like key material, it does not belong here.

## 3. Add a secret

1. Create the plaintext **outside the repo** (or in a temp path), named for a creation
   rule, e.g. `immich.sops.yaml` for production or `demo.lab.sops.yaml` for the lab.
2. Encrypt it in place:

   ```sh
   scripts/secrets/encrypt.sh --dry-run path/to/immich.sops.yaml   # preview
   scripts/secrets/encrypt.sh           path/to/immich.sops.yaml   # encrypt
   ```

3. Confirm the result is opaque and encrypted:

   ```sh
   grep -c 'ENC\[' path/to/immich.sops.yaml     # > 0
   sops filestatus path/to/immich.sops.yaml     # {"encrypted":true}
   ```

4. Move it into the repo, review that no plaintext remains, and commit **only** the
   ciphertext.

To read a value back (never redirect this into a tracked file):

```sh
scripts/secrets/decrypt.sh path/to/immich.sops.yaml
scripts/secrets/decrypt.sh --extract '["stringData"]["password"]' path/to/immich.sops.yaml
```

`sops FILE` (with `$EDITOR`) re-encrypts in place on save — the convenient way to edit
an existing encrypted file.

## 4. Rotate a secret

Two different things, often confused:

- **Rotate a value** (same age key): edit the ciphertext with `sops FILE` (or
  decrypt → edit → re-`encrypt.sh`) and commit. Nothing else changes.
- **Rotate the age key** (new recipient):
  1. Run the GATE 4 ceremony again to create a new production key; escrow it.
  2. Update the recipient in `.sops.yaml`.
  3. Re-key every encrypted file to the new recipient:

     ```sh
     sops updatekeys path/to/immich.sops.yaml   # repeat per file, or loop over them
     ```

  4. Commit the re-keyed ciphertext, then update the cluster `sops-age` Secret (below)
     **before** retiring the old key. Retire the old key only after Flux decrypts cleanly.

Rotating a credential that is *inside* a secret (an API token, a password) is a
different runbook: change it at the source, then update the encrypted value here.
Never delete the source credential before the new encrypted value is committed.

## 5. How Flux consumes the ciphertext

Every cluster `Kustomization` already decrypts SOPS files with the age identity in the
`sops-age` Secret:

```yaml
  decryption:
    provider: sops
    secretRef:
      name: sops-age
```

The Secret must contain the key under `age.agekey`. **Lab** wiring already exists —
`scripts/lab/lab-up.sh` creates it from `~/.config/homelab/lab-age.key` on bring-up.

**Production** — TODO(GATE 0 / GATE 5). The live cluster does not exist yet, and how the
key is delivered during bootstrap depends on owner decisions still open at **GATE 0**
(bootstrap source, git-mirror and Talos answers). Do not implement it yet. When the gate
opens and the cluster is reachable, the out-of-band install is:

```sh
kubectl -n flux-system create secret generic sops-age \
  --from-file=age.agekey="$SOPS_AGE_KEY_FILE" \
  --dry-run=client -o yaml | kubectl apply -f -
```

The key is delivered **out of band and never committed** — not in the repo, not in a
Terraform/Talos-managed manifest. (Whether to also inject it via the Talos machine
config during bootstrap is an open decision; it is deliberately left unimplemented.)

## 6. Recovery if an age key is lost

**Be blunt: loss of the private key = permanent loss of every secret encrypted to it.**
SOPS + age is asymmetric; there is no backdoor, no reset, no support. Only the holder of
the private key can decrypt. Everything else — the repo, backups, Git history — is
ciphertext that nobody can open.

If the **production** key is lost:

1. Stop. Do not pretend recovery is possible.
2. Recreate the key with the GATE 4 ceremony and update `.sops.yaml` + the `sops-age`
   Secret.
3. Re-source **every** credential from its authoritative location (provider consoles,
   password manager) and re-encrypt. The old ciphertext is dead weight — delete it.
4. Because the plaintext values must be re-obtained anyway, treat this as a full
   credential rotation: rotate every secret that was encrypted to the lost key.

This is exactly why §2 requires two offline escrow copies. A key that lives only on the
machine it protects is not escrowed.

## 7. What must never be committed

- Any plaintext secret value.
- An age **private** key (the non-comment line of an age key file).
- `sops-age` Secret manifests, kubeconfigs, Talos machine secrets, Tofu state/plans.
- Production `.env` files, private certificates/keys, offsite-backup credentials.

`.gitignore` enforces the obvious cases and additionally **un-ignores** `*.sops.yaml`
and `*.sops.yml` so legitimate ciphertext is always committable (ciphertext is safe;
plaintext is not).

## 8. How CI checks it

`scripts/secrets/check.sh --check` is the L0 gate. It needs no private key and fails if:

- `.sops.yaml` is missing;
- any file that could be committed and ends in `*.sops.yaml` / `*.sops.yml` /
  `*.sops.json` is **not** actually encrypted (a plaintext secret left behind);
- such a file is gitignored (its ciphertext could not be committed);
- and it warns (does not fail) while the production recipient is still the GATE 4
  placeholder.

Run it locally:

```sh
just secrets-check      # == scripts/secrets/check.sh --check
```

Wired into `.github/workflows/ci.yml` as the `secrets` job, which installs `sops` with the
pinned, checksum-verified installer (`scripts/ci/install-ci-tools.sh sops`) and then runs
`scripts/secrets/check.sh --check`. Because it needs only the `sops` binary (no private
key), it runs both on GitHub Actions and under `act` (`just ci`) — unlike the `secret-scan`
(gitleaks) job, which `act` cannot run. `gitleaks` remains the second net for accidental
plaintext.

## 9. Self-test

```sh
just secrets-verify     # == scripts/secrets/verify.sh
```

`verify.sh` proves in a throwaway temp directory that encrypt → commit-shape → decrypt
round-trips, that structure survives (`--extract`), and that production encryption fails
closed while the placeholder is unset. Nothing it writes ever lands in the repository.
