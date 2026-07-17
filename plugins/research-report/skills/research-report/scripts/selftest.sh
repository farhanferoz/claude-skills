#!/usr/bin/env bash
# Self-test for report_guard.sh: a fixture with planted violations must fail,
# a clean fixture must pass. Run: bash scripts/selftest.sh
set -uo pipefail
SKILL="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="$SKILL/scripts/report_guard.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0

# --- dirty fixture: one of each planted violation -> guard MUST exit non-zero -
cat > "$TMP/dirty.md" <<'EOF'
## 0. Overview

The value is √2, see `foo_bar.py` for the amortised pricing head.

Path /home/user/x and src/autocast/losses.py with $σ=1$.

---
EOF
if bash "$GUARD" "$TMP/dirty.md" >/dev/null 2>&1; then
  echo "FAIL: guard passed a dirty fixture (should have failed)"; fail=1
else
  echo "ok: guard rejected the dirty fixture"
fi

# --- clean fixture -> guard MUST exit 0 --------------------------------------
cat > "$TMP/clean.md" <<'EOF'
# Title

## 1. Setting

The model predicts a Gaussian with mean $\mu$ and covariance $\boldsymbol{\Sigma}$;
the square root is written $\sqrt{2}$. A cited fact follows [@woodbury1950].
EOF
if bash "$GUARD" "$TMP/clean.md" >/dev/null 2>&1; then
  echo "ok: guard passed the clean fixture"
else
  echo "FAIL: guard rejected a clean fixture (should have passed)"; fail=1
fi

[ "$fail" -eq 0 ] && { echo "SELFTEST: pass"; exit 0; } || { echo "SELFTEST: FAIL"; exit 1; }
