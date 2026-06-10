#!/usr/bin/env bash
# session-continuity SessionStart hook — auto-load RESUME.md into context.
#
# Registered (hooks/hooks.json) on SessionStart for all sources: startup,
# resume, clear, compact. A SessionStart hook's plain stdout is injected into
# the model's context for the next request, so after `/clear` the prior RESUME
# is reloaded with zero copy/paste — that is the whole point of the `clear`
# source. Pairs with the /checkpoint skill, which writes RESUME.md.
#
# Behavior:
#   1. cat RESUME.md (slot-aware) to stdout, if present.
#   2. Emit one NOTE when RESUME has grown over budget.
#
# Always exits 0 — a SessionStart hook must never block a session from starting.
# No `set -e`: a parse hiccup should no-op, not abort the start.
#
# Env (all optional):
#   RESUME_SLOT                slot suffix; validated, unsafe value → plain file
#   RESUME_BUDGET_LINES       RESUME line budget before nagging (default 250)
#   CLAUDE_PROJECT_DIR        project root (falls back to $PWD)

budget="${RESUME_BUDGET_LINES:-250}"
base="${CLAUDE_PROJECT_DIR:-$PWD}"

# ---- slot-aware RESUME filename ----
# Parallel same-directory sessions can set RESUME_SLOT to avoid clobbering each
# other's RESUME; an unsafe slot is ignored and we fall back to the plain file.
slot=""
case "${RESUME_SLOT:-}" in
    "")               ;;
    *[!A-Za-z0-9_-]*) ;;   # unsafe → ignore, use plain RESUME.md
    *)                slot=".${RESUME_SLOT}" ;;
esac
resume="$base/RESUME${slot}.md"

# ---- 1. inject RESUME into context ----
[ -f "$resume" ] && cat "$resume"

# ---- 2. budget note (only when something is wrong) ----
if [ -f "$resume" ]; then
    lines=$(wc -l < "$resume" 2>/dev/null | tr -d '[:space:]')
    blocks=$(grep -c '^## Session' "$resume" 2>/dev/null)
    [ -n "$lines" ] || lines=0
    [ -n "$blocks" ] || blocks=0
    if { [ "$lines" -gt "$budget" ] || [ "$blocks" -gt 3 ]; } 2>/dev/null; then
        printf 'NOTE: RESUME is over budget — run /checkpoint to trim.\n'
    fi
fi

exit 0
