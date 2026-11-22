#!/usr/bin/env bash
# agy print-mode guard (PreToolUse, Bash) — `agy -p` reports success it did not have.
#
# THE SYMPTOM (measured 2026-09-03, five consecutive runs in one session): every run printed
# the SAME single line and exited 0:
#   jetski: no output produced — a tool required the "X" permission that headless mode
#   cannot prompt for, so it was auto-denied.
# The actual outcomes behind that identical output were: seven files staged · A GIT COMMIT
# CREATED · nothing · a script written and chmod +x'd · nothing. So exit 0 plus "no output"
# does NOT mean "no change" — work lands before the denial, and the caller cannot tell.
#
# ROOT CAUSE: headless mode has no way to prompt for a tool permission, so it auto-denies and
# treats that as "produced no output" rather than as a failure. The exit status never reflects it.
#
# ENFORCE: route print-mode agy through `agy-run`, which classifies the outcome (77 = denied,
# 78 = unproven silence, else passthrough) and prints what agy actually did, read from its own
# transcript. Interactive `agy` is untouched — only print mode is broken.
#
# Why enforce on day one rather than observe first (poll_loop_guard's doctrine): the match is
# a documented flag on a single command, and the remedy cannot break a correct call — agy-run
# forwards every argument and passes the real exit code through. False-positive cost is one
# word; the false-negative cost is acting on a fabricated success.
# ESCAPE HATCH: prefix one call with CCLAUDE_AGYGUARD_MODE=observe.

input="$(cat 2>/dev/null)" || exit 0
[ -z "$input" ] && exit 0

log="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/agy_print_guard.log"
mode="${CCLAUDE_AGYGUARD_MODE:-block}"

# `agy` as a COMMAND WORD (lib/command_words.py: start, after a separator or prefix such as
# timeout/sudo/env, inside $( ) or `bash -c`) with a print-mode flag among ITS OWN arguments.
# `agy-run`, `legacy_agy`, prose in a heredoc or a quoted argument, and `-p` belonging to
# some other command on the line never match.
# Prints "print" (block-worthy), "mention" (text says agy, parse says no print-mode call), or nothing.
verdict="$(HOOK_LIB="$(dirname "${BASH_SOURCE[0]}")/lib" python3 -c "$(cat <<'PY'
import json, os, re, sys
sys.path.insert(0, os.environ["HOOK_LIB"])
from command_words import commands
try:
    cmd = (json.load(sys.stdin).get("tool_input") or {}).get("command") or ""
except Exception:
    sys.exit(0)
FLAG = re.compile(r"^(-p|--print|--prompt)(=|$)")
if any(c.name == "agy" and any(FLAG.match(a) for a in c.args) for c in commands(cmd)):
    print("print")
elif re.search(r"\bagy\b", cmd):
    print("mention")
PY
)" <<<"$input")"
[ -z "$verdict" ] && exit 0
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)"
if [ "$verdict" = mention ]; then
  printf '%s allow cmd=%.160s\n' "$(date -Is)" "$cmd" >> "$log" 2>/dev/null || true
  exit 0
fi

printf '%s %s cmd=%.160s\n' "$(date -Is)" "$mode" "$cmd" >> "$log" 2>/dev/null || true
[ "$mode" = "observe" ] && exit 0

cat >&2 <<'MSG'
AGY PRINT-MODE GUARD — BLOCKED. `agy -p` cannot tell you whether it worked.

MEASURED on this machine (2026-09-03): five consecutive `agy -p` runs each printed the
same single line — "no output produced ... auto-denied" — and each exited 0. What had
actually happened behind that identical output was:
  run 1: seven files staged      run 2: A GIT COMMIT CREATED      run 3: nothing
  run 4: a script written + chmod +x                              run 5: nothing
Headless mode has no way to prompt for a tool permission, so it auto-denies and calls
that "no output" instead of a failure. Exit 0 therefore does NOT mean "no change" —
side effects land before the denial.

FIX: use the wrapper, same arguments.
    agy-run "<prompt>" --model <model> --effort high
It exits 77 when a permission was denied, 78 on unproven silence, otherwise passes agy's
own code through — and it prints what agy actually did, from agy's own transcript.

(Interactive `agy` is fine and is not blocked. A deliberate exception? Say why and ask.)
MSG
exit 2
