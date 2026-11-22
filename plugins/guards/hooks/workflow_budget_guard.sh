#!/usr/bin/env bash
# PreToolUse(Workflow) — a workflow must carry a budget. No unbounded fan-outs.
#
# WHY A HOOK AND NOT A RULE. "budget every Workflow, always a *dynamic*
# (discovered-scale / loop-until) one" has sat in CLAUDE.md's orchestration
# section for weeks. It is a JUDGMENT rule by shape — whether a budget is the
# *right size* cannot be checked by a script — and judgment rules do not bind
# here (measured 2026-08-10: instruction adherence collapses with the number of
# simultaneously live rules, and the section holding this one had 17).
#
# But the rule has a MECHANICAL SHADOW, which is the whole point of this file:
# a script cannot judge whether a budget is wise, yet it can make its ABSENCE
# impossible. That converts an unenforceable rule into an enforced one without
# judging anything — the treatment to look for before writing any rule off as
# unenforceable.
#
# THE CHECK, purely mechanical:
#   deny iff  an inline `script` (or a readable `scriptPath`) never mentions
#             `budget` at all.
# A workflow that reads budget.total / budget.remaining() / budget.spent(), or
# that scales a fleet from it, passes untouched. The remedy is a few characters,
# so a false denial costs one retry.
#
# DELIBERATELY NOT CHECKED: whether the budget is adequate, whether the loop is
# genuinely dynamic, or whether the fan-out pays for itself. All judgment; none
# visible in a tool payload. A guard that pretended otherwise would be a rule
# wearing a hook's clothes.
#
# NOT DENIED: `name` (a saved workflow — its script is not in the payload, so
# there is nothing to inspect) and `resumeFromRunId` (the run was already
# approved once; re-denying it would strand recoverable work).
#
# Escape hatch: CCLAUDE_WFBUDGET_MODE=off. Fail-open on any parse trouble — a
# guard that aborts a legitimate call on a hiccup is worse than one that misses.

[ "${CCLAUDE_WFBUDGET_MODE:-}" = "off" ] && exit 0
command -v python3 >/dev/null 2>&1 || exit 0

# Read the payload BEFORE handing the heredoc to python. `python3 - <<EOF` makes
# the heredoc the SCRIPT, so stdin no longer carries the hook payload; passing it
# as argv is what the other guards do. Getting this wrong made the deny path
# silently unreachable — caught only because the behavioural test asserted an
# exit code instead of eyeballing the message.
payload="$(cat 2>/dev/null || true)"

python3 - "$payload" <<'PY'
import json
import os
import re
import sys

try:
    payload = json.loads(sys.argv[1]) if len(sys.argv) > 1 else {}
except Exception:
    sys.exit(0)                      # unparseable -> fail open

def _log(tag, detail=""):
    """Every decision, ALLOWs included (D14). This guard had no log at all, so
    'has it ever fired?' was unanswerable — and Workflow calls are rare enough
    that inertness here could persist indefinitely without anyone noticing."""
    try:
        import time
        cfg = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
        with open(os.path.join(cfg, "workflow_budget_guard.log"), "a") as fh:
            fh.write("%s %-14s %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%S"), tag,
                                        str(detail)[:160]))
    except Exception:
        pass


if payload.get("tool_name") != "Workflow":
    sys.exit(0)

ti = payload.get("tool_input") or {}

# A resume re-runs an already-sanctioned script; a saved workflow's body is not
# in the payload. Nothing to inspect in either case.
if ti.get("resumeFromRunId") or (ti.get("name") and not ti.get("script")):
    sys.exit(0)

body = ti.get("script") or ""
if not body:
    path = ti.get("scriptPath")
    if not path:
        sys.exit(0)                  # nothing to inspect -> fail open
    try:
        with open(os.path.expanduser(path)) as fh:
            body = fh.read()
    except OSError:
        sys.exit(0)                  # unreadable -> fail open

# ---- unpinned agentType in a workflow (added 2026-08-13) -------------------
# MEASURED that day: a one-agent Workflow dispatching `agentType: 'dr-checker'`
# ran to completion while agent_dispatch_guard.log stayed at 25 lines, before
# and after. PreToolUse(Agent) does NOT fire for workflow agents, so the pinning
# guard covers the Agent tool ONLY and a workflow is free to run an unpinned
# type at session tier -- in an Opus session, silently, per agent.
#
# This hook is the one place that sees a workflow before it runs, but it sees
# the SCRIPT, not the individual agent() calls. So the check is textual by
# necessity: pull every agentType literal and resolve it against ~/.claude/agents
# exactly as agent_dispatch_guard does. That is weaker than the Agent-tool check
# (a computed agentType is invisible to it) and the limit is stated rather than
# hidden -- but a literal is what every workflow written here has ever used.
AGENT_TYPE = re.compile(r"""agentType\s*:\s*['"]([A-Za-z0-9_-]+)['"]""")
FRONTMATTER_MODEL = re.compile(r"^model:\s*\S+", re.M)


def _pinned(name):
    cfg = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
    for base in (os.path.join(cfg, "agents"),
                 os.path.join(os.path.expanduser("~"), ".claude", "agents")):
        path = os.path.join(base, name + ".md")
        try:
            with open(path) as fh:
                if FRONTMATTER_MODEL.search(fh.read(4096)):
                    return True
        except OSError:
            continue
    return False


unpinned = sorted({t for t in AGENT_TYPE.findall(body) if not _pinned(t)})
if unpinned and os.environ.get("CCLAUDE_WFAGENT_MODE", "enforce") != "off":
    _log("DENY-unpinned", ",".join(unpinned))
    print(
        "WORKFLOW DISPATCHES AN UNPINNED AGENT TYPE: %s\n"
        "No definition carrying a `model:` line was found for it, so it inherits "
        "the SESSION model -- in an Opus session that is an Opus agent per call, "
        "and workflow agents do NOT pass through the Agent-tool dispatch guard "
        "(measured 2026-08-13), so nothing else will catch this.\n"
        "\n"
        "DO INSTEAD: name a pinned role -- utility-worker (haiku), task-worker "
        "(sonnet), adjudicator (opus) -- or pass an explicit `model:` in the "
        "agent() options.\n"
        "If this type is deliberately unpinned so it tracks the session model, "
        "say so and ask (D15)." % ", ".join(unpinned),
        file=sys.stderr,
    )
    sys.exit(2)

if "budget" in body:
    _log("ALLOW-budgeted", "%d bytes of script" % len(body))
    sys.exit(0)

_log("DENY-nobudget", "%d bytes of script" % len(body))
print(
    "WORKFLOW WITHOUT A BUDGET. This script never references `budget`, so it has "
    "no ceiling: a discovered-scale loop can run to the 1000-agent cap before "
    "anything stops it, and you do not see cumulative spend by default.\n"
    "\n"
    "DO INSTEAD — take the turn's token target and bound the work with it:\n"
    "  const FLEET = budget.total ? Math.floor(budget.total / 100_000) : 5\n"
    "or, for a loop-until pattern, guard on budget.total so an unset target "
    "cannot run away:\n"
    "  while (budget.total && budget.remaining() > 50_000) { ... }\n"
    "\n"
    "`budget.total` is the target (null if unset), `budget.spent()` is output "
    "tokens used this turn across the main loop AND all workflows, and "
    "`budget.remaining()` is what is left. State the estimate to the user before "
    "a large fan-out — cost is invisible unless you look.\n"
    "If this workflow is genuinely small and bounded by its own structure, say so "
    "and ask (D15).",
    file=sys.stderr,
)
sys.exit(2)
PY
