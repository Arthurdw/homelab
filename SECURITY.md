# Security Policy

## Reporting a vulnerability

Please report security issues **privately** — do not open a public issue for anything sensitive.

- Email: **<dev@arthurdw.com>**
- Include: what you found, how to reproduce it, and the potential impact.
- Please give reasonable time to fix before any public disclosure.

## Scope

This repository contains infrastructure-as-code and configuration for a personal homelab. Relevant concerns
include, but are not limited to:

- Committed secrets (API keys, tokens, private keys, state files, kubeconfigs).
- Exposure of management interfaces to the public internet.
- Overly permissive CI/CD permissions or trust of untrusted pull requests.

## What we do to reduce risk

- Secret scanning (gitleaks) runs in CI; `.gitignore` excludes state, plans, and secrets.
- No production credentials are required for pull-request validation.
- Destructive live operations require explicit owner approval (see `docs/PROJECT-PLAN.md`).
- Management interfaces are intended to remain private.

## Out of scope

- The external Dokploy server and its Tailscale route (explicitly outside this project).
- Findings that require already-committed secrets to be present in the public history (report them anyway —
  we still want to know).
