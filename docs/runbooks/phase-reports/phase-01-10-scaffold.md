# Phase report — Phases 1–10 (scaffold)

Date: 2026-10-16

## 1. What was inspected

- Existing repo documents (`docs/SPEC.md`, `docs/PROJECT-PLAN.md`, `docs/*`, `versions.yaml`).
- Live hosts: read-only only (prior discovery; no changes this session).
- Upstream sources for facts used below: OpenTofu provider registry (via `tofu init`/`validate`),
  Artifact Hub API (chart versions), GitHub release assets (kubeconform/kustomize in CI).

## 2. What changed (files only)

- `Justfile`, `.actrc`, `.markdownlint-cli2.yaml` (ignore rules), `.gitignore` (commit lock files).
- `infrastructure/environments/homelab/{proxmox,truenas,unifi}/` — pinned providers, validated, no resources.
- `kubernetes/` — Flux roots + `infrastructure/` (sources, metallb, traefik, cert-manager, technitium) +
  `apps/` (immich, audiobookshelf).
- `scripts/backup/` — `restic-backup.sh`, `restic-check.sh`, `env.example`, systemd units.
- `scripts/lab/kind-up.sh` — local kind cluster.
- `docs/backup-policy.md`, `docs/backup-matrix.md`, `docs/disaster-recovery.md`,
  `docs/runbooks/{README,upgrades}.md`.

No live infrastructure was changed.

## 3. Design rationale

- One OpenTofu root per system to keep blast radius and state small and ownership non-overlapping.
- UniFi root is additive/plan-only and the API key stays in the environment (full-access key, risk R19).
- Flux orders `infrastructure` before `apps` via `dependsOn`; SOPS decryption references an out-of-repo key.
- Chart versions pinned to the latest verified on Artifact Hub (2026-10-16).
- Placeholder values use RFC 5737/2606 ranges so nothing resembles a real address/domain.

## 4. Validations/tests run

| Check | Command | Result |
|---|---|---|
| Markdown lint | `markdownlint-cli2 "**/*.md"` | 0 issues |
| YAML lint | `yamllint -s .` | pass |
| Shell lint | `shellcheck -x` (all `*.sh`) | pass (one real bug fixed in `restic-check.sh`) |
| Secret scan | `gitleaks detect` (22 commits) | no leaks |
| OpenTofu fmt | `tofu fmt -check -recursive` | pass |
| OpenTofu validate | `tofu validate` per root | pass (proxmox, truenas, unifi) |
| K8s render | `kubectl kustomize` / `kustomize build` | builds |
| K8s schema | `kubeconform -strict -ignore-missing-schemas` | 0 invalid |
| CI (local) | `act push -j {opentofu,kubernetes,lint}` | all jobs succeeded |

## 5. Actual results (pass/fail, exact)

- `kubeconform` — infrastructure: `Valid: 4, Invalid: 0, Errors: 0, Skipped: 12`; apps:
  `Valid: 2, Invalid: 0, Errors: 0, Skipped: 4` (skipped = CRDs without bundled schemas).
- `act` — `🏁 Job succeeded` for the `opentofu`, `kubernetes`, and `lint` jobs.
- `secret-scan` could not be exercised through `act` (it cannot clone `gitleaks-action` anonymously);
  the equivalent `gitleaks` container scan ran clean instead.

## 6. Risks / unresolved issues

- UniFi provider pinned to a **beta** (`0.60.0-beta.0`) — do not use for critical automation yet
  (see `versions.yaml`).
- Kubernetes app `values` are intentionally empty; they must be filled before any apply.
- GATE 0 decisions (topology, storage, backup mechanism, offsite host, resolver) still open.

## 7. Manual actions still required

- Owner answers to the GATE 0 decisions and the Tier-1 data question.
- Owner provides/creates API tokens where needed; none are stored in the repo.

## 8. Live change made?

No.

## 9. Needed next (approval / info / gate)

- GATE 0 answers to proceed with Phase 2 inventory and Phase 4 rebuild.
