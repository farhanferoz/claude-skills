#!/usr/bin/env bash
# Exercises the self-healing claim logic in write_set_guard.sh across all four
# cases. Each case asserts the EXIT CODE and the resulting registry state.
set -u
HOOK="$(dirname "$(readlink -f "$0")")/write_set_guard.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

SESSION=testsess
OWNER=aold-owner-1111
NEWBIE=anew-worker-2222

mkdir -p "$T/config/write_sets" "$T/config/projects/proj/$SESSION/subagents"
git init -q "$T/repo"
cd "$T/repo" || exit 1
git config user.email t@t; git config user.name t
echo "committed line" > target.txt
git add target.txt && git commit -qm init
FILE="$T/repo/target.txt"

payload() {  # $1 = agent_id
  printf '{"agent_id":"%s","session_id":"%s","cwd":"%s","tool_input":{"file_path":"%s"}}' \
     "$1" "$SESSION" "$T/repo" "$FILE"
}
set_claim() { printf '{"%s":"%s"}' "$FILE" "$OWNER" > "$T/config/write_sets/$SESSION.json"; }
owner_of() { python3 -c "import json;print(json.load(open('$T/config/write_sets/$SESSION.json')).get('$FILE','<none>'))"; }
transcript="$T/config/projects/proj/$SESSION/subagents/agent-$OWNER.jsonl"

run() { CLAUDE_CONFIG_DIR="$T/config" CLAUDE_PROJECT_DIR="$T/repo" bash "$HOOK" <<<"$(payload "$1")" >/dev/null 2>&1; echo $?; }
check() { if [ "$2" = "$3" ]; then echo "  PASS  $1 (got $2)"; else echo "  FAIL  $1 (expected $3, got $2)"; FAILED=1; fi; }
FAILED=0

echo "A) owner LIVE (transcript just written) -> must BLOCK"
set_claim; touch "$transcript"
check "exit code" "$(run $NEWBIE)" 2
check "owner unchanged" "$(owner_of)" "$OWNER"

echo "B) owner STALE + file CLEAN -> must REASSIGN"
set_claim; touch -d '3 hours ago' "$transcript"
check "exit code" "$(run $NEWBIE)" 0
check "owner handed over" "$(owner_of)" "$NEWBIE"

echo "C) owner STALE + file DIRTY -> must BLOCK (this is the 72-uncommitted-lines case)"
set_claim; touch -d '3 hours ago' "$transcript"
echo "uncommitted edit" >> "$FILE"
check "exit code" "$(run $NEWBIE)" 2
check "owner unchanged" "$(owner_of)" "$OWNER"
git -C "$T/repo" checkout -q -- target.txt

echo "D) owner STALE, transcript MISSING, file clean -> must REASSIGN"
set_claim; rm -f "$transcript"
check "exit code" "$(run $NEWBIE)" 0
check "owner handed over" "$(owner_of)" "$NEWBIE"

echo "E) no claim at all -> must ALLOW and record"
printf '{}' > "$T/config/write_sets/$SESSION.json"
check "exit code" "$(run $NEWBIE)" 0
check "claim recorded" "$(owner_of)" "$NEWBIE"

echo "F) main thread (no agent_id) -> must ALLOW, never blocked"
set_claim; touch "$transcript"
rc=$(CLAUDE_CONFIG_DIR="$T/config" CLAUDE_PROJECT_DIR="$T/repo" bash "$HOOK" \
   <<<"{\"session_id\":\"$SESSION\",\"cwd\":\"$T/repo\",\"tool_input\":{\"file_path\":\"$FILE\"}}" >/dev/null 2>&1; echo $?)
check "exit code" "$rc" 0
check "owner untouched" "$(owner_of)" "$OWNER"

echo
[ "$FAILED" = "0" ] && echo "ALL CASES PASS" || echo "SOME CASES FAILED"
exit "$FAILED"
