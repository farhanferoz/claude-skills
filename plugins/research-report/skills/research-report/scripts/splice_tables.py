#!/usr/bin/env python3
"""Splice generated tables into a report between marker comments.

WHY THIS IS IN THE SKILL AND NOT IN ONE REPORT
-----------------------------------------------
The contract forbids a hand-typed numeric results table, and `report_guard.sh`
enforces that. Until now the enforcement shipped without the tool: the splice
mechanism existed only inside one report's own `make_tables.py`, so the next
report to use this skill inherited the refusal and had to reinvent the way out
of it. That is the half of S2 that was never done.

WHAT IS GENERIC AND WHAT IS NOT
--------------------------------
Only the MECHANISM is generic, and only the mechanism is here: find a marker
pair, replace what is between it, leave everything else byte-identical, and
refuse quietly-wrong outcomes. Which numbers a table holds, where they come
from and how they are rounded is the report's own business and stays in the
report's own builder -- a "generic table formatter" would be a worse version of
whatever each report actually needs.

THE MARKERS
-----------
    <!-- BEGIN <kind> table: <name> -->
    ...anything; replaced wholesale...
    <!-- END <kind> table: <name> -->

`kind` groups tables that are built the same way (`results`, `differences`,
`verdicts`); `name` identifies one of them (usually a system). Both are free
text. The caption is written OUTSIDE the markers, in the report, because a
caption is prose and belongs with the prose.

IDEMPOTENCE IS THE POINT
-------------------------
Running this twice must change nothing the second time: the report can then be
rebuilt at any moment without a diff, so a stale table is always visible as a
real diff rather than hiding among churn.

⚠ A GENERATOR CAN SILENTLY REVERT A FIX. Observed 2026-08-13: a report's
builder still emitted a passage that had been consolidated away by hand and a
sentence describing a superseded figure scale, so every run quietly undid two
closed review items. Whatever a splice writes is the source of truth for that
region -- fix the GENERATOR, never the spliced output, or the next run undoes
you.

Usage:
    splice_tables.py <report.md> <blocks.json>
    splice_tables.py --selftest

`blocks.json` is ``{"<kind>": {"<name>": "<markdown block>"}}``. As a library:

    from splice_tables import splice_all
    written, missing = splice_all(Path("report.md"), {"results": {...}})
"""

from __future__ import annotations

import json
import sys
from pathlib import Path


class MarkerError(Exception):
    """A marker pair is missing, malformed, or repeated."""


def markers(kind: str, name: str) -> tuple[str, str]:
    """The BEGIN and END comment for one table."""
    return (
        f"<!-- BEGIN {kind} table: {name} -->",
        f"<!-- END {kind} table: {name} -->",
    )


def splice(text: str, kind: str, name: str, block: str) -> str:
    """Return `text` with this table's region replaced by `block`.

    Raises rather than returning the text unchanged when the markers are not
    usable. A splice that silently does nothing is the failure mode this whole
    mechanism exists to remove: the report keeps its stale numbers and the
    build reports success.
    """
    begin, end = markers(kind, name)
    if text.count(begin) != 1 or text.count(end) != 1:
        msg = (
            f"{kind}/{name}: need exactly one {begin} and one {end}; found "
            f"{text.count(begin)} and {text.count(end)}"
        )
        raise MarkerError(msg)
    pre, rest = text.split(begin, 1)
    _old, post = rest.split(end, 1)
    if not pre.endswith("\n") and pre:
        pre += "\n"
    return f"{pre}{begin}\n\n{block.strip()}\n\n{end}{post}"


def splice_all(
    doc: Path, blocks: dict[str, dict[str, str]], *, strict: bool = True
) -> tuple[int, list[str]]:
    """Splice every block into `doc` in place; return (count, missing).

    `strict` decides what an absent marker pair means. It defaults to True --
    an author who generated a table the report has nowhere to put has made a
    mistake, and the loud version of that is cheaper than a report missing a
    table nobody notices. Pass False while a report is still being assembled.
    """
    text = doc.read_text(encoding="utf-8")
    missing: list[str] = []
    count = 0
    for kind, named in blocks.items():
        for name, block in named.items():
            try:
                text = splice(text, kind, name, block)
            except MarkerError as exc:
                if strict:
                    raise
                missing.append(str(exc))
                continue
            count += 1
    doc.write_text(text, encoding="utf-8")
    return count, missing


def _selftest() -> int:
    """Exercise the splice, its idempotence, and each way it must refuse."""
    import tempfile

    doc = (
        "Before.\n\n<!-- BEGIN results table: ring -->\n\nSTALE\n\n"
        "<!-- END results table: ring -->\n\nTable: A caption.\n\nAfter.\n"
    )
    fresh = "| a | b |\n|:--|--:|\n| x | 1 |"

    out = splice(doc, "results", "ring", fresh)
    assert "STALE" not in out, "the old block must be gone"
    assert fresh in out, out
    # Everything outside the markers is untouched, the caption included: a
    # caption is prose and the splice must never own it.
    assert out.startswith("Before.\n"), out
    assert "Table: A caption." in out
    assert out.endswith("After.\n"), out

    # Idempotence: splicing the same block again changes nothing at all.
    assert splice(out, "results", "ring", fresh) == out, "splice is not idempotent"

    # A missing, duplicated or half-present marker pair RAISES. Returning the
    # text unchanged would let a build report success over stale numbers.
    for broken, why in (
        (doc.replace("<!-- END results table: ring -->", ""), "no END"),
        (doc + doc, "duplicated pair"),
        ("nothing here", "no markers at all"),
    ):
        try:
            splice(broken, "results", "ring", fresh)
        except MarkerError:
            pass
        else:
            msg = f"a {why} fixture must raise"
            raise AssertionError(msg)

    # splice_all writes the file and counts what it did.
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "r.md"
        path.write_text(doc, encoding="utf-8")
        count, missing = splice_all(path, {"results": {"ring": fresh}})
        assert (count, missing) == (1, []), (count, missing)
        assert fresh in path.read_text(encoding="utf-8")
        # A block with nowhere to go is loud by default and countable when not.
        try:
            splice_all(path, {"results": {"torus": fresh}})
        except MarkerError:
            pass
        else:
            msg = "strict splice_all must raise on an absent marker pair"
            raise AssertionError(msg)
        count, missing = splice_all(
            path, {"results": {"torus": fresh}}, strict=False
        )
        assert count == 0 and len(missing) == 1, (count, missing)

    print("=== splice_tables selftest PASSED ===")
    return 0


#: <report.md> and <blocks.json>.
_EXPECTED_ARGS = 2


def main(argv: list[str]) -> int:
    if argv == ["--selftest"]:
        return _selftest()
    if len(argv) != _EXPECTED_ARGS:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        print("usage: splice_tables.py <report.md> <blocks.json>", file=sys.stderr)
        return 2
    doc, blocks_path = Path(argv[0]), Path(argv[1])
    blocks = json.loads(blocks_path.read_text(encoding="utf-8"))
    count, missing = splice_all(doc, blocks)
    for line in missing:
        print(f"SPLICE: {line}", file=sys.stderr)
    print(f"spliced {count} table(s) into {doc}")
    return 0 if not missing else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
