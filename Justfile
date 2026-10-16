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

# Run the full CI workflow locally with act
ci:
  act push

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

# Render kustomizations and validate (if any exist)
k8s-validate:
  #!/usr/bin/env bash
  mapfile -t dirs < <(find kubernetes -name kustomization.yaml -exec dirname {} \; 2>/dev/null)
  if [ ${#dirs[@]} -eq 0 ]; then echo "no kustomizations yet"; exit 0; fi
  for d in "${dirs[@]}"; do
    echo "== build $d =="
    kustomize build "$d" | kubectl apply --dry-run=client -f - >/dev/null
  done

# ---------------------------------------------------------------------------
# Lab (local test-driven development) — see docs/lab.md
# ---------------------------------------------------------------------------

# Bring up the local kind cluster used for manifest/Flux testing
lab-kind-up:
  ./scripts/lab/kind-up.sh

# Tear down the local kind cluster
lab-kind-down:
  kind delete cluster --name homelab-lab

# Show lab prerequisites / resource requirements (no changes)
lab-doctor:
  #!/usr/bin/env bash
  echo "docker:  $(docker --version 2>/dev/null || echo unavailable)"
  echo "kvm:     $(test -w /dev/kvm && echo yes || echo no)"
  echo "ram:     $(free -h | awk '/Mem:/{print $7 " available"}')"
  echo "disk:    $(df -h / | awk 'NR==2{print $4 " free (" $5 " used)"}')"
  echo "kind:    $(command -v kind >/dev/null && kind version || echo 'not installed')"
