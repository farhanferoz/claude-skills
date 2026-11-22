#!/usr/bin/env bash
# Release gates for a research report: the checks that decide whether a built
# PDF may be handed to whoever asked for it.
#
# WHY THIS IS SEPARATE FROM THE GUARD. The guard judges the source against the
# contract; these judge the PROCESS state around it -- is every raised issue
# closed, has anyone read the current text cold, and has the current PDF been
# looked at. All are cheap, none need pandoc, and keeping them out of
# build_report.sh is what lets the selftest exercise them without a pdflatex run.
#
# Usage: bash release_gate.sh <markdown-file> [--shareable]
#   default      -- refuses on open fix-ledger rows, an unresolved evidence
#                   gap, or open cold-read BLOCKERS; WARNS on a stale cold
#                   read or an unreviewed render
#   --shareable  -- also refuses on a stale cold read or an unreviewed render
#                   (the hand-over gate)
set -uo pipefail

DOC=""; SHAREABLE=0
for a in "$@"; do
  case "$a" in
    --shareable) SHAREABLE=1 ;;
    *) [ -z "$DOC" ] && DOC="$a" ;;
  esac
done
[ -n "$DOC" ] || { echo "usage: release_gate.sh <markdown-file> [--shareable]" >&2; exit 2; }
[ -f "$DOC" ] || { echo "no such file: $DOC" >&2; exit 2; }

DOCDIR="$(cd "$(dirname "$DOC")" && pwd)"
LEDGER="$DOCDIR/FIX_LEDGER.md"
STATE="$DOCDIR/evidence/coldread.state"
RSTATE="$DOCDIR/evidence/render.state"
refuse=0

# --- 1. Every raised issue is closed. -----------------------------------------
#     Measured 2026-08-12: rulings made in review rounds were applied from
#     memory of the conversation. Medians agreed and never restored; an agreed
#     experiment still one sentence; the difference-from-baseline tables dropped
#     by a merge with nobody noticing. A ledger only helps if something refuses
#     while a row is open, so this does.
if [ -f "$LEDGER" ]; then
  # Match a STATUS CELL THAT BEGINS with OPEN, not a cell that is exactly OPEN.
  # Found the hard way: rows reading "OPEN -- claimed fixed, not verified" were
  # counted as closed, so the gate under-reported 21 open rows as 12. A qualified
  # OPEN is the most important kind -- it is the row somebody believes is done.
  open_rows="$(grep -cE '^[[:space:]]*-[[:space:]]*\[ \]|\|[[:space:]]*OPEN\b' "$LEDGER" 2>/dev/null || true)"
  if [ "${open_rows:-0}" -gt 0 ]; then
    echo "RELEASE: $open_rows open row(s) in FIX_LEDGER.md — every raised issue is closed" >&2
    echo "RELEASE:   with where it landed and how it was verified, before this builds." >&2
    echo "RELEASE:   Iterating on a fix? Use build_report.sh --draft." >&2
    refuse=1
  fi
fi

# --- 1b. No unresolved evidence gap ships (S7). -------------------------------
#     The skill's own rule is that an evidence gap may be DRAFTED past but never
#     BUILT past: blocking a draft on a missing schematic would be wrong, since
#     that is authoring work, but shipping the marker is worse than either.
#     Nothing enforced it until 2026-08-13, and on that day a fan-out returned
#     drafts carrying two TODO(evidence) markers and two TODO(figure) markers.
#     They were caught by hand. Had one been missed it would have built clean and
#     shipped a literal TODO to a colleague.
gaps="$(grep -nE 'TODO\((evidence|figure|source|number)\)' "$DOC" 2>/dev/null || true)"
if [ -n "$gaps" ]; then
  echo "RELEASE: unresolved evidence gap(s) still in the document:" >&2
  printf '%s\n' "$gaps" | sed 's/^/RELEASE:   /' >&2
  echo "RELEASE:   Settle each from source and delete the marker, or state the gap" >&2
  echo "RELEASE:   in the text as a stated limitation. Drafting past one is fine;" >&2
  echo "RELEASE:   building past one is not." >&2
  refuse=1
fi

# --- 2. Somebody has read THIS text cold. -------------------------------------
#     The cold read is the skill's only semantic gate and its prompt already
#     says to re-run after substantial fixes. It was not re-run: two reads
#     happened on the first draft, then twelve tables and six figures were
#     replaced and a whole section added, and the document went out anyway.
#     Prose asking for a re-run does not bind; a hash comparison does.
#
#     STATE format (record_coldread.sh, R1/R3): "<count> <hash> <date> <findings-path>"
now="$(sha256sum "$DOC" | cut -d' ' -f1)"
recorded_hash=""; findings_path=""
if [ -f "$STATE" ]; then
  read -r _ recorded_hash _ findings_path < "$STATE"
fi
if [ ! -f "$STATE" ]; then
  echo "RELEASE: no cold read on record (expected evidence/coldread.state)." >&2
  echo "RELEASE:   Run the gate in SKILL.md step 4, then record it with record_coldread.sh." >&2
  [ "$SHAREABLE" -eq 1 ] && refuse=1
elif [ "$recorded_hash" != "$now" ]; then
  echo "RELEASE: the cold read on record is STALE — the source has changed since it ran" >&2
  echo "RELEASE:   (recorded: $(cat "$STATE"))." >&2
  [ "$SHAREABLE" -eq 1 ] && refuse=1
else
  echo "RELEASE: cold read current for this exact text."

  # --- 2b. R2: the ranked contract has an exit rule -- zero BLOCKERS. ---------
  #     The cold reader's findings file carries a `## BLOCKERS` section (max
  #     10, ranked) and a flat `## OTHER`. OTHER items are triage/ledger
  #     material and never gate the build; a non-empty BLOCKERS section means
  #     the loop is not done, independent of the fix-ledger and evidence-gap
  #     checks above (those track what the AUTHOR opened; this tracks what the
  #     last cold read is still owed).
  if [ -n "$findings_path" ] && [ -f "$findings_path" ]; then
    blocker_count="$(python3 - "$findings_path" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"^##\s*BLOCKERS\s*$(.*?)(?=^##\s|\Z)", text, re.M | re.S)
body = m.group(1) if m else ""
items = [l for l in body.splitlines()
         if re.match(r"^\s*[-*]\s+\S", l) or re.match(r"^\s*\d+[.)]\s+\S", l)]
print(len(items))
PY
)"
    if [ "${blocker_count:-0}" -gt 0 ]; then
      echo "RELEASE: $blocker_count open BLOCKERS in the last recorded cold read" >&2
      echo "RELEASE:   ($findings_path). The loop exits at zero blockers." >&2
      refuse=1
    fi
  elif [ -n "$findings_path" ]; then
    echo "RELEASE: recorded findings file is missing: $findings_path" >&2
  fi
fi

# --- 3. R5: the current PDF has been looked at, not just built. ---------------
#     build_report.sh writes evidence/render.state as "UNREVIEWED <hash>"
#     after every build; only scripts/mark_rendered.sh, run after opening the
#     pages against contract rule 10, sets it to "REVIEWED <hash> <pages>
#     <date>". A rebuild always resets it, so a rebuild after review must be
#     marked again before a shareable hand-over.
PDF="$DOCDIR/$(basename "$DOC" .md).pdf"
if [ -f "$PDF" ]; then
  pdf_now="$(sha256sum "$PDF" | cut -d' ' -f1)"
  if [ ! -f "$RSTATE" ]; then
    echo "RELEASE: no render review on record (expected evidence/render.state)." >&2
    [ "$SHAREABLE" -eq 1 ] && refuse=1
  else
    rstatus=""; rhash=""
    read -r rstatus rhash _ < "$RSTATE"
    if [ "$rstatus" != "REVIEWED" ] || [ "$rhash" != "$pdf_now" ]; then
      echo "RELEASE: the current PDF has not been render-reviewed — run" >&2
      echo "RELEASE:   scripts/mark_rendered.sh <doc.md> <pages> after opening its pages." >&2
      [ "$SHAREABLE" -eq 1 ] && refuse=1
    else
      echo "RELEASE: render review current for this exact PDF."
    fi
  fi
else
  echo "RELEASE: note — no PDF built yet; render review not checked."
fi

# --- 4. The numbers in the prose were checked against THIS text. -------------
#     Every full rewrite invalidates the number-verification pass, and on
#     2026-09-10 there were four rewrites; running the pass after each one
#     caught two errors that had survived a rewrite (a range stated 0.87-0.92
#     against a register span of 0.87-0.90, and "four percentage points" where
#     the figure showed three). The pass itself is a report, not a gate --
#     roundings are legitimate. STALENESS is the gate, exactly as it is for the
#     cold read and the render review.
NSTATE="$DOCDIR/evidence/numbers.state"
if [ ! -f "$NSTATE" ]; then
  echo "RELEASE: the prose numbers have never been checked against the evidence" >&2
  echo "RELEASE:   register — run scripts/verify_numbers.py <doc.md>." >&2
  [ "$SHAREABLE" -eq 1 ] && refuse=1
else
  n_hash=""; read -r _ n_hash _ < "$NSTATE"
  if [ "$n_hash" != "$now" ]; then
    echo "RELEASE: the number check on record is STALE — the source has changed" >&2
    echo "RELEASE:   since it ran. Re-run scripts/verify_numbers.py <doc.md>." >&2
    [ "$SHAREABLE" -eq 1 ] && refuse=1
  else
    echo "RELEASE: number check current for this exact text."
  fi
fi

if [ "$refuse" -ne 0 ]; then
  echo "RELEASE: refused." >&2
  exit 1
fi
[ "$SHAREABLE" -eq 1 ] && echo "RELEASE: clean — this PDF may be handed over."
exit 0
