#!/usr/bin/env bash
# PreToolUse(Bash) — the foreground poll-loop guard.
#
# THE SYMPTOM (user-reported 2026-07-16): "a lot of the time background tasks are
# started in foreground resulting in the session being blocked." MEASURED across
# 719 transcripts in 12 cages: of 208 poll-loops (`until … sleep … done`), 101
# ran in the FOREGROUND and blocked the calling turn (59 with timeout >= 120s; 84
# subagent, 17 main). Smoking gun, verbatim from one session: a job launched with
# run_in_background:true, its poll-loop ALSO backgrounded, then the SAME poll-loop
# reissued in the FOREGROUND with timeout=180000 — blocking the turn while waiting
# on a job that was already backgrounded. Root convention behind it: `nohup … &`
# + poll-for-marker, itself a workaround for the false "completed" exit that
# `nohup … &` gives inside run_in_background (bg-job-nohup-double-background note).
#
# THE CORRECT PATTERN ALREADY EXISTS, and 107 of the 208 poll-loops used it:
#   Bash(run_in_background: true, command: "until <cond>; do sleep 1; done")
# → the harness delivers ONE completion notification when the loop exits, and the
# turn is never blocked. Monitor() is the richer per-event variant.
#
# WHY OBSERVE MODE IS THE DEFAULT — a deliberate contrast with
# subagent_foreground_guard, which ships ENFORCE:
#   * That guard's harm was DATA LOSS (destroyed 30-40KB worker artifacts), which
#     justifies denying on day one. THIS guard's harm is WASTED WALL-CLOCK — a
#     frozen session, but nothing lost and nothing wrong. Recoverable harm does
#     not justify an unmeasured deny.
#   * That guard keys on a BOOLEAN (run_in_background) — zero false positives by
#     construction. THIS guard must STRING-MATCH a command shape, and
#     subagent_foreground_guard's own header calls string pattern-matching "leaky
#     and prone to false positives" and refuses to do it. A legitimate short poll
#     (`until curl -sf localhost:8000; do sleep 1; done`, waits seconds for a
#     server) is structurally identical to the harmful one; only the WAIT TARGET
#     and DURATION differ. We do not yet know the real false-positive rate.
# So this guard LOGS and ALLOWS. After a week of data (see FLIP CRITERION below)
# the log tells us the true FP rate and the precise harmful signature, and the
# default flips to enforce with a calibrated matcher — the first guard here whose
# enforcement is evidence-based rather than assumed.
#
# FLIP CRITERION (executable from the log alone, so it cannot rot into a TODO):
#   Read $CLAUDE_CONFIG_DIR/poll_loop_guard.log. If the large majority of entries
#   are `narrow=1` (foreground poll-loop that either polls a job-output file or
#   carries timeout >= 120000) and few `narrow=0` entries look like legitimate
#   short readiness polls, set CCLAUDE_POLLGUARD_MODE=enforce as the default.
#   Enforce denies ONLY the narrow signature; broad-but-not-narrow loops stay
#   allowed even under enforce.
#
# FLIPPED TO ENFORCE 2026-08-10, on 4 weeks of data (not 1) across every cage:
#   106 logged entries — 68 narrow=1 (would now be denied), 38 narrow=0 (still
#   allowed). 64% narrow, so a majority rather than the "large majority" the
#   criterion imagined; the decision rested instead on the narrow population
#   being unambiguous — `while kill -0 <pid>`, `until grep -q <marker> <out>`,
#   `while pgrep -f pytest` — every one a foreground wait on an already-running
#   background job. Worst single case: one agent poll-looped a pytest run 5×
#   consecutively at timeout=540000 (a trading-research project, 2026-08-09). Per-cage narrow=1:
#   project A 26, project B 14, project A's walk-forward cage 9, a research project's cages 16, other 3.
#   Revert with CCLAUDE_POLLGUARD_MODE=observe if false denials appear.
#
# WIDENED 2026-08-11 — THE UNROLLED LOOP. The matcher required literal loop
# syntax (`until … do … sleep … done`), so it keyed on the SHAPE of a poll
# rather than on what a poll DOES. Live case, first-person, main thread:
#   Bash("sleep 20; wc -l /…/tasks/<id>.output")
# — a foreground wait on an already-backgrounded job, i.e. exactly the harm this
# file measures, with the loop unrolled to a single iteration. It matched no
# loop keyword and was allowed, even though its target matched this guard's OWN
# narrow signature (`tasks/*.output`). A poll written as one iteration is still
# a poll; writing it twice is still not a loop.
#   ⇒ `sleep N; <anything>` (also `&&` / `||`) is now a recognised shape. The
#     DENY gate is unchanged — the calibrated narrow signature still decides, so
#     `sleep 1; echo hi` is logged and allowed, not denied.
#
# MODES: CCLAUDE_POLLGUARD_MODE = enforce (default) | observe | off.
# FAIL-OPEN ALWAYS: any parse error, missing field, or unwritable state allows
# the call. A guard that wedges a session on bad data is worse than no guard.

payload="$(cat 2>/dev/null || true)"

python3 - "$payload" <<'PY'
import json
import os
import re
import sys
import time

MODE = os.environ.get("CCLAUDE_POLLGUARD_MODE", "enforce")


def allow():
    sys.exit(0)


if MODE == "off":
    allow()

try:
    p = json.loads(sys.argv[1])
except Exception:
    allow()

tool_input = p.get("tool_input") or {}
cmd = tool_input.get("command") or ""
if not cmd:
    allow()

# A backgrounded poll-loop is CORRECT (it is one of the two right patterns) — the
# turn is not blocked. Only foreground loops are in scope.
if tool_input.get("run_in_background") is True:
    allow()

# Poll-loop shape: `(until|while) … do … sleep … done`, in that order, possibly
# spanning newlines. `for … sleep … done` is included (seq-based waits).
POLL = re.compile(r"\b(?:until|while|for)\b[\s\S]*?\bdo\b[\s\S]*?\bsleep\b[\s\S]*?\bdone\b")
# The same wait with the loop unrolled to one iteration: `sleep N; <check>`.
# Chained with `;`, `&&` or `||`. A trailing bare `sleep N` waits on nothing and
# is not matched.
SLEEP_THEN = re.compile(r"\bsleep\s+[\d.]+\s*(?:;|&&|\|\|)\s*\S")
if POLL.search(cmd):
    shape = "loop"
elif SLEEP_THEN.search(cmd):
    shape = "sleep-then-check"
else:
    allow()

# The NARROW (high-confidence-harmful) signature: a foreground poll-loop that
# either waits on a backgrounded job's output file, or is explicitly long. A
# short readiness poll on a URL/port/socket matches neither.
timeout = tool_input.get("timeout")
try:
    long_timeout = timeout is not None and int(timeout) >= 120000
except (TypeError, ValueError):
    long_timeout = False
polls_output = bool(re.search(r"tasks/\S+\.(?:output|log)\b", cmd)) or \
    bool(re.search(r"\bgrep\b[^\n|]*\b(?:-q|--quiet)\b[^\n|]*\.\w+", cmd))
narrow = polls_output or long_timeout

agent_id = p.get("agent_id") or ""
who = agent_id if agent_id else "main"

config = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
log = os.path.join(config, "poll_loop_guard.log")
snippet = cmd[:200].replace("\n", " ")


def note(tag):
    try:
        stamp = time.strftime("%Y-%m-%dT%H:%M:%S")
        line = "%s %s who=%s shape=%s narrow=%d refs_output=%d timeout=%s: %s" % (
            stamp, tag, who, shape, int(narrow), int(polls_output), timeout,
            snippet)
        prev = open(log).read().splitlines()[-499:] if os.path.exists(log) else []
        open(log, "w").write("\n".join(prev + [line]) + "\n")
    except OSError:
        pass


if MODE != "enforce":
    note("OBSERVE")
    allow()

# ENFORCE: deny ONLY the narrow signature. A broad match that is not narrow is
# logged and allowed — enforcement stays calibrated to the measured-harmful shape.
if not narrow:
    note("ENFORCE-ALLOW-broad")
    allow()

note("BLOCK")

if agent_id:
    advice = (
        "You are a subagent. Do NOT background a job and then poll its output "
        "file — you cannot background at all (that guard is separate), and a "
        "foreground poll blocks your whole turn on the timeout.\n"
        "DO INSTEAD: run the actual command in the FOREGROUND and let it block "
        "(waiting IS your job), with `timeout` raised to cover its real runtime. "
        "Land results to disk as they are produced.")
else:
    advice = (
        "This poll-loop runs in the FOREGROUND, so it freezes the session until "
        "the condition holds or the timeout expires — often waiting on a job that "
        "is already running in the background.\n"
        "DO INSTEAD, either:\n"
        "  1. Background the WAIT itself — Bash(run_in_background: true, command: "
        "\"until <cond>; do sleep 1; done\"). You get ONE completion notification "
        "when it exits and keep working meanwhile; the session never freezes.\n"
        "  2. Or use Monitor() to stream events from the job as they occur.\n"
        "  3. If the user asked you to watch/monitor/wait on a long job, invoke "
        "the `watch-job` skill — it is the sanctioned path for exactly this and "
        "picks the right mechanism for you.\n"
        "You do not need to poll in the foreground to 'wait' — background work "
        "notifies you on completion automatically.")

headline = ("Blocked: a foreground poll-loop blocks the turn."
            if shape == "loop" else
            "Blocked: `sleep N; <check>` in the foreground is a poll-loop with "
            "the loop unrolled to one iteration — it blocks the turn for N "
            "seconds to look at a job that is already running in the background, "
            "and the next check means another blocked turn.")

print(
    headline + "\n\n" + advice +
    "\n\nIf this is genuinely a short necessary wait, say why and ask (D15).",
    file=sys.stderr,
)
sys.exit(2)
PY
