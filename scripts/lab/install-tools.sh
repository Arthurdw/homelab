#!/usr/bin/env bash
# Install the pinned tools the lab needs, into BIN_DIR (default ~/.local/bin). No sudo.
# Idempotent: existing tools are left alone. Binaries come from official HTTPS release URLs and
# are checksum-verified when the project publishes a checksums file.
set -euo pipefail

BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
mkdir -p "$BIN_DIR"

# Pinned versions (see versions.yaml). Update deliberately.
KIND_VERSION="${KIND_VERSION:-v0.33.0}"
FLUX_VERSION="${FLUX_VERSION:-2.9.6}"
AGE_VERSION="${AGE_VERSION:-v1.3.2}"
SOPS_VERSION="${SOPS_VERSION:-v3.13.3}"

log() { printf '%s\n' "$*"; }

have() { [ -x "$BIN_DIR/$1" ] || command -v "$1" >/dev/null 2>&1; }

fetch() { curl -fsSL --retry 3 --retry-delay 2 -o "$2" "$1"; }

# verify <file> <checksum-url> <asset-name>
# Prints a verdict; returns non-zero only on an actual mismatch.
verify() {
  local file="$1" url="$2" name="$3" tmp want got
  if [ -z "$url" ]; then
    log "    ! no published checksum for $name (skipped)"
    return 0
  fi
  tmp="$(mktemp)"
  if ! fetch "$url" "$tmp" 2>/dev/null; then
    log "    ! checksum file unavailable for $name (skipped)"
    rm -f "$tmp"
    return 0
  fi
  want="$(awk -v n="$name" '{f=$NF; sub(/^\*/,"",f); if (f==n) print $1}' "$tmp" | head -1)"
  rm -f "$tmp"
  if [ -z "$want" ]; then
    log "    ! no checksum entry for $name (skipped)"
    return 0
  fi
  got="$(sha256sum "$file" | awk '{print $1}')"
  if [ "$want" != "$got" ]; then
    log "    x CHECKSUM MISMATCH for $name"
    return 1
  fi
  log "    + checksum ok ($name)"
}

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) echo "unsupported arch: $ARCH" >&2; exit 1 ;;
esac

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- kind -------------------------------------------------------------------
if have kind; then
  log "kind: present ($(kind version 2>/dev/null | awk '{print $2}'))"
else
  log "kind: installing $KIND_VERSION"
  asset="kind-linux-${ARCH}"
  fetch "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/${asset}" "$TMP/kind"
  verify "$TMP/kind" "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/${asset}.sha256sum" "$asset"
  install -m 0755 "$TMP/kind" "$BIN_DIR/kind"
fi

# --- flux -------------------------------------------------------------------
if have flux; then
  log "flux: present ($(flux --version 2>/dev/null))"
else
  log "flux: installing $FLUX_VERSION"
  asset="flux_${FLUX_VERSION}_linux_${ARCH}.tar.gz"
  fetch "https://github.com/fluxcd/flux2/releases/download/v${FLUX_VERSION}/${asset}" "$TMP/flux.tgz"
  verify "$TMP/flux.tgz" \
    "https://github.com/fluxcd/flux2/releases/download/v${FLUX_VERSION}/flux_${FLUX_VERSION}_checksums.txt" "$asset"
  tar -xzf "$TMP/flux.tgz" -C "$TMP" flux
  install -m 0755 "$TMP/flux" "$BIN_DIR/flux"
fi

# --- age (age + age-keygen) -------------------------------------------------
if have age-keygen; then
  log "age: present"
else
  log "age: installing $AGE_VERSION"
  asset="age-${AGE_VERSION}-linux-${ARCH}.tar.gz"
  fetch "https://github.com/FiloSottile/age/releases/download/${AGE_VERSION}/${asset}" "$TMP/age.tgz"
  verify "$TMP/age.tgz" "" "$asset"
  tar -xzf "$TMP/age.tgz" -C "$TMP"
  install -m 0755 "$TMP/age/age" "$BIN_DIR/age"
  install -m 0755 "$TMP/age/age-keygen" "$BIN_DIR/age-keygen"
fi

# --- sops -------------------------------------------------------------------
if have sops; then
  log "sops: present ($(sops --version 2>/dev/null | awk '{print $NF}'))"
else
  log "sops: installing $SOPS_VERSION"
  asset="sops-${SOPS_VERSION}.linux.${ARCH}"
  fetch "https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/${asset}" "$TMP/sops"
  verify "$TMP/sops" \
    "https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/sops-${SOPS_VERSION}.checksums.txt" "$asset"
  install -m 0755 "$TMP/sops" "$BIN_DIR/sops"
fi

log "tools in $BIN_DIR (ensure it is on PATH): kind flux age age-keygen sops"
