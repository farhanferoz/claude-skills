#!/usr/bin/env python3
"""Measure AI-writing patterns in a body of prose, and calibrate a threshold from it.

Zero dependencies, stdlib only, so it runs in any repo without an environment.

The point of this tool is NOT the rule list — rule lists are cheap and every one of
them is somebody's opinion. The point is the *baseline*. Published thresholds
("more than one em-dash per 1,000 words is a flag") are heuristics with nothing
behind them, and applying a stranger's number to your corpus tells you nothing.
Measuring your own corpus tells you what normal looks like for you, so you can see
whether a change actually moved anything.

    # what does normal look like here?
    scan.py docs/ --baseline .ai-patterns-baseline.json

    # did the thing I just wrote drift from normal?
    scan.py drafts/new-post.md --compare .ai-patterns-baseline.json

Rates are per 1,000 words of PROSE — code blocks, inline code, link targets and
image markup are excluded, because a URL containing "foster" is not a cliché.
"""

from __future__ import annotations

import argparse
import json
import re
import statistics
import sys
from dataclasses import dataclass
from pathlib import Path

TEXT_SUFFIXES = {".md", ".mdoc", ".mdx", ".txt", ".rst", ".markdown"}
MIN_WORDS_FOR_RATE = 200   # below this a per-1k rate is noise, not a measurement
MIN_FILES_FOR_P90 = 10     # a p90 over fewer files than this is not a percentile
RATE_DELTA_EPSILON = 0.01  # per-1k movement below this is rounding, not drift


# --- rules -----------------------------------------------------------------
# Each entry: id -> (regex, one-line description, tier)
# tier "structural" = a syntactic habit; "lexical" = specific vocabulary.
# Lexical rules are the ones most likely to be register rather than authorship,
# so they are reported separately and never auto-corrected.

RULES: dict[str, tuple[re.Pattern[str], str, str]] = {
    "participial_consequence": (
        re.compile(r",\s+(?:thereby\s+|thus\s+)?(?:allowing|enabling|ensuring|leading\s+to|resulting\s+in)\b", re.I),
        "consequence bolted on as a trailing clause instead of its own sentence",
        "structural",
    ),
    "fronted_transition": (
        re.compile(
            r"(?:(?<=^)|(?<=[.!?]\s)|(?<=[.!?]\s\s))"
            r"(?:Moreover|Furthermore|Additionally|Notably|Crucially|Importantly|Consequently),\s+",
            re.M,
        ),
        "sentence opened with a transition adverbial",
        "structural",
    ),
    "not_only_but_also": (
        re.compile(r"\bnot\s+(?:only|just|merely)\b.{0,120}?\bbut\s+(?:also\b|as\s+well\b)", re.I | re.S),
        "'not only X but also Y' frame",
        "structural",
    ),
    "critical_role": (
        re.compile(r"\bplay(?:s|ed)?\s+(?:a\s+)?(?:critical|pivotal|vital|central|key)\s+role\s+in\b", re.I),
        "'plays a critical role in' significance attribution",
        "lexical",
    ),
    "significance_inflation": (
        re.compile(
            r"\b(?:serves?\s+as\s+a\s+testament\s+to|paves?\s+the\s+way\s+for|"
            r"holds?\s+(?:great\s+|immense\s+)?promise\s+for|"
            r"marks?\s+a\s+(?:significant|pivotal|crucial)\s+step|at\s+the\s+forefront\s+of)\b", re.I),
        "routine thing described as a milestone",
        "lexical",
    ),
    # Provenance of this list is mixed, and the difference matters:
    #   corpus-confirmed (Kobak et al. Sci Adv 2025; Matsui PME 2025):
    #     delve, tapestry, underscore, showcasing, meticulous, intricate, pivotal
    #   convergent across tool rule-sets but NOT in any primary excess-word list:
    #     cornerstone, beacon, game-changer  <- listicle-sourced; do not call these "proven"
    # Kept short on purpose. Kobak's largest movers include `potential`, `findings`
    # and `crucial`, which are ordinary English — flagging those would fire on
    # everyone. Report-only either way: a population signal is not a per-document
    # classifier, and none of these papers report labelled accuracy.
    "buzzwords": (
        re.compile(
            r"\b(?:delve|delves|delving|testament|cornerstone|beacon|tapestry|game-changer|"
            r"groundbreaking|revolutionize|revolutionise|unwavering|paramount|foster|fostering|"
            r"harness|harnessing|underpins|underpinning|ever-evolving|multifaceted|seamlessly|"
            r"pivotal)\b", re.I),
        "overrepresented vocabulary",
        "lexical",
    ),
    "em_dash": (
        re.compile(r"—"),
        "em-dash density (report-only: this is register, not authorship)",
        "punctuation",
    ),
}

_FENCED = re.compile(r"```.*?```", re.S)
_INLINE = re.compile(r"`[^`]*`")
_IMAGE = re.compile(r"!\[[^\]]*\]\([^)]*\)")
_LINK = re.compile(r"\[([^\]]*)\]\(([^)]*)\)")
_FRONTMATTER = re.compile(r"\A---\n.*?\n---\n", re.S)


def prose_of(text: str) -> str:
    """Just the words a reader reads."""
    text = _FRONTMATTER.sub("", text)
    text = _FENCED.sub(" ", text)
    text = _INLINE.sub(" ", text)
    text = _IMAGE.sub(" ", text)
    text = _LINK.sub(r"\1", text)
    return text


@dataclass
class FileResult:
    path: Path
    words: int
    counts: dict[str, int]

    @property
    def total(self) -> int:
        return sum(n for rid, n in self.counts.items() if RULES[rid][2] != "punctuation")

    def rate(self, rule: str | None = None) -> float:
        n = self.counts.get(rule, 0) if rule else self.total
        return n / self.words * 1000 if self.words else 0.0


def scan_file(path: Path) -> FileResult | None:
    try:
        body = prose_of(path.read_text(encoding="utf-8", errors="ignore"))
    except OSError:
        return None
    words = len(body.split())
    counts = {rid: len(rx.findall(body)) for rid, (rx, _, _) in RULES.items()}
    return FileResult(path, words, counts)


def collect(targets: list[Path]) -> list[FileResult]:
    files: list[Path] = []
    for t in targets:
        if t.is_dir():
            files += [p for p in sorted(t.rglob("*")) if p.suffix.lower() in TEXT_SUFFIXES]
        elif t.suffix.lower() in TEXT_SUFFIXES or t.is_file():
            files.append(t)
    return [r for r in (scan_file(p) for p in files) if r and r.words]


def summarise(results: list[FileResult]) -> dict:
    scored = [r for r in results if r.words >= MIN_WORDS_FOR_RATE]
    words = sum(r.words for r in results)
    per_rule = {rid: sum(r.counts.get(rid, 0) for r in results) for rid in RULES}
    total = sum(n for rid, n in per_rule.items() if RULES[rid][2] != "punctuation")
    return {
        "files": len(results),
        "words": words,
        "findings": total,
        "rate_per_1k": round(total / words * 1000, 3) if words else 0.0,
        "median_file_rate": round(statistics.median([r.rate() for r in scored]), 3) if scored else 0.0,
        "p90_file_rate": round(
            sorted(r.rate() for r in scored)[int(len(scored) * 0.9)], 3
        ) if len(scored) >= MIN_FILES_FOR_P90 else None,
        "by_rule_per_1k": {
            rid: round(n / words * 1000, 3) for rid, n in sorted(per_rule.items(), key=lambda kv: -kv[1]) if n
        },
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("targets", nargs="+", type=Path, help="files or directories of prose")
    ap.add_argument("--baseline", type=Path, help="write the measured corpus profile here")
    ap.add_argument("--compare", type=Path, help="compare against a previously written baseline")
    ap.add_argument("--worst", type=int, default=5, help="how many worst files to list (default 5)")
    ap.add_argument("--json", action="store_true", help="machine-readable output only")
    args = ap.parse_args()

    results = collect(args.targets)
    if not results:
        print("no prose files found", file=sys.stderr)
        return 2
    summary = summarise(results)

    if args.json:
        print(json.dumps(summary, indent=2))
    else:
        print(f"{summary['files']} files, {summary['words']:,} words of prose")
        print(f"  overall     {summary['rate_per_1k']} findings per 1,000 words")
        print(f"  median file {summary['median_file_rate']}"
              + (f"   p90 {summary['p90_file_rate']}" if summary["p90_file_rate"] is not None else ""))
        print("\n  by rule (per 1,000 words):")
        for rid, rate in summary["by_rule_per_1k"].items():
            tier = RULES[rid][2]
            note = "  [report-only]" if tier == "punctuation" else ""
            print(f"    {rate:>7.2f}  {rid}{note}")
        scored = sorted((r for r in results if r.words >= MIN_WORDS_FOR_RATE),
                        key=lambda r: -r.rate())
        if scored:
            print(f"\n  worst {min(args.worst, len(scored))} files:")
            for r in scored[: args.worst]:
                print(f"    {r.rate():>6.2f}/1k  {r.path}")

    if args.baseline:
        args.baseline.write_text(json.dumps(summary, indent=2) + "\n")
        print(f"\nbaseline written to {args.baseline}")
        print("Set your threshold from THIS, not from a number in someone's blog post.")

    if args.compare and args.compare.exists():
        base = json.loads(args.compare.read_text())
        delta = summary["rate_per_1k"] - base["rate_per_1k"]
        arrow = "worse" if delta > 0 else ("better" if delta < 0 else "unchanged")
        print(f"\nvs baseline: {base['rate_per_1k']} -> {summary['rate_per_1k']} per 1k ({arrow}, {delta:+.3f})")
        for rid in sorted(set(base.get("by_rule_per_1k", {})) | set(summary["by_rule_per_1k"])):
            b = base.get("by_rule_per_1k", {}).get(rid, 0.0)
            c = summary["by_rule_per_1k"].get(rid, 0.0)
            if abs(c - b) >= RATE_DELTA_EPSILON:
                print(f"    {rid:<26} {b:>6.2f} -> {c:>6.2f}  ({c - b:+.2f})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
