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

# Backup alert path: backup-alert.sh against local SMTP sinks, plus systemd-analyze verify on the units
backup-selftest:
  ./scripts/backup/test/alert-selftest.sh

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
  # git-visible files only: gitignored scratch (e.g. the lab UniFi fixture copy) is not a root
  roots=$(git ls-files -co --exclude-standard -z '*.tf' | xargs -0 -r grep -l -e '^terraform {' 2>/dev/null | xargs -r -n1 dirname | sort -u)
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
  for j in opentofu kubernetes render secrets lint; do
    printf '\n########## %s ##########\n' "$j"
    act push -j "$j" --pull=false
  done
  printf '\n(secret-scan [gitleaks] skipped; run: just secrets)\n'

# Run one CI job locally, e.g. `just ci-job lint`
ci-job job:
  act push -j {{job}} --pull=false

# List the CI jobs act will run
ci-list:
  act -l

# Secret scan (gitleaks if installed, else the pinned container image — keep in step with versions.yaml)
secrets:
  #!/usr/bin/env bash
  if command -v gitleaks >/dev/null; then
    gitleaks detect --no-banner --redact
  else
    docker run --rm -v "$PWD:/repo" ghcr.io/gitleaks/gitleaks:v8.30.1 detect --source=/repo --no-banner --redact
  fi

# CI gate: every would-be-committed secret file must be SOPS-encrypted
secrets-check:
  ./scripts/secrets/check.sh --check

# Prove the SOPS + age round-trip (needs the lab age key)
secrets-verify:
  ./scripts/secrets/verify.sh

# Build every kustomization and schema-check it. Mirrors the CI `kubernetes` job — if you
# change one, change the other. A failed or empty render is an error, never a silent pass.
k8s-validate:
  #!/usr/bin/env bash
  set -euo pipefail
  if command -v kustomize >/dev/null 2>&1; then
    render() { kustomize build "$1"; }
  elif command -v kubectl >/dev/null 2>&1; then
    render() { kubectl kustomize "$1"; }
  else
    echo "ERROR: need kustomize or kubectl on PATH" >&2; exit 1
  fi
  mapfile -t dirs < <(find kubernetes -name kustomization.yaml -exec dirname {} \; 2>/dev/null | sort)
  if [ ${#dirs[@]} -eq 0 ]; then echo "no kustomizations yet"; exit 0; fi
  rc=0
  for d in "${dirs[@]}"; do
    echo "== build $d =="
    if ! manifest="$(render "$d")"; then
      echo "ERROR: $d failed to render" >&2; rc=1; continue
    fi
    if [ -z "${manifest//[[:space:]]/}" ]; then
      echo "ERROR: $d rendered empty" >&2; rc=1; continue
    fi
    if command -v kubeconform >/dev/null 2>&1; then
      # SOPS metadata on encrypted Secrets is not part of the Secret schema; strip it first.
      if command -v yq >/dev/null 2>&1; then manifest="$(printf '%s\n' "$manifest" | yq 'del(.sops)')"; fi
      printf '%s\n' "$manifest" | kubeconform -strict -summary -ignore-missing-schemas - || rc=1
    else
      echo "  rendered ok (install kubeconform for schema checks)"
    fi
  done
  exit "$rc"

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

# Bring up the libvirt guests (Talos + NAS stand-in). Try: `just lab-virt-up --dry-run`
lab-virt-up *args:
  ./scripts/lab/virt/up.sh {{args}}

# Tear the libvirt guests down (only harness-owned, name-prefixed domains/networks)
lab-virt-down *args:
  ./scripts/lab/virt/down.sh {{args}}

# Flux on the libvirt Talos lab, reconciling this working tree (re-run = sync)
lab-virt-flux *args:
  ./scripts/lab/virt/flux-up.sh {{args}}

# ssh into the lab-nas stand-in with the harness's lab-only key. The args run on lab-nas as one command line,
# so `just lab-nas-ssh 'a; b'` runs both there. Try: `just lab-nas-ssh sudo systemctl status nfs-kernel-server`
lab-nas-ssh *args:
  ssh -i /var/tmp/homelab-lab-virt/ssh/lab_ed25519 -o IdentitiesOnly=yes -o UserKnownHostsFile=/var/tmp/homelab-lab-virt/ssh/known_hosts -o StrictHostKeyChecking=accept-new debian@10.99.100.10 {{quote(args)}}

# Show libvirt networks, guests, DHCP leases and Talos state
lab-virt-status *args:
  ./scripts/lab/virt/status.sh {{args}}

# Self-hosted UniFi controller fixture (Docker, 127.0.0.1 only): up | status | stop | down
lab-unifi *args:
  ./scripts/lab/unifi-fixture.sh {{args}}

# Plan, apply and re-plan the unifi root against the fixture only (refuses non-loopback endpoints)
lab-unifi-plan *args:
  ./scripts/lab/unifi-fixture-plan.sh {{args}}

# Nested Proxmox VE fixture (libvirt guest lab-pve, 10.99.100.20, 4 GiB): up | status | stop | down [--purge]
lab-pve *args='up':
  ./scripts/lab/pve-fixture.sh {{args}}

# Plan, apply, re-plan and destroy the proxmox root against the fixture only (refuses non-10.99.100.x endpoints)
lab-pve-plan *args:
  ./scripts/lab/pve-fixture-plan.sh {{args}}

# TrueNAS SCALE fixture (libvirt guest lab-truenas, 10.99.100.21, 4-6 GiB): up | status | stop | down [--purge]
lab-truenas *args='up':
  ./scripts/lab/truenas-fixture.sh {{args}}

# Plan, apply and re-plan the truenas root against the fixture only (refuses non-10.99.100.x endpoints; no destroy: prevent_destroy)
lab-truenas-plan *args:
  ./scripts/lab/truenas-fixture-plan.sh {{args}}

# ---------------------------------------------------------------------------
# Live roots (real UniFi / TrueNAS / Proxmox) — credentials from ~/.config/homelab/<root>.env
# Apply order: unifi → truenas → proxmox. See scripts/live/tofu.sh.
# ---------------------------------------------------------------------------

# Read-only plan of a live root: `just plan unifi|truenas|proxmox|all`
plan root *args:
  ./scripts/live/tofu.sh plan {{root}} {{args}}

# Apply a live root; tofu shows the plan and waits for "yes" (never -auto-approve)
apply root *args:
  ./scripts/live/tofu.sh apply {{root}} {{args}}

plan-unifi *args: (plan "unifi" args)
plan-truenas *args: (plan "truenas" args)
plan-proxmox *args: (plan "proxmox" args)
apply-unifi *args: (apply "unifi" args)
apply-truenas *args: (apply "truenas" args)
apply-proxmox *args: (apply "proxmox" args)

# Show lab prerequisites / resource requirements (no changes)
lab-doctor:
  #!/usr/bin/env bash
  echo "docker:  $(docker --version 2>/dev/null || echo unavailable)"
  echo "kvm:     $(test -w /dev/kvm && echo yes || echo no)"
  echo "ram:     $(free -h | awk '/Mem:/{print $7 " available"}')"
  echo "disk:    $(df -h / | awk 'NR==2{print $4 " free (" $5 " used)"}')"
  echo "kind:    $(command -v kind >/dev/null && kind version || echo 'not installed')"
