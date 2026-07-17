#!/usr/bin/env bash
# Build a research-report PDF with the bundled book-chapter toolchain.
# Runs the hard contract guard first, then pandoc (pdflatex) with the
# book-chapter template, --citeproc, and the proportional-table-width filter.
# Builds from the document's own directory so relative figures (\includegraphics)
# and a sibling references.bib resolve.
# Usage: bash scripts/build_report.sh <markdown-file> [bibliography.bib]
set -euo pipefail

DOC="${1:?usage: build_report.sh <markdown-file> [bibliography.bib]}"
[ -f "$DOC" ] || { echo "no such file: $DOC" >&2; exit 1; }

SKILL="$(cd "$(dirname "$0")/.." && pwd)"          # skill root (scripts/ -> ..)
DOCDIR="$(cd "$(dirname "$DOC")" && pwd)"
BASE="$(basename "$DOC" .md)"

# Bibliography: a references.bib beside the document wins; else the bundled one.
BIB="${2:-}"
if [ -z "$BIB" ]; then
  if [ -f "$DOCDIR/references.bib" ]; then BIB="$DOCDIR/references.bib"
  else BIB="$SKILL/assets/references.bib"; fi
fi
BIB="$(cd "$(dirname "$BIB")" && pwd)/$(basename "$BIB")"   # absolute

# --- Hard contract guard: fail before building. -------------------------------
bash "$SKILL/scripts/report_guard.sh" "$DOC"

# --- Build from the document's directory (so relative figures resolve). -------
# Engine is pdflatex — NOT xelatex; the template's mathpazo/helvet are Type1.
cd "$DOCDIR"
pandoc "$BASE.md" \
  -o "$BASE.pdf" \
  --pdf-engine=pdflatex \
  -V fontsize=11pt \
  -V colorlinks=true \
  --citeproc \
  --bibliography="$BIB" \
  --lua-filter "$SKILL/assets/auto_table_widths.lua" \
  -H "$SKILL/assets/book_chapter.tex"

echo "built $DOCDIR/$BASE.pdf"
