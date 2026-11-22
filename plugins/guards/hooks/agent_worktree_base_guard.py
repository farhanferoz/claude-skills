#!/usr/bin/env python3
"""PreToolUse(Agent): refuse worktree isolation that would start from a stale base.

WHY
---
The Agent tool's ``isolation: "worktree"`` creates the worker's worktree from the
repository's default branch, not from the branch the session works on. Measured
2026-11-21 (a research project): a worker's worktree started at ``origin/main``
(ff2d78a4), 110 commits behind ``rank-ladder-mixture``. Its tests passed against
19 Nov code, the change conflicted when moved onto the real branch, and only a
rerun on the real base made its result trustworthy. Owner: "That is really bad
practice. It could end up in a disaster."

WHAT THIS DOES
--------------
For an Agent call with ``isolation: "worktree"`` inside a git repository, it
checks every default-branch candidate the worktree could start from
(``origin/HEAD``'s target, ``origin/main``, ``origin/master``, ``main``,
``master``, whichever exist). If any of them lacks commits of the current HEAD,
the call is refused with the command that makes a worktree from the current
branch. Every decision, allows included, is appended to
``agent_worktree_base_guard.log`` in the Claude config directory (last 500 lines).
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path

#: Branches the harness may start a worktree from, in the order git resolves a
#: default; ``origin/HEAD`` is read first when it is set.
_CANDIDATES = ("origin/main", "origin/master", "main", "master")
_LOG_NAME = "agent_worktree_base_guard.log"
_LOG_KEEP = 500
#: Exit status that makes Claude Code refuse the tool call and show stderr.
_BLOCK = 2


def _git(top: str, *args: str) -> str | None:
    """Output of ``git -C top args``, or None when git fails."""
    done = subprocess.run(
        ["git", "-C", top, *args], capture_output=True, text=True, check=False
    )
    return done.stdout.strip() if done.returncode == 0 else None


def _log(line: str) -> None:
    """Append one decision line, keeping the last ``_LOG_KEEP``."""
    root = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
    path = Path(root) / _LOG_NAME
    try:
        prev = path.read_text().splitlines()[-(_LOG_KEEP - 1) :] if path.exists() else []
        stamp = time.strftime("%Y-%m-%dT%H:%M:%S")
        path.write_text("\n".join([*prev, f"{stamp} {line}"]) + "\n")
    except OSError:
        pass


def _bases(top: str) -> list[str]:
    """The default-branch candidates that exist in this repository."""
    found: list[str] = []
    head_ref = _git(top, "symbolic-ref", "--short", "refs/remotes/origin/HEAD")
    for ref in ([head_ref] if head_ref else []) + list(_CANDIDATES):
        if ref not in found and _git(top, "rev-parse", "--verify", "--quiet", ref):
            found.append(ref)
    return found


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        _log("PASS unreadable payload")
        return 0
    tool_input = payload.get("tool_input") or {}
    name = str(tool_input.get("name") or tool_input.get("description") or "")[:60]
    if tool_input.get("isolation") != "worktree":
        _log(f"PASS no worktree isolation: {name}")
        return 0
    cwd = str(payload.get("cwd") or os.getcwd())
    top = _git(cwd, "rev-parse", "--show-toplevel")
    if not top:
        _log(f"PASS not a git repository ({cwd}): {name}")
        return 0
    branch = _git(top, "rev-parse", "--abbrev-ref", "HEAD") or "HEAD"
    behind = []
    for base in _bases(top):
        count = _git(top, "rev-list", "--count", f"{base}..HEAD")
        if count and int(count) > 0:
            behind.append((base, int(count)))
    if not behind:
        _log(f"PASS {top} {branch}: every default branch holds HEAD: {name}")
        return 0
    worst_base, worst = max(behind, key=lambda item: item[1])
    _log(f"BLOCK {top} {branch}: {worst_base} lacks {worst} commits: {name}")
    repo = Path(top).name
    sys.stderr.write(
        f"Blocked: worktree isolation starts the worker from {worst_base}, which lacks "
        f"{worst} commit(s) of {branch}.\n"
        "Measured 2026-11-21: a worker built on origin/main 110 commits behind its branch; "
        "its tests passed on stale code and the change conflicted on the real branch.\n"
        "DO INSTEAD: make the worktree from the current branch and give the worker its path:\n"
        f"  git -C {top} worktree add -b <task-branch> {Path(top).parent}/{repo}-<task> {branch}\n"
        "then dispatch WITHOUT isolation, with a first step in the brief:\n"
        f"  git merge-base --is-ancestor $(git -C {top} rev-parse HEAD) HEAD || stop and report\n"
        "If this block is wrong for this repository, say so and ask.\n"
    )
    return _BLOCK


if __name__ == "__main__":
    sys.exit(main())
