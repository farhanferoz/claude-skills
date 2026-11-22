#!/usr/bin/env python3
"""Structure ratchet: ruff's code-shape rules may only get better in a repo that opts in.

Run from a repo root. `.structure-baseline.json` there holds {"paths": [...], "counts": {file: {rule: n}}}.
  --check   run ruff (PLR0913 PLR0915 PLR0912 C901) on the baseline's paths; exit 1 and list each offender
            when a (file, rule) count is above the baseline or a new (file, rule) appears.
  --update  rewrite the baseline, only lowering counts (entries at 0 are dropped); never raises or adds.
No baseline file: exit 0 with a one-line note, so other repos are unaffected.
Pattern follows test_growth_check.py (count against a baseline, log every decision, subprocess git/ruff);
log: $CLAUDE_CONFIG_DIR (default ~/.claude)/structure_ratchet.log.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from collections import Counter
from datetime import datetime
from pathlib import Path

RULES = "PLR0913,PLR0915,PLR0912,C901"
BASELINE = ".structure-baseline.json"


def log(verdict: str, detail: str) -> None:
    path = Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude") / "structure_ratchet.log"
    with path.open("a", encoding="utf-8") as out:
        out.write(f"{datetime.now().isoformat(timespec='seconds')} {verdict} repo={Path.cwd()} {detail}\n")


def ruff_bin(root: Path) -> str | None:
    local = root / ".venv" / "bin" / "ruff"
    return str(local) if local.exists() else shutil.which("ruff")


def measure(root: Path, paths: list[str]) -> tuple[dict[str, Counter[str]], dict[tuple[str, str], list[str]]]:
    """Counts per file then rule, and the offender lines per (file, rule)."""
    exe = ruff_bin(root)
    if exe is None:
        raise RuntimeError("ruff not found (.venv/bin/ruff or PATH)")
    done = subprocess.run(
        [exe, "check", "--select", RULES, "--output-format", "json", "--no-cache", *paths],
        capture_output=True, text=True, cwd=root, check=False,
    )
    if done.returncode not in (0, 1):
        raise RuntimeError(f"ruff failed: {done.stderr.strip()}")
    counts: dict[str, Counter[str]] = {}
    where: dict[tuple[str, str], list[str]] = {}
    for item in json.loads(done.stdout or "[]"):
        rel = os.path.relpath(item["filename"], root)
        counts.setdefault(rel, Counter())[item["code"]] += 1
        where.setdefault((rel, item["code"]), []).append(f"{rel}:{item['location']['row']} {item['message']}")
    return counts, where


def total(counts: dict[str, dict[str, int]]) -> int:
    return sum(sum(rules.values()) for rules in counts.values())


def main() -> int:
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    if mode not in ("--check", "--update"):
        sys.stderr.write("usage: structure_ratchet.py --check | --update\n")
        return 2
    root = Path.cwd()
    base_file = root / BASELINE
    if not base_file.exists():
        print(f"structure_ratchet: no {BASELINE} here, skipped")
        log("SKIP", "no baseline")
        return 0
    base = json.loads(base_file.read_text(encoding="utf-8"))
    old: dict[str, dict[str, int]] = base.get("counts", {})
    now, where = measure(root, base["paths"])

    if mode == "--check":
        bad = [
            (file, rule, n, old.get(file, {}).get(rule, 0))
            for file, rules in now.items()
            for rule, n in rules.items()
            if n > old.get(file, {}).get(rule, 0)
        ]
        if not bad:
            log("ALLOW", f"files={len(now)}")
            return 0
        sys.stderr.write("STRUCTURE RATCHET: code-shape violations above the baseline (it may only shrink):\n")
        for file, rule, n, allowed in bad:
            sys.stderr.write(f"  {file} {rule}: {n} found, {allowed} allowed\n")
            for line in where[(file, rule)]:
                sys.stderr.write(f"      {line}\n")
        sys.stderr.write("Split the function (fewer args / statements / branches), then commit again.\n")
        log("BLOCK", "; ".join(f"{f} {r} {n}>{a}" for f, r, n, a in bad))
        return 1

    new: dict[str, dict[str, int]] = {}
    for file, rules in old.items():
        for rule, allowed in rules.items():
            kept = min(allowed, now.get(file, Counter()).get(rule, 0))
            if kept:
                new.setdefault(file, {})[rule] = kept
    if new != old:
        base["counts"] = {f: dict(sorted(r.items())) for f, r in sorted(new.items())}
        base_file.write_text(json.dumps(base, indent=2) + "\n", encoding="utf-8")
        log("UPDATE", f"total {total(old)}->{total(new)}")
        print(f"structure_ratchet: baseline lowered, stage {BASELINE}")
    else:
        log("UPDATE", "unchanged")
    return 0


if __name__ == "__main__":
    sys.exit(main())
