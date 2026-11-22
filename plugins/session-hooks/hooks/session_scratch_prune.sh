#!/usr/bin/env bash
# SessionStart — prune THIS project's old session scratch folders.
#
# WHY (2026-10-23, a product project): Claude Code keeps each session's scratch under
# /tmp/claude-<uid>/<project-slug>/<session-id>/ (scratchpad/, tasks/) and never
# removes it. 23 earlier sessions had left 3.3 GB in five days; the owner had to
# ask for the cleanup ("I don't want any clutter, mess") and agreed to this hook.
# CLAUDE.md "Leave no litter" binds the session; this is its backstop for scratch.
#
# A session folder is deleted only when ALL hold (anything else keeps it):
#   1. its name is a session id (a UUID) and it is not the current session;
#   2. nothing in it (files or folders, symlinks not followed) changed within
#      MAX_AGE_DAYS (2);
#   3. no queued or running slurm job of this user names it (scontrol's job line,
#      and the batch script its Command= points at);
#   4. no running process names it in its command line, and none has its cwd or
#      an open file inside it (/proc, where there is one);
#   5. the project's RESUME.md does not name it.
# FAIL-SAFE: if a check cannot run (squeue present but failing, ps failing), the
# hook deletes NOTHING and logs why. It never follows a symlink and never deletes
# outside the project's scratch root. Always exits 0 (SessionStart cannot block).
#
# OBSERVABLE: every decision (kept + reason, deleted + MB) is appended to
# $CLAUDE_CONFIG_DIR/session_scratch_prune.log (default ~/.claude), one tab-separated line.
#
# Knobs, for a human (documented here only): CCLAUDE_SCRATCH_PRUNE = enforce
# (default) | observe (log "would-delete", delete nothing) | off;
# CCLAUDE_SCRATCH_PRUNE_DAYS (default 2); CCLAUDE_SCRATCH_ROOT (default
# /tmp/claude-<uid>; the self-test points it at a temporary folder).
# Self-test: bash ~/.claude/hooks/session_scratch_prune.selftest.sh

payload="$(cat 2>/dev/null || true)"

python3 - "$payload" <<'PY'
import fcntl
import json
import os
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone

MODE = os.environ.get("CCLAUDE_SCRATCH_PRUNE", "enforce")
if MODE == "off":
    sys.exit(0)
DAYS = float(os.environ.get("CCLAUDE_SCRATCH_PRUNE_DAYS", "2"))
ROOT = os.environ.get("CCLAUDE_SCRATCH_ROOT") or f"/tmp/claude-{os.getuid()}"
UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
CFG = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
LOG = os.path.join(CFG, "session_scratch_prune.log")

try:
    payload = json.loads(sys.argv[1]) if sys.argv[1].strip() else {}
except Exception:
    payload = {}
session = str(payload.get("session_id") or "")
project = os.environ.get("CLAUDE_PROJECT_DIR") or payload.get("cwd") or os.getcwd()


def log(sid: str, decision: str, reason: str, mb: float | None = None) -> None:
    try:
        os.makedirs(CFG, exist_ok=True)
        with open(LOG, "a") as fh:
            stamp = datetime.now(timezone.utc).isoformat(timespec="seconds")
            fh.write(f"{stamp}\t{MODE}\t{project}\t{sid}\t{decision}\t{reason}\t{'' if mb is None else f'{mb:.1f} MB'}\n")
    except OSError:
        pass


def project_root() -> str | None:
    """The scratch folder of this project: the parent of the current session's folder, else <root>/<project path with / as ->."""
    if session and os.path.isdir(ROOT):
        for name in os.listdir(ROOT):
            if os.path.isdir(os.path.join(ROOT, name, session)):
                return os.path.join(ROOT, name)
    guess = os.path.join(ROOT, project.replace("/", "-"))
    return guess if os.path.isdir(guess) else None


def changed_since(path: str, cutoff: float) -> bool:
    for top, dirs, files in os.walk(path, followlinks=False):
        for name in [top, *(os.path.join(top, f) for f in files), *(os.path.join(top, d) for d in dirs)]:
            try:
                if os.lstat(name).st_mtime >= cutoff:
                    return True
            except OSError:
                continue
    return False


def size_mb(path: str) -> float:
    total = 0
    for top, _dirs, files in os.walk(path, followlinks=False):
        for f in files:
            try:
                total += os.lstat(os.path.join(top, f)).st_size
            except OSError:
                pass
    return total / 2**20


class CheckFailed(Exception):
    pass


def _fds(pid: str) -> list[str]:
    try:
        return os.listdir(f"/proc/{pid}/fd")
    except OSError:
        return []


def references() -> str:
    """Every text that may name a scratch folder: slurm jobs and their scripts, process command lines, process cwds and open
    files, the project's RESUME.md. Raises CheckFailed when a check that should run cannot."""
    blob: list[str] = []
    if shutil.which("squeue"):
        user = os.environ.get("USER") or str(os.getuid())
        q = subprocess.run(["squeue", "-h", "-u", user, "-o", "%i"], capture_output=True, text=True, timeout=20)
        if q.returncode != 0:
            raise CheckFailed(f"squeue exited {q.returncode}: {q.stderr.strip()[:200]}")
        for jid in q.stdout.split():
            s = subprocess.run(["scontrol", "show", "job", "-o", jid], capture_output=True, text=True, timeout=20)
            if s.returncode != 0:
                raise CheckFailed(f"scontrol show job {jid} exited {s.returncode}")
            blob.append(s.stdout)
            m = re.search(r"\bCommand=(\S+)", s.stdout)
            if m and os.path.isfile(m.group(1)):
                try:
                    with open(m.group(1), errors="replace") as fh:
                        blob.append(fh.read(1 << 20))
                except OSError:
                    pass
    p = subprocess.run(["ps", "-eww", "-o", "args="], capture_output=True, text=True, timeout=20)
    if p.returncode != 0:
        raise CheckFailed(f"ps exited {p.returncode}")
    blob.append(p.stdout)
    if os.path.isdir("/proc"):
        for pid in filter(str.isdigit, os.listdir("/proc")):
            for link in ["cwd", *(f"fd/{fd}" for fd in _fds(pid))]:
                try:
                    blob.append(os.readlink(f"/proc/{pid}/{link}"))
                except OSError:
                    continue
    resume = os.path.join(project, "RESUME.md")
    if os.path.isfile(resume):
        with open(resume, errors="replace") as fh:
            blob.append(fh.read())
    return "\n".join(blob)


def main() -> None:
    root = project_root()
    if root is None:
        log("-", "skip", f"no scratch folder for this project under {ROOT}")
        return
    try:
        lock = open(os.path.join(root, ".session_scratch_prune.lock"), "w")
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        log("-", "skip", "another prune of this project is running")
        return
    names = sorted(n for n in os.listdir(root) if UUID.match(n) and os.path.isdir(os.path.join(root, n))
                   and not os.path.islink(os.path.join(root, n)))
    try:
        refs = references()
    except (CheckFailed, OSError, subprocess.SubprocessError) as e:
        log("-", "keep-all", f"a check could not run, so nothing is deleted: {e}")
        return
    cutoff = time.time() - DAYS * 86400
    real_root = os.path.realpath(root) + os.sep
    deleted = kept = 0
    freed = 0.0
    for name in names:
        path = os.path.join(root, name)
        if name == session:
            reason = "current session"
        elif changed_since(path, cutoff):
            reason = f"changed within {DAYS:g} days"
        elif name in refs:
            reason = "named by a slurm job, a process or RESUME.md"
        elif not os.path.realpath(path).startswith(real_root):
            reason = "resolves outside the scratch root"
        else:
            reason = ""
        if reason:
            kept += 1
            log(name, "keep", reason)
            continue
        mb = size_mb(path)
        if MODE == "observe":
            log(name, "would-delete", f"older than {DAYS:g} days, unreferenced", mb)
            continue
        try:
            shutil.rmtree(path)
        except OSError as e:
            log(name, "error", f"rmtree failed: {e}", mb)
            continue
        deleted += 1
        freed += mb
        log(name, "deleted", f"older than {DAYS:g} days, unreferenced", mb)
    log("-", "summary", f"{deleted} deleted ({freed:.1f} MB), {kept} kept, root {root}")


try:
    main()
except Exception as e:  # never break a session start
    log("-", "error", f"{type(e).__name__}: {e}")
PY
exit 0
