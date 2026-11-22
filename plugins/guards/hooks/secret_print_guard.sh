#!/usr/bin/env bash
# PreToolUse(Bash|Read|Grep) -- refuse printing a secrets file's CONTENTS into a transcript.
#
# Why: twice in one web-app project an agent printed live Azure OpenAI keys into its own transcript
# (2026-10-27: the LLM_CONFIG_JSON value; 2026-11-17: `cat secrets/llm_config.json | python3 -c
# "<redact fields named like key>"`, whose redaction missed nested fields). A transcript is kept,
# cached and read back; a printed key cannot be un-printed. Rule: ~/.claude/CLAUDE.md "D41"-style
# mechanical guard for a repeat failure (that project's decision record).
#
# What it refuses (command words via lib/command_words.py, not substrings of the whole line):
#   Bash: a reader/printer (cat, head, sed, jq, python -c, ...) whose argument names a file in a
#         `secrets/` directory; `printenv`/`echo` of $LLM_CONFIG_JSON; `aws ssm get-parameter(s)`
#         of a name containing LLM_CONFIG_JSON.
#   Read: a file under a `secrets/` directory.
#   Grep: content output inside a `secrets/` directory.
# What it allows: ls/stat/wc/test/git on such files; `jq 'keys'`-style name-only reads; a Python
# SCRIPT (python x.py) that loads the file in-process; grep -l/-c/-q (names or counts only).
# Every decision that involves a secrets reference is logged, allows included:
#   ${CLAUDE_CONFIG_DIR:-~/.claude}/secret_print_guard.log
# Self-test: bash ~/.claude/hooks/secret_print_guard.selftest.sh

input="$(cat 2>/dev/null)" || exit 0
[ -z "$input" ] && exit 0
log="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/secret_print_guard.log"

verdict="$(HOOK_LIB="$(dirname "${BASH_SOURCE[0]}")/lib" python3 -c "$(cat <<'PY'
import json, os, re, sys
sys.path.insert(0, os.environ["HOOK_LIB"])
from command_words import commands

SECRET_PATH = re.compile(r"(^|[/'\"(\s])secrets/[^/\s'\"]+")  # also inside interpreter code strings
SECRET_DIR = re.compile(r"(^|/)secrets(/|$)")
# Fact: commands that put a file's bytes on stdout (or an interpreter that can).
PRINTERS = {"cat", "head", "tail", "less", "more", "bat", "sed", "awk", "gawk", "jq", "yq", "grep", "rg",
            "egrep", "strings", "xxd", "od", "hexdump", "base64", "cut", "tr", "sort", "uniq", "nl", "tac",
            "diff", "column", "python", "python3", "node", "perl", "ruby", "tee", "dd"}
NAME_ONLY_JQ = re.compile(r"^\s*(keys(\[\])?|map_values\(keys\)|\.\[\]\s*\|\s*keys|to_entries\s*\|\s*map\(\.key\))\s*$")
COUNT_ONLY_GREP = {"-l", "-L", "-c", "-q", "--files-with-matches", "--files-without-match", "--count", "--quiet"}
LLM_VAR = "LLM_CONFIG_JSON"

try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
tool, ti = d.get("tool_name", ""), d.get("tool_input") or {}

def out(v, why):
    print(f"{v}\t{why}")
    sys.exit(0)

if tool == "Read":
    if SECRET_PATH.search(ti.get("file_path") or ""):
        out("block", "read of a secrets file")
    sys.exit(0)
if tool == "Grep":
    if SECRET_DIR.search(ti.get("path") or "") or SECRET_PATH.search(ti.get("glob") or ""):
        if ti.get("output_mode") == "content":
            out("block", "grep content inside secrets/")
        out("allow", "grep names/counts inside secrets/")
    sys.exit(0)
if tool != "Bash":
    sys.exit(0)

seen = False
for c in commands(ti.get("command") or ""):
    args = c.args
    if c.name in {"printenv", "echo", "printf"} and any(LLM_VAR in a for a in args):
        out("block", f"{c.name} of {LLM_VAR}")
    if c.name == "aws" and "ssm" in args and any(LLM_VAR in a for a in args) \
            and any(a.startswith("get-parameter") for a in args):
        out("block", f"aws ssm read of {LLM_VAR}")
    hits = [a for a in args if SECRET_PATH.search(a)]
    if not hits:
        continue
    seen = True
    if c.name not in PRINTERS:
        continue
    if c.name in {"python", "python3", "node", "perl", "ruby"}:
        first = next((a for a in args if not a.startswith("-")), "")
        if "-c" not in args and "-e" not in args and first.endswith((".py", ".js", ".pl", ".rb")) \
                and not SECRET_PATH.search(first):
            continue  # a script that loads the file in-process prints nothing by itself
    if c.name == "jq" and any(NAME_ONLY_JQ.match(a) for a in args if not a.startswith("-") and a not in hits):
        continue
    if c.name in {"grep", "rg", "egrep"} and COUNT_ONLY_GREP & set(args):
        continue
    out("block", f"{c.name} prints {hits[0]}")
if seen:
    out("allow", "secrets reference, no printing command")
PY
)" <<<"$input")"
[ -z "$verdict" ] && exit 0
decision="${verdict%%	*}"; why="${verdict#*	}"
what="$(printf '%s' "$input" | jq -r '.tool_name + " " + ((.tool_input.command // .tool_input.file_path // .tool_input.path // "")|tostring)' 2>/dev/null)"
printf '%s %s why=%s what=%.200s\n' "$(date -Is)" "$decision" "$why" "$what" >> "$log" 2>/dev/null || true
[ "$decision" = allow ] && exit 0

cat >&2 <<MSG
SECRET PRINT GUARD — BLOCKED ($why).
This would print a secrets file's contents (API keys) into the transcript, where it stays.
Twice before, a "redacting" one-liner leaked keys anyway (2026-10-27, 2026-11-17).

Read only what you need, by NAME:
  - which entries/fields exist:   jq 'map_values(keys)' <file>     (or jq 'keys')
  - a model deployment:            the *_DEPLOYMENT setting, never LLM_CONFIG_JSON
  - code that uses it:             run the project's script; it loads the file in-process

If you need a value itself, or think this block is wrong here, say why and ask the owner.
MSG
exit 2
