#!/usr/bin/env bash
# agent_fanout_cap.sh -- PreToolUse(Agent): block simultaneous over-provisioning.
#
# WHY
# ---
# agent_dispatch_guard.sh already denies an unpinned subagent_type that would
# silently inherit the session model. That guard fires correctly; it simply
# never asks "how many". So a fan-out of five pinned `task-worker`s sails
# through, and the cost guidance printed alongside it is advisory text that is
# easy to read and rationalise past.
#
# Measured 2026-08-22, one session: a 5-agent variance dry-run cost $4.45 where
# 3 agents carried the same signal (a 3-2 grader split shows as 2-1 on three),
# and a second 4-agent round re-graded 16 criteria when only 3 had changed.
# ~$2.50 of ~$5.38 was avoidable. The stated reason for over-provisioning was
# fear of losing votes -- and 7 of those 9 agents' answers never arrived through
# the message channel at all, which made the fear feel justified. It was not:
# every subagent transcript is on disk and is readable with
#   python3 ~/.claude/skills/agent-cost/agent_harvest.py --list
# so a lost delivery is recoverable and is never a reason to spawn spares.
#
# WHAT THIS DOES
# --------------
# Counts Agent dispatches within a rolling window. Past the cap it DENIES, and
# the refusal names the harvest tool. It cannot wedge real work: the window is
# short, and once the first wave returns the count decays and more may be
# dispatched deliberately. It only blocks firing a large wave all at once.
#
# Deliberate large fan-out: wait for the in-flight wave, then dispatch again --
# that is also the cheaper pattern, because the first wave's answers usually
# change what the next ones should be asked.

# RELAXED 2026-09-30 (owner chose A): 3 per 180 s serialised orchestration runs whose workers have
# disjoint write sets (a queue of task workers, not a voting panel): on one project the cap blocked
# the fourth of four approved concurrent workers several times in one morning while the plan counter
# stood still. The default is now the owner's approved concurrency (4) in a 60 s window; a panel of
# graders still gets the harvest advice above. Override with CLAUDE_FANOUT_CAP / _WINDOW_SEC.

set -uo pipefail

CAP="${CLAUDE_FANOUT_CAP:-4}"
WINDOW="${CLAUDE_FANOUT_WINDOW_SEC:-60}"

payload="$(cat)"

# Session-scoped state; falls back to a shared file if the id is absent.
sid="$(printf '%s' "$payload" | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    d={}
print(d.get("session_id") or "nosession")
' 2>/dev/null)"
[ -z "$sid" ] && sid="nosession"

state="/tmp/claude-fanout-${UID:-0}-${sid}.log"
now="$(date +%s)"

# Prune entries outside the window, then count what remains.
if [ -f "$state" ]; then
  awk -v now="$now" -v w="$WINDOW" '($1+w) > now' "$state" > "${state}.tmp" 2>/dev/null \
    && mv "${state}.tmp" "$state"
fi
recent="$(wc -l < "$state" 2>/dev/null | tr -d ' ')"
[ -z "$recent" ] && recent=0

if [ "$recent" -ge "$CAP" ]; then
  cat >&2 <<EOF
Blocked: this would be agent #$((recent + 1)) dispatched within ${WINDOW}s, over the
concurrent fan-out cap of ${CAP}.

MEASURED (2026-08-22, this machine): a 5-agent dry-run cost \$4.45 where 3 carried the
same signal, and ~\$2.50 of a \$5.38 session was avoidable over-provisioning. The reason
given for spawning spares was fear of losing votes -- but 7 of 9 agents' answers never
arrived through the message channel, and every one was recoverable from disk.

DO INSTEAD:
  1. Let the in-flight wave finish. A silent or missing answer is NOT lost:
       python3 ~/.claude/skills/agent-cost/agent_harvest.py --list
       python3 ~/.claude/skills/agent-cost/agent_harvest.py <agent-name>
     '--list' separates a lost delivery from an agent that produced nothing.
  2. Then dispatch again if the returned answers show you still need to. They
     usually change what the next agents should be asked, so this is cheaper AND
     better-targeted than firing everything at once.
  3. Scope the re-run to what actually changed -- re-grading unchanged items pays
     full price to re-confirm what you already know.

For an odd-vote panel, 3 is a full panel: a 3-2 split shows as 2-1 on three.
If a wider simultaneous wave is genuinely required, say why and ask (D15).
EOF
  exit 2
fi

printf '%s\n' "$now" >> "$state"
exit 0
