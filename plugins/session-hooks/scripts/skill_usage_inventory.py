#!/usr/bin/env python3
"""Full inventory: every installed skill against how often it was ever invoked.

Counts `Skill` tool_use calls across every transcript in every cage, main
sessions and subagents alike, then joins against what is installed so the
never-used set is explicit rather than inferred.
"""
import json
import re
from collections import Counter
from pathlib import Path

MASTER = Path.home() / ".claude" / "skills"
OWN_REPO = Path.home() / "dev" / "claude-skills" / "plugins"
FRONTMATTER = re.compile(r"^---\s*\n(.*?)\n---", re.S)

# --- what is installed, and where it came from -----------------------------
installed = {}
for d in sorted(MASTER.iterdir()):
    if not d.is_dir():
        continue
    origin = "own-project" if d.is_symlink() else "borrowed"
    installed[d.name] = origin

authored = set()
if OWN_REPO.exists():
    for plug in OWN_REPO.iterdir():
        sk = plug / "skills"
        if sk.is_dir():
            authored.update(x.name for x in sk.iterdir() if x.is_dir())
for name in installed:
    if name in authored:
        installed[name] = "authored"

# --- description size, the thing the listing actually costs ----------------
def desc_len(name):
    p = MASTER / name / "SKILL.md"
    try:
        head = p.read_text(errors="ignore")[:8000]
    except OSError:
        return 0
    m = FRONTMATTER.search(head)
    if not m:
        return 0
    dm = re.search(r"^description:\s*(.*?)(?=^\w[\w-]*:|\Z)", m.group(1), re.S | re.M)
    return len(" ".join(dm.group(1).split())) if dm else 0


# --- usage across every cage ------------------------------------------------
uses = Counter()
sessions = 0
for cage in sorted(Path.home().glob(".claude-*")):
    proj = cage / "projects"
    if not proj.is_dir():
        continue
    for jf in proj.rglob("*.jsonl"):
        sessions += 1
        try:
            raw = jf.read_text(errors="ignore")
        except OSError:
            continue
        if '"Skill"' not in raw:
            continue
        for line in raw.splitlines():
            if '"Skill"' not in line:
                continue
            try:
                row = json.loads(line)
            except ValueError:
                continue
            content = row.get("message", {}).get("content")
            if not isinstance(content, list):
                continue
            for c in content:
                if isinstance(c, dict) and c.get("type") == "tool_use" and c.get("name") == "Skill":
                    skill = (c.get("input") or {}).get("skill") or (c.get("input") or {}).get("command")
                    if skill:
                        uses[str(skill).lstrip("/").split(":")[-1]] += 1

print("transcripts scanned: %d" % sessions)
print("distinct skills ever invoked: %d   total invocations: %d\n"
      % (len(uses), sum(uses.values())))

print("=== USED ===")
print("%-34s %6s  %-11s %s" % ("skill", "uses", "origin", "desc chars"))
for name, n in uses.most_common():
    origin = installed.get(name, "NOT-INSTALLED")
    print("%-34s %6d  %-11s %d" % (name[:34], n, origin, desc_len(name)))

never = [n for n in installed if n not in uses]
print("\n=== NEVER INVOKED: %d skills ===" % len(never))
by_origin = Counter(installed[n] for n in never)
chars = sum(desc_len(n) for n in never)
print("by origin: %s" % dict(by_origin))
print("description cost carried for them: %d chars (~%d tokens) per session AND per subagent"
      % (chars, chars // 4))
print("\n" + ", ".join(sorted(never)))
