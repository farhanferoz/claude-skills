#!/usr/bin/env bash
# Regression tests for test_scope_guard.sh.
#
# WHY THIS EXISTS (D41: a failure that has happened twice gets a mechanical guard).
# Two defects sat in the guard, both recorded in RESUME as "VERIFIED bugs" and neither
# caught by anything, because the guard had no tests at all:
#
#   1. `-m` was missing from the filter flags, so `pytest -m integration` — an already
#      narrowed run — was denied. The naive fix (adding "-m" to FILTER_FLAGS) is WORSE
#      than the bug: `python -m pytest` also contains `-m`, so every pytest invocation
#      would read as filtered and the guard would silently allow everything. Case D below
#      is the one that catches that, and it is the reason this file exists.
#   2. `split_segments` treated a backslash-newline as a command separator, cutting a
#      continued `pytest \<newline> tests/x.py` off from its file list, so a properly
#      narrowed run was denied as a whole-suite run. Live-fired 2026-08-27.
#
# The guard's decision depends on the REPO it is judging (it denies only when the relevant
# subset is a material saving), so testing it against a working repo is unreliable — a
# dirty tree makes nearly every test look relevant and the guard correctly declines to
# deny, which reads as a pass and proves nothing. This builds its own fixture repo:
# 8 test files, exactly one of which mentions the single changed source file.
#
# The second half covers the RE-RUN memory (owner 2026-10-24): a selection that already
# passed on byte-identical dependencies is refused, and a union of unrelated test files
# for a one-module change is warned about. Each rule was broken once and seen red.
#
# Usage:  bash ~/.claude/hooks/test_scope_guard.selftest.sh
# Exit 0 = all cases behave as specified.

set -uo pipefail

HOOK="${HOOK:-${HOOKS_DIR:-$(dirname "$(readlink -f "$0")")}/test_scope_guard.sh}"
REPO="$(mktemp -d)"
# The re-run record and the decision log are written under the config dir; keep
# them out of the real one.
export CLAUDE_CONFIG_DIR="$(mktemp -d)" CCLAUDE_TESTSCOPE_STATE_DIR="$(mktemp -d)"
trap 'rm -rf "$REPO" "$CLAUDE_CONFIG_DIR" "$CCLAUDE_TESTSCOPE_STATE_DIR"' EXIT

[ -f "$HOOK" ] || { echo "no hook at $HOOK"; exit 1; }

# ---------------------------------------------------------------- fixture repo
(
  cd "$REPO" || exit 1
  git init -q .
  git config user.email selftest@local
  git config user.name selftest
  mkdir -p tests src
  echo "def go(): return 1" > src/thing.py
  echo "def other(): return 2" > src/other.py
  for n in alpha beta gamma delta epsilon zeta eta theta; do
    echo "def test_$n(): assert True" > "tests/test_$n.py"
  done
  echo "# exercises src/thing.py" >> tests/test_alpha.py   # the ONLY relevant test
  echo "import pytest" > tests/conftest.py                 # committed clean; the last case edits it
  git add -A
  git commit -qm init
  echo "def go2(): return 3" >> src/thing.py               # one dirty source file
) || { echo "fixture setup failed"; exit 1; }

pass=0; fail=0

# run <name> <command> <ALLOW|DENY> [session-cwd]
run() {
  local name="$1" cmd="$2" want="$3" sess="${4:-$REPO}" got rc
  printf '%s' "$cmd" \
    | python3 -c "import json,sys; print(json.dumps({'tool_input':{'command':sys.stdin.read()},'cwd':'$sess'}))" \
    | timeout -k 5 30 bash "$HOOK" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then got=ALLOW; elif [ "$rc" -eq 124 ]; then got=HANG; else got=DENY; fi
  if [ "$got" = "$want" ]; then
    pass=$((pass+1)); printf 'ok   %-5s  %s\n' "$got" "$name"
  else
    fail=$((fail+1)); printf 'FAIL %-5s (want %s)  %s\n' "$got" "$want" "$name"
  fi
}

# --- the guard's core contract -------------------------------------------------
run "bare whole suite is denied"                'python -m pytest -q' DENY
run "single named file is allowed"              'python -m pytest tests/test_alpha.py' ALLOW
run "-k filter is allowed"                      'python -m pytest -k alpha' ALLOW
run "env-var prefix does not hide a bare run"   'FOO=1 python -m pytest' DENY
run "python3 spelling is denied too"            'python3 -m pytest' DENY

# --- 2026-10-28: a run judged against the wrong repo, and shell variables ------
OTHER_HOME="$(mktemp -d)"; mkdir -p "$OTHER_HOME/other/tests"
(cd "$OTHER_HOME/other" && git init -q . && echo "@test x { true; }" > tests/test_only_there.bats)
HOME="$OTHER_HOME" run "cd ~/repo && one file of that repo: judged there, allowed" \
  'cd ~/other && bats tests/test_only_there.bats' ALLOW
HOME="$OTHER_HOME" run "cd ~/repo && bare suite: still denied in the session repo" \
  'cd ~/nowhere && python -m pytest -q' DENY
run "one test named through a shell variable is allowed" \
  'T=tests/test_alpha.py::test_alpha; python -m pytest -q "$T"' ALLOW
run "a loop over variable-named bats files is allowed" \
  'for f in tests/test_flow.bats; do bats "$f" 2>&1 | tail -2; done' ALLOW
rm -rf "$OTHER_HOME"

# --- 2026-11-22: heredoc bodies are data, not commands -----------------------
run "a heredoc writing test code, then no runner, is allowed" \
  $'cat > tests/test_new.py <<\'EOF\'\nimport pytest\nEOF\nruff check .' ALLOW
run "REGRESSION: a bare run after a heredoc is still denied" \
  $'cat > notes.txt <<\'EOF\'\nhello\nEOF\npython -m pytest -q' DENY
run "REGRESSION: a here-string does not swallow the next line" \
  $'cat <<<"x"\npython -m pytest -q\nx' DENY

run "command -v only looks a runner up"              'ls tests; command -v bats' ALLOW
run "REGRESSION: command as a plain prefix still runs" 'command python -m pytest -q' DENY

run "bats -f filter is allowed"                         'bats -f alpha tests' ALLOW
run "a runner's --help runs nothing"                    'python -m pytest --help' ALLOW
run "a narrowed run in a subshell group is allowed"     '(cd . && python -m pytest tests/test_alpha.py)' ALLOW
run "REGRESSION: a bare run in a subshell group is denied" '(python -m pytest -q)' DENY
run "REGRESSION: a run inside \$( ) is still one word"  'X=$(python -m pytest -q)' DENY

# --- defect 1: pytest's -m marker selector ------------------------------------
run "marker-filtered run is allowed"            'python -m pytest -m integration' ALLOW
run "marker without python -m is allowed"       'pytest -m integration' ALLOW
run "quoted marker is allowed"                  'python -m pytest -m "not slow"' ALLOW
run "-m=value form is allowed"                  'python -m pytest -m=integration' ALLOW
# THE ONE THAT MATTERS: proves the -m fix did not disable the guard wholesale.
run "REGRESSION: python -m pytest still denied" 'python -m pytest' DENY

# --- defect 2: backslash-newline is a continuation, not a separator -----------
run "continued narrowed run is allowed" 'python -m pytest \
  tests/test_alpha.py -q' ALLOW
run "two continuations still allowed" 'python -m pytest \
  -q \
  tests/test_alpha.py' ALLOW
# Proves the continuation fix did not over-allow: still whole-suite after joining.
run "REGRESSION: continued bare run still denied" 'python -m pytest \
  -q' DENY

# --- a changed conftest.py makes every test beneath it relevant (last: it dirties the fixture) ---
echo "@pytest.fixture(autouse=True)" >> "$REPO/tests/conftest.py"
run "changed conftest.py allows the whole suite"  'python -m pytest -q' ALLOW

# --- the re-run memory ---------------------------------------------------------
# post <PostToolUse|PostToolUseFailure> <command> [stdout] [extra tool_input json]
post() {
  local ev="$1" cmd="$2" out="${3:-}" extra="${4:-}" outf
  outf="$(mktemp)"; printf '%s' "$out" > "$outf"      # an env var would cap the output at ~128 KB
  EV="$ev" CMD="$cmd" OUTF="$outf" EXTRA="$extra" REPO="$REPO" /usr/bin/python3 -c '
import json, os
ti = {"command": os.environ["CMD"]}
resp = {"stdout": open(os.environ["OUTF"]).read(), "stderr": "", "interrupted": False}
ex = json.loads(os.environ["EXTRA"] or "{}")
ti.update(ex.get("tool_input", {})); resp.update(ex.get("tool_response", {}))
p = {"hook_event_name": os.environ["EV"], "tool_name": "Bash", "tool_input": ti,
     "cwd": os.environ["REPO"]}
if os.environ["EV"] == "PostToolUse": p["tool_response"] = resp
print(json.dumps(p))' | timeout -k 5 30 bash "$HOOK" >/dev/null 2>&1
  rm -f "$outf"
}
green() { post PostToolUse "$1" "${2:-1 passed in 0.01s}" "${3:-}"; }
# preout <command> <want-substring|""> <name>: stdout of the pre-hook must (not) hold it
preout() {
  local out
  out="$(printf '%s' "$1" | python3 -c "import json,sys; print(json.dumps({'tool_input':{'command':sys.stdin.read()},'cwd':'$REPO'}))" \
    | bash "$HOOK" 2>/dev/null)"
  if { [ -n "$2" ] && [[ "$out" == *"$2"* ]]; } || { [ -z "$2" ] && [ -z "$out" ]; }; then
    pass=$((pass+1)); printf 'ok         %s\n' "$3"
  else
    fail=$((fail+1)); printf 'FAIL       %s (stdout: %s)\n' "$3" "${out:0:80}"
  fi
}
logged() {   # logged <tag> <name>
  if grep -q "$1" "$CLAUDE_CONFIG_DIR/test_scope_guard.log" 2>/dev/null; then
    pass=$((pass+1)); printf 'ok         %s\n' "$2"
  else fail=$((fail+1)); printf 'FAIL       %s\n' "$2"; fi
}
A='python -m pytest tests/test_alpha.py'
echo "from thing import go" >> "$REPO/tests/test_alpha.py"   # alpha now imports src/thing.py

run "never-run selection is allowed"                   "$A" ALLOW
green "$A"
run "same selection, same tree, already green: DENIED" "$A" DENY
run "node-id spelling of the same file is a new key"   "$A::test_alpha" ALLOW
run "a different file is allowed"                      'python -m pytest tests/test_beta.py' ALLOW
run "same file with a -k filter is allowed"            "$A -k alpha" ALLOW
run "wrapper + pipe around the same run is denied"     "timeout 900 $A -q | tail -3" DENY
echo "# edit" >> "$REPO/src/other.py"
run "an unrelated file changed: still denied"          "$A" DENY
(cd "$REPO" && git add -A && git commit -qm "merge-like commit, same content")
run "new commit, same bytes (merge commit): denied"    "$A" DENY
echo "def go3(): return 4" >> "$REPO/src/thing.py"
run "an imported module changed: allowed"              "$A" ALLOW
green "$A"
run "re-recorded on the new state: denied again"       "$A" DENY
echo "# fixture note" >> "$REPO/tests/conftest.py"
run "conftest changed: allowed"                        "$A" ALLOW
green "$A"

# dependencies reached by import only, and by a path named in a string only
mkdir -p "$REPO/data"; echo '{}' > "$REPO/data/cfg.json"; echo "def h(): return 1" > "$REPO/src/helper.py"
echo "from helper import h" >> "$REPO/tests/test_eta.py"
echo "CFG = 'data/cfg.json'" >> "$REPO/tests/test_theta.py"
ETA='python -m pytest tests/test_eta.py'; THETA='python -m pytest tests/test_theta.py'
green "$ETA"; green "$THETA"
run "import-only dependency unchanged: denied"         "$ETA" DENY
echo "def h(): return 2" > "$REPO/src/helper.py"
run "import-only dependency changed: allowed"          "$ETA" ALLOW
run "path-only dependency unchanged: denied"           "$THETA" DENY
echo '{"a": 1}' > "$REPO/data/cfg.json"
run "a file named in a string changed: allowed"        "$THETA" ALLOW
# the filter is part of the key
green "$A -k alpha"
run "same file, another -k expression: allowed"        "$A -k beta" ALLOW
run "same file, same -k expression: denied"            "$A -k alpha" DENY

# a test naming an absolute or parent path must not hang the closure walk (it once looped on "/")
echo hi > "$CLAUDE_CONFIG_DIR/abs.txt"
echo "P = '$CLAUDE_CONFIG_DIR/abs.txt'; Q = '../outside.json'" >> "$REPO/tests/test_kappa.py"
KAPPA='python -m pytest tests/test_kappa.py'
green "$KAPPA"
run "absolute/parent paths in a test do not hang"      "$KAPPA" DENY
echo changed > "$CLAUDE_CONFIG_DIR/abs.txt"
run "a file OUTSIDE the repo is not tracked"           "$KAPPA" DENY
# a closure that cannot be completed is no key: nothing recorded, nothing refused
export CCLAUDE_TESTSCOPE_MAX_DEPS=1
green 'python -m pytest tests/test_epsilon.py'
run "incomplete closure: not recorded (fails open)"    'python -m pytest tests/test_epsilon.py' ALLOW
unset CCLAUDE_TESTSCOPE_MAX_DEPS

# a run that did not pass records nothing
post PostToolUseFailure 'python -m pytest tests/test_beta.py'
run "failed run (PostToolUseFailure) is not recorded"  'python -m pytest tests/test_beta.py' ALLOW
green 'python -m pytest tests/test_gamma.py' '1 failed, 1 passed in 0.02s'
run "exit 0 but output shows a failure: not recorded"  'python -m pytest tests/test_gamma.py' ALLOW
green 'python -m pytest tests/test_gamma.py' 'no tests ran in 0.01s'
run "pytest output with no pass: not recorded"         'python -m pytest tests/test_gamma.py' ALLOW
post PostToolUseFailure "$A"
run "a later failure on a green key forgets it"        "$A" ALLOW

# override
green "$A"
run "TEST_RERUN_OK=<reason> lets the repeat through"   "TEST_RERUN_OK='flaky db' $A" ALLOW
logged "RERUN-OVERRIDE" "the override is logged"
run "an empty reason is no override"                   "TEST_RERUN_OK= $A" DENY

# background and slurm are left alone
post PostToolUse 'python -m pytest tests/test_delta.py' '1 passed' '{"tool_input":{"run_in_background":true},"tool_response":{"backgroundTaskId":"b1"}}'
run "a background launch is not recorded"              'python -m pytest tests/test_delta.py' ALLOW
printf '%s' '{"tool_input":{"command":"'"$A"'","run_in_background":true},"cwd":"'"$REPO"'"}' | bash "$HOOK" >/dev/null 2>&1
if [ $? -eq 0 ]; then pass=$((pass+1)); echo "ok         a background run is not refused"; else fail=$((fail+1)); echo "FAIL       a background run is not refused"; fi
SL='python3 submit.py --name t --what x -- python -m pytest tests/test_epsilon.py'
green "$SL"
run "slurm-submitted line is not recorded"             'python -m pytest tests/test_epsilon.py' ALLOW
run "slurm-submitted line is never refused"            "$SL" ALLOW
green 'git commit -qm x && python -m pytest tests/test_zeta.py'
run "a run chained after a mutating command is not recorded" 'python -m pytest tests/test_zeta.py' ALLOW

# --- bounded cost (2026-10-24: an unbounded loop grew hook children to 34 GB) ---------
BIGOUT="$(python3 -c "print(('.' * 79 + chr(10)) * 4000 + '3 passed in 1s', end='')")"
green 'python -m pytest tests/test_zeta.py' "$BIGOUT"
run "a 320 KB tool output is recorded (was: argument list too long)" 'python -m pytest tests/test_zeta.py' DENY

# a Post event for a non-test command must not wake the interpreter, whatever its OUTPUT says
SHIM="$(mktemp -d)"; MARK="$SHIM/woke"
printf '#!/bin/bash\ntouch %s\nexec /usr/bin/python3 "$@"\n' "$MARK" > "$SHIM/python3"; chmod +x "$SHIM/python3"
PATH="$SHIM:$PATH" post PostToolUse 'free; ps' 'available pytest tox test: x.sh'
[ ! -e "$MARK" ] && { pass=$((pass+1)); echo "ok         Post for a non-test command exits before python"; } \
  || { fail=$((fail+1)); echo "FAIL       Post for a non-test command woke python"; }
PATH="$SHIM:$PATH" post PostToolUse 'python -m pytest tests/test_zeta.py' '1 passed'
[ -e "$MARK" ] && { pass=$((pass+1)); echo "ok         ...and a runner line does (control)"; } \
  || { fail=$((fail+1)); echo "FAIL       control: a runner line did not reach python"; }

# a data file over 2 MB is fingerprinted by size+mtime, not read
mkdir -p "$REPO/data"; head -c 3000000 /dev/zero > "$REPO/data/big.json"
echo "BIG = 'data/big.json'" >> "$REPO/tests/test_gamma.py"
GAMMA='python -m pytest tests/test_gamma.py'
green "$GAMMA"
run "big data file unchanged: denied"                  "$GAMMA" DENY
(printf '"data/hidden.txt" '; head -c 3000000 /dev/zero) > "$REPO/data/big2.json"; echo one > "$REPO/data/hidden.txt"
echo "BIG2 = 'data/big2.json'" >> "$REPO/tests/test_delta.py"
DELTA='python -m pytest tests/test_delta.py'
green "$DELTA"; echo two > "$REPO/data/hidden.txt"
run "a data file is named and fingerprinted, never scanned" "$DELTA" DENY
touch -d '2001-01-01' "$REPO/data/big.json"
run "big data file rewritten (mtime): allowed"         "$GAMMA" ALLOW

# a runaway or oversized step is bounded and allows the command
FAKE="$(mktemp -d)"
printf '#!/bin/bash\nif [ "$1" = diff ] && [ -n "${FAKE_GIT_MODE:-}" ]; then\n  case "$FAKE_GIT_MODE" in hang) sleep 30 ;; flood) head -c 60000000 /dev/zero;; esac; exit 0\nfi\nexec /usr/bin/git "$@"\n' > "$FAKE/git"; chmod +x "$FAKE/git"
echo "@test x { true; }" > "$REPO/tests/test_flow.bats"
BATS='bats tests/test_flow.bats'
START=$SECONDS
FAKE_GIT_MODE=hang CCLAUDE_TESTSCOPE_HARD_WALL_S=2 PATH="$FAKE:$PATH" run "a hung git is cut at the wall-clock cap and allowed" "$BATS" ALLOW
[ $((SECONDS - START)) -lt 15 ] && { pass=$((pass+1)); echo "ok         ...within the cap"; } || { fail=$((fail+1)); echo "FAIL       cap took $((SECONDS - START)) s"; }
FAKE_GIT_MODE=flood PATH="$FAKE:$PATH" green "$BATS"
FAKE_GIT_MODE=flood PATH="$FAKE:$PATH" run "a 60 MB diff is not hashed: no key, no record" "$BATS" ALLOW
BIG20="$(python3 -c "print('x' * 15000000 + ' 3 passed', end='')")"
CCLAUDE_TESTSCOPE_HARD_AS_MB=64 green 'python -m pytest tests/test_theta.py' "$BIG20"
run "over the memory cap: dies quietly, nothing recorded" 'python -m pytest tests/test_theta.py' ALLOW
rm -rf "$SHIM" "$FAKE"

# union of unrelated suites for a one-module change
(cd "$REPO" && git add -A && git commit -qm clean && echo "def test_other(): assert True" > tests/test_other.py \
  && for n in iota kappa; do echo "def test_$n(): assert True" > "tests/test_$n.py"; done \
  && git add -A && git commit -qm more && echo "def other2(): return 5" >> src/other.py)
NINE='python -m pytest tests/test_alpha.py tests/test_beta.py tests/test_gamma.py tests/test_delta.py tests/test_epsilon.py tests/test_zeta.py tests/test_eta.py tests/test_theta.py tests/test_iota.py'
preout "$NINE" "tests/test_other.py" "9 unrelated files for a src/other.py change: warned, naming test_other.py"
run "the union warning does not refuse"                "$NINE" ALLOW
preout "$NINE tests/test_other.py" "" "a selection that includes the related test: no warning"
preout 'python -m pytest tests/test_alpha.py tests/test_beta.py' "" "a small selection: no warning"

echo "---"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
