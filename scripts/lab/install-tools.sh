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
# Either way, a tool already on PATH is left alone.
set -euo pipefail

BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"

# Pinned versions (see versions.yaml).
KIND_VERSION="${KIND_VERSION:-v0.33.0}"
FLUX_VERSION="${FLUX_VERSION:-2.9.6}"
AGE_VERSION="${AGE_VERSION:-v1.3.2}"
SOPS_VERSION="${SOPS_VERSION:-v3.13.3}"

NATIVE=0
DRY=0
for arg in "$@"; do
  case "$arg" in
    --native)  NATIVE=1 ;;
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
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

if have kind; then
  log "kind: present ($(kind version 2>/dev/null | awk '{print $2}'))"
else
  log "kind: installing $KIND_VERSION"
  asset="kind-linux-${ARCH}"
  fetch "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/${asset}" "$TMP/kind"
  verify "$TMP/kind" "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/${asset}.sha256sum" "$asset"
  run install -m 0755 "$TMP/kind" "$BIN_DIR/kind"
fi

if have flux; then
  log "flux: present ($(flux --version 2>/dev/null))"
else
  log "flux: installing $FLUX_VERSION"
  asset="flux_${FLUX_VERSION}_linux_${ARCH}.tar.gz"
  fetch "https://github.com/fluxcd/flux2/releases/download/v${FLUX_VERSION}/${asset}" "$TMP/flux.tgz"
  verify "$TMP/flux.tgz" \
    "https://github.com/fluxcd/flux2/releases/download/v${FLUX_VERSION}/flux_${FLUX_VERSION}_checksums.txt" "$asset"
  tar -xzf "$TMP/flux.tgz" -C "$TMP" flux
  run install -m 0755 "$TMP/flux" "$BIN_DIR/flux"
fi

if have age-keygen; then
  log "age: present"
else
  log "age: installing $AGE_VERSION"
  asset="age-${AGE_VERSION}-linux-${ARCH}.tar.gz"
  fetch "https://github.com/FiloSottile/age/releases/download/${AGE_VERSION}/${asset}" "$TMP/age.tgz"
  verify "$TMP/age.tgz" "" "$asset"
  tar -xzf "$TMP/age.tgz" -C "$TMP"
  run install -m 0755 "$TMP/age/age" "$BIN_DIR/age"
  run install -m 0755 "$TMP/age/age-keygen" "$BIN_DIR/age-keygen"
fi

if have sops; then
  log "sops: present ($(sops --version 2>/dev/null | awk '{print $2}'))"
else
  log "sops: installing $SOPS_VERSION"
  asset="sops-${SOPS_VERSION}.linux.${ARCH}"
  fetch "https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/${asset}" "$TMP/sops"
  verify "$TMP/sops" \
    "https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/sops-${SOPS_VERSION}.checksums.txt" "$asset"
  run install -m 0755 "$TMP/sops" "$BIN_DIR/sops"
fi

log "tools in $BIN_DIR (ensure it is on PATH): kind flux age age-keygen sops"
