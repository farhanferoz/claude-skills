#!/usr/bin/env bash
# PreToolUse(Bash) — a SUBAGENT may not background its own work.
#
# THE FAILURE IT CATCHES, in the worker's own words (transcript, 2026-07-15,
# agent `size-liquidity`, verbatim):
#
#   "I have a background monitor loop already watching for completion (task
#    bmp1voytc), which will notify me automatically once the pipeline finishes
#    or errors. I'll stop polling now and wait for that notification before
#    proceeding."
#
# It never proceeded. Nothing ever woke it. A subagent's turn ENDS when it stops
# issuing tool calls -- at which point it is DONE, not sleeping. The completion
# notification for its background task has no idle agent to deliver itself to.
# The observable result is the pattern that burned four workers in one session:
#   script built (30-40KB, correct, selftests passing) -> long compute launched
#   in the background -> agent idles "waiting" -> artifact NEVER written ->
#   no report -> the root must recover the work from disk and run it by hand.
#
# WHY A HOOK AND NOT A BRIEF. The briefs already said, in bold, in a numbered
# standing clause: "FINISH BY REPORTING via SendMessage. Do not idle holding your
# result." `timing-oos` and `size-liquidity` BOTH carried that clause. Both did
# it anyway. That is the same lesson CLAUDE.md already records about the idle
# guard -- "no brief survives a hook that orders it to shop" -- pointing the
# other way: an instruction the model can rationalise around is not a control.
# `run_in_background: true` is a single boolean in tool_input. Deny it and the
# failure is unreachable, not discouraged.
#
# THE MECHANISM: PreToolUse carries `agent_id` ONLY for calls originating inside
# a subagent (verified empirically on this build by write_set_guard's own probe,
# not taken from the docs -- documented claims have failed on contact here).
#   - no agent_id  -> the MAIN THREAD. ALWAYS allowed. The root is re-invoked on
#                     task completion, so backgrounding is correct FOR THE ROOT and
#                     is exactly how it should run a 15-minute merge without
#                     stalling the user. Never block it.
#   - agent_id set -> a subagent. Deny run_in_background; tell it to run in the
#                     foreground and wait.
#
# SCOPE: `run_in_background: true` only. A subagent's ordinary Bash calls, and
# any `&`/`nohup` inside a command string, are untouched -- the latter is a
# different bug (see the bg-job-nohup-double-background note: `nohup ... &` inside
# run_in_background gives a FALSE "completed" exit) and blocking on string
# pattern-matching would be both leaky and prone to false positives.
#
# MODE: ENFORCE by default. CCLAUDE_FGGUARD_MODE=observe downgrades to log-only.
# Enforce is right because the guard is narrow and the sanctioned path always
# works: the worker simply runs the same command in the foreground. There is no
# legitimate reason for a subagent to background work it must itself consume --
# it cannot consume it. The failure it prevents is silent and costs an hour; the
# failure it can cause is one blocked call with an actionable message.
#
# FAIL-OPEN ALWAYS. Any parse error, missing field, or unwritable state allows
# the call. A guard that wedges a session on bad data is worse than no guard.

payload="$(cat 2>/dev/null || true)"

python3 - "$payload" <<'PY'
import json
import os
import sys
import time

MODE = os.environ.get("CCLAUDE_FGGUARD_MODE", "enforce")


def allow():
    sys.exit(0)


try:
    p = json.loads(sys.argv[1])
except Exception:
    allow()

agent_id = p.get("agent_id") or ""
tool_input = p.get("tool_input") or {}
bg = tool_input.get("run_in_background")

config = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
log = os.path.join(config, "subagent_foreground_guard.log")


def note(msg):
    """Always leave a trail. A guard whose firing cannot be observed cannot be
    debugged -- teammate_idle_guard carried a false claim about its own event for
    weeks because nothing recorded whether it ran."""
    try:
        stamp = time.strftime("%Y-%m-%dT%H:%M:%S")
        prev = open(log).read().splitlines()[-299:] if os.path.exists(log) else []
        open(log, "w").write("\n".join(prev + ["%s %s" % (stamp, msg)]) + "\n")
    except OSError:
        pass


# The main thread backgrounding a long compute is CORRECT and is how the root
# avoids stalling the user. This guard is about subagents only.
if not agent_id:
    allow()

if bg is not True:
    allow()

cmd = (tool_input.get("command") or "")[:160].replace("\n", " ")

if MODE == "observe":
    note("OBSERVE agent=%s would-block bg Bash: %s" % (agent_id, cmd))
    allow()

note("BLOCK agent=%s backgrounded Bash: %s" % (agent_id, cmd))

print(
    "Blocked: run_in_background is not available to a subagent.\n"
    "\n"
    "You are a subagent. Your turn ENDS when you stop making tool calls -- at\n"
    "that point you are DONE, not waiting. A background task's completion\n"
    "notification has no idle agent to wake: it will never reach you, and the\n"
    "run you just launched will finish with nobody to read it (or be killed).\n"
    "\n"
    "This has already destroyed four workers' output in this project. Each one\n"
    "wrote a correct 30-40KB script with passing selftests, launched the real\n"
    "run in the background, said it would 'wait for the notification', and\n"
    "ended. The artifact was never written and the root had to run the script\n"
    "by hand to recover the work.\n"
    "\n"
    "DO INSTEAD: run the SAME command in the FOREGROUND and let it block.\n"
    "  - Drop run_in_background (or set it false).\n"
    "  - Raise `timeout` to cover the real runtime (ms; max 600000 = 10min).\n"
    "  - If it genuinely needs longer than 10 minutes, split the work into\n"
    "    foreground chunks that each land their output to disk as they go, so a\n"
    "    kill costs one chunk instead of everything.\n"
    "\n"
    "Blocking is not wasted time here -- waiting IS your job. Land results to\n"
    "disk as they are produced, then report via SendMessage before you finish.\n"
    "\n"
    "If this is genuinely wrong, say why and ask (D15).",
    file=sys.stderr,
)
sys.exit(2)
PY
