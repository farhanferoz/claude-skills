#!/usr/bin/env python3
"""dupcheck: find copied code in a Python repository, standard library only.

A block counts as a duplicate when two places hold the same run of `MIN_STATEMENTS` or more consecutive statements
once names, literals, annotations, docstrings, imports and formatting are normalised away (a renamed copy of a
function is still a copy). Statements are compared in pre-order with their nesting depth relative to the first one, so
a block pasted at another indentation level still matches. Cost is linear in the number of statements: every window of
`MIN_STATEMENTS` statements is hashed once and the hashes are grouped.

Three ways to use it, none of which needs a configuration file:

  dupcheck.py scan ROOT [--min N] [--only DIR ...] [--include-tests]
      Print every duplicated block in the repository, biggest first.

  dupcheck.py edit FILE [--min N] [--root ROOT]
      For an edit hook. Report only blocks in FILE that duplicate code elsewhere in the repository AND were not
      already in FILE's committed version (`git show HEAD:<path>`). Prints nothing and exits 0 when clean (also for a
      file outside a git checkout, a file that does not parse, a test file, a non-Python file); otherwise prints one
      `file:lines  duplicates  other:lines` line per block and exits 1 (`--exit-zero` forces 0).

  dupcheck.py baseline ROOT --baseline FILE [--write] [--min N] [--only DIR ...]
      For a project that wants a whole-repository test. The baseline lists today's duplicates and may only shrink:
      a new duplicate fails, and so does an entry whose duplicate has gone (delete it) or has grown. `--write` creates
      or prunes the file, keeping reasons already written; each entry carries a `reason`, and a deliberate exception is
      an entry whose reason says why. Library use: `scan_repo`, `load_baseline`, `check_baseline`.

Tests and vendored directories are skipped unless `--include-tests` is given (copied test setup is common and cheap).
"""

from __future__ import annotations

import argparse
import ast
import json
import subprocess
import sys
from bisect import bisect_right
from collections.abc import Iterable, Mapping, Sequence
from dataclasses import dataclass, field
from pathlib import Path

MIN_STATEMENTS = 8
MIN_COPIES = 2  # a block is a duplicate from the second copy
DEFAULT_REASON = "existing duplicate when the baseline was written"
SKIP_DIRS = frozenset({
    ".git", ".hg", ".venv", "venv", "env", "node_modules", "__pycache__", "build", "dist", "site-packages",
    "third_party", "vendor", "vendored", ".tox", ".mypy_cache", ".ruff_cache", ".pytest_cache",
})
TEST_DIRS = frozenset({"tests", "test"})
_COMPOUND = (ast.If, ast.For, ast.While, ast.Try, ast.With, ast.AsyncFor, ast.AsyncWith, ast.FunctionDef,
             ast.AsyncFunctionDef, ast.ClassDef, ast.ExceptHandler)
_KEEP_STR_FIELDS = frozenset({"attr"})  # `x.attr` names a behaviour; plain variable names do not
_DEF_NODES = (ast.FunctionDef, ast.AsyncFunctionDef)
_BLOCK_ITEMS = (ast.stmt, ast.excepthandler, getattr(ast, "match_case", ast.stmt))


# ---------------------------------------------------------------------------
# Normalising a statement header
# ---------------------------------------------------------------------------


def _norm(node: ast.AST) -> str:
    """The node's expressions as one string, with names, literals and annotations replaced; nested statement lists are
    left to the caller (they become tokens of their own)."""
    if isinstance(node, ast.Name):
        return "N"
    if isinstance(node, ast.Constant):
        v = node.value
        return "S" if isinstance(v, str) else "Y" if isinstance(v, bytes) else repr(v) if isinstance(v, bool) or v is None or v is Ellipsis else "#"
    if isinstance(node, ast.arg):
        return "a"
    if isinstance(node, ast.AnnAssign) and node.value is not None:  # `x: int = v` is `x = v` with a note
        return _norm(ast.Assign(targets=[node.target], value=node.value))
    parts = [type(node).__name__]
    for name, value in ast.iter_fields(node):
        if name in ("ctx", "type_comment", "annotation", "returns", "type_params", "kind", "name", "names", "id"):
            if name == "name" and isinstance(node, ast.ExceptHandler):
                parts.append("as" if value else "")
            continue
        if isinstance(value, list):
            if value and isinstance(value[0], _BLOCK_ITEMS):
                continue
            parts.append("[" + ",".join(_norm(v) if isinstance(v, ast.AST) else "" for v in value) + "]")
        elif isinstance(value, ast.AST):
            parts.append(_norm(value))
        elif name in _KEEP_STR_FIELDS or (name == "arg" and isinstance(node, ast.keyword)):
            parts.append(str(value))
    return "(" + " ".join(parts) + ")"


def _is_docstring(node: ast.stmt) -> bool:
    return isinstance(node, ast.Expr) and isinstance(node.value, ast.Constant) and isinstance(node.value.value, str)


_DECLARATIVE_CALLS = frozenset({"add_argument", "add_parser", "add_subparsers", "add_argument_group", "add_mutually_exclusive_group"})


def _is_plain_data(stmt: ast.stmt) -> bool:
    """A module- or class-level `NAME = <expression without a call>` or a bare `name: type`: a constants table or a
    dataclass's fields are data, not logic, and eight of them in a row look alike in every file."""
    if isinstance(stmt, ast.AnnAssign) and stmt.value is None:
        return True
    value = stmt.value if isinstance(stmt, (ast.Assign, ast.AnnAssign)) else None
    return value is not None and not any(isinstance(n, ast.Call) for n in ast.walk(value))


def _is_declarative(stmt: ast.stmt) -> bool:
    """`parser.add_argument(...)` and `sub = parser.add_parser(...)` at any depth: command-line declarations are a table,
    and two commands that share most of their options are not copied logic."""
    call = stmt.value if isinstance(stmt, (ast.Expr, ast.Assign)) else None
    return isinstance(call, ast.Call) and isinstance(call.func, ast.Attribute) and call.func.attr in _DECLARATIVE_CALLS


@dataclass
class _Stream:
    """The statements of one function (or of a class body or module level without its functions), in pre-order."""

    scope: str
    hdr: list[int] = field(default_factory=list)
    tok: list[int] = field(default_factory=list)
    line: list[int] = field(default_factory=list)
    end: list[int] = field(default_factory=list)
    _depth: int = 0
    _last: int = 0

    def add(self, header: str, depth: int, line: int, end: int) -> None:
        h = hash(header)
        self.hdr.append(h)
        self.tok.append(hash((h, depth - self._last)))
        self.line.append(line)
        self.end.append(end)
        self._last = depth


def _emit(node: ast.AST, depth: int, out: _Stream) -> None:
    if isinstance(node, (ast.Import, ast.ImportFrom)) or (isinstance(node, ast.stmt) and (_is_docstring(node) or _is_declarative(node))):
        return
    line = getattr(node, "lineno", None) or node.pattern.lineno  # a `case` has no line of its own
    end = getattr(node, "end_lineno", None) or line
    out.add(_norm(node), depth, line, line if isinstance(node, _COMPOUND) else end)
    for name, value in ast.iter_fields(node):
        if not (isinstance(value, list) and value and isinstance(value[0], _BLOCK_ITEMS)):
            continue
        if name in ("orelse", "finalbody"):
            out.add(name, depth, line, line)
        for child in value:
            _emit(child, depth + 1, out)


def _streams(tree: ast.Module) -> list[_Stream]:
    """One stream per outermost function (nested functions stay inside their parent), one per class body and one for
    module level, so a window never spans two functions."""
    result: list[_Stream] = []

    def visit_body(body: Sequence[ast.stmt], scope: str) -> None:
        own = _Stream(scope)
        for stmt in body:
            if isinstance(stmt, _DEF_NODES):
                fn = _Stream(f"{scope}.{stmt.name}" if scope != "<module>" else stmt.name)
                _emit(stmt, 0, fn)
                result.append(fn)
            elif isinstance(stmt, ast.ClassDef):
                visit_body(stmt.body, f"{scope}.{stmt.name}" if scope != "<module>" else stmt.name)
            elif not _is_plain_data(stmt):
                _emit(stmt, 0, own)
        result.append(own)

    visit_body(tree.body, "<module>")
    return [s for s in result if s.tok]


# ---------------------------------------------------------------------------
# Finding duplicates
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Occurrence:
    path: str
    scope: str
    line: int
    end_line: int

    def __str__(self) -> str:
        return f"{self.path}:{self.line}-{self.end_line}"


@dataclass(frozen=True)
class Clone:
    statements: int
    occurrences: tuple[Occurrence, ...]
    signature: tuple[int, int]  # (hash of the whole normalised run, statements): the content, not the place

    @property
    def key(self) -> str:
        """Where the copies live, without line numbers, so the key survives edits elsewhere in the file."""
        return " | ".join(sorted(f"{o.path}::{o.scope}" for o in self.occurrences))


@dataclass
class _FileStreams:
    path: str
    streams: list[_Stream]


def tokenise(path: str, source: str) -> _FileStreams | None:
    try:
        return _FileStreams(path, _streams(ast.parse(source, filename=path)))
    except (SyntaxError, ValueError, RecursionError):
        return None


def find_clones(files: Iterable[_FileStreams], min_statements: int = MIN_STATEMENTS) -> list[Clone]:
    """Every maximal duplicated run of at least `min_statements` statements, biggest first. Runs that sit wholly inside
    a bigger duplicate are left out. Occurrences within one stream may not overlap."""
    k = min_statements
    flat: list[tuple[str, _Stream, int]] = []  # (path, stream, offset of the stream's first token in the global index)
    groups: dict[tuple[int, ...], list[int]] = {}
    base = 0
    for fs in files:
        for st in fs.streams:
            n = len(st.tok)
            flat.append((fs.path, st, base))
            for i in range(n - k + 1):
                groups.setdefault((st.hdr[i], *st.tok[i + 1 : i + k]), []).append(base + i)
            base += n
    starts = [b for _, _, b in flat]

    kept: dict[int, tuple[int, ...]] = {}  # window start -> the starts of its (non-overlapping) group; equal groups compare equal
    for key, positions in groups.items():
        if len(positions) < MIN_COPIES:
            continue
        chosen: list[int] = []
        for p in positions:  # ascending, because streams were visited in order
            if not chosen or p >= chosen[-1] + k:
                chosen.append(p)
        if len(chosen) < MIN_COPIES:
            continue
        group = tuple(chosen)
        for p in chosen:
            kept[p] = group

    def locate(p: int) -> tuple[int, int]:
        """(index of the stream holding global token `p`, its offset in that stream)."""
        si = bisect_right(starts, p) - 1
        return si, p - starts[si]

    # a run: consecutive windows whose groups move together by one statement
    runs: list[tuple[int, int, tuple[int, ...]]] = []  # (first window start, extra statements, group)
    current: tuple[int, int, tuple[int, ...]] | None = None
    for p in sorted(kept):
        group = kept[p]
        if current is not None and p == current[0] + current[1] + 1:  # the window before it is in `kept`: the run's last
            if tuple(q + 1 for q in kept[p - 1]) == group:
                current = (current[0], current[1] + 1, current[2])
                continue
        if current is not None:
            runs.append(current)
        current = (p, 0, group)
    if current is not None:
        runs.append(current)

    clones: list[Clone] = []
    covers: dict[int, list[tuple[int, int]]] = {}  # stream index -> [(first token, last token)] of bigger clones so far
    for first, extra, group in sorted(runs, key=lambda r: -r[1]):
        size = k + extra
        spans = [locate(q) for q in group]
        if all(_covered(covers, si, off, off + size - 1) for si, off in spans):
            continue
        occs = []
        for si, off in spans:
            path, st, _b = flat[si]
            covers.setdefault(si, []).append((off, off + size - 1))
            occs.append(Occurrence(path, st.scope, st.line[off], st.end[off + size - 1]))
        si, off = locate(first)
        st = flat[si][1]
        clones.append(Clone(size, tuple(occs), (hash((st.hdr[off], *st.tok[off + 1 : off + size])), size)))
    clones.sort(key=lambda c: (-c.statements, c.key))
    return clones


def _covered(covers: dict[int, list[tuple[int, int]]], si: int, lo: int, hi: int) -> bool:
    return any(a <= lo and hi <= b for a, b in covers.get(si, ()))


# ---------------------------------------------------------------------------
# Repository plumbing
# ---------------------------------------------------------------------------


def _git(root: Path, *args: str) -> str | None:
    try:
        run = subprocess.run(["git", *args], cwd=root, capture_output=True, text=True, check=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return None
    return run.stdout


def repo_python_files(root: Path, only: Sequence[str] = (), include_tests: bool = False) -> list[str]:
    """Python files of the repository as paths relative to `root`: the tracked and the untracked-but-not-ignored ones
    (a new file is exactly what a hook wants to see), or a directory walk outside a git checkout."""
    listed = _git(root, "ls-files", "-z", "--cached", "--others", "--exclude-standard")
    if listed is None:
        names = [p.relative_to(root).as_posix() for p in root.rglob("*.py")]
    else:
        names = [p for p in listed.split("\0") if p]
    return sorted(n for n in set(names) if _wanted(n, only, include_tests) and (root / n).is_file())


def _wanted(name: str, only: Sequence[str], include_tests: bool) -> bool:
    if not name.endswith(".py"):
        return False
    parts = name.split("/")
    if SKIP_DIRS.intersection(parts[:-1]):
        return False
    if only and not any(name == o or name.startswith(o.rstrip("/") + "/") for o in only):
        return False
    if not include_tests:
        base = parts[-1]
        if TEST_DIRS.intersection(parts[:-1]) or base.startswith("test_") or base.endswith("_test.py") or base == "conftest.py":
            return False
    return True


def _read(root: Path, name: str) -> str | None:
    try:
        return (root / name).read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return None


def tokenise_repo(root: Path, names: Sequence[str]) -> list[_FileStreams]:
    out = []
    for n in names:
        text = _read(root, n)
        fs = tokenise(n, text) if text is not None else None
        if fs is not None:
            out.append(fs)
    return out


def scan_repo(root: Path, min_statements: int = MIN_STATEMENTS, only: Sequence[str] = (), include_tests: bool = False) -> list[Clone]:
    root = Path(root)
    return find_clones(tokenise_repo(root, repo_python_files(root, only, include_tests)), min_statements)


def new_clones_in_file(root: Path, name: str, min_statements: int = MIN_STATEMENTS, include_tests: bool = False) -> list[Clone]:
    """Clones with a copy in `name` (relative to `root`) that were not already in the committed version of `name`."""
    root = Path(root)
    if not _wanted(name, (), include_tests):
        return []
    names = repo_python_files(root, (), include_tests)
    if name not in names:
        return []
    files = tokenise_repo(root, names)
    mine = [c for c in find_clones(files, min_statements) if any(o.path == name for o in c.occurrences)]
    if not mine:
        return []
    old_text = _git(root, "show", f"HEAD:{name}")
    old = tokenise(name, old_text) if old_text else None
    before: set[tuple[int, int]] = set()
    if old is not None:
        swapped = [old if f.path == name else f for f in files]
        before = {c.signature for c in find_clones(swapped, min_statements) if any(o.path == name for o in c.occurrences)}
    return [c for c in mine if c.signature not in before]


# ---------------------------------------------------------------------------
# Baseline
# ---------------------------------------------------------------------------


def load_baseline(path: Path) -> dict[str, dict]:
    """`key -> {"statements": n, "reason": str}`; a missing file is an empty baseline."""
    try:
        raw = json.loads(Path(path).read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {}
    return {e["key"]: e for e in raw["duplicates"]}


def _biggest(clones: Sequence[Clone]) -> dict[str, Clone]:
    """The biggest clone of each key: a baseline entry is one place, however many runs it holds."""
    biggest: dict[str, Clone] = {}
    for c in clones:
        if c.key not in biggest or c.statements > biggest[c.key].statements:
            biggest[c.key] = c
    return biggest


def check_baseline(clones: Sequence[Clone], baseline: Mapping[str, Mapping]) -> list[str]:
    """Problems, as sentences: a duplicate not in the baseline, one that has grown, an entry whose duplicate is gone,
    an entry without a reason. Empty means the repository is no worse than the baseline."""
    biggest = _biggest(clones)
    problems = []
    for key, c in sorted(biggest.items()):
        entry = baseline.get(key)
        where = "; ".join(str(o) for o in c.occurrences)
        if entry is None:
            problems.append(f"new duplicate of {c.statements} statements ({where}): reuse the existing code, or add a baseline entry with a reason")
        elif c.statements > entry["statements"]:
            problems.append(f"duplicate grew from {entry['statements']} to {c.statements} statements ({where})")
    for key, entry in sorted(baseline.items()):
        if key not in biggest:
            problems.append(f"baseline entry is stale, delete it (the duplicate is gone): {key}")
        if not str(entry.get("reason", "")).strip():
            problems.append(f"baseline entry has no reason: {key}")
    return problems


def write_baseline(path: Path, clones: Sequence[Clone], min_statements: int, previous: Mapping[str, Mapping] | None = None) -> int:
    previous = previous or {}
    entries = [
        {"key": k, "statements": c.statements, "reason": previous.get(k, {}).get("reason", DEFAULT_REASON)}
        for k, c in sorted(_biggest(clones).items())
    ]
    body = ",\n".join("  " + json.dumps(e) for e in entries)
    Path(path).write_text(f'{{\n "min_statements": {min_statements},\n "duplicates": [\n{body}\n ]\n}}\n', encoding="utf-8")
    return len(entries)


# ---------------------------------------------------------------------------
# Command line
# ---------------------------------------------------------------------------


def _describe(c: Clone, focus: str | None = None) -> str:
    mine = [o for o in c.occurrences if o.path == focus] if focus else list(c.occurrences[:1])
    others = [o for o in c.occurrences if o not in mine] or [o for o in c.occurrences if o is not mine[0]]
    return f"{', '.join(map(str, mine))}  duplicates  {', '.join(map(str, others))}  ({c.statements} statements)"


def main(argv: Sequence[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Find copied code (see the module docstring).")
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("scan", "baseline"):
        p = sub.add_parser(name)
        p.add_argument("root", type=Path)
        p.add_argument("--only", action="append", default=[], help="a directory or file to read (repeatable)")
        p.add_argument("--include-tests", action="store_true")
        p.add_argument("--min", type=int, default=MIN_STATEMENTS, dest="min_statements")
        if name == "baseline":
            p.add_argument("--baseline", type=Path, required=True)
            p.add_argument("--write", action="store_true")
    e = sub.add_parser("edit")
    e.add_argument("file", type=Path)
    e.add_argument("--root", type=Path)
    e.add_argument("--min", type=int, default=MIN_STATEMENTS, dest="min_statements")
    e.add_argument("--include-tests", action="store_true")
    e.add_argument("--exit-zero", action="store_true")
    a = ap.parse_args(argv)

    if a.cmd == "scan":
        clones = scan_repo(a.root, a.min_statements, a.only, a.include_tests)
        for c in clones:
            print(_describe(c))
        print(f"{len(clones)} duplicated block(s) of {a.min_statements}+ statements", file=sys.stderr)
        return 0
    if a.cmd == "baseline":
        clones = scan_repo(a.root, a.min_statements, a.only, a.include_tests)
        if a.write:
            n = write_baseline(a.baseline, clones, a.min_statements, load_baseline(a.baseline))
            print(f"wrote {n} entries to {a.baseline}")
            return 0
        problems = check_baseline(clones, load_baseline(a.baseline))
        print("\n".join(problems))
        return 1 if problems else 0

    target = a.file.resolve()
    root = a.root.resolve() if a.root else None
    if root is None:
        top = _git(target.parent, "rev-parse", "--show-toplevel") if target.parent.is_dir() else None
        if not top:
            return 0
        root = Path(top.strip()).resolve()
    try:
        name = target.relative_to(root).as_posix()
    except ValueError:
        return 0
    found = new_clones_in_file(root, name, a.min_statements, a.include_tests)
    for c in found:
        print(_describe(c, name))
    return 1 if found and not a.exit_zero else 0


if __name__ == "__main__":
    raise SystemExit(main())
