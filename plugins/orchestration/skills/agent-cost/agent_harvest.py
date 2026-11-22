#!/usr/bin/env python3
"""Harvest a subagent's final answer from its on-disk transcript.

WHY THIS EXISTS
---------------
A subagent's result reaches the orchestrator as a tool result / teammate
message. That delivery is lossy: measured 2026-08-22, two of nine graders in
one session went `idle` having produced a complete answer that never arrived
(`grader-2` generated 2168 output tokens and the orchestrator saw none of it).
The reflex in that situation is to re-dispatch, which pays the full cost a
second time for work that is already finished and already on disk.

Every subagent's full transcript is written to
`<session>/subagents/agent-<id>.jsonl` as it runs. The final assistant text
block IS the answer. So "the agent returned nothing" is never a reason to
re-dispatch and never a reason to treat the work as lost -- read it from disk.

Usage
-----
    agent_harvest.py                     # every agent in the newest session
    agent_harvest.py grader-2            # one agent by name (substring ok)
    agent_harvest.py grader-2 r2-c       # several
    agent_harvest.py --list              # names + whether an answer is present
    agent_harvest.py --session DIR ...   # a specific session or subagents dir

Prints the LAST assistant text block per agent, which is the agent's return
value. `--all-text` prints every assistant text block instead, for an agent
whose answer was split across turns.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path


def _resolve_subagents_dir(explicit: str | None) -> Path:
    """The `subagents/` dir to read, mirroring agent_cost.py's resolution."""
    if explicit:
        p = Path(explicit).expanduser()
        if p.name == "subagents":
            return p
        if (p / "subagents").is_dir():
            return p / "subagents"
        raise SystemExit(f"no subagents/ under {p}")

    cfg = Path(os.environ.get("CLAUDE_CONFIG_DIR", Path.home() / ".claude"))
    slug = str(Path.cwd()).replace("/", "-")
    proj = cfg / "projects" / slug
    if not proj.is_dir():
        # the cwd slug does not always resolve; fall back to the newest project
        cands = [d for d in (cfg / "projects").glob("*") if (d).is_dir()]
        if not cands:
            raise SystemExit(f"no projects under {cfg / 'projects'}")
        proj = max(cands, key=lambda d: d.stat().st_mtime)

    sessions = [d / "subagents" for d in proj.glob("*") if (d / "subagents").is_dir()]
    if not sessions:
        raise SystemExit(f"no session with subagents/ under {proj}")
    return max(sessions, key=lambda d: d.stat().st_mtime)


def _name_for(jsonl: Path) -> str:
    meta = jsonl.with_suffix("").with_suffix(".meta.json")
    if not meta.is_file():
        meta = Path(str(jsonl)[: -len(".jsonl")] + ".meta.json")
    if meta.is_file():
        try:
            d = json.loads(meta.read_text())
            return d.get("name") or d.get("agentType") or jsonl.stem
        except (json.JSONDecodeError, OSError):
            pass
    return jsonl.stem


def _assistant_texts(jsonl: Path) -> list[str]:
    """Every assistant text block in order. Tool-use blocks are skipped."""
    out: list[str] = []
    try:
        lines = jsonl.read_text(errors="ignore").splitlines()
    except OSError:
        return out
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        msg = row.get("message") or {}
        if msg.get("role") != "assistant":
            continue
        content = msg.get("content")
        if isinstance(content, str):
            if content.strip():
                out.append(content)
        elif isinstance(content, list):
            for block in content:
                if isinstance(block, dict) and block.get("type") == "text":
                    text = block.get("text") or ""
                    if text.strip():
                        out.append(text)
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("names", nargs="*", help="agent name substrings; default all")
    ap.add_argument("--session", help="session dir, or a subagents/ dir")
    ap.add_argument("--list", action="store_true", help="just list agents and whether an answer is present")
    ap.add_argument("--all-text", action="store_true", help="print every assistant text block, not only the last")
    args = ap.parse_args()

    sub = _resolve_subagents_dir(args.session)
    files = sorted(sub.glob("agent-*.jsonl"))
    if not files:
        print(f"no agent transcripts under {sub}", file=sys.stderr)
        return 1

    picked = []
    for f in files:
        name = _name_for(f)
        if args.names and not any(n.lower() in name.lower() or n.lower() in f.stem.lower() for n in args.names):
            continue
        picked.append((name, f))

    if not picked:
        print(f"no agent matched {args.names} in {sub}", file=sys.stderr)
        return 1

    if args.list:
        print(f"({sub})")
        for name, f in picked:
            texts = _assistant_texts(f)
            last = texts[-1] if texts else ""
            print(f"  {name:<16} blocks={len(texts):<3} final={len(last):>6} chars  {'ANSWER PRESENT' if last.strip() else 'EMPTY'}")
        return 0

    for name, f in picked:
        texts = _assistant_texts(f)
        print(f"\n{'=' * 70}\n=== {name}  ({f.name})\n{'=' * 70}")
        if not texts:
            print("(no assistant text in transcript -- the agent produced nothing)")
            continue
        for t in (texts if args.all_text else texts[-1:]):
            print(t)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
