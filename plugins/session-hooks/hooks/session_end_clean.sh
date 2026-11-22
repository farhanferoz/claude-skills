#!/usr/bin/env bash
# SessionEnd — sweep known Claude Code litter from the working directory.
#
# Deletes ONLY the documented `tmpclaude-*-cwd` droppings (anthropics/
# claude-code #17720/#17990/#17609/#18197: left in the project dir with no
# cleanup on exit). Nothing else is ever removed — generic cleanup of
# agent-created files is a judgment call that belongs to the session, not a
# deletion script. Always exits 0.

payload="$(cat 2>/dev/null || true)"

cwd="$(python3 - "$payload" <<'PY' 2>/dev/null
import json, sys
try:
    print(json.loads(sys.argv[1]).get("cwd", ""))
except Exception:
    pass
PY
)"

# BOTH the project root and the payload's cwd, because they are not the same
# directory: cwd is "the current working directory when the hook is invoked" and
# it follows Claude's own `cd` (MEASURED 2026-08-14 — payload cwd=<repo>/tests
# while CLAUDE_PROJECT_DIR stayed <repo>), so a session that moved leaves this
# litter wherever it happened to be at the time. Sweeping one directory misses
# the other, and unlike the guards fixed the same day the right answer here is a
# SUPERSET, not a swap: both are places the droppings genuinely land. The `find`
# pattern is unchanged and still deletes nothing else; a repeated directory is
# harmless (the second pass simply matches nothing).
for dir in "$cwd" "${CLAUDE_PROJECT_DIR:-}"; do
    [ -n "$dir" ] && [ -d "$dir" ] || continue
    find "$dir" -maxdepth 1 -name 'tmpclaude-*-cwd' -type f -delete 2>/dev/null
done
exit 0
