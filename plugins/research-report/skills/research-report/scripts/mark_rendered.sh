#!/usr/bin/env bash
# Mark the CURRENT PDF as render-reviewed (R5): the author has opened the
# pages carrying figures/tables and checked them against contract rule 10 --
# legend, colorbar, axis labels present; no wrapped cell; nothing illegible at
# printed size (SKILL.md step 3b). Every build_report.sh run resets this to
# UNREVIEWED, so a rebuild after review must be marked again before a
# shareable hand-over (release_gate.sh --shareable enforces this).
#
# Usage: bash scripts/mark_rendered.sh <markdown-file> <pages reviewed>
#   <pages reviewed> is free text describing what was opened, e.g. "1-12" or
#   "all" or "3,7,9 (the only pages with figures)".
set -euo pipefail
DOC="${1:?usage: mark_rendered.sh <markdown-file> <pages reviewed>}"
PAGES="${2:?usage: mark_rendered.sh <markdown-file> <pages reviewed>}"
[ -f "$DOC" ] || { echo "no such file: $DOC" >&2; exit 1; }

DOCDIR="$(cd "$(dirname "$DOC")" && pwd)"
BASE="$(basename "$DOC" .md)"
PDF="$DOCDIR/$BASE.pdf"
[ -f "$PDF" ] || { echo "no such file: $PDF -- build it first" >&2; exit 1; }

mkdir -p "$DOCDIR/evidence"
hash="$(sha256sum "$PDF" | cut -d' ' -f1)"
printf 'REVIEWED %s %s %s\n' "$hash" "$PAGES" "$(date -u +%Y-%m-%dT%H:%MZ)" \
  > "$DOCDIR/evidence/render.state"
echo "marked reviewed: $DOCDIR/evidence/render.state"
