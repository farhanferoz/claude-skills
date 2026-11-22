#!/usr/bin/env bash
# timeout-killswitch guard (PreToolUse, Bash) — `timeout N` does not kill.
#
# SCOPE, and the boundary with its neighbour: this guard is ONLY about a cap that
# fails to terminate. The separate question of running too BROAD a test suite
# belongs to `test_scope_guard.sh`, which decides it by measuring which files
# changed and which test files mention them -- strictly better than the command-
# shape match this file used to carry, so that rule was removed rather than
# duplicated. Two guards, one symptom each, no overlap.
#
# THE SYMPTOM (user-reported 2026-08-11, verbatim): "I think we have some test
# suites running over an hour. Computer is very sluggish. This is unacceptable."
#
# MEASURED, same session: FOUR orphaned `pytest` process groups, from a PREVIOUS
# session, each alive 1h17m-1h21m. 1-minute load average 61 on an idle 30 GB box
# (peak 72). RESUME.rollout.md meanwhile asserted "No jobs, no monitors, no agents
# running" -- the session that started them recorded them as absent.
#
# ROOT CAUSE, and it is NOT what it looks like. Every one was launched under
# `timeout 900`. The cap DID fire: `timeout` sent SIGTERM at 900s. The child
# IGNORED it -- stuck in a native call (torch/oneAPI) where SIGTERM is not
# delivered until it returns. GNU `timeout` without `-k` then waits FOREVER for a
# child that will never die, and both processes sit there. Confirmed by hand:
# SIGTERM was ignored a second time; only SIGKILL ended them.
#
# So `timeout N <cmd>` is NOT a kill switch for anything that can block in native
# code -- which is every torch test in these repos. `timeout -k <grace> N <cmd>`
# IS one: SIGTERM, then SIGKILL after the grace period, unconditionally.
#
# ---------------------------------------------------------------------------
# REWRITE, don't refuse (owner decision 2026-10-05). The remedy is mechanical, and
# 95 % of ~1,600 refusals were followed by the same call with `-k` added -- one
# wasted round trip each. So a bare `timeout` in COMMAND POSITION is rewritten to
# `timeout -k 5 ...` through PreToolUse `updatedInput`, and the call runs.
#   * `updatedInput` REPLACES the whole tool input (code.claude.com/docs/en/hooks),
#     so every other field is carried over untouched.
#   * NO permissionDecision is returned. Measured 2026-10-05 with headless probes:
#     without one, the rewritten command still runs, AND it still goes through the
#     normal permission check (a `touch` rewritten this way was refused in default
#     mode). Returning "allow" would have auto-approved every command that happens
#     to contain `timeout` -- a rewrite must not double as a permission grant.
#   * Claude is told what changed (additionalContext), so the edit is never silent.
# STILL REFUSED: a bare `timeout` INSIDE QUOTES. The guard cannot tell
# `ssh host 'cd x; timeout 900 pytest'` (a real command) from a grep pattern or a
# commit message (text), and silently editing text is worse than one refusal.
# EXCEPT when the word after timeout's options is no duration (a number or $var):
# `grep -E 'a|timeout [0-9]+'` is a regex, and real `timeout` would reject it too.
# Refused 2026-11-20 on exactly that grep; logged as `text`.
# `-k` is read from timeout's OWN options only. The old test matched `-k`
# anywhere before ; | & -- so `timeout 900 pytest -k slow` passed as "has -k".
#
# Logs every decision where a `timeout` command word appears -- rewrite, block,
# ok (already has -k), text (quoted, no duration), observe -- to $CLAUDE_CONFIG_DIR/timeout_kill_guard.log.
# Commands with no `timeout` at all are not logged (that is every Bash call).
# ESCAPE HATCH: prefix one call with CCLAUDE_TIMEOUTGUARD_MODE=observe (log only).

exec python3 -c "$(cat <<'PY'
import datetime, json, os, re, sys

GRACE = "5"
try:
    payload = json.load(sys.stdin)
    tool_input = payload.get("tool_input") or {}
    cmd = tool_input.get("command") or ""
except (ValueError, AttributeError):
    sys.exit(0)
if "timeout" not in cmd:
    sys.exit(0)

mode = os.environ.get("CCLAUDE_TIMEOUTGUARD_MODE", "block")
WORD = re.compile(r"timeout\s")
SEP = ";&|\n"
KILL_SHORT = re.compile(r"-[A-Za-z]*k")      # -k, -k5, -vk
TAKES_ARG = {"-k", "-s", "--kill-after", "--signal"}


# Fact about timeout's argv: the first word after its options is a DURATION -- a
# number (900, 30s, 1.5m) or a shell expansion ($T, "${T}"). A quoted `timeout`
# followed by anything else (`[0-9]+`, `\d+`, `.*`) is regex or prose, not a command.
DURATION = re.compile(r"""^\\?["']*(\d|\.\d|\$)""")


def timeout_args(rest):
    """(has -k/--kill-after among timeout's own options, the duration word or "")."""
    toks = rest.split()
    i = 0
    while i < len(toks) and toks[i].startswith("-"):
        t = toks[i]
        if t.startswith("--kill-after") or (not t.startswith("--") and KILL_SHORT.match(t)):
            return True, ""
        i += 2 if t in TAKES_ARG else 1
    return False, toks[i] if i < len(toks) else ""


def find_bare(cmd):
    """(insert_at, quoted) for each `timeout` command word lacking -k.

    Command position = start of a line, or after ; & | (the boundaries this guard
    has always used). Quote state is tracked so a quoted occurrence is refused,
    not edited."""
    hits, quote, at_cmd, i = [], None, True, 0
    while i < len(cmd):
        c = cmd[i]
        if quote != "'" and c == "\\":
            i += 2
            at_cmd = False
            continue
        if quote is None and c in "'\"":
            quote = c
        elif quote == c:
            quote = None
        elif c in SEP:
            at_cmd = True
        elif c in " \t":
            pass
        else:
            if at_cmd and WORD.match(cmd, i):
                j = i + len("timeout")
                while j < len(cmd) and cmd[j] in " \t":
                    j += 1
                end = j
                while end < len(cmd) and cmd[end] not in SEP:
                    end += 1
                has_k, duration = timeout_args(cmd[j:end])
                if has_k:
                    hits.append((None, quote is not None))
                elif quote is None or DURATION.match(duration):
                    hits.append((j, quote is not None))
                else:
                    hits.append((None, "text"))   # quoted, no duration: not a command
            at_cmd = False
        i += 1
    return hits


hits = find_bare(cmd)
if not hits:
    sys.exit(0)
bare = [h for h in hits if h[0] is not None]
quoted = [h for h in bare if h[1]]
if mode == "observe":
    decision = "observe"
elif not bare:
    decision = "text" if any(h[1] == "text" for h in hits) else "ok"
elif quoted:
    decision = "block"
else:
    decision = "rewrite"

log = os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude"),
                   "timeout_kill_guard.log")
try:
    with open(log, "a") as f:
        f.write("%s %s rule=1 n=%d cmd=%.160s\n" % (
            datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
            decision, len(bare), cmd.replace("\n", "\\n")))
except OSError:
    pass

if decision == "block":
    sys.stderr.write("""TIMEOUT-KILLSWITCH GUARD — BLOCKED. A `timeout` inside quotes has no `-k`, so it is not a kill switch.

MEASURED on this machine (2026-08-11): four pytest groups launched under
`timeout 900` were still alive 80 MINUTES later. The cap fired -- SIGTERM was
sent at 900s and the child IGNORED it, because it was blocked in a native
torch/oneAPI call. GNU timeout then waits forever for a child that never dies.

A bare `timeout` outside quotes is fixed for you automatically. This one is
inside quotes, so it may be text rather than a command and is not edited.
FIX if it runs as a command (ssh, bash -c): write it as
    timeout -k 5 900 <cmd>
SIGTERM first, then SIGKILL 5s later, unconditionally.

(Only text, not a command? Say so and ask -- do not route around this (D15).)
""")
    sys.exit(2)
if decision != "rewrite":
    sys.exit(0)

new = cmd
for at, _ in sorted(bare, reverse=True):
    new = new[:at] + "-k %s " % GRACE + new[at:]
updated = dict(tool_input, command=new)
print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "updatedInput": updated,
    "additionalContext": (
        "timeout_kill_guard added `-k %s` to %d `timeout` call(s) so the cap also "
        "SIGKILLs a child that ignores SIGTERM. The command that ran: %s"
        % (GRACE, len(bare), new[:400])),
}}))
PY
)"
