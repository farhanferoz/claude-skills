#!/usr/bin/env bash
# PreToolUse(Bash) — main-thread long jobs must run in the BACKGROUND.
#
# THE SYMPTOM (user-reported 2026-07-16, recurring): "background jobs are being
# run in the foreground and that freezes the session completely — even if the
# session is doing nothing." The live-fire case that motivated this file: a full
# bats suite run issued in the FOREGROUND with timeout=600000 — the session froze
# until the user manually backgrounded it (Ctrl+B). poll_loop_guard.sh does NOT
# cover this: it matches `until … sleep … done` poll-loops, and a plain long
# command (test suite, build, sweep) is not a poll-loop.
#
# THE SIGNATURE is declared by the model itself: a foreground Bash call carrying
# an explicit `timeout` >= CCLAUDE_FGJOB_MAX_MS (default 180000 = 3 min) is the
# model saying "I expect this to run for minutes" while choosing the mode that
# freezes the session for exactly that long.
#
# SECOND SIGNATURE — COST, NOT DECLARATION (added 2026-08-11, first-person
# incident). The original rule above allowed every call that did NOT raise the
# timeout, on the stated assumption that "the harness's 120s default caps that
# freeze on its own". A 120s freeze is still a freeze, and the assumption made
# this guard structurally unable to fire on the commonest case: a command that
# never announces it will be slow. Live case: `strings -n 6 "$B" | grep -oE ...`
# over a 304 MB binary, issued in the FOREGROUND with no timeout field at all.
# It sailed through, ran for minutes, and the USER had to background it by hand
# — the exact symptom this file exists to prevent, committed by the guard's own
# author while working on the guard's own register.
#   ⇒ We now also deny an UNBOUNDED WHOLE-INPUT SCAN OF A LARGE FILE: a
#     scan-class tool (strings/objdump/sort/tar/*sum/… — things whose cost is
#     linear in bytes and cannot early-exit) applied to a path that STATS at
#     >= CCLAUDE_FGJOB_MAX_INPUT_MB (default 100 MB), with no `timeout N` bound
#     anywhere in the command. Paths are read from the whole command string, so
#     `B=/big/file; strings "$B"` is caught via the assignment.
#   ⇒ FALSE-POSITIVE CONTROL: the gate is a REAL STAT of a REAL FILE, not a
#     string guess — the same "keys on a fact, not a shape" property that lets
#     this guard enforce from day one. And the remedy is one token: prefix
#     `timeout 60`, which is honoured and allows the call.
#
# WHY ENFORCE IS THE DEFAULT — the deliberate contrast with poll_loop_guard
# (observe) and the twin of subagent_foreground_guard (enforce):
#   * poll_loop_guard must STRING-MATCH a command shape, so its FP rate was
#     unknown and it ships observe until the log calibrates it. THIS guard keys
#     on a NUMERIC FIELD the model set on purpose — like the boolean that lets
#     subagent_foreground_guard enforce on day one, there is nothing fuzzy to
#     miscalibrate.
#   * The remedy is lossless and immediate: the SAME command with
#     run_in_background:true delivers one completion notification. Nothing about
#     the work changes; only the session stops being hostage to it.
#   * The one legitimate exception (the user explicitly asked to sit and wait,
#     watch-job's "single blocking wait") is exactly what the escape hatch is
#     for — and background+notify is the preferred option even there.
#
# SCOPE: MAIN THREAD ONLY. A subagent's turn ends when it stops calling tools,
# so a subagent must run long work in the foreground with a raised timeout —
# subagent_foreground_guard.sh enforces that side. This guard fires only when
# agent_id is absent. The two are complementary, not overlapping.
#
# MODES: CCLAUDE_FGJOB_MODE = enforce (default) | observe | off.
# THRESHOLDS: CCLAUDE_FGJOB_MAX_MS (default 180000) for the declared signature;
#             CCLAUDE_FGJOB_MAX_INPUT_MB (default 100) for the scan signature.
# FAIL-OPEN ALWAYS: any parse error, missing field or unstattable path allows.

payload="$(cat 2>/dev/null || true)"

python3 - "$payload" <<'PY'
import json
import os
import re
import shlex
import sys
import time

MODE = os.environ.get("CCLAUDE_FGJOB_MODE", "enforce")
try:
    THRESHOLD_MS = int(os.environ.get("CCLAUDE_FGJOB_MAX_MS", "180000"))
except ValueError:
    THRESHOLD_MS = 180000
try:
    MAX_INPUT_BYTES = int(os.environ.get("CCLAUDE_FGJOB_MAX_INPUT_MB", "100")) * 1024 * 1024
except ValueError:
    MAX_INPUT_BYTES = 100 * 1024 * 1024

# Cost is linear in bytes and cannot early-exit for these. `grep`/`rg`/`sed`/
# `awk` are fast per byte, so they count only when the command also PIPES —
# `strings X | grep -oE ...` is the shape that actually ran for minutes.
SCAN_ALWAYS = re.compile(
    r"(?:^|[\s|(;&])(?:strings|objdump|nm|readelf|xxd|hexdump|od|base64"
    r"|sort|tar|gzip|bzip2|xz|zstd|shasum|cksum|sha\d+sum|md5sum)\b")
SCAN_IF_PIPED = re.compile(r"(?:^|[\s|(;&])(?:grep|rg|ag|sed|awk)\b")
# The remedy, honoured: any explicit bound makes the call finite by construction.
# Options may precede the duration: timeout_kill_guard requires `-k <grace>`, so a
# bound written its way (`timeout -k 5 90`) must count, or obeying one guard gets
# the call refused by this one (seen 2026-10-05).
BOUNDED = re.compile(
    r"\btimeout(?:\s+(?:-[ks]\s*\S+|--(?:kill-after|signal)[=\s]\S+|-\S+))*"
    r"\s+[\d.]+[smhd]?\b")
# Path-like tokens anywhere in the command, INCLUDING `VAR=/path` assignments,
# so a scan run through a variable is still caught.
PATHS = re.compile(r"""(?:^|[\s="'])((?:/|~/)[^\s"';|&)>]+)""")


def biggest_stattable_input(command):
    biggest = 0
    for raw in PATHS.findall(command):
        try:
            size = os.path.getsize(os.path.expanduser(raw))
        except OSError:
            continue
        if size > biggest:
            biggest = size
    return biggest


def allow():
    sys.exit(0)


if MODE == "off":
    allow()

try:
    p = json.loads(sys.argv[1])
except Exception:
    allow()

# Subagents MUST run long work in the foreground (their turn ends when tool
# calls stop; subagent_foreground_guard.sh bans them backgrounding). Only the
# main thread has a session to freeze.
if p.get("agent_id"):
    allow()

tool_input = p.get("tool_input") or {}
if tool_input.get("run_in_background") is True:
    allow()

timeout = tool_input.get("timeout")
try:
    declared_long = timeout is not None and int(timeout) >= THRESHOLD_MS
except (TypeError, ValueError):
    declared_long = False

cmd = tool_input.get("command") or ""

# Third signature: A TEST SUITE RUN IN THE FOREGROUND (added 2026-08-13).
#
# FOUND BY THE USER, LIVE, twice in one session -- they had to background the job
# by hand both times, which is verbatim the incident that widened this guard on
# 2026-08-11. The two existing signatures could not see it:
#   * `declared_long` reads the tool_input `timeout` FIELD; a suite run declares
#     none, so it looked instantaneous.
#   * `unbounded_scan` needs a scan-class tool over a >=100MB file; `bats` is
#     neither.
# So the guard covered the honest (a declared long timeout) and the obvious (a
# huge scan) and missed the ordinary -- a `bats tests/test_autock.bats` that
# takes five minutes. Worse, a shell-level `timeout -k 10 600` made it look
# bounded to a reader while still freezing the session for ten minutes: an
# explicit bound answers "will it terminate", never "will it block me".
#
# THE FACT, not the wording: the command invokes a known test runner and does NOT
# narrow the run. Runner table and filter flags are the SAME data test_scope_guard
# uses -- one definition of "what is a test runner" on this machine, not two that
# drift. A narrowed run (`-k`, `-f`, a filter) stays allowed: those are the fast
# ones, and they are how you iterate.  For pytest, 1-3 named test files or node ids
# (no directory) count as narrowed too.
RUNNERS = ("pytest", "py.test", "bats", "jest", "vitest", "mocha", "ava",
           "rspec", "phpunit", "ctest", "tox", "nox")
RUNNER_PAIRS = (("cargo", "test"), ("go", "test"), ("npm", "test"),
                ("yarn", "test"), ("make", "test"), ("make", "check"))
FILTER_FLAGS = ("-k", "-f", "--filter", "--testNamePattern", "-t", "--grep",
                "-run", "--only", "--changed", "--changedSince", "--onlyChanged",
                "--last-failed", "--lf", "--name", "--example")

WRAPPERS = ("timeout", "env", "sudo", "nice", "ionice", "stdbuf", "command")
ENV_ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
DURATION = re.compile(r"^[\d.]+[smhd]?$")
SEPARATORS = (";", "&&", "||", "|", "&")
# One to three named test files / node ids narrow a run to the fast path.
MAX_NARROW_FILES = 3
TEST_FILE = re.compile(r"\.(?:py|bats|js|jsx|ts|tsx|rb|rs|go|php)(?:::\S+)?$|::\S")
NARROWED_BY_PATH = []               # the command text, when path-narrowed (for the allow log)


def _named_files_narrow(rest):
    """True iff the runner's own arguments name 1..3 test files / node ids and no
    directory. A shell variable, a directory, four or more files, or no path
    leaves the run unnarrowed."""
    args = []
    for t in rest:
        if t in SEPARATORS:
            break
        args.append(t)
    files = [t for t in args if TEST_FILE.search(t)]
    dirs = [t for t in args if not t.startswith("-") and not TEST_FILE.search(t)
            and (t.endswith("/") or "/" in t)]
    return 1 <= len(files) <= MAX_NARROW_FILES and not dirs


def _tokens(command):
    """argv tokens with `;`/`&`/`|` as tokens of their own, or None if the
    command cannot be parsed (fail-open: an unparseable command is allowed).

    PUNCTUATION-AWARE ON PURPOSE. Plain shlex.split glues a separator onto the
    preceding word when there is no space: `sleep 100; grep x` tokenises as
    ['sleep', '100;', ...], so the duration never matches, and `echo hi;bats
    tests/` tokenises as ['echo', 'hi;bats', 'tests/'], so the runner is never
    seen in command position. MEASURED 2026-08-16 against the installed hook:
    `echo hi;bats tests/` was ALLOWED while `bats tests/; echo done` was
    blocked — the same suite, decided by a space. One tokeniser for both
    signatures, so the two cannot drift apart again."""
    try:
        lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|")
        lexer.whitespace_split = True
        return list(lexer)
    except ValueError:                  # unbalanced quotes -> not parseable
        return None


def _is_unnarrowed_suite(command, honour_filters=True):
    """The runner must be in COMMAND POSITION, and narrowing must come AFTER it.

    Both halves are defects this function had on its first run, and both are
    already documented in test_scope_guard, which is the canonical version of
    this parsing:
      * `git commit -m bats` was DENIED -- "bats" was a substring-ish argument
        match, not a command. shlex tokenising plus a command-position test fixes
        it, and also stops `grep -E "a|bats|c"` matching, since the quoted run is
        ONE token.
      * `timeout -k 10 600 bats ...` was ALLOWED -- `-k` is pytest's filter flag
        AND timeout's kill-after flag, so a wrapper's own option read as "already
        narrowed". Filter flags are now only consulted after the runner index.
    D16(4): argv tokens, never substrings."""
    toks = _tokens(command)
    if toks is None:
        return None
    at_cmd, i = True, 0
    while i < len(toks):
        t = toks[i]
        if t in SEPARATORS:
            at_cmd, i = True, i + 1
            continue
        if not at_cmd:
            i += 1
            continue
        base = os.path.basename(t)
        # Skip wrappers and env assignments; `timeout` also takes POSITIONAL
        # durations its flags do not cover.
        if ENV_ASSIGN.match(t) or base in WRAPPERS:
            i += 1
            while i < len(toks) and toks[i].startswith("-"):
                i += 1
            if base == "timeout":
                while i < len(toks) and DURATION.match(toks[i]):
                    i += 1
            continue
        name = None
        if base in RUNNERS:
            name = base
        elif i + 1 < len(toks) and (base, toks[i + 1]) in RUNNER_PAIRS:
            name = "%s %s" % (base, toks[i + 1])
        # `python -m pytest` is the commonest invocation of all and is neither a
        # bare runner nor a fixed pair -- the runner is the THIRD token. Missed on
        # the first pass, caught by the matrix.
        elif (base in ("python", "python3") and i + 2 < len(toks)
                and toks[i + 1] == "-m"
                and os.path.basename(toks[i + 2]) in RUNNERS):
            name = "%s -m %s" % (base, toks[i + 2])
        if name:
            rest = toks[i + 1:]
            if honour_filters and any(f in rest for f in FILTER_FLAGS):
                return None             # narrowed AFTER the runner: the fast path
            # pytest family only: a named bats file is the documented five-minute
            # incident above, so a named file does not narrow a bats run.
            if (honour_filters and "pytest" in name and _named_files_narrow(rest)):
                NARROWED_BY_PATH.append(command)
                return None
            return name
        at_cmd = False                  # a real command that is not a runner
        i += 1
    return None

suite = None
if tool_input.get("run_in_background") is not True:
    suite = _is_unnarrowed_suite(cmd)
if NARROWED_BY_PATH:
    try:
        _cfg = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
        with open(os.path.join(_cfg, "foreground_long_job_guard.log"), "a") as _fh:
            _fh.write("%s ALLOW-narrowed-by-path %s\n"
                      % (time.strftime("%Y-%m-%dT%H:%M:%S"), cmd[:120]))
    except OSError:
        pass
if suite and os.environ.get("CCLAUDE_FGJOB_SUITE_MODE", "enforce") != "off":
    print(
        "Blocked: `%s` runs a test suite in the FOREGROUND with nothing narrowing "
        "it. A suite here routinely runs minutes (the ccage bats file takes ~5), "
        "and the whole session is frozen for the duration — you cannot read, edit "
        "or answer while it runs, and it has twice been backgrounded by hand.\n"
        "A shell `timeout` does NOT fix this: a bound answers 'will it terminate', "
        "never 'will it block me'.\n"
        "DO INSTEAD, either:\n"
        "  1. re-issue with run_in_background: true and keep working — you get ONE "
        "completion notification; or\n"
        "  2. narrow the run (-k / -f / --filter / a single test name) — still do "
        "it in the background; narrowing cuts the wait, it does not remove it.\n"
        "If a blocking foreground suite run is genuinely what you want, say so and "
        "ask." % suite,
        file=sys.stderr)
    sys.exit(2)

# Fifth signature: A NARROWED OR BOUNDED TEST RUN, STILL IN THE FOREGROUND
# (added 2026-08-16).
#
# The third signature above exempts a narrowed run, on the reasoning that
# "those are the fast ones, and they are how you iterate". MEASURED the same day,
# by this guard's own author while working on this guard's own plan:
#   timeout -k 5 180 ./tests/bats/bin/bats tests/test_autock.bats -f "supervisor"
# slipped past every signature at once — BOUNDED (so the declared-timeout and
# scan checks stayed quiet), NARROWED with -f (so the suite check returned early),
# no sleep (so the wait check stayed quiet). The user backgrounded it by hand,
# which is the identical symptom that created this file and then widened it twice.
#
# The suite refusal three lines up already states the rule that catches this: "a
# bound answers 'will it terminate', never 'will it block me'." A FILTER answers
# neither. Narrowing changes how long the freeze lasts, not whether there is one,
# and the remedy costs nothing: run_in_background returns one notification and
# the session stays usable. No test run needs to hold the session.
#
# SHIPS OBSERVING, unlike its siblings. They key on facts with a known false-
# positive rate (a numeric field, a real stat of a real file). This one fires on
# EVERY foreground test invocation, which is a far wider net than any of them, and
# the honest position is that nobody has yet measured how often that is the wrong
# call. The log answers that before the guard is allowed to refuse anything.
runner = None
if tool_input.get("run_in_background") is not True and not suite:
    runner = _is_unnarrowed_suite(cmd, honour_filters=False)
TESTRUN_MODE = os.environ.get("CCLAUDE_FGJOB_TESTRUN_MODE", "observe")
if runner and TESTRUN_MODE != "off":
    _msg = (
        "Blocked: `%s` runs tests in the FOREGROUND. Narrowing it (-k / -f / a "
        "single test) shortens the freeze; it does not remove it, and neither "
        "does a shell `timeout` — a bound answers 'will it terminate', never "
        "'will it block me'. MEASURED here: a bounded, narrowed bats run had to "
        "be backgrounded by hand.\n"
        "DO INSTEAD: re-issue the SAME command with run_in_background: true. You "
        "get one completion notification and the session stays usable meanwhile. "
        "Keep the narrowing — it is still the right scope, just not the right "
        "mode.\n"
        "If a blocking foreground test run is genuinely what you want, say so and "
        "ask." % runner)
    if TESTRUN_MODE == "enforce":
        print(_msg, file=sys.stderr)
        sys.exit(2)
    try:
        _cfg = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
        with open(os.path.join(_cfg, "foreground_long_job_guard.log"), "a") as _fh:
            _fh.write("%s OBSERVE-testrun %s\n"
                      % (time.strftime("%Y-%m-%dT%H:%M:%S"), cmd[:120]))
    except OSError:
        pass

# Fourth signature: A FOREGROUND WAIT (added 2026-08-16).
#
# The single-long-command failure is fixed — 11,053 foreground calls over four
# days, none above 300s. The waiting moved: 215 calls that exist only to wait,
# 30.5 minutes of dead session time. poll_loop_guard logged this shape 97 times
# without blocking it, and that log calibrates the threshold: 44 of the 97
# carry no literal sleep (so the shape is ~45% wrong), while the durations at
# 10s or more number exactly 20 and account for nearly all the lost time.
#
# The remedy is strictly better, not merely different: a background `until`
# loop returns THE MOMENT the condition holds, where a fixed sleep is either
# too short (poll again) or too long (waste).
SLEEP_UNITS = {"": 1, "s": 1, "m": 60, "h": 3600, "d": 86400}


def _foreground_sleep(command):
    """Seconds of the longest foreground `sleep` in command position, or None.

    Command position only, argv tokens not substrings (D16(4)) -- the same
    SEPARATORS/WRAPPERS/ENV_ASSIGN/DURATION _is_unnarrowed_suite uses, so
    `git commit -m "fix sleep 60"` is one quoted token and cannot match.
    Tokenising is punctuation-aware (see _tokens) -- plain shlex.split leaves
    `sleep 20;` as one token `20;`, which fails the duration regex and hides
    the sleep entirely; verified against every CASE below."""
    toks = _tokens(command)
    if toks is None:
        return None
    worst, at_cmd, i = None, True, 0
    while i < len(toks):
        t = toks[i]
        if t in SEPARATORS:
            at_cmd, i = True, i + 1
            continue
        if not at_cmd:
            i += 1
            continue
        base = os.path.basename(t)
        if ENV_ASSIGN.match(t) or base in WRAPPERS:
            i += 1
            while i < len(toks) and toks[i].startswith("-"):
                i += 1
            if base == "timeout":
                while i < len(toks) and DURATION.match(toks[i]):
                    i += 1
            continue
        if base == "sleep" and i + 1 < len(toks):
            m = re.fullmatch(r"([\d.]+)([smhd]?)", toks[i + 1])
            # `sleep 60 &` is backgrounded BY THE SHELL, so it never holds the
            # session -- blocking it would be a false positive, and a guard that
            # fires on correct work teaches its own dismissal (the fan-out-size
            # gate died of exactly that). `&&` is a separate token from `&` under
            # this tokeniser, so this cannot swallow `sleep 60 && next`.
            backgrounded = (i + 2 < len(toks) and toks[i + 2] == "&")
            if m and not backgrounded:
                secs = float(m.group(1)) * SLEEP_UNITS[m.group(2)]
                worst = max(worst or 0, secs)
        at_cmd = False
        i += 1
    return worst


try:
    MAX_SLEEP_S = int(os.environ.get("CCLAUDE_FGJOB_MAX_SLEEP_S", "10"))
except ValueError:
    MAX_SLEEP_S = 10

if os.environ.get("CCLAUDE_FGJOB_SLEEP_MODE", "enforce") != "off":
    _slept = _foreground_sleep(cmd)
    if _slept is not None and _slept >= MAX_SLEEP_S:
        print(
            "Blocked: this call spends %.0f seconds asleep on the main thread. "
            "The session is frozen for the whole of it and can do nothing.\n"
            "DO INSTEAD: re-issue with run_in_background: true and a condition "
            "instead of a delay —\n"
            "  until <test that the thing is done>; do sleep 5; done\n"
            "which returns the MOMENT it is true and gives you one completion "
            "notification, where a fixed sleep is either too short or wasted.\n"
            "Measured over four days here: 215 waiting calls, 30.5 minutes of "
            "dead session time. Sleeps under %ds stay allowed.\n"
            "If a blocking foreground wait is genuinely what you want, say so "
            "and ask — do not route around this (D15)."
            % (_slept, MAX_SLEEP_S),
            file=sys.stderr)
        sys.exit(2)

# Second signature: an unbounded whole-input scan of a large REAL file.
scan_bytes = 0
if not declared_long and cmd and not BOUNDED.search(cmd):
    if SCAN_ALWAYS.search(cmd) or (SCAN_IF_PIPED.search(cmd) and "|" in cmd):
        scan_bytes = biggest_stattable_input(cmd)
unbounded_scan = scan_bytes >= MAX_INPUT_BYTES

if not declared_long and not unbounded_scan:
    allow()

kind = "declared" if declared_long else "scan"
snippet = cmd[:200].replace("\n", " ")
config = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
log = os.path.join(config, "foreground_long_job_guard.log")


def note(tag):
    try:
        stamp = time.strftime("%Y-%m-%dT%H:%M:%S")
        line = "%s %s kind=%s timeout=%s scan_mb=%d: %s" % (
            stamp, tag, kind, timeout, scan_bytes // (1024 * 1024), snippet)
        prev = open(log).read().splitlines()[-499:] if os.path.exists(log) else []
        open(log, "w").write("\n".join(prev + [line]) + "\n")
    except OSError:
        pass


if MODE != "enforce":
    note("OBSERVE")
    allow()

note("BLOCK")

if declared_long:
    minutes = int(timeout) / 60000.0
    reason = (
        "Blocked: this Bash call declares timeout=%sms (~%.0f min) and runs in "
        "the FOREGROUND on the main thread — the session would freeze for up to "
        "that long, doing nothing.\n"
        "DO INSTEAD: re-issue the SAME command with run_in_background: true. You "
        "get ONE completion notification when it finishes and keep working "
        "meanwhile; the raised timeout is unnecessary in the background."
        % (timeout, minutes))
else:
    reason = (
        "Blocked: this is an UNBOUNDED whole-input scan of a %d MB file, running "
        "in the FOREGROUND on the main thread. It declares no timeout, so it gets "
        "the harness default and can freeze the session for the full 120s while "
        "you can do nothing — a scan whose cost is linear in bytes will use it.\n"
        "DO INSTEAD, either:\n"
        "  1. BOUND it — prefix `timeout 60` (any explicit bound is accepted and "
        "this guard then allows the call). Narrow the input while you are there: "
        "match on the file directly instead of piping a full-file scan into a "
        "second filter.\n"
        "  2. Or re-issue with run_in_background: true and keep working; you get "
        "ONE completion notification.\n"
        "This guard used to trust the declared timeout alone, which meant a "
        "command that never announced it would be slow could never be caught. "
        "The size above is a real stat of a real file, not a guess."
        % (scan_bytes // (1024 * 1024)))

print(
    reason +
    "\nIf the user explicitly asked for a blocking foreground wait, say so and "
    "ask — do not route around this (D15).",
    file=sys.stderr,
)
sys.exit(2)
PY
