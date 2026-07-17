#!/usr/bin/env bash
# PreCompact + SessionEnd — never lose the NAME of a running agent at a context
# boundary.
#
# THE INCIDENT (2026-07-15): a session was /clear'ed with 8 teammates running.
# The clear wiped the orchestrator's memory of them; it did NOT stop them. The
# next session inherited 8 live workers it had never dispatched, could not
# enumerate (there is no tool to list in-process teammates), and could only
# identify by reading a task tracker's owner column backwards. ~2.07M tokens.
# You can only stop an agent you can NAME, so a name you have lost is an agent
# you cannot kill.
#
# WHAT THIS HOOK CAN AND CANNOT DO — verified against the hooks reference, not
# assumed. The first design for this guard ("a SessionEnd hook that blocks the
# clear and names the agents") is IMPOSSIBLE, and that was caught only by
# reading the docs instead of reasoning:
#
#   PreCompact   CAN block  (exit 2, or {"decision":"block"})
#   SessionEnd   CANNOT block — "exit code and stderr are ignored"
#   SessionStart CANNOT block, but re-injects RESUME.md (resume_autoload.sh)
#
# So the strategy splits by what each event can actually do:
#
#   PreCompact(manual) -> BLOCK, naming the live agents. A boundary the user
#                         drove; they can stop the agents and re-run /compact.
#   PreCompact(auto)   -> RECORD only, never block. Blocking an auto-compact
#                         cannot help: the context still has to shrink, so a
#                         block just walks the session into the hard limit.
#   SessionEnd(*)      -> RECORD only (it cannot block). This is the /clear
#                         path, i.e. THE incident, and recording is the whole
#                         fix: the names land in RESUME.md, and SessionStart's
#                         resume_autoload.sh reads RESUME.md back into the very
#                         next session. The clear can still orphan them -- but
#                         it can no longer make them ANONYMOUS, which is what
#                         made the incident unrecoverable.
#
# FAIL-OPEN / FAIL-QUIET BY DESIGN. Any parse error, missing path, or ambiguity
# allows the boundary. A false block is worse than a missed one: this guard must
# never wedge a session that is trying to compact. It blocks only on CONFIDENT
# liveness (see below), and only on a manual compact.
#
# LIVENESS PREDICATE (design reused from ccage's live-verified circuit breaker,
# lib/subagent_watch.py::idle_completed -- NOT re-invented):
#   An agent is COMPLETE when it emitted an idle_notification in the PARENT
#   transcript AND has not written to its own transcript since. Renewed writes
#   after idle mean it resumed. Both signals required; either missing => treat
#   as not-complete (fail-safe: keep watching).
#   For BLOCKING we additionally require the transcript to be FRESH
#   (< _FRESH_MIN minutes), because a finished-but-unsignalled agent goes quiet
#   quickly, and blocking on a stale corpse would wedge the session for nothing.
#   RECORDING uses the looser rule -- a spurious RESUME line costs nothing.

payload="$(cat 2>/dev/null || true)"

python3 - "$payload" <<'PY'
import fcntl
import json
import os
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

# Block only on an agent whose transcript moved within this many minutes. A
# genuinely running agent writes far more often than this.
_FRESH_MIN = 10.0
_HEADING = "### Unstopped agents at last context boundary"
_ID_DISALLOWED = re.compile(r"[^A-Za-z0-9._-]")
# A description is prose, so it must keep spaces -- but it is model-written text
# landing in RESUME.md, so control bytes and newlines (which could forge a
# RESUME bullet) still have to go. Two sinks, two rules.
_DESC_DISALLOWED = re.compile(r"[\x00-\x1f\x7f]")
# The parent transcript's in-band completion signal. Quotes are JSON-escaped on
# disk, hence the \\? -- same shape ccage's scanner matches.
_IDLE = re.compile(
    r'idle_notification\\?"\s*,\s*\\?"from\\?"\s*:\s*\\?"([^"\\]+)\\?"'
    r'\s*,\s*\\?"timestamp\\?"\s*:\s*\\?"([^"\\]+)\\?"')


def allow():
    sys.exit(0)


try:
    payload = json.loads(sys.argv[1])
except Exception:
    allow()  # unparseable payload: never block a boundary on bad input

event = payload.get("hook_event_name") or ""
trigger = payload.get("trigger") or ""
reason = payload.get("reason") or ""
cwd = payload.get("cwd") or ""
transcript_path = payload.get("transcript_path") or ""

if not transcript_path:
    allow()

# The subagents dir is derived from the parent transcript's own path rather than
# recomputed from cwd: transcript is <projects>/<slug>/<session>.jsonl and the
# agents live at <projects>/<slug>/<session>/subagents/. Deriving it avoids
# reimplementing Claude Code's project-slug rule (every non-alphanumeric char ->
# '-'), which is a real source of bugs.
parent = Path(transcript_path)
sub_dir = parent.with_suffix("") / "subagents"


def breadcrumb(note: str) -> None:
    """Record every firing, even the silent ones.

    This exists because of a specific, expensive failure: teammate_idle_guard.sh
    carried a header claiming its event "was NOT observed to fire for Agent-tool
    subagents". That was FALSE on the current build, and the error survived for
    weeks precisely because NOTHING recorded whether the hook ran. A guard whose
    firing cannot be observed is a guard nobody can debug or falsify -- so this
    one leaves a trail whether or not it acts. Capped, best-effort, never raises.
    """
    try:
        log = Path(os.environ.get("CLAUDE_CONFIG_DIR")
                   or os.path.expanduser("~/.claude")) / "agent_reaper.log"
        stamp = datetime.now(timezone.utc).isoformat()
        line = "%s %s trigger=%s reason=%s %s\n" % (
            stamp, event or "?", trigger or "-", reason or "-", note)
        prev = log.read_text().splitlines()[-199:] if log.exists() else []
        log.write_text("\n".join(prev + [line.rstrip()]) + "\n")
    except OSError:
        pass


if not sub_dir.is_dir():
    breadcrumb("no subagents dir — allow")
    allow()  # no subagents ever spawned in this session


def sanitize(raw: str, limit: int = 80) -> str:
    """Agent ids flow into RESUME.md, which is auto-injected into the next
    session's context. They originate in model-writable meta files, so strip
    anything that could forge a RESUME line or carry control bytes."""
    return _ID_DISALLOWED.sub("", raw)[:limit]


def agent_identity(t: Path):
    """(id, description) from the sibling .meta.json; fall back to the stem.
    The transcript FILENAME encodes a different string than the real teammate
    id, so the meta is authoritative -- but the stem is what `TaskStop` accepts,
    so both are reported."""
    name, desc = "", ""
    try:
        m = json.loads(t.with_suffix(".meta.json").read_text())
        name = m.get("name") or ""
        desc = m.get("description") or ""
    except (OSError, ValueError):
        pass
    desc = _DESC_DISALLOWED.sub(" ", desc).strip()[:60]
    return sanitize(name or t.stem), desc, t.stem


# Completion signals from the parent transcript: teammate_id -> latest idle epoch.
idle = {}
try:
    with parent.open("rb") as f:
        for line in f:
            text = line.decode("utf-8", errors="replace")
            for m in _IDLE.finditer(text):
                try:
                    ts = m.group(2).replace("Z", "+00:00")
                    dt = datetime.fromisoformat(ts)
                    if dt.tzinfo is None:
                        dt = dt.replace(tzinfo=timezone.utc)
                    epoch = dt.timestamp()
                except (ValueError, TypeError, OverflowError):
                    continue
                if epoch > idle.get(m.group(1), 0.0):
                    idle[m.group(1)] = epoch
except OSError:
    pass  # unreadable parent: fall through, every agent counts as not-complete

now = time.time()
live = []
for t in sorted(sub_dir.glob("agent-*.jsonl")):
    try:
        mtime = t.stat().st_mtime
    except OSError:
        continue
    aid, desc, stem = agent_identity(t)
    idle_epoch = idle.get(aid)
    # Complete == emitted idle AND silent since. Anything else is not complete.
    completed = idle_epoch is not None and mtime <= idle_epoch
    if completed:
        continue
    stale_min = (now - mtime) / 60.0
    live.append({"id": aid, "stem": stem, "desc": desc, "stale_min": stale_min})

if not live:
    breadcrumb("%d agent(s), all complete — allow" % len(list(sub_dir.glob("agent-*.jsonl"))))
    allow()


def record(lines):
    """Append the names to RESUME.md so they survive the boundary. RESUME.md is
    read back into the next session by resume_autoload.sh (SessionStart), which
    is the ONLY reason a /clear becomes recoverable. flock-guarded: /checkpoint
    and ccage's watcher also write this file. A skipped line beats a corrupt
    RESUME, so give up rather than write unsynchronized."""
    if not cwd:
        return
    path = Path(cwd) / "RESUME.md"
    if not path.exists():
        return  # never create RESUME.md in a repo that doesn't use one
    stamp = datetime.now(timezone.utc).isoformat()
    try:
        with path.open("a+") as f:
            for attempt in range(3):
                try:
                    fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except OSError:
                    if attempt == 2:
                        return
                    time.sleep(0.2)
            try:
                f.seek(0)
                if _HEADING not in f.read():
                    f.seek(0, os.SEEK_END)
                    f.write("\n%s\n" % _HEADING)
                    # The next session acts on these lines blind, so the rule of
                    # engagement travels WITH the data: measured 2026-07-16,
                    # sessions were sweep-stopping every recorded id long after
                    # death — a burst of 'No task found' errors per boundary.
                    f.write(
                        "Entries below are SNAPSHOTS from a past boundary, not "
                        "liveness claims. Before stopping one, check its "
                        "subagents/agent-<id>.jsonl mtime; if TaskStop replies "
                        "'No task found', the agent is ALREADY dead — that is "
                        "SUCCESS, not an error to retry. Delete handled lines.\n")
                f.seek(0, os.SEEK_END)
                for ln in lines:
                    f.write("- %s %s\n" % (stamp, ln))
            finally:
                fcntl.flock(f, fcntl.LOCK_UN)
    except OSError:
        pass


why = "%s%s" % (event, "/%s" % (trigger or reason) if (trigger or reason) else "")
names = ", ".join(a["id"] for a in live)
record(["%s: agent '%s'%s was NOT stopped (quiet %.0fmin). If still live (mtime!), stop by bare id: TaskStop %s"
        % (why, a["id"], " — %s" % a["desc"] if a["desc"] else "", a["stale_min"], a["stem"])
        for a in live])

# Only a MANUAL compact can be blocked usefully (see header). Everything else
# has already been recorded above, which is the whole fix for the /clear path.
fresh = [a for a in live if a["stale_min"] < _FRESH_MIN]
breadcrumb("live=%s fresh=%d -> %s" % (
    names, len(fresh),
    "BLOCK" if (event == "PreCompact" and trigger == "manual" and fresh) else "record-only"))
if event == "PreCompact" and trigger == "manual" and fresh:
    sys.stderr.write(
        "%d agent(s) are still running and would be orphaned by this compact: %s.\n"
        "Compaction wipes your memory of them but does NOT stop them, and you can only "
        "stop an agent you can name.\n"
        "Stop each one now (TaskStop <id>: %s), or salvage its work first — then re-run "
        "/compact. Their names have been recorded in RESUME.md either way.\n"
        % (len(fresh), ", ".join(a["id"] for a in fresh),
           ", ".join(a["stem"] for a in fresh)))
    sys.exit(2)

allow()
PY
exit $?
