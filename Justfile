# Homelab task runner — `just <recipe>`
set shell := ["bash", "-euo", "pipefail", "-c"]

# List available recipes
default:
  @just --list

# ---------------------------------------------------------------------------
# Static checks / CI
# ---------------------------------------------------------------------------

# Run all available local static checks (mirrors CI)
check:
  ./scripts/check.sh

# Install the pinned binary tools the CI checks need (helm, yq, actionlint, shellcheck,
# kubeconform, kustomize) into ~/.local/bin.
ci-tools:
  BIN_DIR="$HOME/.local/bin" ./scripts/ci/install-ci-tools.sh

# Abstract (no-cluster) render check for every Flux HelmRelease
render:
  ./scripts/ci/render-helm-releases.sh

# Render check in strict mode: also fails while any HelmRelease values are still unwritten
render-strict:
  ./scripts/ci/render-helm-releases.sh --strict

# Format OpenTofu
fmt:
  tofu fmt -recursive

# Validate every OpenTofu root (backend disabled; no live access)
validate:
  #!/usr/bin/env bash
  roots=$(grep -rl --include='*.tf' -e '^terraform {' . 2>/dev/null | xargs -r -n1 dirname | sort -u)
  if [ -z "$roots" ]; then echo "no OpenTofu roots yet"; exit 0; fi
  for d in $roots; do
    echo "== validate $d =="
    (cd "$d" && tofu init -backend=false -input=false >/dev/null && tofu validate)
  done

# Run the CI workflow locally with act.
# `secret-scan` is excluded: act cannot clone gitleaks-action anonymously — use `just secrets`.
ci:
  #!/usr/bin/env bash
  set -euo pipefail
  for j in opentofu kubernetes render lint; do
    printf '\n########## %s ##########\n' "$j"
    act push -j "$j" --pull=false
  done
  printf '\n(secret-scan skipped; run: just secrets)\n'

# Run one CI job locally, e.g. `just ci-job lint`
ci-job job:
  act push -j {{job}}

# List the CI jobs act will run
ci-list:
  act -l

# Secret scan (gitleaks if installed, else the container image)
secrets:
  #!/usr/bin/env bash
  if command -v gitleaks >/dev/null; then
    gitleaks detect --no-banner --redact
  else
    docker run --rm -v "$PWD:/repo" ghcr.io/gitleaks/gitleaks:latest detect --source=/repo --no-banner --redact
  fi

# CI gate: every would-be-committed secret file must be SOPS-encrypted
secrets-check:
  ./scripts/secrets/check.sh --check

# Prove the SOPS + age round-trip (needs the lab age key)
secrets-verify:
  ./scripts/secrets/verify.sh

# Render kustomizations and validate (if any exist)
k8s-validate:
  #!/usr/bin/env bash
  KUSTOMIZE="kustomize"
  command -v kustomize >/dev/null 2>&1 || KUSTOMIZE="kubectl kustomize"
  mapfile -t dirs < <(find kubernetes -name kustomization.yaml -exec dirname {} \; 2>/dev/null)
  if [ ${#dirs[@]} -eq 0 ]; then echo "no kustomizations yet"; exit 0; fi
  for d in "${dirs[@]}"; do
    echo "== build $d =="
    if command -v kubeconform >/dev/null 2>&1; then
      $KUSTOMIZE "$d" | kubeconform -strict -summary -ignore-missing-schemas -
    else
      $KUSTOMIZE "$d" >/dev/null && echo "  rendered ok (install kubeconform for schema checks)"
    fi
  done

# Validate generated Talos machine configs (talosctl validate --mode metal; offline)
talos-validate:
  ./scripts/talos/validate.sh

# ---------------------------------------------------------------------------
# Lab (local test-driven development) — see docs/lab.md
# ---------------------------------------------------------------------------

# Bring up the local kind cluster used for manifest/Flux testing
lab-kind-up:
  ./scripts/lab/kind-up.sh

# Tear down the local kind cluster
lab-kind-down:
  kind delete cluster --name homelab-lab

# Install the tools the lab needs (default: pinned binaries; `just lab-tools --native` uses pacman)
lab-tools *args:
  ./scripts/lab/install-tools.sh {{args}}

# Bring up the full lab: kind + in-cluster Git server + Flux reconciling THIS repo
lab-up:
  ./scripts/lab/lab-up.sh

# Rebuild the lab Git image from the working tree and re-sync Flux (fast iteration)
lab-sync:
  ./scripts/lab/lab-sync.sh

# Tear the lab down
lab-down:
  ./scripts/lab/lab-down.sh

# Show what the lab cluster is reconciling
lab-status:
  ./scripts/lab/lab-status.sh

# Show lab prerequisites / resource requirements (no changes)
lab-doctor:
  #!/usr/bin/env bash
  echo "docker:  $(docker --version 2>/dev/null || echo unavailable)"
  echo "kvm:     $(test -w /dev/kvm && echo yes || echo no)"
  echo "ram:     $(free -h | awk '/Mem:/{print $7 " available"}')"
  echo "disk:    $(df -h / | awk 'NR==2{print $4 " free (" $5 " used)"}')"
  echo "kind:    $(command -v kind >/dev/null && kind version || echo 'not installed')"
