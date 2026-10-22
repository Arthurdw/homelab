#!/usr/bin/env bash
# Install the tools the lab needs.
#
# Two modes:
#
#   (default)   Download pinned release binaries into BIN_DIR (default ~/.local/bin).
#               No sudo, exact versions from versions.yaml, works on any distro and in CI.
#               This is what the agent/CI uses.
#
#   --native    Install via the system package manager (pacman on Arch/Omarchy). System-managed;
#               needs sudo (not passwordless here, so a human runs this). Versions come from the
#               repos and may lag the pins — drift is reported, not hidden.
#
#   --dry-run   Print what would happen, change nothing.
#
# Binary mode: a tool already on PATH is left alone only if it reports exactly the pinned
# version; missing or different versions get the pin installed into BIN_DIR (which is put
# first on PATH). --native installs only missing tools and reports drift against the pins.
set -euo pipefail

BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"

# Pinned versions (see versions.yaml).
# renovate: datasource=github-releases depName=kubernetes-sigs/kind
KIND_VERSION="${KIND_VERSION:-v0.33.0}"
# renovate: datasource=github-releases depName=fluxcd/flux2 extractVersion=^v(?<version>.+)$
FLUX_VERSION="${FLUX_VERSION:-2.9.6}"
# renovate: datasource=github-releases depName=FiloSottile/age
AGE_VERSION="${AGE_VERSION:-v1.3.2}"
# renovate: datasource=github-releases depName=getsops/sops
SOPS_VERSION="${SOPS_VERSION:-v3.13.3}"

NATIVE=0
DRY=0
for arg in "$@"; do
  case "$arg" in
    --native)  NATIVE=1 ;;
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

log() { printf '%s\n' "$*"; }

# run <cmd...>  — executes, or prints in --dry-run.
run() {
  if [ "$DRY" = 1 ]; then
    printf '    [dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

have() { command -v "$1" >/dev/null 2>&1; }

# norm_version <string> — strip a leading "v" and any "+build" suffix.
norm_version() { local v="${1#v}"; printf '%s' "${v%%+*}"; }

# tool_version <tool> — the normalized version the tool on PATH reports ("" if absent).
tool_version() {
  have "$1" || return 0
  local v=""
  case "$1" in
    kind)       v="$(kind version 2>/dev/null | awk '{print $2}')" ;;
    flux)       v="$(flux --version 2>/dev/null | awk '{print $3}')" ;;
    age-keygen) v="$(age --version 2>/dev/null | head -1)" ;;
    sops)       v="$(sops --version --disable-version-check 2>/dev/null | awk 'NR==1{print $2}')" ;;
  esac
  norm_version "$v"
}

# have_version <tool> <pin> — true if the tool on PATH reports exactly <pin>.
# Sets FOUND to the reported version ("none" if missing/unreadable).
FOUND=""
have_version() {
  FOUND="$(tool_version "$1")"
  [ -n "$FOUND" ] || FOUND="none"
  [ "$FOUND" = "$(norm_version "$2")" ]
}

fetch() { curl -fsSL --retry 3 --retry-delay 2 -o "$2" "$1"; }

# verify <file> <checksum-url> <asset-name>
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

# ---------------------------------------------------------------------------
# Native (package manager) install
# ---------------------------------------------------------------------------
native_install() {
  if ! command -v pacman >/dev/null 2>&1; then
    log "--native is only implemented for pacman-based distros (Arch/Omarchy)."
    log "Falling back is easy: run without --native to use pinned binaries."
    exit 1
  fi

  # tool-check -> package name. All four are in Arch 'extra' (checked 2026-10-16),
  # so no AUR helper (paru/yay) is required.
  local pkgs=()
  have kind       || pkgs+=(kind)
  have flux       || pkgs+=(fluxcd)
  have age-keygen || pkgs+=(age)
  have sops       || pkgs+=(sops)

  if [ "${#pkgs[@]}" -eq 0 ]; then
    log "all tools already present"
  else
    log "package manager: pacman"
    log "   installing: ${pkgs[*]}"
    if [ "$DRY" = 1 ]; then
      run sudo pacman -S --needed --noconfirm "${pkgs[@]}"
    else
      if ! sudo -n true 2>/dev/null; then
        log "   note: sudo will prompt for your password"
      fi
      sudo pacman -S --needed --noconfirm "${pkgs[@]}"
    fi
  fi

  [ "$DRY" = 1 ] && return 0

  # Report drift against the pins — do not pretend the repos match.
  log ""
  log "installed vs pinned:"
  local pairs=("kind:$KIND_VERSION" "fluxcd:v${FLUX_VERSION}" "age:$AGE_VERSION" "sops:$SOPS_VERSION")
  local pair name want got
  for pair in "${pairs[@]}"; do
    name="${pair%%:*}"; want="${pair#*:}"
    got="$(pacman -Q "$name" 2>/dev/null | awk '{print $2}' | sed 's/-[0-9]*$//')"
    if [ -z "$got" ]; then
      log "  $name: not installed"
    elif [ "v$got" = "$want" ] || [ "$got" = "$want" ]; then
      log "  $name: $got (= pin)"
    else
      log "  $name: $got  != pin $want   <-- drift"
    fi
  done
}

if [ "$NATIVE" = 1 ]; then
  native_install
  exit 0
fi

# ---------------------------------------------------------------------------
# Pinned binary install (portable, no sudo)
# ---------------------------------------------------------------------------
mkdir -p "$BIN_DIR"
export PATH="$BIN_DIR:$PATH"

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) echo "unsupported arch: $ARCH" >&2; exit 1 ;;
esac

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if have_version kind "$KIND_VERSION"; then
  log "kind: present ($FOUND)"
else
  log "kind: installing $KIND_VERSION (found $FOUND)"
  asset="kind-linux-${ARCH}"
  fetch "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/${asset}" "$TMP/kind"
  verify "$TMP/kind" "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/${asset}.sha256sum" "$asset"
  run install -m 0755 "$TMP/kind" "$BIN_DIR/kind"
fi

if have_version flux "$FLUX_VERSION"; then
  log "flux: present ($FOUND)"
else
  log "flux: installing $FLUX_VERSION (found $FOUND)"
  asset="flux_${FLUX_VERSION}_linux_${ARCH}.tar.gz"
  fetch "https://github.com/fluxcd/flux2/releases/download/v${FLUX_VERSION}/${asset}" "$TMP/flux.tgz"
  verify "$TMP/flux.tgz" \
    "https://github.com/fluxcd/flux2/releases/download/v${FLUX_VERSION}/flux_${FLUX_VERSION}_checksums.txt" "$asset"
  tar -xzf "$TMP/flux.tgz" -C "$TMP" flux
  run install -m 0755 "$TMP/flux" "$BIN_DIR/flux"
fi

if have_version age-keygen "$AGE_VERSION"; then
  log "age: present ($FOUND)"
else
  log "age: installing $AGE_VERSION (found $FOUND)"
  asset="age-${AGE_VERSION}-linux-${ARCH}.tar.gz"
  fetch "https://github.com/FiloSottile/age/releases/download/${AGE_VERSION}/${asset}" "$TMP/age.tgz"
  verify "$TMP/age.tgz" "" "$asset"
  tar -xzf "$TMP/age.tgz" -C "$TMP"
  run install -m 0755 "$TMP/age/age" "$BIN_DIR/age"
  run install -m 0755 "$TMP/age/age-keygen" "$BIN_DIR/age-keygen"
fi

if have_version sops "$SOPS_VERSION"; then
  log "sops: present ($FOUND)"
else
  log "sops: installing $SOPS_VERSION (found $FOUND)"
  asset="sops-${SOPS_VERSION}.linux.${ARCH}"
  fetch "https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/${asset}" "$TMP/sops"
  verify "$TMP/sops" \
    "https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/sops-${SOPS_VERSION}.checksums.txt" "$asset"
  run install -m 0755 "$TMP/sops" "$BIN_DIR/sops"
fi

log "tools in $BIN_DIR (ensure it is on PATH): kind flux age age-keygen sops"
