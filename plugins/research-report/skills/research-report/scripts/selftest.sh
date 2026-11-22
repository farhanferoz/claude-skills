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

# --- each python-based rule must FAIL the build on its own --------------------
# Regression test: these three checks printed their violations but exited 0, so
# a doc breaking only them shipped "clean". Each gets its own single-violation
# fixture so the wiring cannot silently break again.
solo_must_fail() {  # name, content
  printf '%s' "$2" > "$TMP/solo.md"
  if bash "$GUARD" "$TMP/solo.md" >/dev/null 2>&1; then
    echo "FAIL: guard passed a doc whose only violation is: $1"; fail=1
  else
    echo "ok: guard rejected: $1"
  fi
}
solo_must_fail "math in a code span" \
  '# T

## 1. Setting

The value `sqrt(2)` is here.
'
solo_must_fail "code-like backtick span" \
  '# T

## 1. Setting

See `losses.gaussian` for it.
'
solo_must_fail "heading register commentary" \
  '# T

## 1. The method, in plain terms

Body text here.
'
solo_must_fail "rhetorical-question heading" \
  '# T

## 1. Was the search honest?

Body text here.
'
solo_must_fail "over-long table caption" \
  "# T

## 1. Results

**Table 1 — $(python3 -c "print('word '*40)")**

| a | b |
|---|---|
| 1 | 2 |
"
solo_must_fail "invalid report-structure manifest" \
  '# T
<!-- report-structure: whatever -->

## 1. Setting

Body text here.
'

# --- section-size skew: one section dominating must fail ----------------------
python3 - "$TMP/skew.md" <<'PY'
import sys
w = "word " * 200
big = "word " * 4000
with open(sys.argv[1], "w") as f:
    f.write("# T\n<!-- report-structure: per-subject -->\n\n")
    for i in range(1, 6):
        f.write(f"## {i}. Subject {i}\n\n{w}\n\n")
    f.write(f"## 6. The overgrown section\n\n{big}\n")
PY
if bash "$GUARD" "$TMP/skew.md" >/dev/null 2>&1; then
  echo "FAIL: guard passed a document with one section dominating it"; fail=1
else
  echo "ok: guard rejected section-size skew"
fi

# --- a well-proportioned document with a declared spine must PASS -------------
python3 - "$TMP/shape.md" <<'PY'
import sys
w = "word " * 200
with open(sys.argv[1], "w") as f:
    f.write("# T\n<!-- report-structure: per-subject -->\n\n")
    for i in range(1, 7):
        f.write(f"## {i}. Subject {i}\n\n{w}\n\n")
PY
if bash "$GUARD" "$TMP/shape.md" >/dev/null 2>&1; then
  echo "ok: guard passed a well-proportioned document"
else
  echo "FAIL: guard rejected a well-proportioned document"; fail=1
fi


# ============================================================================
# Rules 13-15 + the release gates. Each needs a report DIRECTORY (section list,
# evidence/), not just a file, so each fixture gets its own tree.
# ============================================================================
GATE="$SKILL/scripts/release_gate.sh"
WORDS="$(python3 -c "print('word '*60)")"

mkfixture() {   # $1 = dir name; builds a fully compliant report tree
  d="$TMP/$1"; mkdir -p "$d/evidence" "$d/figures"; : > "$d/figures/a.png"
  : > "$d/figures/sheet.png"
  cat > "$d/evidence/predraft.md" <<'EOF'
# Pre-draft register

## Subject

What the fixture is about, in one sentence.

## Contributions

| contribution | role | carried in |
|---|---|---|
| widget | The thing the fixture contributes to its subject. | First subject |

## Asset inventory

| asset | where it is | points per curve | candidate |
|---|---|---|---|
| an existing curve | an earlier report | 7 | yes |

## Figure selection

figures/sheet.png -- the candidates the choice was made from.

## Figure provenance

| figure | where it came from | embedded text |
|---|---|---|
| a.png | an earlier report | inspected -- no internal codes |
EOF
  cat > "$d/evidence/definitions.md" <<'EOF'
# Definitions

## Score

The fixture's headline metric.

## Spread

The ensemble standard deviation.
EOF
  cat > "$d/SECTION_LIST.md" <<EOF
# Section list — fixture

<!-- agreed-by: Fixture Owner, 2026-08-13 -->

| part | section | words | tables | figures |
|---|---|---|---|---|
| 1 | First subject | 60 | 1 | 1 |
| 1 | Second subject | 60 | 0 | 0 |
EOF
  cat > "$d/report.md" <<EOF
# Title

<!-- report-structure: per-subject -->

## 1. First subject

The widget is the subject of this section.

$WORDS

<!-- BEGIN results table: fixture -->

| model | Score | Spread |
|---|---|---|
| one | 0.11 | 0.01 |
| two | 0.22 | 0.02 |
| three | 0.33 | 0.03 |

<!-- END results table: fixture -->

![A figure](figures/a.png)

## 2. Second subject

$WORDS
EOF
}

write_findings() {   # $1 = output path, $2 = 0 (clean) or 1 (one blocker)
  if [ "$2" = "1" ]; then
    blockers="- the mean is never defined before it is used in section 1."
  else
    blockers="none."
  fi
  {
    printf '## BLOCKERS\n\n%s\n\n## OTHER\n\n' "$blockers"
    python3 -c "print('- a minor presentation note.\n' * 150)"
  } > "$1"
}

tree_must_fail() {  # $1 = dir, $2 = description
  if bash "$GUARD" "$TMP/$1/report.md" >/dev/null 2>&1; then
    echo "FAIL: guard passed a report whose only violation is: $2"; fail=1
  else
    echo "ok: guard rejected: $2"
  fi
}

# (vii) the compliant fixture must PASS -- checked first, so a later failure is
#       known to be the planted violation and not the fixture itself.
mkfixture clean_tree
if bash "$GUARD" "$TMP/clean_tree/report.md" >/dev/null 2>&1; then
  echo "ok: guard passed a budget-conformant report"
else
  echo "FAIL: guard rejected a budget-conformant report"; fail=1
  bash "$GUARD" "$TMP/clean_tree/report.md" 2>&1 | grep "^GUARD: " | grep -v "note" | head -5
fi

# (i) a budgeted table that never appeared
mkfixture missing_table
sed -i 's/| 1 | First subject | 60 | 1 | 1 |/| 1 | First subject | 60 | 2 | 1 |/' \
  "$TMP/missing_table/SECTION_LIST.md"
tree_must_fail missing_table "a budgeted table missing from the section"

# (ii) a budgeted section with no counterpart in the document (an
#      under-populated roster shows up exactly this way, one row per missing
#      sibling)
mkfixture missing_section
printf '| 1 | Third subject | 60 | 0 | 0 |\n' >> "$TMP/missing_section/SECTION_LIST.md"
tree_must_fail missing_section "a budgeted section absent from the document"

# (iii) a results table typed by hand instead of spliced from the readout
mkfixture typed_table
python3 - "$TMP/typed_table/report.md" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("<!-- BEGIN results table: fixture -->\n", "")
s = s.replace("<!-- END results table: fixture -->\n", "")
open(p, "w").write(s)
PY
tree_must_fail typed_table "a hand-typed numeric results table"

# (iii-b) the escape hatch: a genuinely hand-made table marked as such passes
mkfixture manual_table
python3 - "$TMP/manual_table/report.md" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("<!-- BEGIN results table: fixture -->", "<!-- table: manual -->")
s = s.replace("<!-- END results table: fixture -->\n", "")
open(p, "w").write(s)
PY
if bash "$GUARD" "$TMP/manual_table/report.md" >/dev/null 2>&1; then
  echo "ok: guard allowed a table marked <!-- table: manual -->"
else
  echo "FAIL: guard rejected an explicitly hand-made table"; fail=1
fi

# (iv) a value already retracted can never reappear
mkfixture retracted
printf '13655 | superseded: the cause was the numerator, not the denominator\n' \
  > "$TMP/retracted/evidence/retracted_values.txt"
sed -i 's/| two | 0.22 | 0.02 |/| two | 13655 | 0.02 |/' "$TMP/retracted/report.md"
tree_must_fail retracted "a retracted value reappearing in the document"

# a short section is a WARNING, never a failure: a hard floor is satisfied by
# padding, which is worse than brevity
mkfixture short_section
sed -i 's/| 1 | Second subject | 60 | 0 | 0 |/| 1 | Second subject | 400 | 0 | 0 |/' \
  "$TMP/short_section/SECTION_LIST.md"
if bash "$GUARD" "$TMP/short_section/report.md" >/dev/null 2>&1; then
  echo "ok: a single under-budget section warns without failing"
else
  echo "FAIL: an under-budget section hard-failed the guard (should warn)"; fail=1
fi

# prose living in an UNBUDGETED subsection counts toward its parent's budget:
# section lists routinely budget commentary subsections "with their parent" and
# give them no row, and counting them separately reported sections that were at
# budget as empty
mkfixture nested_words
python3 - "$TMP/nested_words/report.md" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
s = s.replace("## 2. Second subject\n", "## 2. Second subject\n\n### Commentary\n")
open(p, "w", encoding="utf-8").write(s)
PY
# NOTE the here-string: `cmd | grep -q` is WRONG under `set -o pipefail`, which
# is on above. grep -q exits at the first match, the guard dies of SIGPIPE, and
# the pipeline reports that non-zero -- so a MATCHING pattern takes the else
# branch and the check silently reports the opposite of the truth. Measured here
# 2026-08-13: this fixture passed against a guard with the fix removed.
out="$(bash "$GUARD" "$TMP/nested_words/report.md" 2>&1 || true)"
if grep -q "Second subject' is 0 words" <<<"$out"; then
  echo "FAIL: prose in an unbudgeted subsection was not counted with its parent"; fail=1
else
  echo "ok: an unbudgeted subsection's prose counts toward its parent's budget"
fi

# an unresolved evidence gap must never build (S7): drafted past, not built past
mkfixture evidence_gap
printf '# Fix ledger\n\n| # | issue | status |\n|---|---|---|\n| R01 | x | DONE |\n' \
  > "$TMP/evidence_gap/FIX_LEDGER.md"
printf '\nTODO(evidence): confirm the cohort size for the composite objective\n' \
  >> "$TMP/evidence_gap/report.md"
if bash "$GATE" "$TMP/evidence_gap/report.md" >/dev/null 2>&1; then
  echo "FAIL: release gate built a document still carrying a TODO(evidence) marker"; fail=1
else
  echo "ok: release gate refused an unresolved evidence gap"
fi

# (v) an open fix-ledger row refuses the build
mkfixture ledger_open
printf '# Fix ledger\n\n- [ ] restore the medians to the results tables\n' \
  > "$TMP/ledger_open/FIX_LEDGER.md"
if bash "$GATE" "$TMP/ledger_open/report.md" >/dev/null 2>&1; then
  echo "FAIL: release gate passed a report with an open fix-ledger row"; fail=1
else
  echo "ok: release gate refused an open fix-ledger row"
fi
# a QUALIFIED open status is still open -- the most important kind, since it is
# the row somebody already believes is done
printf '| R1 | a thing | a fix | somewhere | OPEN -- claimed fixed, not verified |\n' \
  >> "$TMP/ledger_open/FIX_LEDGER.md"
if bash "$GATE" "$TMP/ledger_open/report.md" >/dev/null 2>&1; then
  echo "FAIL: release gate treated 'OPEN -- not verified' as closed"; fail=1
else
  echo "ok: release gate counted a qualified OPEN row as open"
fi
sed -i '/OPEN -- claimed fixed/d' "$TMP/ledger_open/FIX_LEDGER.md"
sed -i 's/- \[ \]/- [x]/' "$TMP/ledger_open/FIX_LEDGER.md"
write_findings "$TMP/ledger_open/findings.md" 0
bash "$SKILL/scripts/record_coldread.sh" "$TMP/ledger_open/report.md" "$TMP/ledger_open/findings.md" >/dev/null 2>&1
python3 "$SKILL/scripts/verify_numbers.py" "$TMP/ledger_open/report.md" >/dev/null 2>&1
if bash "$GATE" "$TMP/ledger_open/report.md" --shareable >/dev/null 2>&1; then
  echo "ok: release gate passed once the row was closed and the read recorded"
else
  echo "FAIL: release gate refused a closed ledger with a current cold read"; fail=1
fi

# (vi) a cold read that predates the current text refuses the hand-over build
mkfixture coldread_stale
write_findings "$TMP/coldread_stale/findings.md" 0
bash "$SKILL/scripts/record_coldread.sh" "$TMP/coldread_stale/report.md" "$TMP/coldread_stale/findings.md" >/dev/null 2>&1
printf '\nOne more sentence, added after the read.\n' >> "$TMP/coldread_stale/report.md"
if bash "$GATE" "$TMP/coldread_stale/report.md" --shareable >/dev/null 2>&1; then
  echo "FAIL: release gate called a stale cold read shareable"; fail=1
else
  echo "ok: release gate refused a stale cold read for hand-over"
fi
if bash "$GATE" "$TMP/coldread_stale/report.md" >/dev/null 2>&1; then
  echo "ok: a stale cold read only warns on an ordinary build"
else
  echo "FAIL: a stale cold read blocked an ordinary build (should warn)"; fail=1
fi

# ============================================================================
# 2026-09-06 rework: R1-R5, R7, R8. Each fires AND goes silent once satisfied.
# ============================================================================

# --- R1: the reader writes findings to a file; a too-small file is refused. --
mkfixture r1_fixture
python3 -c "print('## BLOCKERS\n\nnone.\n\n## OTHER\n\ntoo short.')" \
  > "$TMP/r1_fixture/tiny.md"
if bash "$SKILL/scripts/record_coldread.sh" "$TMP/r1_fixture/report.md" \
     "$TMP/r1_fixture/tiny.md" >/dev/null 2>&1; then
  echo "FAIL: record_coldread accepted a findings file under 2 KB"; fail=1
else
  echo "ok: record_coldread refused a findings file under 2 KB"
fi
write_findings "$TMP/r1_fixture/ok.md" 0
if bash "$SKILL/scripts/record_coldread.sh" "$TMP/r1_fixture/report.md" \
     "$TMP/r1_fixture/ok.md" >/dev/null 2>&1; then
  echo "ok: record_coldread accepted a findings file over 2 KB"
else
  echo "FAIL: record_coldread refused a findings file over 2 KB"; fail=1
fi

# --- R2: release gate refuses on open BLOCKERS; passes at zero. -------------
mkfixture r2_fixture
write_findings "$TMP/r2_fixture/blocked.md" 1
bash "$SKILL/scripts/record_coldread.sh" "$TMP/r2_fixture/report.md" \
  "$TMP/r2_fixture/blocked.md" >/dev/null 2>&1
if bash "$GATE" "$TMP/r2_fixture/report.md" >/dev/null 2>&1; then
  echo "FAIL: release gate passed a report with an open cold-read BLOCKER"; fail=1
else
  echo "ok: release gate refused an open cold-read BLOCKER"
fi
write_findings "$TMP/r2_fixture/clean.md" 0
bash "$SKILL/scripts/record_coldread.sh" "$TMP/r2_fixture/report.md" \
  "$TMP/r2_fixture/clean.md" >/dev/null 2>&1
if bash "$GATE" "$TMP/r2_fixture/report.md" >/dev/null 2>&1; then
  echo "ok: release gate passed once BLOCKERS was empty"
else
  echo "FAIL: release gate refused a report with zero cold-read blockers"; fail=1
fi

# --- R3: two reads is the ceiling; a third refuses without the override. ----
mkfixture r3_fixture
write_findings "$TMP/r3_fixture/f1.md" 0
bash "$SKILL/scripts/record_coldread.sh" "$TMP/r3_fixture/report.md" \
  "$TMP/r3_fixture/f1.md" >/dev/null 2>&1   # read #1
bash "$SKILL/scripts/record_coldread.sh" "$TMP/r3_fixture/report.md" \
  "$TMP/r3_fixture/f1.md" >/dev/null 2>&1   # read #2
if bash "$SKILL/scripts/record_coldread.sh" "$TMP/r3_fixture/report.md" \
     "$TMP/r3_fixture/f1.md" >/dev/null 2>&1; then
  echo "FAIL: record_coldread accepted a third read with no override"; fail=1
else
  echo "ok: record_coldread refused a third read with no override"
fi
if REPORT_ALLOW_THIRD_READ=1 bash "$SKILL/scripts/record_coldread.sh" \
     "$TMP/r3_fixture/report.md" "$TMP/r3_fixture/f1.md" >/dev/null 2>&1; then
  echo "ok: REPORT_ALLOW_THIRD_READ=1 let the third read record"
else
  echo "FAIL: REPORT_ALLOW_THIRD_READ=1 still refused a third read"; fail=1
fi

# --- R4: a table metric column with no matching definitions.md heading. -----
mkdir -p "$TMP/r4/evidence" "$TMP/r4/figures"
cat > "$TMP/r4/report.md" <<'EOF'
# T
<!-- report-structure: per-subject -->

## 1. Results

| model | RMSE | Spread |
|---|---|---|
| one | 0.11 | 0.01 |
| two | 0.22 | 0.02 |
EOF
if bash "$GUARD" "$TMP/r4/report.md" >/dev/null 2>&1; then
  echo "FAIL: guard passed a table metric column with no definitions.md at all"; fail=1
else
  echo "ok: guard rejected a metric column with no definitions.md"
fi
printf '# Definitions\n\n## Spread\n\nEnsemble standard deviation.\n' \
  > "$TMP/r4/evidence/definitions.md"
if bash "$GUARD" "$TMP/r4/report.md" >/dev/null 2>&1; then
  echo "FAIL: guard passed with RMSE still undefined in the register"; fail=1
else
  echo "ok: guard rejected RMSE missing from the definitions register"
fi
printf '\n## Root Mean Square Error (RMSE)\n\nLower is better.\n' \
  >> "$TMP/r4/evidence/definitions.md"
if bash "$GUARD" "$TMP/r4/report.md" >/dev/null 2>&1; then
  echo "ok: guard passed once every metric column had a matching heading"
else
  echo "FAIL: guard rejected a fully-defined metric column (name+unit tolerant match)"; fail=1
fi
cat > "$TMP/r4/notable.md" <<'EOF'
# T
<!-- report-structure: per-subject -->

## 1. Setting

No tables here, just prose about $\mu$.
EOF
if bash "$GUARD" "$TMP/r4/notable.md" >/dev/null 2>&1; then
  echo "ok: a document with no tables skips rule 19 gracefully"
else
  echo "FAIL: a document with no tables was refused by rule 19"; fail=1
fi

# --- R5: render review resets on every build; refuses shareable until marked.
mkdir -p "$TMP/r5"
cat > "$TMP/r5/report.md" <<'EOF'
# T

<!-- report-structure: per-subject -->

## 1. Setting

A Gaussian with mean $\mu$; a cited fact follows [@woodbury1950].
EOF
bash "$SKILL/scripts/build_report.sh" "$TMP/r5/report.md" >/dev/null 2>&1
if bash "$GATE" "$TMP/r5/report.md" --shareable >/dev/null 2>&1; then
  echo "FAIL: release gate called a freshly-built, unreviewed PDF shareable"; fail=1
else
  echo "ok: release gate refused an unreviewed render for hand-over"
fi
bash "$SKILL/scripts/mark_rendered.sh" "$TMP/r5/report.md" "1" >/dev/null 2>&1
write_findings "$TMP/r5/findings.md" 0
bash "$SKILL/scripts/record_coldread.sh" "$TMP/r5/report.md" "$TMP/r5/findings.md" \
  >/dev/null 2>&1
python3 "$SKILL/scripts/verify_numbers.py" "$TMP/r5/report.md" >/dev/null 2>&1
if bash "$GATE" "$TMP/r5/report.md" --shareable >/dev/null 2>&1; then
  echo "ok: release gate passed once the current PDF was marked reviewed"
else
  echo "FAIL: release gate refused a marked-reviewed PDF with a current cold read"; fail=1
fi
bash "$SKILL/scripts/build_report.sh" "$TMP/r5/report.md" >/dev/null 2>&1   # rebuild
if bash "$GATE" "$TMP/r5/report.md" --shareable >/dev/null 2>&1; then
  echo "FAIL: a rebuild after review was still treated as reviewed"; fail=1
else
  echo "ok: a rebuild reset render review — refused until marked again"
fi

# --- R7: SKILL.md is on a diet, and the assertion itself would catch a --------
#     document that regrew past it (not just a document that happens to fit).
skill_bytes="$(wc -c < "$SKILL/SKILL.md")"
if [ "$skill_bytes" -lt 9000 ]; then
  echo "ok: SKILL.md is $skill_bytes bytes (< 9000)"
else
  echo "FAIL: SKILL.md is $skill_bytes bytes (>= 9000) -- the diet regrew"; fail=1
fi
python3 -c "print('word ' * 2300)" > "$TMP/oversize_skill_fixture.md"   # ~9001+ bytes
oversize_bytes="$(wc -c < "$TMP/oversize_skill_fixture.md")"
if [ "$oversize_bytes" -ge 9000 ]; then
  echo "ok: the 9000-byte assertion itself rejects an oversize fixture ($oversize_bytes bytes)"
else
  echo "FAIL: fixture generator did not produce a >=9000-byte file"; fail=1
fi

# --- R8: preflight checks the toolchain, and fails by NAMING what's missing. -
if bash "$SKILL/scripts/build_report.sh" --preflight >/dev/null 2>&1; then
  echo "ok: preflight passes with pandoc/pdflatex on PATH"
else
  echo "FAIL: preflight failed with a normal PATH -- pandoc/pdflatex missing?"; fail=1
fi
PFBIN="$TMP/pf_bin"; mkdir -p "$PFBIN"
for t in dirname mktemp sed rm mkdir basename cat env printf; do
  p="$(command -v "$t" 2>/dev/null)"; [ -n "$p" ] && ln -sf "$p" "$PFBIN/$t"
done
pf_out="$(PATH="$PFBIN" /bin/bash "$SKILL/scripts/build_report.sh" --preflight 2>&1 >/dev/null || true)"
if grep -q "missing: pandoc pdflatex" <<<"$pf_out"; then
  echo "ok: preflight with a stripped PATH names the missing tools"
else
  echo "FAIL: preflight with a stripped PATH did not name pandoc/pdflatex ($pf_out)"; fail=1
fi

# --- S2's other half: the splice tool the guard's refusal assumes exists ------
#     The guard fails a hand-typed numeric results table. Until 2026-08-13 the
#     way OUT of that refusal lived only inside one report's own builder, so the
#     next report inherited the rule without the tool. Its own fixtures cover
#     the splice, its idempotence and each way it must refuse; this checks the
#     tool is present and passing, because a skill that enforces a rule it
#     cannot help you satisfy is the defect S2 was written for.
if python3 "$SKILL/scripts/splice_tables.py" --selftest >/dev/null 2>&1; then
  echo "ok: the table-splice tool is present and its fixtures pass"
else
  echo "FAIL: the table-splice tool is missing or failing its own fixtures"; fail=1
fi

# --- R9: the pre-draft gate (2026-09-10 rework). Each defect must REFUSE, ----
#     and the register must go silent once it is fixed. The fixtures above
#     already prove the silent half; these prove the firing half, one defect at
#     a time, because a gate nobody has seen fail is a gate nobody has tested.
PDG="$SKILL/scripts/predraft_gate.sh"
mkfixture predraft
PD="$TMP/predraft/evidence/predraft.md"
cp "$PD" "$TMP/predraft_good.md"

mv "$PD" "$TMP/predraft_hidden.md"
if bash "$GUARD" "$TMP/predraft/report.md" >/dev/null 2>&1; then
  echo "FAIL: guard passed a report with a section list and a figure and NO"
  echo "      pre-draft register"; fail=1
else
  echo "ok: guard refused a report with no pre-draft register"
fi
mv "$TMP/predraft_hidden.md" "$PD"

predraft_must_refuse() {   # $1 = what is wrong, $2 = sed program over the register
  cp "$TMP/predraft_good.md" "$PD"
  sed -i "$2" "$PD"
  if bash "$PDG" "$TMP/predraft/report.md" >/dev/null 2>&1; then
    echo "FAIL: pre-draft gate accepted: $1"; fail=1
  else
    echo "ok: pre-draft gate refused: $1"
  fi
  cp "$TMP/predraft_good.md" "$PD"
}
predraft_must_refuse "a subject stated in two sentences" \
  's|^What the fixture is about, in one sentence\.$|One sentence. And a second one.|'
predraft_must_refuse "an asset inventory with no point count" \
  's|points per curve|where else|'
predraft_must_refuse "a contribution with no role sentence" \
  's|The thing the fixture contributes to its subject\.|x|'
predraft_must_refuse "a figure selection naming no contact sheet" \
  's|^figures/sheet.png.*$|We picked one.|'
predraft_must_refuse "a borrowed figure never declared as inspected" \
  's|inspected -- no internal codes|looks fine|'
cp "$TMP/predraft_good.md" "$PD"
# The mentions-per-section note is reported for a contribution the document
# DOES name; a contribution named nowhere refuses before it can be counted, so
# read the note first and then break the naming.
if bash "$PDG" "$TMP/predraft/report.md" 2>&1 | grep -q "mentions of 'widget' per section"; then
  echo "ok: pre-draft gate reports contribution mentions per section"
else
  echo "FAIL: pre-draft gate did not report mentions per section"; fail=1
fi
sed -i 's|The widget is the subject of this section\.|A sentence naming nothing.|' \
  "$TMP/predraft/report.md"
if bash "$PDG" "$TMP/predraft/report.md" >/dev/null 2>&1; then
  echo "FAIL: pre-draft gate accepted a section that never names the contribution"
  echo "      it is declared to carry"; fail=1
else
  echo "ok: pre-draft gate refused a section that never names its contribution"
fi

# --- R10: metric proper names, colliding units, procedural voice. ------------
mkdir -p "$TMP/r10/evidence"
r10() {   # $1 = label, $2 = table row for the header, $3 = definitions body
  printf '# T\n\n## 1. Results\n\n%s\n|---|---|\n| one | 0.11 |\n' "$2" \
    > "$TMP/r10/report.md"
  printf '%s' "$3" > "$TMP/r10/evidence/definitions.md"
  if bash "$GUARD" "$TMP/r10/report.md" >/dev/null 2>&1; then
    echo "FAIL: guard passed: $1"; fail=1
  else
    echo "ok: guard refused: $1"
  fi
}
r10 "a lowercase metric column name" \
  '| model | spread over error |' \
  '# D\n\n## Spread over error\n\nThe ratio.\n'
r10 "an acronym whose register heading never expands it" \
  '| model | SSR |' \
  '# D\n\n## SSR\n\nThe ratio.\n'
r10 "a unit word that is also a defined term" \
  '| model | Coverage Error (points) |' \
  '# D\n\n## Coverage Error\n\nHow far from nominal.\n\n## Points\n\nA grid point.\n'
printf '# T\n\n## 1. Results\n\n| model | Spread-Skill Ratio (SSR) |\n|---|---|\n| one | 0.9 |\n' \
  > "$TMP/r10/report.md"
printf '# D\n\n## Spread-Skill Ratio (SSR)\n\nSpread over error.\n' \
  > "$TMP/r10/evidence/definitions.md"
if bash "$GUARD" "$TMP/r10/report.md" >/dev/null 2>&1; then
  echo "ok: guard passed a proper metric name with its acronym expanded"
else
  echo "FAIL: guard refused a properly named, properly expanded metric"; fail=1
fi
printf '# T\n\n## 1. Setting\n\nWe evaluate under a contract. We therefore report the panel.\n' \
  > "$TMP/r10/voice.md"
voice_out="$(bash "$GUARD" "$TMP/r10/voice.md" 2>&1 || true)"
if grep -q "2 first-person procedural construction" <<<"$voice_out"; then
  echo "ok: guard counted both procedural constructions on one line"
else
  echo "FAIL: guard miscounted procedural voice ($voice_out)"; fail=1
fi
if bash "$GUARD" "$TMP/r10/voice.md" >/dev/null 2>&1; then
  echo "ok: procedural voice is a NOTE, not a refusal"
else
  echo "FAIL: procedural voice hard-failed the guard; it must only note"; fail=1
fi

# --- R11: the preflight exercises what it certifies. -------------------------
#     The old 3-line preflight passed a toolchain that crashed on the report's
#     first captioned table, because it had no caption and ran no lua filter.
#     Mutating a COPY of the skill proves the new one has teeth without
#     touching the real assets.
PFSKILL="$TMP/pfskill"
cp -a "$SKILL" "$PFSKILL" 2>/dev/null || true
rm -rf "$PFSKILL/.ruff_cache"
sed -i 's|  tbl\.caption\.long = pandoc\.Blocks({})|  tbl.caption = pandoc.Caption({})|' \
  "$PFSKILL/assets/caption_below.lua"
if grep -q 'tbl.caption = pandoc.Caption' "$PFSKILL/assets/caption_below.lua"; then
  if bash "$PFSKILL/scripts/build_report.sh" --preflight >/dev/null 2>&1; then
    echo "FAIL: preflight passed a caption filter that crashes on a captioned table"
    fail=1
  else
    echo "ok: preflight caught a caption filter broken on this pandoc"
  fi
else
  echo "FAIL: the preflight mutation was not applied — the red below would be fake"
  fail=1
fi
if bash "$SKILL/scripts/build_report.sh" --preflight 2>&1 | grep -q "captioned table"; then
  echo "ok: preflight says it exercised a captioned table and a figure"
else
  echo "FAIL: preflight no longer reports what it exercised"; fail=1
fi
if bash "$SKILL/scripts/build_report.sh" --preflight 2>&1 | grep -qE "header-includes|BOTH preamble routes"; then
  echo "ok: preflight states which preamble route this pandoc honours"
else
  echo "FAIL: preflight did not state the preamble route"; fail=1
fi

# --- R11b: a table caption is emitted inside a group. ----------------------
#     \captionof outside any group leaked the caption package's zero \parskip
#     into the rest of the document (2026-10-14). Check the emitted LaTeX on a
#     real captioned table, and break a COPY of the filter to see the check fail.
mkdir -p "$TMP/r11b"
printf '| a | b |\n|---|---|\n| 1 | 2 |\n\nTable: A caption.\n\nNext paragraph.\n' > "$TMP/r11b/t.md"
cap_group() {  # $1 = filter; succeeds when the caption is wrapped in braces
  pandoc "$TMP/r11b/t.md" -t latex --lua-filter "$1" 2>/dev/null | grep -qF '{\captionof{table}'
}
if cap_group "$SKILL/assets/caption_below.lua"; then
  echo "ok: table caption is emitted inside a group"
else
  echo "FAIL: table caption is emitted outside a group (its settings leak)"; fail=1
fi
sed 's|{\\\\captionof{table}{'"'"' .. latex .. '"'"'}}|\\\\captionof{table}{'"'"' .. latex .. '"'"'}|' \
  "$SKILL/assets/caption_below.lua" > "$TMP/r11b/bare.lua"
if cmp -s "$SKILL/assets/caption_below.lua" "$TMP/r11b/bare.lua"; then
  echo "FAIL: the caption-group mutation was not applied — the red below would be fake"; fail=1
elif cap_group "$TMP/r11b/bare.lua"; then
  echo "FAIL: the caption-group check passed an ungrouped caption"; fail=1
else
  echo "ok: the caption-group check fails on an ungrouped caption"
fi

# --- R12: the number check, and its staleness gate. -------------------------
if python3 "$SKILL/scripts/verify_numbers.py" --selftest >/dev/null 2>&1; then
  echo "ok: the number-verification tool passes its own fixtures"
else
  echo "FAIL: the number-verification tool is missing or failing its fixtures"; fail=1
fi
mkdir -p "$TMP/r12/evidence"
printf '# T\n\n## 1. Setting\n\nThe ratio spans 0.87 to 0.90.\n' > "$TMP/r12/report.md"
printf '| id | claim |\n|---|---|\n| c1 | the ratio spans 0.87 to 0.90 |\n' \
  > "$TMP/r12/evidence/claims.md"
if bash "$GATE" "$TMP/r12/report.md" --shareable >/dev/null 2>&1; then
  echo "FAIL: hand-over gate passed a report whose numbers were never checked"; fail=1
else
  echo "ok: hand-over gate refused a report with no number check on record"
fi
python3 "$SKILL/scripts/verify_numbers.py" "$TMP/r12/report.md" >/dev/null 2>&1
printf 'A later edit.\n' >> "$TMP/r12/report.md"
if bash "$GATE" "$TMP/r12/report.md" 2>&1 | grep -q "number check on record is STALE"; then
  echo "ok: an edit after the number check marks it stale"
else
  echo "FAIL: an edit after the number check did not mark it stale"; fail=1
fi

[ "$fail" -eq 0 ] && { echo "SELFTEST: pass"; exit 0; } || { echo "SELFTEST: FAIL"; exit 1; }
