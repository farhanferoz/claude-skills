#!/usr/bin/env bash
# Shared hard guard for research reports.
# Governed by notes/research/RESEARCH_REPORT_CONTRACT.md.
# Usage:  bash _build/report_guard.sh <markdown-file>
# Exits 1 and lists every violation if the doc breaks any contract rule that
# has a textual signature. Semantic rules (terms defined, math derived) are not
# greppable and are owned by the cold-reader pass.
set -euo pipefail

DOC="${1:?usage: report_guard.sh <markdown-file>}"
fail=0
report() { echo "GUARD: $1" >&2; fail=1; }

# --- 1. No "section 0": numbering starts at 1 (DOC_STANDARD). -----------------
if grep -nE "^#+ 0[. ]" "$DOC" >&2; then
  report "section-0 heading — start numbering at 1."
fi

# --- 2. No literal radical sign anywhere. -------------------------------------
if grep -n "√" "$DOC" >&2; then
  report "literal √ — use \\sqrt{} in math, sqrt() in code."
fi

# --- 3. Math never in code spans; unicode math never inside \$...\$. ------------
python3 - "$DOC" <<'PY' || true
import re, sys
MATH_CHARS = re.compile(r"[λσκαβεπτμξδγωΣΔρηΦ≈≤≥∼→·‖√∞±∇∂×−½]")
FORMULA_HINTS = re.compile(r"sqrt\(|\bmean\(|\blog [a-z]|\bE\[")
bad, in_fence = [], False
for n, line in enumerate(open(sys.argv[1], encoding="utf-8"), 1):
    if line.lstrip().startswith("```"):
        in_fence = not in_fence; continue
    if in_fence: continue
    for seg in line.split("`")[1::2]:
        if MATH_CHARS.search(seg) or FORMULA_HINTS.search(seg):
            bad.append((n, "math in code span", seg.strip()))
    for seg in line.split("$")[1::2]:
        if MATH_CHARS.search(seg):
            bad.append((n, "unicode math char inside $...$", seg.strip()))
for n, why, seg in bad:
    print(f"GUARD: line {n}: {why}: {seg!r}", file=sys.stderr)
sys.exit(1 if bad else 0)
PY
[ "${PIPESTATUS[0]:-0}" -ne 0 ] && fail=1 || true

# --- 4. No machine-local paths or working-branch names. -----------------------
if grep -nE "/home/|\.venv|add-gaussian|add-energy|nll-es-integration" "$DOC" >&2; then
  report "machine-local path or working-branch name."
fi

# --- 5. NO CODE REFERENCES (contract rule 1; strict, unlike a code-explainer).
#     File extensions, source-tree path prefixes, and code-like backtick spans
#     (snake_case, CamelCase, call syntax, dotted attr, slashes).
if grep -noE '\b[A-Za-z0-9_./-]+\.(py|ya?ml|sh|ipynb|toml|cfg|json)\b' "$DOC" >&2; then
  report "code reference: file with a source extension — write what it does, not where it lives."
fi
if grep -noE '\b(src|tests|configs?|scripts|local_hydra|notes|outputs)/[A-Za-z0-9_./-]+' "$DOC" >&2; then
  report "code reference: source-tree path — describe the thing, not its path."
fi
# Backtick spans that look like code (not prose, not a single italic symbol).
python3 - "$DOC" <<'PY' || true
import re, sys
CODEY = re.compile(r"[a-z0-9]_[a-z0-9]|[a-z][A-Z]|\(\)|\.[a-z]|/")  # snake/Camel/call/attr/path
bad, in_fence = [], False
for n, line in enumerate(open(sys.argv[1], encoding="utf-8"), 1):
    if line.lstrip().startswith("```"):
        in_fence = not in_fence; continue
    if in_fence: continue
    for seg in line.split("`")[1::2]:
        if CODEY.search(seg):
            bad.append((n, seg.strip()))
for n, seg in bad:
    print(f"GUARD: line {n}: code-like backtick span: {seg!r}", file=sys.stderr)
sys.exit(1 if bad else 0)
PY
[ "${PIPESTATUS[0]:-0}" -ne 0 ] && fail=1 || true

# --- 6. Banned-word denylist (contract rule 2; grows as new jargon is flagged).
#     Only UNAMBIGUOUS coinages/misuses belong here. A real word whose fitness is
#     context-dependent (e.g. "pricing"/"mispricing" or "oracle" — correct domain
#     terms in a finance report, jargon-misuse in an ML one) is the cold reader's
#     call, not a hard ban, so this guard stays domain-portable. Add a word here
#     the first time it is flagged, so the same fancy term never ships twice.
# Stems (no -w, so inflections are caught: amortis->amortised, slave->slaved).
DENY='amortis|amortiz|slave|slaver|surrogate|fee-dead|fee-kill|prob-reg'
if grep -niE "$DENY" "$DOC" >&2; then
  report "banned fancy/coined word (see denylist) — use a plain word or define it plainly."
fi

# --- 7. No thematic-break rules between sections (contract: book-chapter form).
if grep -nE '^(---|\*\*\*|___)\s*$' "$DOC" >&2; then
  report "thematic-break rule (---) — book chapters do not separate sections with rules."
fi

# --- 8. Figure coverage (contract rule 7): every figure generated for this -----
#     report is embedded. The doc declares its figure namespace(s) in a manifest
#     comment near the top:  <!-- report-figures: kalshi-flb pm-cost -->  . For
#     each prefix, every matching PNG in the sibling figures/ dir must be
#     referenced in the doc; an existing-but-unembedded figure hard-fails. This
#     is the completeness gate the build alone cannot give (the build only
#     catches the reverse — a referenced figure that is missing). Namespacing by
#     prefix keeps a shared figures/ dir (several reports) from cross-firing.
#     No manifest → not enforced (prints a notice), so non-figure docs still pass.
FIGDIR="$(dirname "$DOC")/figures"
MANIFEST="$(grep -oiE '<!--[[:space:]]*report-figures:[^>]*-->' "$DOC" | head -1 \
            | sed -E 's/.*report-figures:[[:space:]]*//I; s/[[:space:]]*-->.*//' || true)"
if [ -z "$MANIFEST" ]; then
  echo "GUARD: note — no <!-- report-figures: ... --> manifest; figure-coverage not enforced." >&2
elif [ -d "$FIGDIR" ]; then
  for prefix in $MANIFEST; do
    for f in "$FIGDIR/$prefix"*.png "$FIGDIR/$prefix"*.pdf; do
      [ -e "$f" ] || continue
      base="$(basename "$f")"
      if ! grep -qF "$base" "$DOC"; then
        report "figure $base exists (prefix '$prefix') but is not embedded — surface it, or move it out of figures/."
      fi
    done
  done
fi

if [ "$fail" -ne 0 ]; then
  echo "GUARD: research-report contract violated — fix the lines above." >&2
  exit 1
fi
echo "GUARD: clean."
