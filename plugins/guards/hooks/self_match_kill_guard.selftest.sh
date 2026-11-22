#!/usr/bin/env bash
# Self-test for self_match_kill_guard.sh, in the secret_print_guard.selftest.sh convention: real PreToolUse payloads,
# assert the exit status (0 = allowed, 2 = blocked). Run: bash self_match_kill_guard.selftest.sh
set -u
HOOK="${HOOKS_DIR:-$(dirname "$(readlink -f "$0")")}/self_match_kill_guard.sh"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
export CLAUDE_CONFIG_DIR="$WORK"  # keep the real log out of a test run
PASS=0; FAIL=0
check() { # check <expected_exit> <description> <command>
  local want=$1 desc=$2
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$3" \
    | bash "$HOOK" > "$WORK/out" 2>&1
  local got=$?
  if [ "$got" -eq "$want" ]; then PASS=$((PASS+1)); printf '  ok    %s\n' "$desc"
  else FAIL=$((FAIL+1)); printf '  FAIL  %s (wanted %s, got %s)\n' "$desc" "$want" "$got"; cat "$WORK/out"; fi
}
# The real incidents (21 Nov 2026)
check 2 "remote gate check found itself (bracket text appears later)" \
  "timeout -k 5 1200 ssh -n cluster 'cd ~/project && pgrep -u \$USER -f \"cluster_[s]ubmit\" >/dev/null && { echo wait; exit 3; }; bash scripts/cluster_submit.sh job.sbatch'"
check 2 "pkill of a pattern in its own command" "pkill -f swe64_arfc_divergence_probe; sleep 1; ps -ef | grep probe"
check 2 "plain pgrep, measured to find the wrapper shell" "pgrep -af zzqq_unique_marker"
# The obvious ways around it
check 2 "long option" "pkill --full divergence_probe"
check 2 "absolute path" "/usr/bin/pgrep -f 'submit_study' >/dev/null && echo busy"
check 2 "inside bash -c" "bash -c 'pgrep -f foo_bar && echo yes'"
check 2 "combined short flags" "pgrep -alf foo_bar"
# Legitimate shapes stay allowed
check 0 "bracket form whose text appears nowhere else" "pgrep -af 'zzqq_[u]nique_marker2'"
check 0 "exact name, no -f" "pgrep -x python3"
check 0 "kill by PID" "kill 232309"
check 0 "a script being written (heredoc body)" "cat > s.sh <<'EOF'
while pgrep -f 'bash .*submit_study_(rest|extra).sh' >/dev/null; do sleep 30; done
EOF
chmod +x s.sh"
check 0 "a grep for the words" "grep -n 'pgrep -f foo' run.sh"
check 0 "a commit message naming it" "git commit -m 'fix: pkill -f pattern matched the caller'"
check 0 "no pgrep at all" "ls -la"
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
