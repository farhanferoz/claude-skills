#!/usr/bin/env bash
# PreToolUse(Bash) — main-thread long jobs must run in the BACKGROUND.
#
# THE SYMPTOM (user-reported 2026-07-16, recurring): "background jobs are being
# run in the foreground and that freezes the session completely — even if the
# session is doing nothing." The live-fire case that motivated this file: a full
# bats suite run issued in the FOREGROUND with timeout=600000 — the session froze
# until the user manually backgrounded it (Ctrl+B). poll_loop_guard.sh does NOT
# cover this: it matches `until … sleep … done` poll-loops, and a plain long
# command (test suite, build, sweep) is not a poll-loop.
#
# THE SIGNATURE is declared by the model itself: a foreground Bash call carrying
# an explicit `timeout` >= CCLAUDE_FGJOB_MAX_MS (default 180000 = 3 min) is the
# model saying "I expect this to run for minutes" while choosing the mode that
# freezes the session for exactly that long. Calls WITHOUT a raised timeout are
# left alone — the harness's 120s default caps that freeze on its own.
#
# WHY ENFORCE IS THE DEFAULT — the deliberate contrast with poll_loop_guard
# (observe) and the twin of subagent_foreground_guard (enforce):
#   * poll_loop_guard must STRING-MATCH a command shape, so its FP rate was
#     unknown and it ships observe until the log calibrates it. THIS guard keys
#     on a NUMERIC FIELD the model set on purpose — like the boolean that lets
#     subagent_foreground_guard enforce on day one, there is nothing fuzzy to
#     miscalibrate.
#   * The remedy is lossless and immediate: the SAME command with
#     run_in_background:true delivers one completion notification. Nothing about
#     the work changes; only the session stops being hostage to it.
#   * The one legitimate exception (the user explicitly asked to sit and wait,
#     watch-job's "single blocking wait") is exactly what the escape hatch is
#     for — and background+notify is the preferred option even there.
#
# SCOPE: MAIN THREAD ONLY. A subagent's turn ends when it stops calling tools,
# so a subagent must run long work in the foreground with a raised timeout —
# subagent_foreground_guard.sh enforces that side. This guard fires only when
# agent_id is absent. The two are complementary, not overlapping.
#
# MODES: CCLAUDE_FGJOB_MODE = enforce (default) | observe | off.
# THRESHOLD: CCLAUDE_FGJOB_MAX_MS (default 180000).
# FAIL-OPEN ALWAYS: any parse error or missing field allows the call.

payload="$(cat 2>/dev/null || true)"

python3 - "$payload" <<'PY'
import json
import os
import sys
import time

MODE = os.environ.get("CCLAUDE_FGJOB_MODE", "enforce")
try:
    THRESHOLD_MS = int(os.environ.get("CCLAUDE_FGJOB_MAX_MS", "180000"))
except ValueError:
    THRESHOLD_MS = 180000


def allow():
    sys.exit(0)


if MODE == "off":
    allow()

try:
    p = json.loads(sys.argv[1])
except Exception:
    allow()

# Subagents MUST run long work in the foreground (their turn ends when tool
# calls stop; subagent_foreground_guard.sh bans them backgrounding). Only the
# main thread has a session to freeze.
if p.get("agent_id"):
    allow()

tool_input = p.get("tool_input") or {}
if tool_input.get("run_in_background") is True:
    allow()

timeout = tool_input.get("timeout")
try:
    declared_long = timeout is not None and int(timeout) >= THRESHOLD_MS
except (TypeError, ValueError):
    declared_long = False
if not declared_long:
    allow()

cmd = tool_input.get("command") or ""
snippet = cmd[:200].replace("\n", " ")
config = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
log = os.path.join(config, "foreground_long_job_guard.log")


def note(tag):
    try:
        stamp = time.strftime("%Y-%m-%dT%H:%M:%S")
        line = "%s %s timeout=%s: %s" % (stamp, tag, timeout, snippet)
        prev = open(log).read().splitlines()[-499:] if os.path.exists(log) else []
        open(log, "w").write("\n".join(prev + [line]) + "\n")
    except OSError:
        pass


if MODE != "enforce":
    note("OBSERVE")
    allow()

note("BLOCK")
minutes = int(timeout) / 60000.0
print(
    "Blocked: this Bash call declares timeout=%sms (~%.0f min) and runs in the "
    "FOREGROUND on the main thread — the session would freeze for up to that "
    "long, doing nothing.\n"
    "DO INSTEAD: re-issue the SAME command with run_in_background: true. You get "
    "ONE completion notification when it finishes and keep working meanwhile; "
    "the raised timeout is unnecessary in the background.\n"
    "(Escape hatch, only if the user explicitly asked for a blocking foreground "
    "wait: CCLAUDE_FGJOB_MODE=off for this call.)" % (timeout, minutes),
    file=sys.stderr,
)
sys.exit(2)
PY
