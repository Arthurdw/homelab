# Contributing

This is primarily a personal homelab, but the workflow is deliberately strict because the hosts are treated
as production.

## Ground rules

- **Never commit secrets or sensitive data.** No API keys, tokens, private keys, kubeconfigs, Talos secrets,
  unencrypted state, plan files with sensitive values, `.env` files, or private addresses/hostnames you don't
  intend to publish. `docs/private/` is gitignored and machine-local.
- **Audit before implementing.** Follow the phase/gate model in [`docs/PROJECT-PLAN.md`](docs/PROJECT-PLAN.md).
- **Small, reviewable changes.** One logical change per commit.
- **Test in the lab first.** See [`docs/lab.md`](docs/lab.md). CI only does static validation.

## Commit convention

Use [Conventional Commits](https://www.conventionalcommits.org/):

```text
<type>(<scope>): <summary>
```

Common types: `feat`, `fix`, `docs`, `chore`, `ci`, `refactor`, `test`, `build`.
Examples:

```text
docs(plan): add phase 0 audit deliverables
feat(proxmox): add talos worker vm module
ci(opentofu): add fmt/validate workflow
```

## Local checks before committing

Run the repo checks locally:

```sh
./scripts/check.sh
```

This runs the same static checks CI runs (formatting, linting, secret scanning) where the tools are available.

## Pull requests

- PR validation is **static only** — it never requires production credentials and never applies changes.
- Infrastructure **plans/applies are gated** and run only from protected environments with approval.
- Do not commit generated state or plans.

## Reporting security issues

See [`SECURITY.md`](SECURITY.md).
