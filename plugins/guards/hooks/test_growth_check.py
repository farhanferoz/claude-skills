"""Test-growth check for `git commit` (called by commit_provenance_guard.sh, PreToolUse Bash).

A commit that adds tests must say why: a line `Tests: +N, <the defect the new tests catch that no existing test
does>` in its message. Owner, 2026-10-18: test proliferation "is just a complete waste of time"; it kept recurring
in every project because each task adds tests and nothing ever counts the total. The check fires only on a commit
whose tests grow, so it costs nothing on the others.

What counts: test functions in test files (Python `def test_`, Go `func Test`, JS/TS `it(`/`test(` in
*.test.* / *.spec.*, bats `@test`), against the commit being built on (HEAD, or HEAD's parent for --amend), over
the files the commit will include, each read as the commit will take it (owner, 2026-11-21: a commit that names
its files was charged for another session's uncommitted tests in files it does not include):
  - pathspecs given (`git commit -- <paths>`, `git commit <paths>`): only the changed files they match (exact path,
    directory, glob, `.`), from the working tree; `-i/--include` adds the staged files (from the index);
  - `-a/--all`: every changed tracked file, from the working tree;
  - otherwise: the staged files, from the index.
The guard runs before the command, so a `git add` earlier in the same command has not happened yet: the files it
takes in (by path, glob, directory, `.`, -A/--all, -u) join the set, from the working tree. An untracked file counts
only when the same command `git add`s it (owner, 2026-11-03). A command that cannot be parsed counts the whole working
tree (it over-counts rather than misses). A merge in progress is skipped (its tests were justified on their branch).

Fail-open on anything unexpected. Escape hatch: CCLAUDE_TEST_GROWTH_MODE=observe (log only).
Log: $CLAUDE_CONFIG_DIR/test_growth_check.log, every decision, with the file set it counted over.
"""

from __future__ import annotations

import json
import os
import re
import fnmatch
import shlex
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime
from enum import StrEnum
from pathlib import Path

COMMIT = re.compile(r"(^|[;&|`(])\s*git\b[^;&|]*\scommit(\s|$)")
TESTS_LINE = re.compile(r"(^|[\s\"'])Tests:\s*\S")
COUNTERS: list[tuple[re.Pattern[str], re.Pattern[str]]] = [
    (re.compile(r"(^|/)(test_[^/]*|[^/]*_test)\.py$|(^|/)tests?/[^/]*\.py$"), re.compile(r"^\s*(async\s+)?def test_", re.M)),
    (re.compile(r"_test\.go$"), re.compile(r"^func Test", re.M)),
    (re.compile(r"\.(test|spec)\.[cm]?[jt]sx?$"), re.compile(r"^\s*(it|test)(\.each\([^)]*\))?\(", re.M)),
    (re.compile(r"\.bats$"), re.compile(r"^@test ", re.M)),
]


class FileSource(StrEnum):
    """Which set of files a decision counted over (logged)."""

    WHOLE_TREE = "whole-tree"
    PATHSPEC = "pathspec"
    ALL = "all"
    INDEX = "index"


@dataclass(frozen=True)
class FileSet:
    """The test files a commit will include; `worktree` are read from the working tree, the rest from the index."""

    sources: frozenset[FileSource]
    files: tuple[str, ...]
    worktree: frozenset[str]


@dataclass(frozen=True)
class Growth:
    total: int
    grown: list[str]
    left_out: int  # untracked test files the command does not add
    sources: str


@dataclass(frozen=True)
class CommitArgs:
    all: bool
    include: bool
    pathspecs: tuple[str, ...]


def git(repo: Path, *args: str) -> str | None:
    done = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, check=False)
    return done.stdout if done.returncode == 0 else None


def names(repo: Path, *args: str) -> list[str]:
    """Paths printed by a `git <listing> ...` run NUL-separated (`-z` goes before any `--`)."""
    return [p for p in (git(repo, args[0], "-z", *args[1:]) or "").split("\0") if p]


def is_test_file(path: str) -> bool:
    return any(name.search(path) for name, _ in COUNTERS)


def count(path: str, text: str | None) -> int:
    if not text:
        return 0
    return next((len(fn.findall(text)) for name, fn in COUNTERS if name.search(path)), 0)


def repo_of(cmd: str, cwd: str) -> Path:
    """The directory the commit runs in: `git -C <dir>`, else a leading `cd <dir> &&`, else the session's."""
    try:
        words = shlex.split(cmd, posix=True)
    except ValueError:
        words = cmd.split()
    base = Path(cwd)
    if words[:1] == ["cd"] and len(words) > 1:
        base = base / Path(words[1]).expanduser()
    for i, word in enumerate(words[:-1]):
        if word == "git" and words[i + 1] == "-C" and i + 2 < len(words):
            return base / Path(words[i + 2]).expanduser()
    return base


def message(cmd: str, repo: Path) -> str:
    """The command (holds -m and heredoc text) plus a named -F/--file message file."""
    found = re.search(r"(?:-F|--file=?)\s*([^\s;&|]+)", cmd)
    if found and found.group(1) != "-":
        path = Path(found.group(1)).expanduser()
        path = path if path.is_absolute() else repo / path
        try:
            return cmd + "\n" + path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            pass
    return cmd


GIT_OPTS_WITH_VALUE = {"-C", "-c", "--git-dir", "--work-tree", "--namespace"}
ADD_ALL = {"-A", "--all"}
ADD_TRACKED = {"-u", "--update"}
ENV_ASSIGNMENT = re.compile(r"^\w+=")
# A heredoc body (kept out of tokenising: a quote in its text would make the whole command unparseable).
HEREDOC = re.compile(r"(<<-?[ \t]*(['\"]?)(\w+)\2[^\n]*\n).*?^[ \t]*\3[ \t]*$\n?", re.M | re.S)
# Facts from `git commit -h`: the options that take a separate value, and the short ones whose value may be attached.
COMMIT_SHORT_VALUE = set("mFcCt")
COMMIT_SHORT_OPTIONAL = set("Su")
COMMIT_LONG_VALUE = {"--message", "--file", "--reuse-message", "--reedit-message", "--author", "--date", "--fixup",
                     "--squash", "--trailer", "--template", "--cleanup"}


def segments(cmd: str) -> list[list[str]] | None:
    """The command split at `;`, `&&`, `||`, `|`, `&`, parentheses, without redirections; None when it cannot be parsed."""
    try:
        lexer = shlex.shlex(HEREDOC.sub(r"\1", cmd), posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        words = list(lexer)
    except ValueError:
        return None
    out: list[list[str]] = []
    segment: list[str] = []
    skip = False
    for word in [*words, ";"]:
        chars = set(word)
        if skip:
            skip = False
        elif word and chars <= set("<>&|") and chars & set("<>"):  # a redirection: drop it, its target and a `2` before it
            if segment[-1:] and segment[-1].isdigit():
                segment.pop()
            skip = True
        elif word and chars <= set("&|;()"):
            if segment:
                out.append(segment)
            segment = []
        else:
            segment.append(word)
    return out


def git_args(segment: list[str], verb: str) -> list[str] | None:
    """The words after `git [global options] <verb>` when the segment is that git command, else None."""
    i = 0
    while i < len(segment) and ENV_ASSIGNMENT.match(segment[i]):
        i += 1
    if segment[i:i + 1] != ["git"]:
        return None
    i += 1
    while i < len(segment) and segment[i].startswith("-"):
        i += 2 if segment[i] in GIT_OPTS_WITH_VALUE else 1
    return segment[i + 1:] if segment[i:i + 1] == [verb] else None


def add_pathspecs(cmd: str) -> list[str] | None:
    """Pathspecs of every `git add` in the command (`ADD_ALL`/`ADD_TRACKED` markers for -A/--all, -u/--update);
    None when the command cannot be parsed."""
    parsed = segments(cmd)
    if parsed is None:
        return None
    specs: list[str] = []
    for segment in parsed:
        args = git_args(segment, "add")
        if args is not None:
            cut = args.index("--") if "--" in args else len(args)
            specs += [a for a in args[:cut] if a in ADD_ALL | ADD_TRACKED or not a.startswith("-")] + args[cut + 1:]
    return specs


def parse_commit(args: list[str]) -> CommitArgs | None:
    """-a/-i flags and pathspecs of one `git commit`, skipping option values; None when they cannot be read."""
    every = include = False
    specs: list[str] = []
    i = 0
    while i < len(args):
        arg = args[i]
        i += 1
        if arg == "--":
            specs += args[i:]
            break
        if arg.startswith("--"):
            name, equals, _ = arg.partition("=")
            if name == "--pathspec-from-file":
                return None
            i += 1 if name in COMMIT_LONG_VALUE and not equals else 0
            every |= name == "--all"
            include |= name == "--include"
        elif arg.startswith("-") and arg != "-":
            for pos, flag in enumerate(arg[1:], 1):
                if flag in COMMIT_SHORT_VALUE:
                    i += 1 if pos == len(arg) - 1 else 0
                    break
                if flag in COMMIT_SHORT_OPTIONAL:
                    break
                every |= flag == "a"
                include |= flag == "i"
        else:
            specs.append(arg)
    if any(spec.startswith(":") for spec in specs):  # pathspec magic is not matched here
        return None
    return CommitArgs(every, include, tuple(specs))


def commit_invocations(cmd: str) -> list[CommitArgs] | None:
    """Every `git commit` in the command; None when the command cannot be parsed or holds none."""
    parsed = segments(cmd)
    if parsed is None:
        return None
    found: list[CommitArgs] = []
    for segment in parsed:
        args = git_args(segment, "commit")
        if args is not None:
            one = parse_commit(args)
            if one is None:
                return None
            found.append(one)
    return found or None


def matching(files: list[str], specs: list[str], repo: Path, root: Path) -> list[str]:
    """The files a list of pathspecs (relative to `repo`) selects: exact path, directory prefix, glob or `.`."""
    rels = [os.path.relpath((repo / spec).resolve(), root.resolve()) for spec in specs]
    return [path for path in files
            if any(rel == "." or path == rel or path.startswith(rel + "/") or fnmatch.fnmatch(path, rel) for rel in rels)]


def added_files(files: list[str], cmd: str, repo: Path, root: Path, untracked: bool) -> list[str]:
    """The files the command's own `git add` takes in (all of them when the command cannot be parsed)."""
    specs = add_pathspecs(cmd)
    if specs is None or ADD_ALL & set(specs) or (not untracked and ADD_TRACKED & set(specs)):
        return files
    return matching(files, [spec for spec in specs if spec not in ADD_TRACKED], repo, root)


def select(root: Path, repo: Path, base: str, cmd: str, amend: bool) -> tuple[FileSet, int]:
    """The test files the commit will include and how each is read, and the untracked test files left out."""
    tracked = [p for p in names(root, "diff", "--name-only", base, "--") if is_test_file(p)]
    staged = [p for p in names(root, "diff", "--cached", "--name-only", base, "--") if is_test_file(p)]
    untracked = [p for p in names(root, "ls-files", "--others", "--exclude-standard") if is_test_file(p)]
    new = added_files(untracked, cmd, repo, root, untracked=True)
    invocations = commit_invocations(cmd)
    if invocations is None:
        everything = tracked + new
        whole = FileSet(frozenset({FileSource.WHOLE_TREE}), tuple(dict.fromkeys(everything)), frozenset(everything))
        return whole, len(untracked) - len(new)
    in_head = [p for p in names(root, "diff", "--name-only", "HEAD^", "HEAD", "--") if is_test_file(p)] if amend else []
    files: list[str] = []
    worktree: list[str] = []
    sources: set[FileSource] = set()
    for one in invocations:
        if one.pathspecs:
            sources.add(FileSource.PATHSPEC)
            picked = matching(tracked + new, list(one.pathspecs), repo, root)
            files += picked + in_head + (staged if one.include else [])
            worktree += picked
        elif one.all:
            sources.add(FileSource.ALL)
            files += tracked + new
            worktree += tracked + new
        else:
            sources.add(FileSource.INDEX)
            taken = added_files(tracked, cmd, repo, root, untracked=False) + new
            files += staged + taken
            worktree += taken
    return FileSet(frozenset(sources), tuple(dict.fromkeys(files)), frozenset(worktree)), len(untracked) - len(new)


def growth(repo: Path, amend: bool, cmd: str = "") -> Growth:
    """Tests added over the commit being built on, in the files the commit will include."""
    top = (git(repo, "rev-parse", "--show-toplevel") or "").strip()
    if not top or (Path(top) / ".git" / "MERGE_HEAD").exists():
        return Growth(0, [], 0, "merge-or-no-repo")
    root = Path(top)
    base = "HEAD^" if amend else "HEAD"
    if git(root, "rev-parse", "--verify", "-q", base) is None:
        base = (git(root, "hash-object", "-t", "tree", "/dev/null") or "").strip()
    chosen, left_out = select(root, repo, base, cmd, amend)
    total, grown = 0, []
    for path in chosen.files:
        if path in chosen.worktree:
            file = root / path
            text = file.read_text(encoding="utf-8", errors="replace") if file.is_file() else None
        else:
            text = git(root, "show", f":{path}")
        delta = count(path, text) - count(path, git(root, "show", f"{base}:{path}"))
        total += delta
        if delta > 0:
            grown.append(f"{path} +{delta}")
    return Growth(total, grown, left_out, "+".join(sorted(chosen.sources)))


def main() -> int:
    data = json.loads(sys.stdin.read() or "{}")
    cmd = (data.get("tool_input") or {}).get("command") or ""
    if not COMMIT.search(cmd):
        return 0
    repo = repo_of(cmd, data.get("cwd") or os.getcwd())
    found = growth(repo, amend="--amend" in cmd, cmd=cmd)
    justified = bool(TESTS_LINE.search(message(cmd, repo)))
    verdict = "ALLOW" if found.total <= 0 or justified else os.environ.get("CCLAUDE_TEST_GROWTH_MODE", "BLOCK").upper()
    log = Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude") / "test_growth_check.log"
    with log.open("a", encoding="utf-8") as out:
        out.write(f"{datetime.now().isoformat(timespec='seconds')} {verdict} repo={repo} tests={found.total:+d} "
                  f"untracked_test_files_not_added={found.left_out} files={found.sources}\n")
    if verdict != "BLOCK":
        return 0
    sys.stderr.write(
        f"TEST GROWTH: this commit adds {found.total} test(s) ({'; '.join(found.grown[:6])}) and its message does not say why.\n"
        "Owner rule (~/.claude/rules/coding-standards.md, section 6 Tests): first fold each new check into an existing\n"
        "test of the same behaviour, and delete any new test that only repeats one. If tests still grow, add a line\n"
        "to the message: `Tests: +N, <the defect each new test catches that no existing test does>`.\n"
    )
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:  # noqa: BLE001 - fail open: a broken check must never block a commit
        sys.exit(0)
