#!/usr/bin/env bash
# TeammateIdle hook — the anti-idle enforcement for Agent Teams.
#
# Fires when a teammate is about to go idle. Exit 2 = "tasks remain, keep
# working" (blocks the idle); exit 0 = allow. Fail-open by design: any parse
# error, missing state, or ambiguity allows the idle — this guard must never
# trap an agent in a work loop on bad data.
#
# The Agent Teams hook payload is EXPERIMENTAL and version-unstable. Claude Code
# 2.1.206 sent {..., teammate_name, team_name}; 2.1.207 (live-fire 2026-07-13)
# DROPS both, and the task dir is keyed by a parent team-session id a child's env
# never exposes. So we no longer require team_name: fast-path on it when present,
# else fall back to the most-recently-modified team dir (the team that just
# acted, whose teammate is now idling) — a heuristic whose only failure mode is
# fail-open. Without teammate_name the "your own open tasks" check is skipped;
# the "unclaimed unblocked tasks remain" check still applies.
# NOTE: in 2.1.207 this event was NOT observed to fire for Agent-tool subagents;
# the fix keeps it correct for whatever context does fire it. Live tasks are
# tasks/<team>/<id>.json ({status, owner?, blockedBy}).
#
# ⚠️ Task files PERSIST after completion, carrying {"status": "completed"} —
# presence is NOT openness. This header claimed the opposite until 2026-07-16.
# The code below was already right (it filters on `status`), but the same false
# premise WAS live in task_completed_guard.sh, where it silently made any task
# with a blockedBy edge uncompletable forever. Openness is a STATUS, never a
# stat(). Left stated here so the next editor cannot reintroduce it from a
# comment.

payload="$(cat 2>/dev/null || true)"

python3 - "$payload" <<'PY'
import glob, json, os, sys

def _log(tag, detail=""):
    """Every decision, ALLOWs included (D14) — an allow here is invisible
    otherwise, so 'is this guard still wired?' had no answer."""
    try:
        import time
        cfg = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
        with open(os.path.join(cfg, "teammate_idle_guard.log"), "a") as fh:
            fh.write("%s %-12s %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%S"), tag,
                                        str(detail)[:120]))
    except Exception:
        pass


def allow(reason="ok"):
    _log("ALLOW", reason)
    sys.exit(0)

try:
    payload = json.loads(sys.argv[1])
except Exception:
    allow()

teammate = payload.get("teammate_name") or ""
team = payload.get("team_name") or ""
config_root = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")

# ---------------------------------------------------------------------------
# DELIVERY CHECK — a teammate that has not reported is not finished.
#
# Passing `name:` to the Agent tool moves the agent onto the teammate mailbox,
# where the harness delivers its final report to NOBODY: the report lands in the
# agent's own transcript and stops there. MEASURED 2026-08-16 with a two-arm
# probe (identical agents differing only in `name:`) — the anonymous arm's report
# arrived automatically in 2.2s; the named arm's never arrived at all. Across
# every transcript on this machine: 28 named spawns, 28 spawn receipts, ZERO
# agent-completion notifications. Known upstream (anthropics/claude-code#48160,
# #61248). This project names every agent, so it is permanently on that path.
#
# THIS RUNS BEFORE THE TASK-DIR RESOLUTION ON PURPOSE. The check below
# early-allows when no team task dir exists, and this project deliberately keeps
# NO team task files (the register's checkboxes are the tracker) — so a delivery
# check placed after it would be dead code in exactly the setup it was written
# for. Pinned by test_check_runs_even_with_no_team_task_dir.
REPORT_MODE = os.environ.get("CCLAUDE_IDLE_REPORT_MODE", "observe")


def _delivered_report(name):
    """True/False if knowable, None if not. None ALWAYS allows.

    Reads the TEAMMATE'S OWN transcript. The payload's `transcript_path` is the
    ROOT session's — measured 2026-08-16 — and the root sends messages
    constantly, so scanning that file credits every teammate with the root's work
    and the guard silently never fires. The subagents dir hangs off `session_id`
    (the CURRENT session), NOT `team_name` (the LAUNCH one): the same
    launch-vs-current split that made the stop guard read a directory which never
    existed for a whole 14-hour run.

    Structural, not substring: an agent that merely DISCUSSES SendMessage in
    prose — one working on this very guard, say — has not reported. Same
    speaking-is-not-working trap that `_worked_since` hit in ccage-auto."""
    if not name:
        return None                     # field is version-unstable; claim nothing
    tp = payload.get("transcript_path") or ""
    sid = payload.get("session_id") or ""
    if not tp or not sid:
        return None
    pattern = os.path.join(os.path.dirname(tp), sid, "subagents",
                           "agent-a%s-*.jsonl" % name)
    hits = glob.glob(pattern)
    if not hits:
        return None                     # cannot see it -> cannot judge it
    found = False
    for path in hits:
        try:
            with open(path, errors="replace") as fh:
                for line in fh:
                    if '"SendMessage"' not in line:      # cheap prefilter only
                        continue
                    try:
                        row = json.loads(line)
                    except ValueError:
                        continue
                    content = (row.get("message") or {}).get("content")
                    if not isinstance(content, list):
                        continue
                    for blk in content:
                        if not isinstance(blk, dict):
                            continue
                        if blk.get("type") != "tool_use":
                            continue
                        if blk.get("name") != "SendMessage":
                            continue
                        if (blk.get("input") or {}).get("to") == "main":
                            found = True
        except OSError:
            return None                 # unreadable -> fail open
    return found


if REPORT_MODE != "off":
    _sent = _delivered_report(teammate)
    if _sent is False:
        if REPORT_MODE == "enforce":
            # Name the ONE remedy and stop. This hook has already caused the
            # opposite failure once: it used to list free task ids and tell an
            # idle teammate to claim the next one, and an agent briefed
            # "READ-ONLY AUDIT" went and built a whole strategy (2026-07-15).
            # A worker's brief cannot survive a hook that orders it to go
            # shopping. So: no task lists, no suggestions, no second option.
            sys.stderr.write(
                "Do not go idle: you have not delivered your report. Your final "
                "message reaches nobody — a named agent's plain output stays in "
                "its own transcript and is never shown to the session that "
                "dispatched you. Call SendMessage now with to: \"main\" and the "
                "full report you were asked for, then go idle.\n")
            _log("DENY", "no report: %s" % teammate)
            sys.exit(2)
        _log("OBSERVE", "no report: %s" % teammate)

# Resolve the active team's task dir without depending on team_name (dropped in
# 2.1.207). A wrong guess only ever fails OPEN.
task_dir = None
if team:
    d = os.path.join(config_root, "tasks", team)
    if os.path.isdir(d):
        task_dir = d
if task_dir is None:
    dirs = [d for d in glob.glob(os.path.join(config_root, "tasks", "*")) if os.path.isdir(d)]
    if dirs:
        task_dir = max(dirs, key=os.path.getmtime)
if task_dir is None:
    allow()

try:
    files = [f for f in os.listdir(task_dir) if f.endswith(".json")]
except OSError:
    allow()

open_ids = set()
tasks = []
for f in files:
    try:
        t = json.load(open(os.path.join(task_dir, f)))
        open_ids.add(str(t.get("id")))
        tasks.append(t)
    except Exception:
        continue

# A teammate is nagged ONLY about work ALREADY ASSIGNED TO IT.
#
# It is NEVER told about unclaimed tasks. That was this guard's original
# behaviour and it was actively harmful: it named the free task ids and told the
# teammate to "Run TaskList, claim the next task", which turns every idle worker
# into a claim-anything worker regardless of its brief. Observed 2026-07-15: an
# agent briefed "READ-ONLY AUDIT, do not modify any file" claimed a whole new
# strategy build; a read-only auditor built a 204-line dossier; and a throwaway
# probe restricted to `tools: Read, Bash, Grep, Glob`, asked only to list its own
# tool names, used ToolSearch to reach TaskList and claimed a task within ~60s.
# A worker's brief cannot survive a hook that orders it to go shopping.
#
# NOTE (corrected 2026-07-15): the header's claim that this event "was NOT
# observed to fire for Agent-tool subagents" is FALSE on the current build --
# the probe above was an Agent-tool subagent and it DID receive this feedback.
# Assume it fires for every worker.
#
# Assigning unclaimed work is the ROOT's job, not a worker's. If the root idles
# with work outstanding, that is caught by the root's own orchestrator gate.
own_open = [t for t in tasks
            if teammate and t.get("owner") == teammate
            and t.get("status") in ("pending", "in_progress")]

if own_open:
    sys.stderr.write(
        "Do not go idle: %d task(s) assigned to YOU are still open (%s). "
        "Finish or explicitly hand back your OWN assigned work. "
        "Do NOT claim any other task: only work your dispatch contract names.\n"
        % (len(own_open), ", ".join("#%s" % t.get("id") for t in own_open)))
    _log("DENY", "%d own open" % len(own_open))
    sys.exit(2)

allow()
PY
exit $?
