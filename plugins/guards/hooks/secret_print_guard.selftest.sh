#!/usr/bin/env bash
# Self-test for secret_print_guard.sh, in the sbatch_gate_guard.selftest.sh convention: real PreToolUse
# payloads, assert the exit status (0 = allowed, 2 = blocked). Run: bash secret_print_guard.selftest.sh
set -u
HOOK="${HOOKS_DIR:-$(dirname "$(readlink -f "$0")")}/secret_print_guard.sh"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
export CLAUDE_CONFIG_DIR="$WORK"  # keep the real log out of a test run
PASS=0; FAIL=0

check() { # check <expected_exit> <description> <payload-json>
  local want=$1 desc=$2 payload=$3
  printf '%s' "$payload" | bash "$HOOK" > "$WORK/out" 2>&1
  local got=$?
  if [ "$got" -eq "$want" ]; then PASS=$((PASS+1)); printf '  ok    %s\n' "$desc"
  else FAIL=$((FAIL+1)); printf '  FAIL  %s (wanted %s, got %s)\n' "$desc" "$want" "$got"; cat "$WORK/out"; fi
}
bash_case() { check "$1" "$2" "$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$3")"; }
tool_case() { check "$1" "$2" "$(python3 -c 'import json,sys; print(json.dumps({"tool_name":sys.argv[1],"tool_input":json.loads(sys.argv[2])}))' "$3" "$4")"; }

# The two real incidents
bash_case 2 "11-17 shape: cat piped into a redacting python" 'cat secrets/llm_config.json | python3 -c "import json,sys; print(json.load(sys.stdin))"'
bash_case 2 "10-27 shape: echo the env value" 'echo "$LLM_CONFIG_JSON" | head -c 400'
bash_case 2 "ssm read with decryption" 'aws ssm get-parameter --name /webapp/prod/LLM_CONFIG_JSON --with-decryption --profile webapp'
# The obvious ways around it
bash_case 2 "absolute path" 'head -c 2000 /home/user/dev/webapp/backend/secrets/llm_config.json'
bash_case 2 "python -c opening it" "python3 -c \"import json; print(json.load(open('secrets/llm_config.json')))\""
bash_case 2 "inside bash -c" "bash -c 'cat secrets/supabase_prod.json'"
bash_case 2 "jq full dump" "jq . secrets/llm_config.json"
bash_case 2 "sed print" "sed -n 1,20p backend/secrets/llm_config.json"
bash_case 2 "grep content" "grep -n api_key secrets/llm_config.json"
tool_case 2 "Read tool" "Read" '{"file_path":"/home/user/dev/webapp/backend/secrets/llm_config.json"}'
tool_case 2 "Grep tool content mode" "Grep" '{"pattern":"key","path":"/home/user/dev/webapp/backend/secrets","output_mode":"content"}'
# Legitimate shapes stay allowed
bash_case 0 "list the folder" "ls -la secrets/"
bash_case 0 "is it ignored" "git check-ignore -v secrets/llm_config.json"
bash_case 0 "names only via jq" "jq 'map_values(keys)' secrets/llm_config.json"
bash_case 0 "grep names only" "grep -l endpoint secrets/*.json"
bash_case 0 "a script that loads it" "../venv/bin/python scripts/check_prod_health.py --config secrets/llm_config.json"
bash_case 0 "grep the code for the var" "grep -rn LLM_CONFIG_JSON --include=*.py ."
bash_case 0 "deployment setting from ssm" "aws ssm get-parameter --name /webapp/prod/LLM_GENERATION_DEPLOYMENT --profile webapp"
bash_case 0 "mention in a quoted echo" 'echo "never cat secrets/llm_config.json"'
bash_case 0 "unrelated command" "git status --short"
tool_case 0 "Read an ordinary file" "Read" '{"file_path":"/home/user/dev/webapp/backend/core/secrets.py"}'
tool_case 0 "Grep tool file list" "Grep" '{"pattern":"key","path":"/home/user/dev/webapp/backend/secrets"}'

# The allow path is logged too
grep -q ' allow ' "$WORK/secret_print_guard.log" && { PASS=$((PASS+1)); echo "  ok    allow decisions are logged"; } \
  || { FAIL=$((FAIL+1)); echo "  FAIL  no allow line in the log"; }
echo "PASS=$PASS FAIL=$FAIL"; [ "$FAIL" -eq 0 ]
