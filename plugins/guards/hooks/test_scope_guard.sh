#!/usr/bin/env bash
# PreToolUse(Bash) — a WHOLE test suite must not be run for a SMALL change.
#
# THE SYMPTOM (user-reported 2026-08-11, recurring across sessions): "other
# sessions are happily running test suites that take over an hour". The
# first-person case the same day: a change touching two files, whose two
# relevant suites had ALREADY been run green, followed by `./tests/ci-local.sh`
# — 400 tests, ~30 min, for nothing. Committed by the author of the register
# item that names this exact problem (issue 14), minutes after quoting it.
#
# WHY A HOOK AND NOT A RULE. Issue 14 has been written down, with prior art
# (pytest-testmon, Jest --changedSince, Bazel), since 2026-08-10. A written rule
# is precisely what failed: it was read, quoted, and then walked past. Per the
# ratified placement rule — mechanical rule → blocking hook — this is the
# mechanical shadow of "run only the relevant tests".
#
# WHAT IT KEYS ON — FACTS, NOT PHRASING. Both foreground guards were once walked
# past because they keyed on how a command was *worded*. This one measures:
#   1. the command invokes a test runner, and selects NO subset (no test FILE
#      among its arguments, no filter flag). A script argument is opened and its
#      CONTENT checked for the same, so an aggregate wrapper like ci-local.sh is
#      caught without ever matching on its name. A "file.py::test_name" node id
#      counts as a selection (the id is stripped before the filesystem is asked),
#      and so does a named test FILE that does not exist yet -- both were denied
#      as whole-suite runs until 2026-09-11, the second telling a session to
#      "narrow" a command that was already the narrowest form that exists. A
#      DIRECTORY argument such as `pytest tests/` still means everything.
#   2. `git status` says the working tree touches a specific set of files;
#   3. the repo's test files are enumerated, and the RELEVANT ones are those
#      that are themselves changed or that literally mention a changed file's
#      name. This is a grep result, not a guess about what "relates" to what.
# It denies only when all three hold AND the relevant set is a strict, non-empty
# subset — i.e. only when it can name the cheaper command the model should run
# instead. No selection to offer → allow. Nothing changed → allow. That is the
# unconfigured default path: on a clean tree, or in a repo with no tests, this
# guard is silent and allows everything.
#
# SCOPE: main thread AND subagents. A dispatched worker burning an hour on an
# unrelated suite is the same waste, and the refusal hands it the exact command
# to run instead, so it is never left stuck.
#
# MODES: CCLAUDE_TESTSCOPE_MODE = enforce (default) | observe | off.
#   The full suite is legitimate before a release — that is what `off` is for:
#   CCLAUDE_TESTSCOPE_MODE=off ./tests/ci-local.sh
# TUNING: CCLAUDE_TESTSCOPE_MIN_FILES (default 5) — suites smaller than this are
#   never worth splitting, so they are allowed whole.
# RELEASES: CCLAUDE_TESTSCOPE_RANGE, or a `.claude-testscope-range` file at the
#   repo root holding one line like `b24be2d..ee7fe8c`. A release ships COMMITTED
#   history, which `git status` cannot see and which branch-vs-base scores as
#   empty once merged — so relevance was computed from whatever unrelated edits
#   happened to be lying in the tree. The range is UNIONED into the changed set,
#   never substituted for it. It can only widen the relevant-test set and make a
#   refusal more accurate; it is NOT a bypass, and is not the `off` hatch, which
#   remains human-only and unadvertised at the moment of refusal (see below).
# RE-RUN MEMORY (owner 2026-10-24): besides a whole-suite run, a test selection that
#   already PASSED on byte-identical dependencies is refused. PostToolUse records an
#   exit-0 run (PostToolUseFailure forgets the key); PreToolUse refuses the repeat.
#   Key = repo + selected files + filter flags + a hash of what the files can reach
#   (see "re-run memory" in the code). Record: ~/.claude/state/test_rerun/<repo>.json,
#   pruned after 7 days. A repeat that is truly needed carries TEST_RERUN_OK=<reason>
#   in the command; it is logged (RERUN-OVERRIDE). Foreground runs only are recorded
#   and refused: background and slurm-submitted lines carry no exit code at hook time.
#   A selection of more than 8 files, none of them a test of a changed source file
#   (tests/test_<module>.py for <module>.py), gets a WARNING naming the ones that are.
#   Registered under PreToolUse, PostToolUse and PostToolUseFailure (all matcher Bash);
#   the event is read from the payload's hook_event_name.
# BOUNDED COST (2026-10-24, after an unbounded loop grew three hook children to 34, 23
#   and 10 GB): the python child sets RLIMIT_AS 1 GiB and a 6 s alarm (both exit 0 =
#   allow), the closure walk is bounded by files, bytes and wall clock and returns
#   "unknown" (= allow, no record) when over, data files over 2 MB are fingerprinted
#   by size+mtime and never read, and the payload reaches python on fd 3 because one
#   argv string is capped at 128 KB. A Post event looks only at the command, for a
#   runner name, before anything else is spent. Overrides for the self-test:
#   CCLAUDE_TESTSCOPE_HARD_AS_MB, CCLAUDE_TESTSCOPE_HARD_WALL_S, CCLAUDE_TESTSCOPE_MAX_DEPS.
# FAIL-OPEN ALWAYS: any parse error, missing git, unreadable file or scan that
# exceeds the time budget allows the command. A guard that breaks a session is
# worse than the waste it prevents.

payload="$(cat 2>/dev/null || true)"

# FAST PATH — this hook runs on EVERY Bash call, and python3 startup alone is
# ~60 ms (measured 2026-08-11), on top of four other PreToolUse guards. If the
# payload mentions no test-runner token and no shell script, there is nothing
# this guard could possibly deny, so exit before paying for an interpreter.
# It is a PRE-FILTER, never the decision: it uses the same keywords the runner
# table does, so it cannot skip a case the analysis would have caught, and a
# miss here is a missed block — never a wrong one.
# POST EVENTS (the re-run record) concern only a file-selecting RUNNER line, and their
# payload carries the whole tool output (megabytes): scan just the tool_input part,
# for runner names only. Output text such as "available" (from `free`) once matched
# `*ava*` below and woke the interpreter for nothing.
head="${payload:0:20000}"            # globbing a multi-MB tool output costs 0.3 s
case "$head" in
    *'"hook_event_name":"Post'*|*'"hook_event_name": "Post'*)
        scan="${head#*\"tool_input\"}"
        scan="${scan%%\"tool_response\"*}"
        case "$scan" in
            *pytest*|*py.test*|*bats*|*jest*|*vitest*|*mocha*|*karma*|*rspec*|*phpunit*\
            |*ctest*|*tox*|*nox*|*gradle*|*mvn*|*"-m unittest"*|*" ava "*) ;;
            *) exit 0 ;;
        esac ;;
esac
case "$payload" in
    *pytest*|*py.test*|*bats*|*jest*|*vitest*|*mocha*|*ava*|*karma*|*rspec*\
    |*minitest*|*phpunit*|*ctest*|*tox*|*nox*|*gradle*|*mvn*|*.sh*\
    |*" test"*|*"test:"*|*"test\""*|*"-m unittest"*\
    |*--selftest*|*--self-test*) ;;
    *) exit 0 ;;
esac
# `--selftest` added 2026-08-11 to OBSERVE, not to block. That flag is how
# a research repository runs its checks, and because it matched nothing
# above, this guard never even started there — inert from the day it shipped.
# Deliberately NOT wired into the deny path: the visible complaint there is
# REPETITION (the same check re-run with nothing changed), and three attempts to
# measure that from transcript text were each wrong in the same direction, so no
# rule is being written from them. Admitting the flag makes those runs show up in
# the log; the repetition question gets settled from that log, or not at all.

# The payload goes in on fd 3, not as an argument: one argument is capped at 128 KB and
# a Post payload carries the whole tool output ("Argument list too long", measured).
python3 - 3<<<"$payload" <<'PY'
import json
import os
import re
import resource
import shlex
import signal
import subprocess
import sys
import time

# HARD CAPS (2026-10-24: an unbounded loop in this guard grew three hook children to
# 34, 23 and 10 GB on a shared machine). Whatever goes wrong below, the process is
# bounded in memory and in time, and a guard that dies allows the command.
try:                                # env overrides exist for the self-test
    HARD_AS_BYTES = int(os.environ.get("CCLAUDE_TESTSCOPE_HARD_AS_MB", "1024")) << 20
    HARD_WALL_S = int(os.environ.get("CCLAUDE_TESTSCOPE_HARD_WALL_S", "6"))
except ValueError:
    HARD_AS_BYTES, HARD_WALL_S = 1 << 30, 6


def _give_up(*_args):
    os._exit(0)


try:
    resource.setrlimit(resource.RLIMIT_AS, (HARD_AS_BYTES, HARD_AS_BYTES))
except (ValueError, OSError):
    pass
signal.signal(signal.SIGALRM, _give_up)
signal.alarm(HARD_WALL_S)
sys.excepthook = _give_up                  # incl. MemoryError

MODE = os.environ.get("CCLAUDE_TESTSCOPE_MODE", "enforce")
if MODE == "off":
    sys.exit(0)
try:
    MIN_FILES = int(os.environ.get("CCLAUDE_TESTSCOPE_MIN_FILES", "5"))
except ValueError:
    MIN_FILES = 5

BUDGET_S = 3.0                      # whole-guard wall clock; over it, allow
MAX_TEST_FILES = 400                # enumeration cap; over it, allow
MAX_READ_BYTES = 400_000            # per test file, when grepping for mentions
START = time.time()

try:
    with os.fdopen(3) as _fh:
        payload = json.loads(_fh.read() or "{}")
except (ValueError, OSError):
    sys.exit(0)

cmd = ((payload.get("tool_input") or {}).get("command") or "").strip()
if not cmd:
    sys.exit(0)
cwd = payload.get("cwd") or os.getcwd()

# ---------------------------------------------------------------- test runners
# Naming a tool is a fact about the tool, not a guess about the wording. Each
# entry: the token that identifies the runner, and whether a bare invocation
# (no path argument at all) already means "everything".
RUNNERS = {
    "pytest": True, "py.test": True, "tox": True, "nox": True,
    "bats": False,                     # bats needs a path; a bare call is a usage error
    "jest": True, "vitest": True, "mocha": True, "ava": True, "karma": True,
    "rspec": True, "minitest": True, "phpunit": True,
    "ctest": True, "gradle": True, "mvn": True,
}
# Subcommand forms: the runner is two tokens.
RUNNER_PAIRS = {
    ("cargo", "test"), ("go", "test"), ("dotnet", "test"), ("swift", "test"),
    ("npm", "test"), ("yarn", "test"), ("pnpm", "test"), ("bun", "test"),
    ("npm", "run"), ("make", "test"), ("make", "check"),
    ("python", "-m"), ("python3", "-m"),
}
# A filter flag means the model already narrowed the run — never second-guess it.
FILTER_FLAGS = ("-k", "--filter", "--testNamePattern", "-t", "--grep", "-run",
                "--only", "--changed", "--changedSince", "--onlyChanged",
                "--last-failed", "--lf", "-e", "--name", "--test", "--example")

def _has_filter_flag(toks):
    """Has the caller already narrowed the run?

    `-m` is pytest's MARKER selector (`-m integration`, `-m "not slow"`) and is a genuine
    filter — but it is ALSO the `-m` in `python -m pytest`, which narrows nothing. Adding
    it to FILTER_FLAGS naively makes every `python -m pytest` look filtered and silently
    disables this whole guard, which is the D37 failure mode: partial coverage reading as
    full coverage. So `-m` counts ONLY when it does not directly follow a python
    interpreter. Verified both ways against a fixture repo before shipping.
    """
    for i, t in enumerate(toks):
        head = t.split("=")[0]
        if head == "-m":
            if i > 0 and os.path.basename(toks[i - 1]) in ("python", "python3"):
                continue                    # `python -m pytest` — not a filter
            return True
        if t in FILTER_FLAGS or head in FILTER_FLAGS:
            return True
    return False


TEST_NAME = re.compile(
    r"(^test_|_test\.|\.test\.|\.spec\.|^spec_|_spec\.|\.bats$|^Test.*\.java$)",
    re.IGNORECASE)
SKIP_DIRS = {".git", "node_modules", ".venv", "venv", "__pycache__", "target",
             "build", "dist", ".tox", ".mypy_cache", ".pytest_cache", "vendor",
             ".next", "coverage", "htmlcov", ".gradle", "Pods"}


def out_of_budget():
    return time.time() - START > BUDGET_S


def run(args, **kw):
    try:
        p = subprocess.run(args, cwd=cwd, capture_output=True, text=True,
                           timeout=2, **kw)
        return p.stdout if p.returncode == 0 else ""
    except Exception:
        return ""


def is_test_path(path):
    return bool(TEST_NAME.search(os.path.basename(path))) or \
        any(part in ("tests", "test", "spec", "__tests__")
            for part in path.split(os.sep))


def tokens_of(command):
    try:
        return shlex.split(command)
    except ValueError:
        return command.split()


SEGMENT_SPLIT = re.compile(r"\s*(?:\|\||&&|;|\||\n)\s*")
ENV_ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
WRAPPERS = {"sudo", "time", "nohup", "env", "command", "exec", "nice", "stdbuf",
            "timeout", "poetry", "uv", "pipenv", "npx", "bunx", "hatch", "rye"}
SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}
DURATION = re.compile(r"^\d+(?:\.\d+)?[smhd]?$")   # `timeout`'s positional args


def leading(toks):
    """The command actually being run: env assignments, wrappers and their own
    flags dropped. Restricting the whole analysis to THIS position is what keeps
    a command that merely NAMES a test path — `cat tests/ci-local.sh`, `git add
    tests/` — from being read as running it. Found by this guard blocking its
    own verification command, 2026-08-11."""
    i = 0
    while i < len(toks):
        t = toks[i]
        base = os.path.basename(t)
        if ENV_ASSIGN.match(t) or base in WRAPPERS:
            i += 1
            while i < len(toks) and toks[i].startswith("-"):
                i += 1
            # `timeout` takes POSITIONAL durations its flags don't cover, and
            # dropping only the flags left "10" looking like the command:
            # `timeout -k 10 900 python -m pytest -q` was read as running `10`
            # and allowed — a genuine whole-suite run, missed. Found 2026-08-11
            # by firing this guard against the real command shapes in
            # a research repository, which wraps its long runs in
            # `timeout`, rather than against the repo the guard was written in.
            if base == "timeout":
                while i < len(toks) and DURATION.match(toks[i]):
                    i += 1
            continue
        break
    return toks[i:]


def split_segments(command):
    """Split on shell operators, but NOT on ones inside quotes.

    `SEGMENT_SPLIT` alone cut `grep -E "a|bats|c"` into a segment whose leading
    token was `bats`, so a read-only grep was denied as a whole-suite run —
    live-fired against this guard twice on 2026-08-11, both times while trying to
    audit it. Quotes are tracked one character at a time; a `|`, `;` or `&&`
    inside them is data, not a pipeline.
    """
    segs, buf, quote, i = [], [], None, 0
    while i < len(command):
        ch = command[i]
        if quote:
            buf.append(ch)
            if ch == quote and command[i - 1: i] != "\\":
                quote = None
            i += 1
            continue
        if ch in "\"'":
            quote = ch
            buf.append(ch)
            i += 1
            continue
        two = command[i:i + 2]
        if two in ("&&", "||"):
            segs.append("".join(buf)); buf = []; i += 2; continue
        if ch == "\n" and buf and buf[-1] == "\\":
            # Line continuation, NOT a separator. `pytest \<newline>  tests/x.py` is one
            # command; splitting here left a segment of bare `pytest` with no file list, so
            # a properly narrowed run was denied as a whole-suite run. Live-fired against
            # this guard 2026-08-27 while running a single test file.
            buf.pop(); buf.append(" "); i += 1; continue
        if ch in ";|\n":
            segs.append("".join(buf)); buf = []; i += 1; continue
        buf.append(ch)
        i += 1
    segs.append("".join(buf))
    return segs


def find_runner(toks):
    """Index of the runner token in a segment's leading tokens, or None."""
    runner_at = None
    for i, t in enumerate(toks):
        if i > 1:                      # the runner leads the segment, or follows
            break                      # one subcommand token — never deeper
        base = os.path.basename(t)
        if base in RUNNERS:
            runner_at = i
            break
        if i + 1 < len(toks) and (base, toks[i + 1]) in RUNNER_PAIRS:
            # `python -m pytest` / `npm run test:all` — keep looking for the
            # real runner token, but treat the pair itself as a runner.
            if base in ("python", "python3") and toks[i + 1] == "-m":
                if i + 2 < len(toks) and os.path.basename(toks[i + 2]) in RUNNERS:
                    return i + 2
                continue
            if (base, toks[i + 1]) == ("npm", "run"):
                nxt = toks[i + 2] if i + 2 < len(toks) else ""
                if "test" not in nxt:
                    continue
            runner_at = i
            break
    return runner_at


def looks_like_whole_suite(command, depth=0):
    """True when the command RUNS a test runner and names no subset.

    Each `;`/`&&`/`|` segment is judged on its leading command only. A script in
    that position is opened and inspected with the same rule (once), so an
    aggregate wrapper is caught by what it does, not by what it is called."""
    if depth == 0:
        return any(_segment_is_whole_suite(seg, depth)
                   for seg in split_segments(command) if seg.strip())
    return _segment_is_whole_suite(command, depth)


def _segment_is_whole_suite(command, depth):
    toks = leading(tokens_of(command))
    if not toks:
        return False
    if os.path.basename(toks[0]) in SHELLS and len(toks) > 1:
        toks = [t for t in toks[1:] if not t.startswith("-")]   # `bash run.sh`
        if not toks:
            return False
    if _has_filter_flag(toks):
        return False

    runner_at = find_runner(toks)

    if runner_at is None:
        # Not a runner itself. If the LEADING token is a script that exists, look
        # inside it — one level, so an aggregate wrapper is judged by its content.
        # Leading only: an argument that merely names a script is not running it.
        if depth == 0:
            for t in toks[:1]:
                if t.startswith("-"):
                    continue
                cand = t if os.path.isabs(t) else os.path.join(cwd, t)
                # INSIDE THE REPO ONLY. This whole analysis is about THIS repo's
                # suite, so a script living outside it cannot be the aggregate
                # wrapper for it — and inspecting one produces false denials:
                # measured 2026-08-11, `bash ~/.claude/hooks/test_scope_guard.sh`
                # was itself denied as a "whole test suite", because a guard whose
                # source lists every runner name reads like a wrapper that invokes
                # them. Any tooling script that merely MENTIONS runners hit this.
                # Heredocs, `python -c` snippets and greps were never affected —
                # `leading()` already handles those.
                try:
                    inside = os.path.realpath(cand).startswith(
                        os.path.realpath(root) + os.sep)
                except (OSError, NameError):
                    inside = False
                if not inside:
                    continue
                if os.path.isfile(cand) and os.access(cand, os.X_OK):
                    try:
                        with open(cand, "rb") as fh:
                            head = fh.read(2)
                            # A TEXT script only. This guard runs on every Bash
                            # call, and shlex-splitting the "lines" of a large
                            # binary is both pointless and slow.
                            if head != b"#!":
                                continue
                            body = (head + fh.read(MAX_READ_BYTES)).decode("utf-8", "replace")
                    except OSError:
                        continue
                    for line in body.splitlines()[:400]:
                        if out_of_budget():
                            return False
                        line = line.strip()
                        if line.startswith("#") or not line:
                            continue
                        if looks_like_whole_suite(line, depth=1):
                            return True
        return False

    # A runner IS present. Does anything after it narrow the run to a subset?
    for t in toks[runner_at + 1:]:
        if t.startswith("-"):
            continue
        if "..." in t:                      # go's ./... — explicitly everything
            return True
        # pytest/jest node ids select ONE test inside a file ("file.py::test_x",
        # "file.js -t name"). Measured false positive 2026-09-11 (a product project): a
        # single-node-id run was denied as a whole-suite run and told to "narrow"
        # a command that was already the narrowest form possible. Strip the id
        # before asking the filesystem -- the selection is narrower, never broader.
        base = t.split("::", 1)[0]
        # A variable or command substitution names a selection this guard cannot
        # resolve without executing it (`T=tests/a.py::t; <runner> -q "$T"`, a
        # `for f in ...; do bats "$f"` loop). Reading it as "everything" refused
        # single-test runs (2026-10-28); fail open, like every other unresolvable
        # input here.
        if "$" in t or "`" in t:
            return False
        base = os.path.expanduser(base)
        cand = base if os.path.isabs(base) else os.path.join(cwd, base)
        if os.path.isfile(cand) and is_test_path(base):
            return False                    # a specific test file: already scoped
        if os.path.isfile(cand):
            return False                    # some other file: not our business
        # A named test FILE that is not on disk yet is still a selection, not
        # "everything": measured 2026-09-11 (a product project), a command that wrote a
        # new test file and immediately ran it was denied as a full-suite run.
        # Restricted to things that look like a test FILE -- a directory such as
        # `pytest tests/` must keep falling through to "everything" below.
        if base.endswith((".py", ".js", ".ts", ".jsx", ".tsx")) and is_test_path(base):
            return False
    return True                             # bare, or only directories → everything


def enumerate_tests(root):
    found = []
    for dirpath, dirnames, filenames in os.walk(root):
        # Skip vendored/submoduled repositories: a directory carrying its own
        # .git is a DIFFERENT project, and its tests are not this change's tests.
        # (Measured: without this, ccage's vendored bats framework contributed
        # 231 of 258 "test files".) A fact on disk, not a name we blacklisted.
        dirnames[:] = [d for d in dirnames
                       if d not in SKIP_DIRS and not d.startswith(".")
                       and not os.path.exists(os.path.join(dirpath, d, ".git"))]
        for fn in filenames:
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, root)
            if TEST_NAME.search(fn) and is_test_path(rel):
                found.append(rel)
                if len(found) > MAX_TEST_FILES or out_of_budget():
                    return None
    return found


def branch_changed_files(root):
    """What this BRANCH changed against its base, for when the tree is clean.

    THE DEFECT THIS FIXES (measured from this guard's own log, 2026-08-11):
    `ALLOW-cleantree  189 tests` appeared four times in a research repository
    while a 27-minute full suite ran. The guard measured only UNCOMMITTED changes,
    so on a merge or feature branch — where the work is committed and `git status`
    is empty — it concluded "nothing changed, no cheaper subset to name" and waved
    the whole suite through. Every branch workflow was a blind spot, which is why
    the guard had never denied a real run anywhere. The relevant diff there is
    branch-vs-base, not the dirty tree.
    """
    base = None
    for cand in ("origin/HEAD", "origin/main", "origin/master", "main", "master"):
        if run(["git", "rev-parse", "--verify", "--quiet", cand]):
            base = cand
            break
    if not base:
        return []
    merge_base = (run(["git", "merge-base", "HEAD", base]) or "").strip()
    if not merge_base:
        return []
    out = run(["git", "diff", "--name-only", merge_base, "HEAD"]) or ""
    return [p for p in (l.strip() for l in out.splitlines())
            if p and os.path.isfile(os.path.join(root, p))]


RANGE_FILE = ".claude-testscope-range"
RANGE_RE = re.compile(r"^[0-9A-Za-z._/@{}-]+\.\.\.?[0-9A-Za-z._/@{}-]+$")


def range_changed_files(root):
    """Files changed by a COMMIT RANGE in play but invisible to `git status`.

    THE DEFECT THIS FIXES (measured 2026-08-28, a web-app project). A backend release
    shipped `b24be2d..ee7fe8c` -- 21 commits already merged to master AND pushed.
    `git status` was clean of them, and `branch_changed_files` diffs
    merge-base(HEAD, origin/master)..HEAD, which is EMPTY on a merged branch. So
    the guard scored relevance against the only thing it could see -- five
    unrelated working-tree files -- and named three test files with nothing to do
    with what was being deployed. "Committed, pushed, not yet deployed" was a
    blind spot with no signal at all, and the deploy of record shipped five
    runtime files whose tests were never proposed.

    THIS IS NOT A HATCH, and is deliberately not one. The range only ADDS to the
    changed set, so it can only ever make the relevant-test set LARGER and the
    refusal MORE accurate. It never turns a denial into an allow on the grounds
    that a run is too broad: if the range still implies a cheaper subset, that
    subset is what gets named. A fabricated range buys nothing -- git validates
    both endpoints, and a range resolving to no files is discarded. The full
    suite runs only when the range genuinely makes nearly every test relevant,
    which is the guard agreeing, not being bypassed.

    Source, in order: CCLAUDE_TESTSCOPE_RANGE, else a `.claude-testscope-range`
    file at the repo root holding one line, e.g. `b24be2d..ee7fe8c`.
    """
    raw = (os.environ.get("CCLAUDE_TESTSCOPE_RANGE") or "").strip()
    if not raw:
        try:
            with open(os.path.join(root, RANGE_FILE), "r") as fh:
                raw = fh.readline().strip()
        except (OSError, UnicodeDecodeError, ValueError):
            return []
    if not raw or not RANGE_RE.match(raw):
        return []
    sep = "..." if "..." in raw else ".."
    left, _, right = raw.partition(sep)
    for end in (left, right):
        if not run(["git", "rev-parse", "--verify", "--quiet", end]):
            return []                       # unresolvable endpoint -> ignore
    out = run(["git", "diff", "--name-only", raw]) or ""
    return [p for p in (l.strip() for l in out.splitlines())
            if p and os.path.isfile(os.path.join(root, p))]


def changed_files(root):
    porcelain = run(["git", "status", "--porcelain", "--untracked-files=all"])
    files = []
    for line in (porcelain or "").splitlines():
        path = line[3:].strip()
        if " -> " in path:                  # renames
            path = path.split(" -> ", 1)[1]
        path = path.strip('"')
        if path and os.path.isfile(os.path.join(root, path)):
            files.append(path)
    # A release ships COMMITTED history, which `git status` cannot see. UNION,
    # never fall back: a dirty tree full of unrelated edits must not hide the
    # range, which is the exact shape that produced the 2026-08-28 miss.
    rng = range_changed_files(root)
    if rng:
        files = sorted(set(files) | set(rng))
    if not files:
        return branch_changed_files(root)
    return files


def relevant_tests(root, tests, changed):
    """A test is relevant if it IS changed, if it sits under a changed conftest.py's
    directory, or if it literally mentions a changed file's name or stem. A grep
    result — not an opinion about coupling.

    A conftest.py configures every test beneath it (autouse fixtures, hooks)
    without any test naming it, so mention-matching scored an autouse change as
    relevant to almost nothing and refused the whole-suite run it needed (guard
    card CIW, 2026-10-14)."""
    changed_set = set(changed)
    scopes = [os.path.dirname(c) for c in changed if os.path.basename(c) == "conftest.py"]
    needles = set()
    for c in changed:
        base = os.path.basename(c)
        stem = os.path.splitext(base)[0]
        needles.add(base)
        if len(stem) > 3:
            needles.add(stem)
            needles.add(stem.replace("-", "_"))
            needles.add(stem.replace("_", "-"))
    hits = []
    for t in tests:
        if t in changed_set or any(not s or t.startswith(s + "/") for s in scopes):
            hits.append(t)
            continue
        if out_of_budget():
            return None
        try:
            with open(os.path.join(root, t), "rb") as fh:
                body = fh.read(MAX_READ_BYTES).decode("utf-8", "replace")
        except OSError:
            continue
        if any(n in body for n in needles):
            hits.append(t)
    return hits


def log(tag, detail=""):
    """Record EVERY decision, allows included (D14, 2026-08-11).

    This guard shipped with no logging at all, and was inert in
    a research repository from the day it landed — its runner table knew
    pytest and bats but not `python script.py --selftest`, which is how that
    project runs its checks. Nothing recorded the misses, because a hook that
    exits 0 writes its stderr to the debug log only (never the transcript, never
    to Claude), so establishing "this never fired" took an afternoon of transcript
    archaeology. An ALLOW is the entry that matters here: a DENY already shows up
    in the transcript, while inertness leaves no trace anywhere.
    """
    try:
        cfg = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
        path = os.path.join(cfg, "test_scope_guard.log")
        line = "%s %-14s %s %s" % (time.strftime("%Y-%m-%dT%H:%M:%S"), tag,
                                   MODE, detail.replace("\n", " ")[:160])
        prev = open(path).read().splitlines()[-499:] if os.path.exists(path) else []
        open(path, "w").write("\n".join(prev + [line]) + "\n")
    except Exception:
        pass                                # logging must never break a session


def effective_cwd(command, start):
    """Follow leading `cd` segments so paths resolve WHERE THE COMMAND RUNS.

    Measured 2026-08-22 (a web-app project): `cd backend && python -m pytest
    tests/a.py tests/b.py` was denied as "the WHOLE test suite (54 test files)"
    and the refusal recommended Playwright specs from a DIFFERENT repo. Two
    faults, one cause -- the guard judged everything against the SESSION cwd:

      * `tests/a.py` was resolved against the session cwd, where it does not
        exist, so `os.path.isfile(cand)` was False and the "a specific test
        file: already scoped" exit never fired. Naming files stopped counting
        as narrowing.
      * `root` comes from `git rev-parse` run in that same wrong cwd, so it
        enumerated the sibling repo's tests and selected from its changed
        files.

    One web-app project keeps backend/ and frontend/ as separate repos under
    one directory, so `cd <repo> && <runner>` is the NORMAL shape here, not an
    edge case. Only plain literal `cd <dir>` is followed: a token containing a
    shell metacharacter is not resolvable without executing it, and this guard
    must never execute anything it inspects.
    """
    here = start
    for seg in split_segments(command):
        toks = tokens_of(seg)
        if len(toks) != 2 or toks[0] != "cd":
            continue
        target = toks[1]
        # A leading `~` is the user's home, resolvable without executing anything.
        # Skipping it left `cd ~/dev/other-repo && <runner> tests/x` judged against
        # the SESSION repo: 2026-10-28, a one-file run was refused as "the WHOLE test
        # suite (32 test files)" of a repo the command never entered.
        if target == "~" or target.startswith("~/"):
            target = os.path.expanduser(target)
        if any(ch in target for ch in "$*?`~"):
            continue                        # unresolvable without executing it
        cand = target if os.path.isabs(target) else os.path.join(here, target)
        cand = os.path.normpath(cand)
        if os.path.isdir(cand):
            here = cand
    return here


# ------------------------------------------------------------ re-run memory
# THE SECOND WASTE (owner 2026-10-24, a product project): the same test files run green,
# then run AGAIN after a merge commit whose content for those files and for the
# code they import had not changed; and a one-module change that ran a
# 1,970-test union of neighbouring suites. The whole-suite check above cannot see
# either: both runs name files.
#
# RECORD (PostToolUse, which fires ONLY when the Bash call exited 0 -- measured
# 2026-10-24 with a logging hook: `true` -> PostToolUse, `false` ->
# PostToolUseFailure, whose payload carries `error: "Exit code 1"` and no
# tool_response). REFUSE (PreToolUse): the same selection whose DEPENDENCY CONTENT
# is byte-identical to a recorded green run. FACTS, NOT PHRASING again: the key is
# the selected files + filter flags + a hash of what those files can reach.
#
# What "can reach": the test files, every in-repo python module they import
# (transitively), the conftest.py chain, the pytest config files, and any in-repo
# file whose relative path appears as a string in a test (fixtures, scripts run
# by subprocess). Hashed from the WORKING TREE, so a merge commit that moved HEAD
# but not those bytes does not change the key, and an uncommitted edit does. Not
# python (bats, jest...) -> the whole tree (HEAD tree + diff + untracked) is the
# state. KNOWN LIMIT: a dependency reached only dynamically (importlib on a built
# string, a data file named by concatenation) is invisible; that is what the
# logged TEST_RERUN_OK override is for.
RERUN_TTL_S = 7 * 86400             # state older than this is pruned
UNION_MAX_FILES = 8                 # selections bigger than this get the relevance check
EVENT = payload.get("hook_event_name") or "PreToolUse"
NON_RUN_FLAGS = {"--collect-only", "--co", "--help", "-h", "--version",
                 "--fixtures", "--markers", "--setup-plan", "--dry-run"}
TEST_EXTS = (".py", ".js", ".ts", ".jsx", ".tsx", ".bats", ".sh")
# Segments allowed around a test run without making the tree state unknowable.
HARMLESS = {"cd", "echo", "export", "true", "set", "source", ".", "tail", "head",
            "tee", "grep", "cat", "wc"}
CONFIG_FILES = ("pyproject.toml", "pytest.ini", "setup.cfg", "tox.ini")
# Linear-time scans (an ast parse and a `[\w./-]+\.ext` regex both cost seconds over a
# few hundred modules, measured 2026-10-24: 12 test files reached 329 modules).
QUOTED_PATH = re.compile(r"""["']([\w./-]{3,200})["']""")
PATH_EXTS = (".py", ".sh", ".json", ".toml", ".yaml", ".yml", ".txt", ".cfg", ".csv", ".jsonl")
IMPORT_LINE = re.compile(
    r"^[ \t]*(?:from[ \t]+(\.*[\w.]*)[ \t]+import[ \t]+(\([^)]*\)|[^\n]*)|import[ \t]+([\w., \t]+))",
    re.MULTILINE)
OVERRIDE = re.compile(r"\bTEST_RERUN_OK=(\"[^\"]+\"|'[^']+'|[^\s\"';&|]+)")
BAD_OUTPUT = re.compile(r"\b[1-9]\d* (?:failed|errors?)\b|^(?:FAILED|ERROR) |^not ok ",
                        re.MULTILINE)
PASSED = re.compile(r"\b[1-9]\d* passed\b")
try:
    MAX_DEP_FILES = int(os.environ.get("CCLAUDE_TESTSCOPE_MAX_DEPS", "1500"))
except ValueError:
    MAX_DEP_FILES = 1500
MAX_DEP_BYTES = 2_000_000             # per file
MAX_TOTAL_BYTES = 40_000_000         # over all files of one closure
_NOT_A_RUN = object()


def _rel_in_repo(path):
    """Repo-relative form of an existing path under root, else None."""
    try:
        full = os.path.realpath(path)
        base = os.path.realpath(root)
    except OSError:
        return None
    if not full.startswith(base + os.sep):
        return None
    rel = os.path.relpath(full, base)
    return None if any(p in SKIP_DIRS for p in rel.split(os.sep)) else rel


def classify_segment(seg):
    """_NOT_A_RUN for a harmless segment, None for one that makes the tree state
    unknowable (or a run with no usable file selection), else
    {'runner', 'files', 'filters'}."""
    toks = leading(tokens_of(seg))
    if not toks:
        return _NOT_A_RUN
    runner_at = find_runner(toks)
    if runner_at is None:
        return _NOT_A_RUN if os.path.basename(toks[0]) in HARMLESS else None
    args = toks[runner_at + 1:]
    files, filters, i = [], [], 0
    while i < len(args):
        t = args[i]
        head = t.split("=")[0]
        if t in NON_RUN_FLAGS:
            return None
        if t.startswith("-"):
            if head in FILTER_FLAGS or head == "-m":
                if "=" in t or i + 1 >= len(args):
                    filters.append(t)
                else:
                    filters.append(t + " " + args[i + 1])
                    i += 1
            i += 1
            continue
        base, sep, node = t.partition("::")
        cand = base if os.path.isabs(base) else os.path.join(cwd, base)
        if os.path.isfile(cand) or base.endswith(TEST_EXTS):
            rel = _rel_in_repo(cand) if os.path.isfile(cand) else \
                os.path.relpath(os.path.normpath(cand), root)
            if rel is None or rel.startswith(".."):
                return None
            files.append(rel + sep + node)
        elif os.path.isdir(cand):
            return None                     # a directory is a wider selection
        i += 1                              # else: the value of a flag we do not model
    if not files:
        return None
    return {"runner": os.path.basename(toks[runner_at]), "files": files,
            "filters": filters}


def selection_of(command):
    """The combined selection of a command, or None when it is not a pure,
    file-selecting test run whose tree state is knowable."""
    runs = []
    for seg in split_segments(command):
        if not seg.strip():
            continue
        c = classify_segment(seg)
        if c is None:
            return None
        if c is not _NOT_A_RUN:
            runs.append(c)
    if not runs:
        return None
    return {"runner": runs[0]["runner"],
            "files": sorted({f for r in runs for f in r["files"]}),
            "filters": sorted({f for r in runs for f in r["filters"]})}


def _read(rel, limit=MAX_DEP_BYTES):
    try:
        with open(os.path.join(root, rel), "rb") as fh:
            return fh.read(limit)
    except OSError:
        return None


def _py_imports(rel, body):
    """Candidate in-repo files for every import in one python file."""
    here = os.path.dirname(rel)
    bases = [".", "src", here]
    names = []                              # (dotted name, relative-level)
    for m in IMPORT_LINE.finditer(body):
        if m.group(3) is not None:          # import a.b, c as d
            names += [(n.split()[0], 0) for n in m.group(3).split(",") if n.split()]
            continue
        mod = m.group(1)
        level = len(mod) - len(mod.lstrip("."))
        mod = mod.lstrip(".")
        names.append((mod, level))
        for part in re.split(r"[,()\s]+", m.group(2).split("#")[0]):
            if part and part not in ("as", "*") and part.isidentifier():
                names.append(((mod + "." + part).strip("."), level))
    cands = []
    for name, level in names:
        parts = name.split(".") if name else []
        roots = [os.path.normpath(os.path.join(here, *[".."] * (level - 1)))] if level else bases
        for b in roots:
            stem = os.path.join(b, *parts) if parts else b
            cands += [stem + ".py", os.path.join(stem, "__init__.py")]
    return cands


def _is_big(rel):
    try:
        return os.stat(os.path.join(root, rel)).st_size > MAX_DEP_BYTES
    except OSError:
        return False


def _fingerprint(rel):
    """Content hash for a small file; size + mtime for a data file over MAX_DEP_BYTES
    (the corpora a test names run to GB: hashing them per Bash call is not an option;
    a rewritten file only ever reads as CHANGED, which allows the re-run)."""
    import hashlib
    if _is_big(rel):
        st = os.stat(os.path.join(root, rel))
        return ("big:%d:%d" % (st.st_size, st.st_mtime_ns)).encode()
    return hashlib.sha256(_read(rel) or b"").digest()


def dependency_files(files):
    """Repo-relative files the selection can reach (see the block comment).

    Every candidate path is tried ONCE (`tried`) and only existing in-repo files are
    queued, so the work is bounded by the number of real files, never by how many
    import lines or quoted strings mention them."""
    tried, queue, seen, total = set(), [], [], 0

    def push(cand):
        rel = os.path.normpath(cand)
        # Repo-relative only: an absolute or `..` path named in a test string once
        # made the walk loop on "/" forever (found 2026-10-24).
        if rel in tried or rel.startswith(("/", "..")):
            return
        tried.add(rel)
        if os.path.isfile(os.path.join(root, rel)):
            queue.append(rel)

    for f in files:
        push(f.split("::", 1)[0])
    for c in CONFIG_FILES:
        push(c)
    while queue:
        if len(seen) >= MAX_DEP_FILES or out_of_budget():
            return None                      # an incomplete closure is no key: fail open
        rel = queue.pop()
        seen.append(rel)
        parts = [p for p in os.path.dirname(rel).split(os.sep) if p]
        for k in range(len(parts) + 1):      # conftest chain + package markers
            d = os.sep.join(parts[:k])
            push(os.path.join(d, "conftest.py"))
            push(os.path.join(d, "__init__.py"))
        if _is_big(rel):
            continue                         # data file: named, fingerprinted, never read
        body = _read(rel)
        if body is None:
            continue
        total += len(body)
        if total > MAX_TOTAL_BYTES:
            return None                      # too big to key: fail open
        text = body.decode("utf-8", "replace")
        if rel.endswith(".py"):
            for cand in _py_imports(rel, text):
                push(cand)
        here = os.path.dirname(rel)
        for m in QUOTED_PATH.findall(text):
            if m.endswith(PATH_EXTS):
                push(m)
                push(os.path.join(here, m))
    return sorted(seen)


def _hash_stream(args, h, cap):
    """Feed a command's stdout into `h` in chunks; False if it exceeds `cap` bytes."""
    try:
        proc = subprocess.Popen(args, cwd=cwd, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL)
    except OSError:
        return False
    n = 0
    for chunk in iter(lambda: proc.stdout.read(65536), b""):
        n += len(chunk)
        if n > cap:
            proc.kill()
            proc.wait()
            return False
        h.update(chunk)
    return proc.wait() == 0


def whole_tree_state():
    """HEAD tree + diff content + untracked contents; None when too big/unknown."""
    import hashlib
    h = hashlib.sha256()
    tree = (run(["git", "rev-parse", "HEAD^{tree}"]) or "").strip()
    if not tree:
        return None
    h.update(tree.encode())
    if not _hash_stream(["git", "diff", "HEAD", "--binary"], h, MAX_TOTAL_BYTES):
        return None
    others = (run(["git", "ls-files", "--others", "--exclude-standard"]) or "").splitlines()
    if len(others) > 2000:
        return None
    for rel in sorted(others):
        h.update(rel.encode())
        h.update(_read(rel, 1_000_000) or b"")
    return h.hexdigest()


def tree_state(sel):
    import hashlib
    if not all(f.split("::", 1)[0].endswith(".py") for f in sel["files"]):
        return whole_tree_state()
    deps = dependency_files(sel["files"])
    if deps is None:
        return None
    h = hashlib.sha256()
    for rel in deps:
        h.update(rel.encode())
        h.update(_fingerprint(rel))
    return h.hexdigest()


def rerun_key(sel):
    import hashlib
    state = tree_state(sel)
    if state is None:
        return None
    blob = json.dumps([os.path.realpath(root), sel["files"], sel["filters"], state])
    return hashlib.sha256(blob.encode()).hexdigest()


def _state_path():
    import hashlib
    # ~/.claude, NOT $CLAUDE_CONFIG_DIR: every cage on this machine has its own config
    # dir, and the record is a fact about the repo's bytes, so a worker in another cage
    # must see the same green run.
    base = os.environ.get("CCLAUDE_TESTSCOPE_STATE_DIR") or \
        os.path.expanduser("~/.claude/state/test_rerun")
    name = hashlib.sha1(os.path.realpath(root).encode()).hexdigest()[:16]
    return os.path.join(base, name + ".json")


def _load_entries(path):
    try:
        with open(path) as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def update_entries(mutate):
    """Locked read-modify-write of this repo's green-run record; prunes old keys."""
    import fcntl
    path = _state_path()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path + ".lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        entries = {k: v for k, v in _load_entries(path).items()
                   if time.time() - v.get("ts", 0) < RERUN_TTL_S}
        mutate(entries)
        tmp = path + ".tmp%d" % os.getpid()
        with open(tmp, "w") as fh:
            json.dump(entries, fh)
        os.replace(tmp, path)


def record_run():
    """PostToolUse / PostToolUseFailure: remember (or forget) a green selection."""
    tool_input = payload.get("tool_input") or {}
    resp = payload.get("tool_response") or {}
    if tool_input.get("run_in_background") or resp.get("backgroundTaskId") \
            or resp.get("interrupted"):
        return log("SKIP-record", "background or interrupted")
    sel = selection_of(cmd)
    if not sel:
        return
    key = rerun_key(sel)
    if key is None:
        return log("SKIP-record", "tree state unknown")
    if EVENT == "PostToolUseFailure":
        update_entries(lambda e: e.pop(key, None))
        return log("FORGET-green", " ".join(sel["files"])[:120])
    out = "%s\n%s" % (resp.get("stdout") or "", resp.get("stderr") or "")
    # Exit 0 can hide a failure (`pytest a; true`, `pytest a | tail`), so the
    # output is read too: a failure line, or a pytest run with no pass, is no record.
    if BAD_OUTPUT.search(out) or (sel["runner"] in ("pytest", "py.test")
                                  and not PASSED.search(out)):
        return log("SKIP-record", "output does not show a clean pass")
    entry = {"ts": time.time(), "files": sel["files"], "cmd": cmd[:200]}
    update_entries(lambda e: e.__setitem__(key, entry))
    log("RECORD-green", " ".join(sel["files"])[:120])


def related_tests(changed):
    """Tests named for a changed source file by the repo convention
    tests/test_<module>.py (or <module>_test.py), plus changed tests themselves."""
    tests = enumerate_tests(root) or []
    stems = {os.path.splitext(os.path.basename(c))[0] for c in changed
             if not is_test_path(c) and c.endswith(".py")}
    wanted = {"test_%s.py" % s for s in stems} | {"%s_test.py" % s for s in stems}
    return sorted({t for t in tests if os.path.basename(t) in wanted}
                  | {c for c in changed if c in set(tests)})


def check_rerun(sel):
    """PreToolUse: refuse a green-on-this-state repeat; warn on an unrelated union."""
    key = rerun_key(sel)
    if key is None:
        return log("ALLOW-rerun-unknown", "")
    hit = _load_entries(_state_path()).get(key)
    if hit and time.time() - hit.get("ts", 0) < RERUN_TTL_S:
        m = OVERRIDE.search(cmd)
        if m:
            return log("RERUN-OVERRIDE", m.group(1).strip("\"'")[:100])
        mins = int((time.time() - hit["ts"]) / 60)
        when = time.strftime("%H:%M", time.localtime(hit["ts"]))
        lead = "Blocked" if MODE != "observe" else "Would block"
        msg = (
            f"{lead}: these test files already PASSED at {when} ({mins} min ago) and "
            f"nothing they can reach has changed since: the {len(sel['files'])} file(s), "
            f"every in-repo module they import, the conftest chain, the pytest config "
            f"and any file they name all hash identically (a merge commit that left "
            f"those bytes alone does not count as a change).\n"
            f"  {' '.join(sel['files'])[:300]}\n"
            f"DO INSTEAD: change code first and re-run, or run a different selection. "
            f"If a repeat is truly needed (flaky check, changed environment), put "
            f"TEST_RERUN_OK=<reason> in front of the command; it is logged.")
        log("DENY-RERUN" if MODE != "observe" else "WOULD-DENY-RERUN",
            " ".join(sel["files"])[:120])
        if MODE == "observe":
            print(f"NOTE (test rerun, observe mode): {msg}", file=sys.stderr)
            return
        print(msg, file=sys.stderr)
        sys.exit(2)
    if len(sel["files"]) > UNION_MAX_FILES:
        changed = changed_files(root)
        mine = {f.split("::", 1)[0] for f in sel["files"]}
        rel = related_tests(changed)
        if rel and not mine & set(rel):
            note = (f"WARNING (test scope): this selects {len(mine)} test files and none "
                    f"of them is a test of a changed file. The tests that relate to the "
                    f"change: {' '.join(rel[:20])}. Run those unless the wider run is "
                    f"deliberate.")
            log("WARN-union", f"{len(mine)} files, {len(rel)} related")
            print(json.dumps({"hookSpecificOutput": {
                "hookEventName": "PreToolUse", "additionalContext": note}}))


cwd = effective_cwd(cmd, cwd)

root = (run(["git", "rev-parse", "--show-toplevel"]) or "").strip()
if not root or not os.path.isdir(root):
    log("ALLOW-nogit", cmd[:80])
    sys.exit(0)
if EVENT in ("PostToolUse", "PostToolUseFailure"):
    try:
        record_run()
    except Exception as exc:                # a record that fails must never break a session
        log("ERR-record", repr(exc)[:120])
    sys.exit(0)
if not (payload.get("tool_input") or {}).get("run_in_background"):
    try:
        _sel = selection_of(cmd)
        if _sel:
            check_rerun(_sel)
    except Exception as exc:                # FAIL-OPEN, like the rest of this guard
        log("ERR-rerun", repr(exc)[:120])
if not looks_like_whole_suite(cmd):
    log("ALLOW-scoped", cmd[:80])
    sys.exit(0)

tests = enumerate_tests(root)
if not tests or len(tests) < MIN_FILES or out_of_budget():
    log("ALLOW-fewtests", "%d tests" % len(tests or []))
    sys.exit(0)
changed = changed_files(root)
if not changed:
    log("ALLOW-cleantree", "%d tests" % len(tests))
    sys.exit(0)                             # nothing to select on → run it all
hits = relevant_tests(root, tests, changed)
if hits is None or not hits or len(hits) >= len(tests):
    log("ALLOW-noselection", "%d changed, %s hits" % (len(changed), len(hits or [])))
    sys.exit(0)                             # no cheaper command to name → allow

# THE SUBSET MUST BE BOTH A REAL SAVING AND FULLY NAMEABLE.
# Found 2026-08-11 by firing this guard against the real repos instead of a
# synthetic one. On a long-lived branch the branch-vs-base diff is enormous
# (1,492 files in one research repository), so nearly everything looks relevant:
# 232 tests -> 189 "relevant". Denying that saves ~18% and is not worth a
# round-trip. Worse, the listing was capped at 12, so the refusal would have
# ordered a run of 12 of the 189 relevant tests — the guard would have caused
# UNDER-testing, which is far more expensive than the waste it prevents.
# Deny only when the saving is material AND every relevant test can be named.
SAVING_RATIO = 0.5          # relevant must be under half the suite
MAX_LISTED = 40             # more than this cannot be a usable command
if len(hits) > SAVING_RATIO * len(tests) or len(hits) > MAX_LISTED:
    log("ALLOW-nosaving", "%d of %d tests relevant" % (len(hits), len(tests)))
    sys.exit(0)

listing = " ".join(sorted(hits))
lead = "Blocked" if MODE != "observe" else "Would block"
msg = (
    f"{lead}: this runs the WHOLE test suite ({len(tests)} test files), but the "
    f"working tree touches {len(changed)} file(s) and only {len(hits)} test file(s) "
    f"reference them. The rest is spend with no signal — measured, not guessed: "
    f"the {len(hits)} named below either changed themselves or mention a changed "
    f"file by name.\n"
    f"DO INSTEAD — run only these:\n  {listing}\n"
    f"If the user asked for the whole suite, or this is a release, say so and ask "
    f"— do not route around this."
)
# The refusal NAMES THE REMEDY, NEVER THE BYPASS (D15, 2026-08-11). It used to end
# with "prefix CCLAUDE_TESTSCOPE_MODE=off to this call", and that one line produced
# 11 of the 15 guard bypasses measured across all cages in a single day: the model
# was following the guard's own instructions. The hatch still exists for a human
# and is documented in the header above; it is no longer advertised at the moment
# of refusal, which is exactly when it is cheapest to take.

if MODE == "observe":
    log("WOULD-BLOCK", "%d tests -> %d relevant" % (len(tests), len(hits)))
    print(f"NOTE (test scope, observe mode): {msg}", file=sys.stderr)
    sys.exit(0)
log("DENY", "%d tests -> %d relevant; %d changed" % (len(tests), len(hits), len(changed)))
print(msg, file=sys.stderr)
sys.exit(2)
PY
