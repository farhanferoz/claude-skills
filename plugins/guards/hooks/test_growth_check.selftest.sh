#!/usr/bin/env bash
# Self-test of the test-growth check, through commit_provenance_guard.sh as a session calls it. Run by hand:
#   bash ~/.claude/hooks/test_growth_check.selftest.sh
# HOOKS_DIR=<dir> runs the same cases against the guard and check in another directory.
set -u
HOOKS_DIR="${HOOKS_DIR:-$(cd "$(dirname "$0")" && pwd)}"
GUARD="$HOOKS_DIR/commit_provenance_guard.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export CLAUDE_CONFIG_DIR="$T/cfg"; mkdir -p "$CLAUDE_CONFIG_DIR"
R="$T/repo"; git init -q "$R" && git -C "$R" config user.email t@t && git -C "$R" config user.name t
mkdir -p "$R/tests"; printf 'def test_a():\n    assert 1\n' > "$R/tests/test_x.py"
git -C "$R" add -A && git -C "$R" commit -qm init
fails=0
check() {  # expected-exit  command  (run from cwd $T, so the repo must come from -C or cd)
    local got
    jq -nc --arg c "$2" --arg d "$T" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' | bash "$GUARD" 2>/dev/null
    got=$?
    local shown="${2//$T/\$T}"; shown="${shown%%$'\n'*}"   # one line, without the temp directory
    [ "$got" = "$1" ] && echo "ok   want $1 got $got  $shown" || { echo "FAIL want $1 got $got  $shown"; fails=$((fails + 1)); }
}
printf 'def test_a():\n    assert 1\n\ndef test_b():\n    assert 2\n' > "$R/tests/test_x.py"   # +1, unstaged
check 2 "git -C $R add -A && git -C $R commit -m 'more'"
check 0 "git -C $R add -A && git -C $R commit -m 'more

Tests: +1, guards b'"
check 2 "cd $R && git commit -am 'more'"                                                    # repo from cd
git -C "$R" checkout -q -- tests/test_x.py
printf 'def test_a():\n    assert 3\n' > "$R/tests/test_x.py"                                  # changed, not grown
check 0 "cd $R && git commit -am 'reword a test'"
printf 'def test_n():\n    assert 1\n' > "$R/tests/test_new.py"; : > "$R/notes.txt"             # untracked: +1 only if added
check 0 "cd $R && git commit -am 'reword a test'"                                           # not added: not this commit's
check 0 "cd $R && git add notes.txt && git commit -m 'notes'"
check 2 "git -C $R add tests/test_new.py && git -C $R commit -m 'new'"                      # by path
check 2 "cd $R && git add tests && git commit -m 'new'"                                     # by directory
check 2 "cd $R && git add 'tests/*.py' && git commit -m 'new'"                              # by glob
check 2 "cd $R && git add -A && git commit -m 'new'"
check 2 "cd $R/tests && git add . && git commit -m 'new'"                                   # '.' from a subdirectory

# --- A commit counts the files it will include (2026-11-21 incident: `-- B` was charged for test edits in A) ---
A=tests/test_x.py; B=src/m.py
reset() {  # clean tree on the baseline commit: A holds 1 test, B is a plain file
    git -C "$R" reset -q --hard && git -C "$R" clean -qfd
    mkdir -p "$R/src"; printf 'x = 1\n' > "$R/$B"; printf 'def test_a():\n    assert 1\n' > "$R/$A"
    git -C "$R" add -A && git -C "$R" commit -qm base >/dev/null 2>&1
}
grow_a() { printf 'def test_a():\n    assert 1\n\ndef test_b():\n    assert 2\n' > "$R/$A"; printf 'x = 2\n' > "$R/$B"; }
TL=$'\n\nTests: +1, guards b'
last_log() { tail -1 "$CLAUDE_CONFIG_DIR/test_growth_check.log"; }
check_log() {  # substring  (of the last log line)
    last_log | grep -q -- "$1" && echo "ok   log has $1" || { echo "FAIL log lacks $1"; fails=$((fails + 1)); }
}
reset; grow_a                                                       # A +1 and B changed, both unstaged
check 0 "cd $R && git commit -q -m 'fix' -- $B"                      # the incident: names B only
check_log "files=pathspec"
check 2 "cd $R && git commit -q -m 'fix' -- $A"
check 0 "cd $R && git commit -q -m \"fix$TL\" -- $A"
check 2 "cd $R && git commit -q -m 'fix' $A"                         # bare pathspec after the options
check 2 "cd $R && git commit $A -m 'fix'"                            # bare pathspec before them
check 0 "cd $R && git commit -m 'fix' $B"
check 0 "cd $R && git commit -m $A -- $B"                            # a -m value that looks like a path
check 0 "cd $R && git commit -qm 'fix' -- $B"                        # option cluster -qm
check 0 "cd $R && git commit --message='fix' --author='a <a@a>' -- $B"
check 0 "cd $R && git commit --message 'fix' --date 'now' --author a -- $B"
check 0 "cd $R && git commit -m 'fix' -- $B > /dev/null 2>&1"        # redirections are not pathspecs
check 0 "cd $R && git commit -m 'fix' -- $B 2>&1 | tail -3"
check 0 "cd $R && git commit --amend --no-edit -- $B"
check 2 "cd $R && git commit -m 'fix' -- tests/"                     # the way around it: a directory ...
check 2 "cd $R && git commit -m 'fix' -- 'tests/*.py'"               # ... a glob ...
check 2 "cd $R && git commit -m 'fix' -- ."                          # ... or everything
check 2 "cd $R/tests && git commit -m 'fix' -- test_x.py"            # relative to a subdirectory
check 0 "cd $R/tests && git commit -m 'fix' -- ../$B"
check 2 "git -C $R commit -m 'fix' -- $A"
check 2 "cd $R && git commit -m 'fix' --pathspec-from-file=list.txt" # unreadable pathspecs: counts the tree
check 2 "cd $R && git commit -m 'fix -- $B"                          # unbalanced quote: counts the tree
check 2 "cd $R && git commit -m 'fix' -- ':(exclude)$B'"             # pathspec magic: counts the tree
check 0 "cd $R && git commit -F - -- $B <<'EOF'
don't count this
EOF"                                                               # heredoc text with a quote
check 2 "cd $R && git commit -F - -- $A <<'EOF'
don't count this
EOF"
check 0 "cd $R && git commit -m \"\$(cat <<'EOF'
fix: it's B only
EOF
)\" -- $B"
check 0 "cd $R && FOO=1 git commit -m fix -- $B"                     # environment prefix
check 2 "cd $R && git commit -a -m 'fix'"                            # -a: every changed tracked file
check 2 "cd $R && git commit -am 'fix'"
check 0 "cd $R && git commit -a -m \"fix$TL\""
check 0 "cd $R && git commit -m 'fix'"                               # bare: nothing staged
check_log "files=index"
check 0 "cd $R && git add $B && git commit -m 'fix'"                 # adds B only
check 2 "cd $R && git add $A && git commit -m 'fix'"                 # adds A
check 2 "cd $R && git add -A && git commit -m 'fix'"
check 2 "cd $R && git add -u && git commit -m 'fix'"                 # -u takes every tracked change
check 2 "cd $R && git add tests && git commit -m 'fix'"              # by directory
git -C "$R" add "$A"                                                # A staged
check 2 "cd $R && git commit -m 'fix'"
check 0 "cd $R && git commit -m 'fix' -- $B"                         # staged A is not in a pathspec commit
check 2 "cd $R && git commit -i -m 'fix' -- $B"                      # unless --include
check 2 "cd $R && git commit -m 'fix' -i -- $B"
printf 'def test_a():\n    assert 1\n' > "$R/$A"                    # worktree reverted, the index still holds +1
check 2 "cd $R && git commit -m 'fix'"                               # the index is what a bare commit takes
check 0 "cd $R && git commit -a -m 'fix'"                            # -a takes the worktree: no growth
git -C "$R" reset -q --hard; grow_a; git -C "$R" add "$A"           # +1 staged, then one more unstaged
printf 'def test_a():\n    assert 1\n\ndef test_b():\n    assert 2\n\ndef test_c():\n    assert 3\n' > "$R/$A"
check 2 "cd $R && git commit -m 'fix'"
check_log "tests=+1"                                                # the index copy: +1, not +2
check 2 "cd $R && git commit -m 'fix' -- $A"
check_log "tests=+2"                                                # the worktree copy
# a commit that names a file the same command adds
reset; printf 'def test_n():\n    assert 1\n' > "$R/tests/test_new.py"; grow_a
check 0 "cd $R && git add tests/test_new.py && git commit -m 'fix' -- $B"
check 2 "cd $R && git add tests/test_new.py && git commit -m 'fix' -- tests/test_new.py"
check 0 "cd $R && git commit -m 'fix' -- $B && git commit -m 'more' -- $B"
check 2 "cd $R && git commit -m 'fix' -- $B && git commit -m 'more' -- $A"   # one of two commits grows
exit "$fails"
