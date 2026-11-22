#!/usr/bin/env bash
# Record that a cold read completed against the CURRENT text of a report.
# Run this only after a fresh-context reader has actually written its findings
# to a file (R1 -- the subagent result channel truncates a returned message,
# so the reader writes to disk instead of replying with the report).
#
# Usage: bash record_coldread.sh <markdown-file> <findings-file>
#
# R3: two reads is the ceiling. A third read means the document was not
# ready, not that the reader needs one more pass -- this refuses it unless
# REPORT_ALLOW_THIRD_READ=1, which must be stated in the ledger.
set -euo pipefail
DOC="${1:?usage: record_coldread.sh <markdown-file> <findings-file>}"
FINDINGS="${2:?usage: record_coldread.sh <markdown-file> <findings-file>}"
[ -f "$DOC" ] || { echo "no such file: $DOC" >&2; exit 1; }
[ -f "$FINDINGS" ] || { echo "no such findings file: $FINDINGS" >&2; exit 1; }

# --- R1: a findings file too small to be a real read is refused. -------------
#     Two of three reads were lost to the agent result channel before this
#     existed (2026-09-05); the size floor also catches a reader that opened
#     the file and wrote almost nothing to it.
size="$(wc -c < "$FINDINGS")"
if [ "$size" -lt 2048 ]; then
  echo "record_coldread: $FINDINGS is $size bytes (min 2048) -- too small to" >&2
  echo "  be a completed cold read; the reader likely returned early or was cut off." >&2
  exit 1
fi

DOCDIR="$(cd "$(dirname "$DOC")" && pwd)"
mkdir -p "$DOCDIR/evidence"
STATE="$DOCDIR/evidence/coldread.state"

# --- R3: the read count is against the DOCUMENT, keyed by its evidence dir,
#     not reset by anything except starting a fresh document. A read against
#     a text that later changed still counts -- the ceiling is on effort
#     spent reading this report, not on reads of one specific hash.
prev=0
if [ -f "$STATE" ]; then
  prev="$(awk '{print $1; exit}' "$STATE" 2>/dev/null || echo 0)"
fi
case "$prev" in ''|*[!0-9]*) prev=0 ;; esac
count=$((prev + 1))

if [ "$count" -ge 3 ]; then
  allow="${REPORT_ALLOW_THIRD_READ:-}"
  if [ "$allow" != "1" ]; then
    echo "record_coldread: this would be cold read #$count on this document." >&2
    echo "  Two reads is the ceiling -- a third is not ready, go back to authoring" >&2
    echo "  (R4 register, U2 section rewrite), not another read." >&2
    echo "  Override only with REPORT_ALLOW_THIRD_READ=1, stated in the ledger." >&2
    exit 1
  fi
  echo "record_coldread: REPORT_ALLOW_THIRD_READ=1 -- recording read #$count anyway." >&2
fi

hash="$(sha256sum "$DOC" | cut -d' ' -f1)"
findings_abs="$(cd "$(dirname "$FINDINGS")" && pwd)/$(basename "$FINDINGS")"
printf '%s %s %s %s\n' "$count" "$hash" "$(date -u +%Y-%m-%dT%H:%MZ)" "$findings_abs" \
  > "$STATE"
echo "recorded: $STATE (read #$count, findings: $findings_abs)"
