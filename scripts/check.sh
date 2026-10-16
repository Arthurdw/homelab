#!/usr/bin/env bash
# Local repository checks. Mirrors the static checks CI runs, where tools are available.
# Never touches live infrastructure. Safe to run anytime.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
fail=0
have() { command -v "$1" >/dev/null 2>&1; }

# --- secrets ---
if have gitleaks; then
  echo "== gitleaks =="
  gitleaks detect --no-banner --redact || { echo "FAILED: gitleaks"; fail=1; }
else
  echo "== gitleaks == skipped (missing: gitleaks) =="
fi

# --- OpenTofu ---
if have tofu; then
  echo "== tofu fmt =="
  tofu fmt -check -recursive || { echo "FAILED: tofu fmt"; fail=1; }
  roots=$(grep -rl --include='*.tf' -e '^terraform {' . 2>/dev/null | xargs -r -n1 dirname | sort -u)
  for d in $roots; do
    echo "== tofu validate: $d =="
    (cd "$d" && tofu init -backend=false -input=false >/dev/null && tofu validate) || { echo "FAILED: validate $d"; fail=1; }
  done
  [ -z "$roots" ] && echo "(no OpenTofu roots yet)"
else
  echo "== tofu == skipped (missing: tofu) =="
fi

# --- YAML ---
if have yamllint; then
  echo "== yamllint =="
  yamllint . || { echo "FAILED: yamllint"; fail=1; }
else
  echo "== yamllint == skipped (missing: yamllint) =="
fi

# --- Markdown ---
if have markdownlint-cli2; then
  echo "== markdownlint =="
  markdownlint-cli2 "**/*.md" || { echo "FAILED: markdownlint"; fail=1; }
else
  echo "== markdownlint == skipped (missing: markdownlint-cli2) =="
fi

# --- Shell ---
if have shellcheck; then
  echo "== shellcheck =="
  mapfile -t sh < <(find . -name '*.sh' -not -path './.git/*')
  if [ "${#sh[@]}" -gt 0 ]; then
    shellcheck -x "${sh[@]}" || { echo "FAILED: shellcheck"; fail=1; }
  fi
fi

echo
[ "$fail" -eq 0 ] && echo "All available checks passed." || echo "Some checks FAILED."
exit "$fail"
