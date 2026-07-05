#!/usr/bin/env bash
# session-continuity SessionStart hook — auto-load RESUME.md into context +
# cheap health check.
#
# Registered (hooks/hooks.json) on SessionStart for all sources: startup,
# resume, clear, compact. A SessionStart hook's plain stdout is injected into
# the model's context for the next request, so after `/clear` the prior RESUME
# is reloaded with zero copy/paste — that is the whole point of the `clear`
# source. Pairs with the /checkpoint skill, which writes RESUME.md.
#
# Behavior:
#   0. On a genuinely new session (source=startup), clear a stale .session-done
#      marker so /keepwarm doesn't quit early because of yesterday's --final.
#   1. cat RESUME.md (slot-aware) to stdout, if present.
#   2. After a /compact, nudge the model to refresh RESUME before continuing.
#   3. Emit at most two one-line NOTEs when state needs maintenance
#      (RESUME over budget → /checkpoint; memory dir messy → /checkpoint --tidy).
#
# Always exits 0 — a SessionStart hook must never block a session from starting.
# No `set -e`: a parse hiccup should no-op, not abort the start.
#
# Env (all optional):
#   RESUME_SLOT               slot suffix; validated, unsafe value → plain file
#   RESUME_BUDGET_LINES       RESUME line budget before nagging (default 250)
#   MEMORY_ORPHAN_MAX         max un-indexed memory files before nagging (def 3)
#   CLAUDE_PROJECT_DIR        project root (falls back to $PWD)
#   CLAUDE_CONFIG_DIR         config dir, for locating this project's memory/

budget="${RESUME_BUDGET_LINES:-250}"
orphan_max="${MEMORY_ORPHAN_MAX:-3}"
base="${CLAUDE_PROJECT_DIR:-$PWD}"

# SessionStart delivers its trigger source (startup|resume|clear|compact) as JSON
# on stdin. Read it once — guarded by `timeout` when available so a blocked stdin
# can never hang session start (Claude Code closes stdin after the JSON, so the
# plain `cat` fallback returns on stock systems without `timeout`). Source is
# extracted without jq so the hook has no hard dependencies.
if command -v timeout >/dev/null 2>&1; then
    hook_input="$(timeout 2 cat 2>/dev/null)"
else
    hook_input="$(cat 2>/dev/null)"
fi
src="$(printf '%s' "$hook_input" | sed -n 's/.*"source"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"

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

# ---- 0. clear a stale completion marker on a genuinely new session ----
# `.session-done` (written by `/checkpoint --final`) tells /keepwarm the work is
# finished. It must survive `/clear` (source=clear) so a final checkpoint still
# stands the helpers down — but a brand new session (source=startup) is NOT done,
# so a marker left over from a previous session would falsely quit its helpers.
# Clear it only on startup.
if [ "$src" = "startup" ]; then
    rm -f "$base/.session-done" 2>/dev/null
fi

# ---- 1. inject RESUME into context ----
[ -f "$resume" ] && cat "$resume"

# ---- 1b. post-compaction nudge ----
# After auto-compaction (or a manual /compact) the conversation is summarized and
# the RESUME above is only as fresh as the last /checkpoint. A hook can't run the
# /checkpoint skill itself, so prompt the model to refresh RESUME before continuing.
if [ "$src" = "compact" ]; then
    printf '\nNOTE: context was just auto-compacted — run /checkpoint now to fold any work since your last checkpoint into RESUME.md, then continue.\n'
fi

# ---- 2. health notes (one line each, only when something is wrong) ----
# RESUME budget: too many lines OR more than 3 "## Session" blocks.
if [ -f "$resume" ]; then
    lines=$(wc -l < "$resume" 2>/dev/null | tr -d '[:space:]')
    blocks=$(grep -c '^## Session' "$resume" 2>/dev/null)
    [ -n "$lines" ] || lines=0
    [ -n "$blocks" ] || blocks=0
    if { [ "$lines" -gt "$budget" ] || [ "$blocks" -gt 3 ]; } 2>/dev/null; then
        printf 'NOTE: RESUME is over budget — run /checkpoint to trim.\n'
    fi
fi

# Memory hygiene for THIS project's memory dir (never another project's).
# Claude Code encodes the project dir by replacing BOTH "/" and "_" with "-".
# Two single-char substitutions, NOT a single bracket character class — macOS
# bash 3.2 mishandles such a class, so the tidy NOTE would silently never fire there.
slug="${base//\//-}"; slug="${slug//_/-}"
memdir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$slug/memory"
index="$memdir/MEMORY.md"
if [ -f "$index" ]; then
    needs_tidy=0

    # (a) dead index link: a referenced .md file that no longer exists.
    while IFS= read -r ref; do
        [ -n "$ref" ] || continue
        [ -f "$memdir/$ref" ] || needs_tidy=1
    done < <(grep -oE '\]\([^)]+\.md\)' "$index" 2>/dev/null | sed -E 's/^\]\(//; s/\)$//')

    # (b) orphans: memory files not represented in the index.
    if [ "$needs_tidy" -eq 0 ]; then
        files=$(find "$memdir" -maxdepth 1 -type f -name '*.md' ! -name 'MEMORY.md' 2>/dev/null | wc -l | tr -d '[:space:]')
        idx=$(grep -cE '^[[:space:]]*-[[:space:]]*\[' "$index" 2>/dev/null)
        [ -n "$files" ] || files=0
        [ -n "$idx" ] || idx=0
        [ "$((files - idx))" -gt "$orphan_max" ] && needs_tidy=1

        # (c) large flat index with no section headers at all.
        if [ "$needs_tidy" -eq 0 ] && [ "$files" -gt 8 ] && ! grep -q '^## ' "$index" 2>/dev/null; then
            needs_tidy=1
        fi
    fi

    [ "$needs_tidy" -eq 1 ] && printf 'NOTE: memory needs tidying — run /checkpoint --tidy.\n'
fi

exit 0
