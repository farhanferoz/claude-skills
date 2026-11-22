#!/usr/bin/env bash
# Build a research-report PDF with the bundled book-chapter toolchain.
# Runs the hard contract guard first, then pandoc (pdflatex) with the
# book-chapter template, --citeproc, and the proportional-table-width filter.
# Builds from the document's own directory so relative figures (\includegraphics)
# and a sibling references.bib resolve.
# Usage: bash scripts/build_report.sh <markdown-file> [bibliography.bib]
set -euo pipefail

# --draft skips the release gates (iterating on a fix); --shareable tightens
# them (the hand-over build). Plain build refuses on open fix-ledger rows.
# --preflight (R8) checks the toolchain instead of building any report.
DRAFT=0; SHAREABLE=0; PREFLIGHT=0; NOTE=0; POS=()
for a in "$@"; do
  case "$a" in
    --draft) DRAFT=1 ;;
    # A SHORT NOTE, not a chapter: 10pt and no contents page. A two-page note
    # has no sections, so --toc emits a bare 'Contents' heading over an empty
    # list, and 11pt chapter leading costs it a whole page. Opt-in: nothing
    # changes for a document that does not pass it.
    --note) NOTE=1 ;;
    --shareable) SHAREABLE=1 ;;
    --preflight) PREFLIGHT=1 ;;
    *) POS+=("$a") ;;
  esac
done
set -- "${POS[@]:-}"

SKILL="$(cd "$(dirname "$0")/.." && pwd)"          # skill root (scripts/ -> ..)

# --- Preflight (R8): is the toolchain even here, before a word is drafted. ----
#     step 0 of the loop runs this first: a missing pandoc or pdflatex is a
#     five-second check now, or a wasted drafting session discovered at step 3.
if [ "$PREFLIGHT" -eq 1 ]; then
  missing=()
  command -v pandoc  >/dev/null 2>&1 || missing+=("pandoc")
  command -v pdflatex >/dev/null 2>&1 || missing+=("pdflatex")
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "BUILD: preflight FAILED -- missing: ${missing[*]}" >&2
    exit 1
  fi
  PFTMP="$(mktemp -d)"
  trap 'rm -rf "$PFTMP"' EXIT
  # ⛔ THE TEST DOCUMENT CARRIES A CAPTIONED TABLE AND A FIGURE, AND IT RUNS THE
  #    REAL FILTER CHAIN. The old preflight was three lines of prose built with
  #    no lua filters, and on 2026-09-10 it certified a toolchain that crashed on
  #    the first captioned table of the report: `caption_below.lua` called
  #    `pandoc.Caption`, a constructor that does not exist before pandoc 3.6.
  #    Measured that day: the 3-line document passes that exact defect, the
  #    captioned one fails it with "attempt to call a nil value (field
  #    'Caption')". A preflight that does not exercise a feature cannot vouch
  #    for it.
  python3 - "$PFTMP/pf.png" <<'PNGEOF'
import struct, sys, zlib
def chunk(t, d):
    return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
w = h = 16
raw = b"".join(b"\x00" + bytes([200, 200, 220]) * w for _ in range(h))
open(sys.argv[1], "wb").write(
    b"\x89PNG\r\n\x1a\n"
    + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
PNGEOF
  cat > "$PFTMP/preflight.md" <<'EOF'
---
header-includes:
  - \newcommand{\pfyamlsentinel}{reached}
---

# Preflight

## 1. Setting

A test document, built to prove the toolchain works end to end.

: A captioned table, which is the construct that crashed the real build.

| model | Score |
|---|---|
| one | 0.11 |

![A captioned figure.](pf.png)
EOF
  printf '\\newcommand{\\pfhsentinel}{reached}\n' > "$PFTMP/pf_header.tex"
  if ! (cd "$PFTMP" && pandoc preflight.md -o preflight.pdf \
        --pdf-engine=pdflatex \
        --lua-filter "$SKILL/assets/auto_table_widths.lua" \
        --lua-filter "$SKILL/assets/caption_below.lua" \
        -H "$SKILL/assets/book_chapter.tex" \
        >"$PFTMP/preflight.log" 2>&1); then
    echo "BUILD: preflight FAILED -- pandoc/pdflatex could not build a test" >&2
    echo "  document with a captioned table and a figure, through the same lua" >&2
    echo "  filters the real build uses:" >&2
    sed 's/^/BUILD:   /' "$PFTMP/preflight.log" >&2
    exit 1
  fi

  # --- Which preamble route does THIS pandoc honour? ---------------------------
  #     Pandoc parses YAML `header-includes` as MARKDOWN, so `- \usepackage{...}`
  #     silently vanishes -- no error, no warning, no effect. On 2026-09-10 a full
  #     page of margin and title settings did nothing and the only symptom was a
  #     document that would not shrink; it was found by dumping the .tex and
  #     grepping. This asserts the fact instead of remembering it, every run.
  (cd "$PFTMP" && pandoc preflight.md -o preflight.tex -s --pdf-engine=pdflatex \
     -H "$SKILL/assets/book_chapter.tex" -H pf_header.tex >/dev/null 2>&1) || true
  yaml_ok=0; h_ok=0
  grep -q 'pfyamlsentinel' "$PFTMP/preflight.tex" 2>/dev/null && yaml_ok=1
  grep -q 'pfhsentinel'    "$PFTMP/preflight.tex" 2>/dev/null && h_ok=1
  if [ "$h_ok" -ne 1 ]; then
    echo "BUILD: preflight FAILED -- a command passed with -H did NOT reach the" >&2
    echo "  generated LaTeX. That is the route a report's preamble.tex uses, so" >&2
    echo "  no per-report preamble would take effect on this toolchain." >&2
    exit 1
  fi
  if [ "$yaml_ok" -eq 1 ]; then
    echo "BUILD: preflight -- this pandoc honours BOTH preamble routes (YAML"
    echo "  header-includes and -H)."
  else
    echo "BUILD: preflight -- this pandoc SILENTLY DROPS YAML header-includes;"
    echo "  put per-report LaTeX in a preamble.tex beside the document (the -H"
    echo "  route, verified working just now). A fenced {=latex} block is dropped"
    echo "  the same way; bare inline LaTeX on its own line does work."
  fi
  echo "BUILD: preflight clean -- pandoc, pdflatex, the template, both lua"
  echo "  filters, a captioned table and a figure all work."
  exit 0
fi

DOC="${1:?usage: build_report.sh [--draft|--shareable|--preflight] <markdown-file> [bibliography.bib]}"
[ -f "$DOC" ] || { echo "no such file: $DOC" >&2; exit 1; }

DOCDIR="$(cd "$(dirname "$DOC")" && pwd)"
BASE="$(basename "$DOC" .md)"

# Bibliography: a references.bib beside the document wins; else the bundled one.
BIB="${2:-}"
if [ -z "$BIB" ]; then
  if [ -f "$DOCDIR/references.bib" ]; then BIB="$DOCDIR/references.bib"
  else BIB="$SKILL/assets/references.bib"; fi
fi
BIB="$(cd "$(dirname "$BIB")" && pwd)/$(basename "$BIB")"   # absolute

# --- Release gates: open fix-ledger rows, and a cold read on the current text.
if [ "$DRAFT" -eq 0 ]; then
  if [ "$SHAREABLE" -eq 1 ]; then
    bash "$SKILL/scripts/release_gate.sh" "$DOC" --shareable
  else
    bash "$SKILL/scripts/release_gate.sh" "$DOC"
  fi
else
  echo "BUILD: --draft — release gates skipped; this PDF is not handed over." >&2
fi

# --- Project provenance gate (contract rule 11), if the report ships one. -----
#     What makes two measured numbers comparable is project-specific, so the
#     checker lives beside the document rather than in this skill. If it is
#     there, it is authoritative.
if [ -f "$DOCDIR/provenance_check.py" ]; then
  echo "BUILD: running the report's own provenance gate." >&2
  python3 "$DOCDIR/provenance_check.py" || {
    echo "BUILD: provenance gate refused — a declared contrast is between numbers that" >&2
    echo "BUILD:   were not produced comparably. Fix the pair or waive the axis in writing." >&2
    exit 1
  }
fi

# --- Hard contract guard: fail before building. -------------------------------
bash "$SKILL/scripts/report_guard.sh" "$DOC"

# --- Figure aspect ratio: the silent illegibility bug. ------------------------
#     pdflatex fits an image TALLER THAN IT IS WIDE to the page HEIGHT, not the
#     width, so a tall multi-panel canvas is scaled down until its axis labels are
#     a few points high -- with no warning anywhere. Measured 2026-08-12: an
#     8x22.5in stacked grid rendered at ~3pt labels and two full cold reads did
#     not catch it, because it reads as a figure rather than as an error.
#
#     THE THRESHOLD IS THE TEXT BLOCK'S OWN ASPECT, not a round number. Letter
#     paper with this template's margins gives a 7.3 x 9.0in measure, so an image
#     taller than 9.0/7.3 = 1.23 of its width is the one pdflatex fits to height
#     -- that ratio IS the switch, so anything else either misses real cases or
#     invents them. Measured 2026-08-13: the old 1.5 let a 1.44 figure through
#     that was height-fitted to 86% of the measure AND overflowed its page.
python3 - "$DOC" <<'PYEOF'
import os, re, struct, sys
doc = sys.argv[1]
docdir = os.path.dirname(os.path.abspath(doc))
for m in re.finditer(r"^!\[[^\]]*\]\(([^)]+)\)", open(doc, encoding="utf-8").read(), re.M):
    rel = m.group(1).split()[0].strip('"')
    path = os.path.join(docdir, rel)
    if not path.lower().endswith(".png") or not os.path.exists(path):
        continue
    with open(path, "rb") as f:
        head = f.read(24)
    if len(head) < 24 or head[12:16] != b"IHDR":
        continue
    w, h = struct.unpack(">II", head[16:24])
    # 9.0in text height / 7.3in text measure; see the note above.
    if w and h / w > 9.0 / 7.3:
        print(f"BUILD: WARNING -- {rel} is {w}x{h} ({h/w:.2f}x taller than wide). "
              f"pdflatex fits such an image to the page HEIGHT, which shrinks its width "
              f"and every label with it. Emit it landscape, one file per panel group.",
              file=sys.stderr)
PYEOF

# --- Build from the document's directory (so relative figures resolve). -------
# Engine is pdflatex — NOT xelatex; the template's mathpazo/helvet are Type1.
cd "$DOCDIR"
FONTSIZE=11pt; TOC_OPTS="--toc --toc-depth=2"
if [ "$NOTE" -eq 1 ]; then FONTSIZE=10pt; TOC_OPTS=""; fi

# --- Per-report preamble ------------------------------------------------------
#     A `preamble.tex` beside the document is included AFTER the skill template,
#     so a report can override the chapter defaults (margins, title block) it
#     does not want.
#     ⛔ THIS EXISTS BECAUSE THE OBVIOUS ROUTE SILENTLY DOES NOTHING. Pandoc
#     parses YAML `header-includes` as MARKDOWN, so `- \usepackage{titling}`
#     and a fenced ```{=latex}``` block both vanish from the preamble with no
#     error, no warning and no effect (measured 2026-09-10: a full page of
#     margin and title settings was dropped, and the only symptom was a
#     document that would not shrink).
EXTRA_HEADER=()
if [ -f "$DOCDIR/preamble.tex" ]; then
  EXTRA_HEADER=(-H "$DOCDIR/preamble.tex")
  echo "BUILD: including preamble.tex from the report directory."
fi
pandoc "$BASE.md" \
  -o "$BASE.pdf" \
  --pdf-engine=pdflatex \
  -V fontsize="$FONTSIZE" \
  -V colorlinks=true \
  --citeproc \
  --bibliography="$BIB" \
  $TOC_OPTS \
  --lua-filter "$SKILL/assets/auto_table_widths.lua" \
  --lua-filter "$SKILL/assets/caption_below.lua" \
  -H "$SKILL/assets/book_chapter.tex" \
  "${EXTRA_HEADER[@]}"

# A character present in the source can be silently DROPPED by pdflatex if the
# font lacks it -- observed with U+2021, which left footnote markers invisible
# while the footnote explaining them still shipped. Compare the two.
python3 - "$BASE.md" "$BASE.pdf" <<'PYEOF'
import subprocess, sys, re
md = open(sys.argv[1], encoding="utf-8").read()
try:
    pdf = subprocess.run(["pdftotext", sys.argv[2], "-"], capture_output=True,
                         text=True, check=True).stdout
except Exception:
    sys.exit(0)
lost = sorted({c for c in md if ord(c) > 0x7F and c not in pdf and not c.isspace()})
for c in lost:
    print(f"BUILD: WARNING — {c!r} (U+{ord(c):04X}) appears in the source but NOT in the "
          f"rendered PDF; pdflatex dropped it silently.", file=sys.stderr)
PYEOF

# --- Page-fill report: a sparse page is visible without opening the PDF. -----
#     Float placement has no universally right answer -- pinning figures with
#     \floatplacement{figure}{H} left a 45%-empty page on the 2026-09-10 note,
#     and letting them float (htbp) packed it correctly, but the reverse happens
#     too. What was missing was not the right default; it was ANY signal that a
#     page had gone sparse, short of opening the document and looking.
python3 - "$BASE.pdf" <<'PYEOF'
import subprocess, sys
try:
    out = subprocess.run(["pdftotext", "-layout", sys.argv[1], "-"],
                         capture_output=True, text=True, check=True).stdout
except Exception:
    sys.exit(0)
pages = out.split("\f")
if pages and not pages[-1].strip():
    pages = pages[:-1]
fills = [sum(1 for l in p.split("\n") if l.strip()) for p in pages]
if len(fills) < 2:
    sys.exit(0)
ranked = sorted(fills)
median = ranked[len(ranked) // 2]
if median <= 0:
    sys.exit(0)
# The last page is legitimately short; every other one is a question.
sparse = [(i + 1, f) for i, f in enumerate(fills[:-1]) if f < 0.6 * median]
if sparse:
    where = ", ".join(f"page {n} at {round(100 * f / median)}%" for n, f in sparse)
    print(f"BUILD: page-fill — {where} of the median page ({median} lines). "
          f"A float pinned with [H] is the usual cause; letting it float "
          f"(htbp) normally packs the document.", file=sys.stderr)
PYEOF

# --- Render review state: every build resets to UNREVIEWED (R5). -------------
#     A build changes the PDF (pdflatex embeds a build timestamp, so even an
#     unchanged source gets a new hash); only mark_rendered.sh, run AFTER
#     actually opening the rendered pages, may declare the CURRENT pdf
#     reviewed again. release_gate.sh --shareable refuses hand-over until it is.
mkdir -p "$DOCDIR/evidence"
pdf_hash="$(sha256sum "$DOCDIR/$BASE.pdf" | cut -d' ' -f1)"
printf 'UNREVIEWED %s\n' "$pdf_hash" > "$DOCDIR/evidence/render.state"

echo "built $DOCDIR/$BASE.pdf"
