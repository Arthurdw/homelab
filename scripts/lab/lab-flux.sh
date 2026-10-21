#!/usr/bin/env bash
# Shared helper: install Flux into the CURRENT kubectl context and point it at the lab Git server.
# Sourced by lab-up.sh (kind) and virt/flux-up.sh (libvirt Talos). Expects log/note to be defined,
# and must run from the repo root (it applies kubernetes/clusters/lab/*.yaml by relative path).
#
# lab_flux_wire <branch> <git_url> <age_key> <sync: infrastructure|all>
#   1. flux install (the version of the pinned flux CLI) and wait for the controllers
#   2. the lab SOPS age key as Secret flux-system/sops-age (generated once, outside the repo)
#   3. GitRepository flux-system -> <git_url> @ <branch>
#   4. the REAL lab cluster Kustomizations: cluster-settings first, then infrastructure,
#      infrastructure-configs and (sync=all) apps
#
# Idempotent: re-running re-applies everything and triggers a reconcile.

lab_flux_wire() {
  local branch="$1" git_url="$2" age_key="$3" sync="$4"

  log "install Flux"
  flux install
  kubectl -n flux-system wait --for=condition=Available --timeout=300s \
    deploy/source-controller deploy/kustomize-controller deploy/helm-controller

  log "SOPS age key (lab-only, outside the repo)"
  mkdir -p "$(dirname "$age_key")"
  if [ ! -f "$age_key" ]; then
    age-keygen -o "$age_key" 2>/dev/null
    note "generated $age_key"
  fi
  kubectl -n flux-system create secret generic sops-age \
    --from-file=age.agekey="$age_key" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  note "sops-age secret present (decryption key for the lab)"

  log "wire Flux to the repo"
  flux create source git flux-system --url="$git_url" --branch="$branch" --interval=1m --export \
    | kubectl apply -f - >/dev/null
  flux reconcile source git flux-system
  kubectl -n flux-system wait --for=condition=Ready gitrepository/flux-system --timeout=120s

  log "apply the REAL cluster Kustomizations (lab cluster dir)"
  # cluster-settings must exist before the Kustomizations reconcile, or Flux would substitute
  # EMPTY STRINGS for every ${VAR} (and the CI guard is not involved at runtime).
  kubectl apply -f kubernetes/clusters/lab/cluster-settings.yaml >/dev/null
  kubectl apply -f kubernetes/clusters/lab/infrastructure.yaml \
    -f kubernetes/clusters/lab/infrastructure-configs.yaml >/dev/null
  if [ "$sync" = "all" ]; then
    kubectl apply -f kubernetes/clusters/lab/apps.yaml >/dev/null
  else
    note "SYNC=$sync — apps Kustomization not applied"
  fi
  flux reconcile kustomization infrastructure --with-source || true
}
