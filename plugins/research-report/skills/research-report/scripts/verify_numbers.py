#!/usr/bin/env python3
"""Check every number in the prose against the evidence register.

WHY. Every full rewrite of a report invalidates the number-verification pass,
and on 2026-09-10 there were four of them. Doing this mechanically after each
one caught two real errors that had survived the rewrite: a spread-skill range
stated as 0.87-0.92 when the register's span was 0.87-0.90, and "four
percentage points" where the figure showed three. Both are the same shape --
a number that survived a rewrite it was no longer true after -- and neither is
visible to a reader who knows what the sentence is supposed to say.

WHAT IT DOES. Pulls every numeral out of the PROSE (tables are generated from
the readout under guard rule 14, so they are already tied to source), plus
spelled-out numbers one..twelve, and asks whether each traces to a number in
the evidence register. Anything that does not is printed for eyeballing: most
will be roundings and cross-references, and the point is that the list is
short enough to read.

It is a REPORT, not a gate -- roundings are legitimate and a refusal would
teach you to switch it off. What IS a gate is staleness: it writes
evidence/numbers.state, and release_gate.sh refuses a hand-over whose state
does not match the current text. That is the mechanical form of "every rewrite
invalidates the pass".

Usage:
  python3 verify_numbers.py <doc.md> [--evidence DIR] [--strict] [--quiet]
  python3 verify_numbers.py --selftest
"""
from __future__ import annotations

import datetime as _dt
import hashlib
import os
import re
import sys

WORDS = {"one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
         "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
         "twelve": 12}

NUM = re.compile(r"(?<![\w.])(-?\d+(?:\.\d+)?)(?![\w.]*[A-Za-z_])")
WORD_NUM = re.compile(r"\b(" + "|".join(WORDS) + r")\b", re.I)

# Numbers that are references or scaffolding, never claims.
SKIP_CONTEXT = re.compile(
    r"\b(figure|fig\.|table|tab\.|section|§|appendix|equation|eq\.|page|"
    r"chapter|part|step|rule|item)\s*$", re.I)


def prose_lines(text: str):
    """(lineno, line) for prose only: no fences, tables, headings, comments."""
    out, in_fence = [], False
    for n, line in enumerate(text.split("\n"), 1):
        s = line.strip()
        if s.startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence or not s:
            continue
        if s.startswith(("|", "#", "<!--", ":", "!", "> ")):
            continue
        out.append((n, line))
    return out


def draft_numbers(text: str):
    """[(lineno, token, value)] for every claimable number in the prose."""
    found = []
    for n, line in prose_lines(text):
        # Strip inline math and code: a symbol's subscript is not a claim.
        bare = re.sub(r"\$[^$]*\$", " ", line)
        bare = re.sub(r"`[^`]*`", " ", bare)
        for m in NUM.finditer(bare):
            tok = m.group(1)
            before = bare[:m.start()].rstrip()
            if SKIP_CONTEXT.search(before):
                continue
            v = float(tok)
            if 1900 <= v <= 2100 and "." not in tok:
                continue                      # a year
            found.append((n, tok, v))
        for m in WORD_NUM.finditer(bare):
            found.append((n, m.group(1).lower(), float(WORDS[m.group(1).lower()])))
    return found


def register_numbers(evdir: str):
    """Every number the evidence register contains, with the raw text."""
    vals, blob = set(), []
    if not os.path.isdir(evdir):
        return vals, ""
    for root, _dirs, files in os.walk(evdir):
        for f in sorted(files):
            if not f.lower().endswith((".md", ".txt", ".csv", ".tsv", ".yaml",
                                       ".yml", ".json")):
                continue
            if f == "numbers.state":
                continue
            try:
                blob.append(open(os.path.join(root, f), encoding="utf-8",
                                 errors="replace").read())
            except OSError:
                continue
    text = "\n".join(blob)
    for m in re.finditer(r"-?\d+(?:\.\d+)?", text):
        try:
            vals.add(float(m.group(0)))
        except ValueError:
            pass
    return vals, text


def traces(value: float, token: str, reg_vals: set[float], reg_text: str) -> bool:
    """Does a drafted number trace to the register: exactly, or as a rounding."""
    if value in reg_vals:
        return True
    if token.isalpha() and re.search(rf"\b{token}\b", reg_text, re.I):
        return True
    dp = len(token.split(".")[1]) if "." in token else 0
    for rv in reg_vals:
        if round(rv, dp) == value:
            return True
        # A percentage in the prose against a fraction in the register.
        if dp == 0 and abs(rv) <= 1.0 and round(rv * 100, 0) == value:
            return True
    return False


def check(doc: str, evdir: str | None = None, quiet: bool = False):
    text = open(doc, encoding="utf-8").read()
    docdir = os.path.dirname(os.path.abspath(doc))
    evdir = evdir or os.path.join(docdir, "evidence")
    reg_vals, reg_text = register_numbers(evdir)
    nums = draft_numbers(text)
    unmatched = [(n, t) for n, t, v in nums if not traces(v, t, reg_vals, reg_text)]
    if not quiet:
        if not reg_vals:
            print(f"NUMBERS: no evidence register found at {evdir} -- every number "
                  f"in the prose is unverified.", file=sys.stderr)
        print(f"NUMBERS: {len(nums)} number(s) in the prose, "
              f"{len(nums) - len(unmatched)} traced to the register, "
              f"{len(unmatched)} not.")
        for n, t in unmatched:
            print(f"NUMBERS:   line {n}: {t} -- not in the register. A rounding or "
                  f"a cross-reference is fine; a claim is not.", file=sys.stderr)
    return nums, unmatched


def write_state(doc: str, unmatched: int) -> str:
    docdir = os.path.dirname(os.path.abspath(doc))
    os.makedirs(os.path.join(docdir, "evidence"), exist_ok=True)
    h = hashlib.sha256(open(doc, "rb").read()).hexdigest()
    path = os.path.join(docdir, "evidence", "numbers.state")
    with open(path, "w", encoding="utf-8") as f:
        f.write(f"CHECKED {h} {_dt.date.today().isoformat()} {unmatched}\n")
    return path


def selftest() -> int:
    import tempfile
    ok = True
    with tempfile.TemporaryDirectory() as d:
        os.makedirs(os.path.join(d, "evidence"))
        open(os.path.join(d, "evidence", "claims.md"), "w").write(
            "| id | claim | source |\n|---|---|---|\n"
            "| c1 | the ratio spans 0.87 to 0.90 | run A |\n"
            "| c2 | coverage falls short by 3 percentage points | run B |\n")
        doc = os.path.join(d, "report.md")
        open(doc, "w").write(
            "# T\n\n## 1. Setting\n\n"
            "The ratio spans 0.87 to 0.92, and coverage falls four percentage "
            "points short. See Figure 3 and Table 2, from 2026.\n")
        nums, unmatched = check(doc, quiet=True)
        toks = sorted(t for _n, t in unmatched)
        # The two planted errors are caught...
        for want in ("0.92", "four"):
            if want not in toks:
                print(f"FAIL: selftest did not flag {want!r} (flagged {toks})")
                ok = False
        # ...and the true values, the float/table refs and the year are not.
        for wrong in ("0.87", "3", "2026"):
            if wrong in toks:
                print(f"FAIL: selftest wrongly flagged {wrong!r}")
                ok = False
        # Mutation: correct the draft and the flags must clear.
        open(doc, "w").write(
            "# T\n\n## 1. Setting\n\n"
            "The ratio spans 0.87 to 0.90, and coverage falls three percentage "
            "points short.\n")
        _n2, u2 = check(doc, quiet=True)
        if u2:
            print(f"FAIL: a corrected draft still flagged {[t for _l, t in u2]}")
            ok = False
        p = write_state(doc, 0)
        if not open(p).read().startswith("CHECKED "):
            print("FAIL: numbers.state was not written in the expected form")
            ok = False
    print("verify_numbers selftest: " + ("pass" if ok else "FAIL"))
    return 0 if ok else 1


def main(argv: list[str]) -> int:
    if "--selftest" in argv:
        return selftest()
    args = [a for a in argv if not a.startswith("--")]
    if not args:
        print(__doc__.strip().split("Usage:")[-1], file=sys.stderr)
        return 2
    doc = args[0]
    if not os.path.isfile(doc):
        print(f"NUMBERS: no such file: {doc}", file=sys.stderr)
        return 2
    evdir = None
    if "--evidence" in argv:
        i = argv.index("--evidence")
        if i + 1 < len(argv):
            evdir = argv[i + 1]
    _nums, unmatched = check(doc, evdir, quiet="--quiet" in argv)
    write_state(doc, len(unmatched))
    return 1 if ("--strict" in argv and unmatched) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
