#!/usr/bin/env bash
# approval-prompt guard (PreToolUse, Bash) — refuse command shapes that make Claude
# Code stop for a human approval even under bypassPermissions.
#
# THE SYMPTOM (owner, 2026-10-10, verbatim): "Just before going away, I open the
# session to see whether everything was fine and there was a decision for me. Which
# I had to press yes on. If something like that happens, it will be completely
# blocked. Can you ensure that this doesn't happen again?"
#
# MEASURED, guard session c7a4a017 (Lane-B batch 3, three Sonnet workers, all in
# bypassPermissions): every Bash call was accepted by mode EXCEPT exactly two, which
# carried `permissionDecision.source == "user_temporary"` -- a person pressed yes.
# Both, and only those two, passed `rm -rf` a COMMAND SUBSTITUTION:
#     rm -rf "$(cat /tmp/guard-E2-scratch-path)" /tmp/guard-E2-scratch-path
#     rm -rf "$(cat /tmp/claude-1000/e7/scratch)" /tmp/claude-1000/e7
# Seven other `rm -rf` calls in the same run were accepted silently, including
# `rm -rf "$SCRATCH"` with SCRATCH assigned from `$(mktemp ...)` earlier in the same
# command. So the trigger is the substitution in rm's own arguments (the harness
# cannot see what would be deleted), not rm, not -rf, not variables.
# Why workers write it: shell state does not persist between Bash calls, so a
# `mktemp -d` path gets saved to a file and read back in the cleanup call.
#
# REFUSE, don't ask: a refusal goes straight back to the model, which rewrites the
# call (a literal path, or assign to a variable first); a prompt waits for a human
# who may be away for hours. Exit 2 = block with stderr as guidance; exit 0 = allow.
# Only `rm` as a COMMAND WORD is checked (lib/command_words.py: start of a command, after a
# separator, then/do/else, or behind sudo/command/env/timeout...), and only a substitution in
# its own arguments counts, so `echo "rm $(x)"`, a commit message, a heredoc body or a comment
# that mentions rm are left alone, and so is a single-quoted '$(x)' (inert text).
# Logs each refusal, and each allowed command that contained an `rm`, to
# $CLAUDE_CONFIG_DIR/approval_prompt_guard.log.
# Tests: ~/.claude/tests/test_approval_prompt_guard.py

HOOK_LIB="$(dirname "${BASH_SOURCE[0]}")/lib" exec python3 -c "$(cat <<'PY'
import datetime, os, re, sys, json

sys.path.insert(0, os.environ["HOOK_LIB"])
from command_words import commands

try:
    payload = json.load(sys.stdin)
    cmd = (payload.get("tool_input") or {}).get("command") or ""
except Exception:
    sys.exit(0)


def log(verdict, detail):
    try:
        log_dir = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
        with open(os.path.join(log_dir, "approval_prompt_guard.log"), "a") as fh:
            fh.write(f"{datetime.datetime.now().isoformat(timespec='seconds')} {verdict} {detail[:160]!r}\n")
    except OSError:
        pass


bad = [c for c in commands(cmd) if c.name == "rm" and any(w.subst for w in c.words[1:])]
if not bad:
    if re.search(r"\brm\b", cmd):  # the text mentions rm, the parse says no rm gets a substitution
        log("allow", cmd.replace("\n", " "))
    sys.exit(0)

log("block", " ".join(w.text for w in bad[0].words))

sys.stderr.write(
    "Refused: `rm` is given a command substitution ($(...) or backticks). Claude Code stops\n"
    "for a HUMAN approval on that shape even in bypassPermissions, so an unattended run would\n"
    "sit blocked until someone presses yes (measured 2026-10-10: the only two approval prompts\n"
    "in a three-worker batch were exactly this).\n"
    "Rewrite it, then run it:\n"
    "  * use a literal path:            rm -rf /tmp/guard-C7-scratch\n"
    "  * or assign first, then delete:  D=$(cat /tmp/x-path); rm -rf -- \"$D\"\n"
    "For scratch space prefer a fixed, named directory (mkdir -p /tmp/<task>-scratch) over\n"
    "mktemp, since shell state does not survive between Bash calls.\n"
)
sys.exit(2)
PY
)"
