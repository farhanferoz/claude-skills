#!/usr/bin/env bash
# Self-test for agent_worktree_base_guard.py. Usage: bash test_agent_worktree_base_guard.selftest.sh [guard.py]
# Pass a broken copy as $1 to watch it fail. Exits non-zero on the first failed case.
set -uo pipefail
GUARD="${1:-$(dirname "$(readlink -f "$0")")/agent_worktree_base_guard.py}"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export CLAUDE_CONFIG_DIR="$T/cfg"; mkdir -p "$CLAUDE_CONFIG_DIR"
fail=0
q() { git -C "$1" "${@:2}" -q 2>/dev/null || git -C "$1" "${@:2}" >/dev/null 2>&1; }

git init -q --bare "$T/origin.git"
git init -q -b main "$T/repo"
git -C "$T/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
git -C "$T/repo" remote add origin "$T/origin.git"
git -C "$T/repo" push -q origin main 2>/dev/null
git -C "$T/repo" checkout -q -b feature
git -C "$T/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m ahead

payload() { printf '{"cwd": "%s", "tool_input": {"description": "probe", %s}}' "$1" "$2"; }
check() {  # name, expected exit, payload
  out="$(printf '%s' "$3" | python3 "$GUARD" 2>&1)"; rc=$?
  if [ "$rc" -ne "$2" ]; then echo "FAIL $1: exit $rc, expected $2"; echo "$out" | head -3; fail=1
  else echo "ok   $1 (exit $rc)"; fi
}
check "branch ahead of origin/main, worktree isolation -> block" 2 "$(payload "$T/repo" '"isolation": "worktree"')"
check "branch ahead, no isolation -> allow" 0 "$(payload "$T/repo" '"subagent_type": "task-worker"')"
git -C "$T/repo" checkout -q main
check "on main level with origin/main, worktree isolation -> allow" 0 "$(payload "$T/repo" '"isolation": "worktree"')"
check "not a git repository -> allow" 0 "$(payload "$T" '"isolation": "worktree"')"
REAL="${WORKTREE_GUARD_REAL_REPO:-}"  # optional: a real repository where the complaint came from
if [ -d "$REAL/.git" ] && [ "$(git -C "$REAL" rev-list --count origin/main..HEAD 2>/dev/null || echo 0)" -gt 0 ]; then
  check "the real repository (where the complaint came from) -> block" 2 "$(payload "$REAL" '"isolation": "worktree"')"
fi
for want in BLOCK "PASS no worktree isolation" "PASS $T/repo main" "PASS not a git repository"; do
  grep -q "$want" "$CLAUDE_CONFIG_DIR/agent_worktree_base_guard.log" \
    && echo "ok   log has '$want'" || { echo "FAIL log lacks '$want'"; fail=1; }
done
[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$fail"
