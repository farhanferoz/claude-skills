#!/usr/bin/env bash
# TaskCompleted hook — completion-integrity check for the shared task list.
#
# Fires when a task is being marked completed, BEFORE the transition is
# finalized (the task's <id>.json is still on disk). Exit 2 blocks the
# completion and the task stays active; exit 0 allows it. Fail-open: any
# missing state or ambiguity allows the completion.
#
# The Agent Teams hook payload is EXPERIMENTAL and version-unstable. Claude Code
# 2.1.206 sent {..., task_id, task_subject, task_description, teammate_name,
# team_name}; 2.1.207 (live-fire confirmed 2026-07-13) DROPS team_name and
# teammate_name, sending only {..., session_id, transcript_path, cwd, prompt_id,
# task_id, task_subject, task_description}. The task dir is keyed by the PARENT
# team-session id (tasks/session-<parent8>/), which a child session's env never
# exposes — so team_name was the only payload link, and it is gone in 2.1.207.
# We therefore DO NOT depend on team_name: locate the task file by task_id across
# every team dir, disambiguating stale same-id files by task_subject (then newest
# mtime — the file being completed right now is the freshest-touched). When
# team_name IS present (older builds) it is honoured as a fast path.
#
# A task file is <task_id>.json and it PERSISTS after completion, carrying
# {"status": "completed"}. This header used to claim the opposite — that completed
# files are removed, so presence == open — and the check below was built on it.
# Measured 2026-07-16 across every cage on disk: every task dir holds a mix of
# completed/pending/in_progress files. The consequence was severe and silent: once
# a dependency COMPLETED, its file stayed put, so any task carrying a blockedBy
# edge could never be completed again — the guard refused forever, and the refusal
# looked like a legitimate dependency error. Openness is a STATUS, never a stat().
#
# Check enforced: a task whose blockedBy still references OPEN tasks cannot be
# marked complete — completing around an unmet dependency almost always means
# the dependency wave was skipped, not satisfied.

payload="$(cat 2>/dev/null || true)"

python3 - "$payload" <<'PY'
import glob, json, os, sys

def allow():
    sys.exit(0)

try:
    payload = json.loads(sys.argv[1])
except Exception:
    allow()

task_id = str(payload.get("task_id") or "")
task_subject = payload.get("task_subject") or ""
team = payload.get("team_name") or ""
if not task_id:
    allow()

config_root = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")

def _subject(p):
    try:
        return json.load(open(p)).get("subject") or ""
    except Exception:
        return None

# Resolve the task file WITHOUT relying on team_name (dropped in 2.1.207).
cands = []
if team:                                             # fast path: builds that still send it
    p = os.path.join(config_root, "tasks", team, task_id + ".json")
    if os.path.isfile(p):
        cands = [p]
if not cands:
    cands = glob.glob(os.path.join(config_root, "tasks", "*", task_id + ".json"))
if not cands:
    allow()
if task_subject:                                     # prefer a subject match over stale same-id files
    subj = [p for p in cands if _subject(p) == task_subject]
    if subj:
        cands = subj
path = max(cands, key=os.path.getmtime)              # freshest: the one being completed now
task_dir = os.path.dirname(path)
try:
    task = json.load(open(path))
except Exception:
    allow()

OPEN_STATUSES = frozenset(("pending", "in_progress"))


def _is_open(blocker_id):
    """True iff blocker_id names a task that is still open.

    Read the status; never infer it from the file existing. A missing or
    unreadable blocker is treated as closed, per this hook's fail-open contract.
    """
    p = os.path.join(task_dir, str(blocker_id) + ".json")
    try:
        with open(p) as f:
            return json.load(f).get("status") in OPEN_STATUSES
    except (OSError, ValueError):
        return False


open_blockers = [str(b) for b in (task.get("blockedBy") or []) if _is_open(b)]
if open_blockers:
    label = task_subject or ("#" + task_id)
    sys.stderr.write(
        "Completion blocked: task #%s ('%s') is still blockedBy open task(s) %s. "
        "Finish or explicitly unblock the dependencies first (TaskUpdate), or "
        "correct the dependency edge if it is stale — do not complete around it.\n"
        % (task_id, label, ", ".join("#" + b for b in open_blockers)))
    sys.exit(2)

allow()
PY
exit $?
