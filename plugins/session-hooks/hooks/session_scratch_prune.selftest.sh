#!/usr/bin/env bash
# Self-test for session_scratch_prune.sh: a temporary scratch root with one folder per rule, stub slurm commands on PATH,
# real processes for the process rules. Run: bash ~/.claude/hooks/session_scratch_prune.selftest.sh  (exit 0 = all pass)
set -u
HOOK="$(dirname "$0")/session_scratch_prune.sh"
WORK=$(mktemp -d); PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; rm -rf "$WORK"; }
trap cleanup EXIT
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1"; fi; }

PROJ="$WORK/proj"; mkdir -p "$PROJ"
ROOT="$WORK/root"; SLUG="$ROOT/$(echo "$PROJ" | tr / -)"; mkdir -p "$SLUG"
id() { python3 -c 'import uuid; print(uuid.uuid4())'; }
CUR=$(id); OLD=$(id); RECENT=$(id); RESUMED=$(id); PROC=$(id); CWD=$(id); SLURM=$(id); LINK=$(id)
make_old() { mkdir -p "$SLUG/$1/scratchpad/deep"; echo x > "$SLUG/$1/scratchpad/deep/f.txt"; find "$SLUG/$1" -exec touch -h -d '3 days ago' {} +; }
for s in "$CUR" "$OLD" "$RECENT" "$RESUMED" "$PROC" "$CWD" "$SLURM"; do make_old "$s"; done
touch "$SLUG/$RECENT/scratchpad/deep/f.txt"                     # one fresh file deep inside
mkdir -p "$SLUG/not-a-session/scratchpad"; find "$SLUG/not-a-session" -exec touch -h -d '3 days ago' {} +
mkdir -p "$WORK/outside"; echo keep > "$WORK/outside/precious.txt"; ln -s "$WORK/outside" "$SLUG/$LINK"
echo "see /tmp/x/$RESUMED/scratchpad/run.sh" > "$PROJ/RESUME.md"
python3 -c 'import time; time.sleep(120)' "$PROC" & PIDS+=($!)
(cd "$SLUG/$CWD/scratchpad" && exec sleep 120) & PIDS+=($!)
find "$SLUG/$CWD" -exec touch -h -d '3 days ago' {} +            # the subshell's cd must not count as a change
mkdir -p "$WORK/stub" "$WORK/stubfail"
echo "#!/bin/sh
python3 $SLUG/$SLURM/scratchpad/job.py" > "$WORK/job.sbatch"
printf '#!/bin/sh\necho 12345\n' > "$WORK/stub/squeue"
printf '#!/bin/sh\necho "JobId=12345 JobName=x Command=%s/job.sbatch WorkDir=/home"\n' "$WORK" > "$WORK/stub/scontrol"
printf '#!/bin/sh\necho "slurm down" >&2; exit 1\n' > "$WORK/stubfail/squeue"
chmod +x "$WORK"/stub/* "$WORK"/stubfail/*
sleep 0.3

run() { # run <PATH-prefix> [mode]
  printf '{"session_id":"%s","cwd":"%s","hook_event_name":"SessionStart"}' "$CUR" "$PROJ" | \
    env PATH="$1:$PATH" CCLAUDE_SCRATCH_ROOT="$ROOT" CLAUDE_CONFIG_DIR="$WORK/cfg" CLAUDE_PROJECT_DIR="$PROJ" \
        CCLAUDE_SCRATCH_PRUNE="${2:-enforce}" bash "$HOOK"
}
LOG="$WORK/cfg/session_scratch_prune.log"

# 1. a failing squeue: nothing is deleted, and the log says why
run "$WORK/stubfail"; check "hook exits 0 when a check fails" "[ $? -eq 0 ]"
check "failing squeue deletes nothing" "[ -d '$SLUG/$OLD' ]"
check "failing squeue is logged as keep-all" "grep -q 'keep-all' '$LOG'"

# 2. observe mode: logs would-delete, deletes nothing
run "$WORK/stub" observe
check "observe deletes nothing" "[ -d '$SLUG/$OLD' ]"
check "observe logs would-delete for the old folder" "grep -q \"$OLD	would-delete\" '$LOG'"

# 3. enforce
run "$WORK/stub"
check "old unreferenced folder is deleted" "[ ! -e '$SLUG/$OLD' ]"
check "deletion is logged with its size" "grep -q \"$OLD	deleted	.*MB\" '$LOG'"
check "current session is kept" "[ -d '$SLUG/$CUR' ] && grep -q \"$CUR	keep	current session\" '$LOG'"
check "a fresh file deep inside keeps the folder" "[ -d '$SLUG/$RECENT' ]"
check "a folder named in RESUME.md is kept" "[ -d '$SLUG/$RESUMED' ]"
check "a folder named on a process command line is kept" "[ -d '$SLUG/$PROC' ]"
check "a folder holding a process's cwd is kept" "[ -d '$SLUG/$CWD' ]"
check "a folder named in a queued job's batch script is kept" "[ -d '$SLUG/$SLURM' ]"
check "a non-session folder is untouched" "[ -d '$SLUG/not-a-session' ]"
check "a symlinked session name is not followed" "[ -L '$SLUG/$LINK' ] && [ -f '$WORK/outside/precious.txt' ]"
check "every run logs a summary" "[ \$(grep -c 'summary' '$LOG') -eq 2 ]"

echo "session_scratch_prune selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
