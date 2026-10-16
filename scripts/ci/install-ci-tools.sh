#!/usr/bin/env bash
# install-ci-tools.sh — install the *binary* tools the static CI checks need, at pinned
# versions, verified against published checksums where upstream publishes them.
#
# This mirrors scripts/lab/install-tools.sh on purpose: no `curl | bash`, no floating
# tags, no `latest`. Versions are pinned here and chosen to match versions.yaml where an
# entry exists (helm, kubeconform, kustomize); the additions (yq, actionlint, shellcheck,
# sops) are pinned here because versions.yaml is the infrastructure inventory, not the CI
# toolchain, and is reviewed separately.
#
# Usage:
#   scripts/ci/install-ci-tools.sh [tool ...]      # default: all tools below
#   BIN_DIR=~/.local/bin scripts/ci/install-ci-tools.sh
#
# Tools: helm yq actionlint shellcheck kubeconform kustomize sops
#
# A tool already on PATH is left alone (but its version is NOT checked); point BIN_DIR at
# a directory on PATH, or add BIN_DIR to PATH afterwards.
#
# Note on checksums: shellcheck does not publish a checksum file for its release assets,
# so its download is unverified (reported, never silent). Everything else is verified.
set -euo pipefail

# Pinned versions.
HELM_VERSION="${HELM_VERSION:-4.3.1}"          # versions.yaml: ci_tools.helm
YQ_VERSION="${YQ_VERSION:-v4.47.2}"
ACTIONLINT_VERSION="${ACTIONLINT_VERSION:-1.7.12}"
SHELLCHECK_VERSION="${SHELLCHECK_VERSION:-0.11.0}"
KUBECONFORM_VERSION="${KUBECONFORM_VERSION:-0.8.0}"   # versions.yaml: ci_tools.kubeconform
KUSTOMIZE_VERSION="${KUSTOMIZE_VERSION:-5.8.3}"       # versions.yaml: ci_tools.kustomize
# sops is needed by scripts/secrets/check.sh (the L0 SOPS gate). Pinned to the same
# version scripts/lab/install-tools.sh already verifies, so lab and CI agree.
SOPS_VERSION="${SOPS_VERSION:-3.13.3}"

BIN_DIR="${BIN_DIR:-/usr/local/bin}"

have() { command -v "$1" >/dev/null 2>&1; }
log()  { printf '%s\n' "$*"; }

fetch() { curl -fsSL --retry 3 --retry-delay 2 -o "$2" "$1"; }

# verify <file> <checksum-url> <asset-name>  (empty url => no published checksum)
verify() {
  local file="$1" url="$2" name="$3" tmp want got
  if [ -z "$url" ]; then
    log "    ! no published checksum for $name (unverified)"
    return 0
  fi
  tmp="$(mktemp)"
  if ! fetch "$url" "$tmp" 2>/dev/null; then
    log "    ! checksum file unavailable for $name (unverified)"
    rm -f "$tmp"
    return 0
  fi
  want="$(awk -v n="$name" '{f=$NF; sub(/^\*/,"",f); if (f==n) print $1}' "$tmp" | head -1)"
  rm -f "$tmp"
  if [ -z "$want" ]; then
    log "    ! no checksum entry for $name (unverified)"
    return 0
  fi
  got="$(sha256sum "$file" | awk '{print $1}')"
  if [ "$want" != "$got" ]; then
    log "    x CHECKSUM MISMATCH for $name"
    return 1
  fi
  log "    + checksum ok ($name)"
}

install_file() { # install_file <src> <name>
  mkdir -p "$BIN_DIR" 2>/dev/null || true
  if [ -w "$BIN_DIR" ]; then
    install -m 0755 "$1" "$BIN_DIR/$2"
  elif have sudo; then
    sudo install -m 0755 "$1" "$BIN_DIR/$2"
  else
    log "ERROR: $BIN_DIR is not writable and sudo is unavailable; set BIN_DIR to a writable dir on PATH." >&2
    exit 1
  fi
}

# --- argument handling ------------------------------------------------------
all_tools=(helm yq actionlint shellcheck kubeconform kustomize sops)
tools=("$@")
if [ "${#tools[@]}" -eq 0 ]; then tools=("${all_tools[@]}"); fi
for t in "${tools[@]}"; do
  case "$t" in
    helm|yq|actionlint|shellcheck|kubeconform|kustomize|sops) ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) log "ERROR: unknown tool: $t (choose from: ${all_tools[*]})" >&2; exit 2 ;;
  esac
done

# --- arch -------------------------------------------------------------------
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) ARCH=amd64; ARCH_SC=x86_64 ;;
  aarch64|arm64) ARCH=arm64; ARCH_SC=aarch64 ;;
  *) log "unsupported arch: $ARCH" >&2; exit 1 ;;
esac

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

wanted() { local t; for t in "${tools[@]}"; do [ "$t" = "$1" ] && return 0; done; return 1; }

log "installing into $BIN_DIR (arch $ARCH)"

# --- helm -------------------------------------------------------------------
if wanted helm; then
  if have helm; then
    log "helm: present ($(helm version --short 2>/dev/null || echo '?'))"
  else
    log "helm: installing $HELM_VERSION"
    asset="helm-v${HELM_VERSION}-linux-${ARCH}.tar.gz"
    fetch "https://get.helm.sh/${asset}" "$TMP/helm.tgz"
    verify "$TMP/helm.tgz" "https://get.helm.sh/${asset}.sha256sum" "$asset"
    tar -xzf "$TMP/helm.tgz" -C "$TMP" "linux-${ARCH}/helm"
    install_file "$TMP/linux-${ARCH}/helm" helm
  fi
fi

# --- yq (mikefarah) ---------------------------------------------------------
if wanted yq; then
  if have yq && yq --version 2>&1 | grep -q mikefarah; then
    log "yq: present ($(yq --version))"
  else
    log "yq: installing $YQ_VERSION"
    asset="yq_linux_${ARCH}"
    fetch "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/${asset}" "$TMP/yq"
    verify "$TMP/yq" "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/checksums" "$asset"
    install_file "$TMP/yq" yq
  fi
fi

# --- actionlint -------------------------------------------------------------
if wanted actionlint; then
  if have actionlint; then
    log "actionlint: present ($(actionlint --version 2>/dev/null | head -1))"
  else
    log "actionlint: installing $ACTIONLINT_VERSION"
    asset="actionlint_${ACTIONLINT_VERSION}_linux_${ARCH}.tar.gz"
    fetch "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/${asset}" "$TMP/actionlint.tgz"
    verify "$TMP/actionlint.tgz" \
      "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_checksums.txt" "$asset"
    tar -xzf "$TMP/actionlint.tgz" -C "$TMP" actionlint
    install_file "$TMP/actionlint" actionlint
  fi
fi

# --- shellcheck -------------------------------------------------------------
if wanted shellcheck; then
  if have shellcheck; then
    log "shellcheck: present ($(shellcheck --version 2>/dev/null | awk '/version:/{print $2}'))"
  else
    log "shellcheck: installing $SHELLCHECK_VERSION"
    asset="shellcheck-v${SHELLCHECK_VERSION}.linux.${ARCH_SC}.tar.xz"
    fetch "https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/${asset}" "$TMP/shellcheck.tar.xz"
    verify "$TMP/shellcheck.tar.xz" "" "$asset"   # no published checksum upstream
    tar -xJf "$TMP/shellcheck.tar.xz" -C "$TMP"
    install_file "$TMP/shellcheck-v${SHELLCHECK_VERSION}/shellcheck" shellcheck
  fi
fi

# --- kubeconform ------------------------------------------------------------
if wanted kubeconform; then
  if have kubeconform; then
    log "kubeconform: present"
  else
    log "kubeconform: installing $KUBECONFORM_VERSION"
    asset="kubeconform-linux-${ARCH}.tar.gz"
    fetch "https://github.com/yannh/kubeconform/releases/download/v${KUBECONFORM_VERSION}/${asset}" "$TMP/kc.tgz"
    verify "$TMP/kc.tgz" "https://github.com/yannh/kubeconform/releases/download/v${KUBECONFORM_VERSION}/CHECKSUMS" "$asset"
    tar -xzf "$TMP/kc.tgz" -C "$TMP" kubeconform
    install_file "$TMP/kubeconform" kubeconform
  fi
fi

# --- kustomize --------------------------------------------------------------
if wanted kustomize; then
  if have kustomize; then
    log "kustomize: present"
  else
    log "kustomize: installing $KUSTOMIZE_VERSION"
    asset="kustomize_v${KUSTOMIZE_VERSION}_linux_${ARCH}.tar.gz"
    fetch "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${KUSTOMIZE_VERSION}/${asset}" "$TMP/kustomize.tgz"
    verify "$TMP/kustomize.tgz" \
      "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${KUSTOMIZE_VERSION}/checksums.txt" "$asset"
    tar -xzf "$TMP/kustomize.tgz" -C "$TMP" kustomize
    install_file "$TMP/kustomize" kustomize
  fi
fi

# --- sops -------------------------------------------------------------------
# Used by scripts/secrets/check.sh (the SOPS gate). Static Go binary, no libs.
if wanted sops; then
  if have sops; then
    log "sops: present ($(sops --version 2>/dev/null | awk '{print $2}'))"
  else
    log "sops: installing v${SOPS_VERSION}"
    asset="sops-v${SOPS_VERSION}.linux.${ARCH}"
    fetch "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/${asset}" "$TMP/sops"
    verify "$TMP/sops" \
      "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.checksums.txt" "$asset"
    install_file "$TMP/sops" sops
  fi
fi

log "done. ensure $BIN_DIR is on PATH."
