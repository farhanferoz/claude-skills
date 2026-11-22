#!/usr/bin/env bash
# self-match guard (PreToolUse, Bash) -- a `pgrep -f`/`pkill -f` pattern that matches the caller's own command line.
#
# THE SYMPTOM (a research project, 21 Nov 2026, three times in one day): `pkill -f <pattern>` killed the session's own
# shell twice, and `pgrep -f 'cluster_[s]ubmit' && exit 3` refused a gate run because it found itself.
#
# WHY: `-f` matches the pattern against the FULL command line of every process except pgrep itself. Every Bash call runs
# inside a wrapper `bash -c '<the whole command>'` that stays alive while the command runs (measured 21 Nov: a plain
# `pgrep -af zzqq_unique_marker` printed the wrapper shell, rc 0). So a pattern that matches its own command text always
# finds that wrapper: pgrep always succeeds, pkill kills the caller. Over ssh the same holds on the far side: the remote
# `bash -c '<remote command>'` carries the pattern too. The bracket form (`cluster_[s]ubmit`) avoids it only while the
# text it matches (`cluster_submit`) appears nowhere else in the command -- on 21 Nov it appeared later in the same line.
#
# RULE: refuse a `pgrep`/`pkill` with -f (or --full) whose pattern matches the text its own shell carries: the whole
# command for a call at top level, the nested string for a call inside a quoted remote or `bash -c` command. Calls written
# inside a heredoc body are not run by this command (a script being written, or stdin to a remote shell whose own
# command line is `bash -s`), so they are not checked. An unparseable command is allowed and logged as such.
#
# Logs every decision on a command that names pgrep or pkill (allow, block, unparsed, no -f) to
# $CLAUDE_CONFIG_DIR/self_match_kill_guard.log.

exec python3 -c "$(cat <<'PY'
import datetime, json, os, re, shlex, sys

try:
    cmd = (json.load(sys.stdin).get("tool_input") or {}).get("command") or ""
except (ValueError, AttributeError):
    sys.exit(0)
if not re.search(r"\b(pgrep|pkill)\b", cmd):
    sys.exit(0)

# Options of procps pgrep/pkill that take a value (a fact about their argv), so the value is not read as the pattern.
TAKES_VALUE = {"-d", "-g", "-G", "-P", "-s", "-t", "-u", "-U", "-F", "--delimiter", "--pgroup", "--group", "--parent",
               "--session", "--terminal", "--euid", "--uid", "--pidfile", "--signal", "--ns", "--nslist", "-q", "--queue"}
SEPARATORS = {";", "&&", "||", "|", "&", "\n", "(", ")", "|&", ";;"}


def strip_heredocs(text):
    """The command with every heredoc body removed (bodies are text, not commands run now)."""
    out, lines, i = [], text.split("\n"), 0
    opener = re.compile(r"<<(-?)\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2")
    while i < len(lines):
        line = lines[i]
        out.append(line)
        ends = [(m.group(1) == "-", m.group(3)) for m in opener.finditer(line)]
        i += 1
        for dash, word in ends:
            while i < len(lines) and (lines[i].lstrip("\t") if dash else lines[i]) != word:
                i += 1
            i += 1  # the delimiter line
    return "\n".join(out)


def calls(text, seen, depth=0):
    """(pattern, seen_text) for every pgrep/pkill -f in ``text``; nested command strings recurse with their own text."""
    lexer = shlex.shlex(text, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    lexer.commenters = ""
    tokens = list(lexer)
    found, segment_start = [], 0
    for k, tok in enumerate(tokens):
        if tok in SEPARATORS:
            segment_start = k + 1
            continue
        nested = re.search(r"\b(pgrep|pkill)\b", tok) and re.search(r"\s", tok)
        if nested:
            # A command string another shell runs: ssh's remote command or a `-c` string. Any other quoted text that
            # names pgrep (a grep pattern, a commit message) is text, not a call.
            runs = (k > 0 and tokens[k - 1] == "-c") or "ssh" in map(os.path.basename, tokens[segment_start:k])
            if runs and depth < 3:
                found += calls(strip_heredocs(tok), tok, depth + 1)
            continue
        if os.path.basename(tok) not in ("pgrep", "pkill"):
            continue
        full, pattern, j = False, None, k + 1
        while j < len(tokens) and tokens[j] not in SEPARATORS:
            t = tokens[j]
            if t == "--full" or (t.startswith("-") and not t.startswith("--") and "f" in t[1:] and not t[1:].isdigit()):
                full = True
            if t in TAKES_VALUE:
                j += 2
                continue
            if t.startswith("-") and len(t) > 1:
                j += 1
                continue
            pattern = t
            break
        found.append((full, pattern, seen))
    return found


log_path = os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude"), "self_match_kill_guard.log")


def log(decision, detail):
    try:
        with open(log_path, "a") as f:
            f.write(f"{datetime.datetime.now().isoformat(timespec='seconds')}\t{decision}\t{detail}\t{cmd[:300]!r}\n")
    except OSError:
        pass


try:
    found = calls(strip_heredocs(cmd), cmd)
except ValueError as exc:
    log("unparsed", str(exc))
    sys.exit(0)

hits = []
for full, pattern, seen in found:
    if not full or pattern is None:
        log("allow", "no -f" if not full else "no pattern")
        continue
    try:
        matched = re.search(pattern, seen) is not None
    except re.error:
        matched = pattern in seen
    log("block" if matched else "allow", f"pattern={pattern!r}")
    if matched:
        hits.append(pattern)

if hits:
    shown = ", ".join(repr(p) for p in hits)
    sys.stderr.write(
        f"BLOCKED: pgrep/pkill -f pattern {shown} matches this command's own text, so it finds the shell running "
        "this command (pgrep always succeeds; pkill kills the caller). Measured 21 Nov 2026: a plain "
        "`pgrep -af <marker>` printed the session's own wrapper shell.\n"
        "DO INSTEAD: target the process exactly: its PID (from the command that started it, or `ps -eo pid,args` "
        "filtered on an exact argv field), `pgrep -x <name>` without -f, or wait on a log line or file the "
        "process writes. A bracketed pattern (`foo_[b]ar`) works only when the text it matches (`foo_bar`) appears "
        "nowhere else in the command.\n"
        "If this refusal is wrong for this command, say so to the owner rather than rewording around it.\n")
    sys.exit(2)
sys.exit(0)
PY
)"
