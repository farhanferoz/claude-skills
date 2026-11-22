#!/usr/bin/env bash
# SessionStart — surface ACTUAL spend, so estimates get corrected.
#
# THE GAP THIS CLOSES (first-person, 2026-08-10). Doctrine requires an estimate
# before a fan-out ("state estimated cost before any large fan-out") and I gave
# one: "$8-12". It was wrong by roughly 3x. Nothing ever told me, because cost is
# only ever stated FORWARD and never reconciled BACKWARD. An estimate with no
# feedback loop cannot improve — the ritual runs forever and stays wrong.
#
# WHY NOTHING NEW IS COMPUTED HERE. The numbers already exist: `tokenol` (the
# user's own tool, github.com/farhanferoz/tokenol) parses Claude Code's JSONL
# transcripts and reports daily/session/project/model rollups, with a live view
# and a ccusage cross-check. ccusage and the agent-cost skill read the same
# source. THREE tools already compute this; the defect was never measurement, it
# was that nothing INVOKED any of them. So this hook invokes; it does not compute.
#
# LATENCY IS WHY THIS IS CACHED. `tokenol` takes ~3.4 s on this machine and grows
# with transcript volume — far too slow to sit in a session's startup path, and
# SessionEnd (~1.5 s budget, cannot block) is worse. So: print the CACHED number
# instantly, then refresh in the background for next time. A number that is one
# session stale beats a startup that stalls, and beats no number at all.
#
# NOT machine-readable at source: tokenol has no --json, so the table is parsed.
# That is deliberate rather than lazy — adding --json means editing another repo,
# which needs the user's go-ahead in the moment (other sessions may be live in
# it). The parse is anchored on the date column and fails silent.
#
# FAIL-OPEN, ALWAYS SILENT ON ERROR: no tokenol, no cache, bad parse -> print
# nothing. A cost report must never delay or clutter a session start.

# The payload used to be drained unread. The fan-out half needs its `cwd`:
# agent_cost.py resolves the project from the PROCESS's working directory, and a
# hook does not reliably run in the session's. Found by firing this from another
# directory — it resolved a project that does not exist and silently reported
# nothing, which is the failure mode that looks identical to "no fan-out".
payload="$(cat 2>/dev/null || true)"

config="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
cache="$config/cost_today.cache"

# The two halves are independent: a machine without `tokenol` can still get the
# fan-out line, and vice versa. This used to be one early `exit 0` on tokenol,
# which would have silently taken the fan-out half with it.
have_tokenol=0
command -v tokenol >/dev/null 2>&1 && have_tokenol=1

# ---- the FAN-OUT half -------------------------------------------------------
# WHY IT EXISTS, and why the daily total above cannot do its job: the failure
# that started all of this was an ESTIMATE — "$8-12" stated before one fan-out,
# actual roughly 3x. A daily project total cannot isolate one fan-out, so it
# closes a different loop than the one that broke. `agent_cost.py` already prices
# every subagent transcript; this INVOKES it and never reimplements it.
#
# No date stamp, deliberately: the line claims only "most recent", which stays
# true until a newer fan-out exists. Stamping it with today's date would label a
# fan-out from three days ago as today's. The background refresh below DELETES
# the cache when there is nothing to report, so the line cannot outlive its
# subject.
fanout_cache="$config/fanout_cost.cache"
agentcost=""
for c in "$config/skills/agent-cost/agent_cost.py" \
         "$HOME/.claude/skills/agent-cost/agent_cost.py"; do
    [ -f "$c" ] && { agentcost="$c"; break; }
done
command -v python3 >/dev/null 2>&1 || agentcost=""

[ -f "$fanout_cache" ] && cat "$fanout_cache" 2>/dev/null

# 1. Report what we already know — instantly.
if [ "$have_tokenol" = 1 ] && [ -f "$cache" ]; then
    # Only surface it if it is from today; yesterday's total is noise.
    if [ "$(cut -d'|' -f1 "$cache" 2>/dev/null)" = "$(date +%F)" ]; then
        line="$(cut -d'|' -f2- "$cache" 2>/dev/null)"
        [ -n "$line" ] && printf 'Spend today — %s (cached; refreshes in background).\n' "$line"
    fi
fi

# 2. Refresh for next time, detached, so nothing waits on it.
(
    parse() {   # $1 = extra tokenol args; echoes the cost cell for today's row
        tokenol daily --since 1d $1 2>/dev/null \
            | sed 's/\x1b\[[0-9;]*m//g' \
            | awk -F'│' -v d="$(date +%F)" '
                $2 ~ d { gsub(/ /, "", $5); print $5; exit }'
    }
    # This project only. The -A (all-projects) scan walks every ~/.claude* dir —
    # 76 of them here — and takes MINUTES, which is why the first version of this
    # hook never populated its cache at all. Per-project spend is the useful
    # number at a project's session start anyway; run `tokenol daily -A` by hand
    # for the cross-project total.
    if [ "$have_tokenol" = 1 ]; then
        here="$(parse '')"
        if [ -n "$here" ]; then
            printf '%s|this project %s\n' "$(date +%F)" "$here" > "$cache.tmp" 2>/dev/null \
                && mv -f "$cache.tmp" "$cache" 2>/dev/null
        fi
    fi

    # Fan-out actuals. With no argument agent_cost.py resolves the newest session
    # under THIS cage that has a subagents/ directory — which at a session start
    # is the previous session, since this one has spawned nothing yet. That is
    # exactly the wanted target and it costs no path logic of our own.
    hookcwd="$(printf '%s' "$payload" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("cwd") or "")
except Exception: pass' 2>/dev/null)"
    # The PROJECT, not the payload's cwd: agent_cost.py resolves the cage from
    # the directory we land in, and cwd follows Claude's own `cd` (measured
    # 2026-08-14 — a subdirectory payload while CLAUDE_PROJECT_DIR stayed at the
    # root). Landing in a subdirectory keys the wrong cage, or none, and this
    # whole block then prints nothing — silence that reads as "no fan-out".
    projdir="${CLAUDE_PROJECT_DIR:-$hookcwd}"
    [ -n "$projdir" ] && [ -d "$projdir" ] && cd "$projdir" 2>/dev/null

    if [ -n "$agentcost" ]; then
        line="$(python3 "$agentcost" --json 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
a = [x for x in (d.get("agents") or []) if (x.get("cost_usd") or 0) > 0]
if not a:
    raise SystemExit(0)
top = max(a, key=lambda x: x.get("cost_usd") or 0)
print("Most recent fan-out — %d helper%s, $%.2f actual (largest: %s $%.2f). "
      "Check it against the estimate you gave."
      % (len(a), "" if len(a) == 1 else "s", d.get("total_cost_usd") or 0,
         top.get("name") or "?", top.get("cost_usd") or 0))
' 2>/dev/null)"
        if [ -n "$line" ]; then
            printf '%s\n' "$line" > "$fanout_cache.tmp" 2>/dev/null \
                && mv -f "$fanout_cache.tmp" "$fanout_cache" 2>/dev/null
        else
            rm -f "$fanout_cache" 2>/dev/null
        fi
    fi
) </dev/null >/dev/null 2>&1 &

exit 0
