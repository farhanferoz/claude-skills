"""Turn a Bash command into its simple commands, so a guard decides on command words and
argument tokens, never on raw text.

WHY (audit 2026-10-28, block samples): six guards matched words anywhere in the command
text, so `grep -n 'uv sync' notes.md`, a heredoc that rewrites RESUME.md, `ps | grep
'next dev'` and `man sbatch` were blocked for merely MENTIONING a word.

WHAT `commands()` DOES. It scans the text once, tracking quotes, heredocs and comments, and
returns every simple command as a `Command`:
  * the text of quoted arguments is data: it is one word, never searched for commands;
  * heredoc bodies and `# comments` are dropped;
  * `;  &&  ||  |  &  newline  (  )  { }` and the keywords then/do/else/if/while/... end a
    command; a command word is the first word after them and after the prefixes sudo,
    env (+ VAR=val), timeout [opts] N, nice [-n N], nohup, time, command, exec, builtin;
  * `$( )` and backticks (outside single quotes) are parsed as commands of their own;
  * the string given to `bash|sh|zsh -c`, to `eval`, and the remote command of `ssh host ...`
    is parsed too: that text really is executed.
Word.subst is True when the word holds a `$(`/backtick outside single quotes, which is
what approval_prompt_guard needs and a quote-stripping tokenizer cannot say.

Deviation from "parse with shlex": shlex throws away which quote a word was in, so
`'$(x)'` (inert) and `"$(x)"` (runs) look identical. This scanner keeps that bit. The
existing shlex users (container_lifecycle_guard, docker_hostnet_guard,
foreground_long_job_guard, test_scope_guard) tokenise with the same separators and prefix
list; only container_lifecycle_guard and the five other hooks in this change use this one.

Fail-open: `commands()` returns [] for text it cannot scan; callers allow on [].
"""
import os
import re
from dataclasses import dataclass, field

KEYWORDS = {"then", "do", "else", "elif", "if", "while", "until", "!", "{", "}", "fi", "done"}
ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
REDIRECT = re.compile(r"^\d*[<>]")
DURATION = re.compile(r"^\d[\d.]*[smhd]?$")
SHELLS = {"bash", "sh", "zsh", "dash"}
# option flags of each prefix that consume the next word
PREFIX_VALUE_FLAGS = {
    "sudo": {"-u", "-g", "-C", "-h", "-p", "-U", "-D", "-r", "-t"},
    "env": {"-u", "-C", "-S"},
    "timeout": {"-k", "-s", "--kill-after", "--signal"},
    "nice": {"-n", "--adjustment"},
    "nohup": set(),
    "time": {"-f", "-o", "--format", "--output"},
    "command": set(),
    "exec": {"-a"},
    "builtin": set(),
}


@dataclass(frozen=True)
class Word:
    text: str
    subst: bool = False


@dataclass
class Command:
    words: list  # list[Word]; words[0] is the command word (empty for a bare VAR=val)
    assigns: dict = field(default_factory=dict)  # leading VAR=val, incl. after `env`

    @property
    def name(self):
        return os.path.basename(self.words[0].text) if self.words else ""

    @property
    def args(self):
        return [w.text for w in self.words[1:]]


def commands(text):
    try:
        out = []
        _parse(text, 0, None, out)
        return out
    except Exception:
        return []


def _parse(s, i, closer, out):
    """Scan s from i; append Commands to out; stop after `closer` (')' or '`') or at the
    end. Returns the index after the closer."""
    n = len(s)
    words, cur, subst, started = [], [], False, False
    heredocs = []  # (delimiter, strip_tabs) waiting for the next newline

    def end_word():
        nonlocal cur, subst, started
        if started:
            words.append(Word("".join(cur), subst))
        cur, subst, started = [], False, False

    def end_command():
        end_word()
        if words:
            _emit(words[:], out)
        words.clear()

    while i < n:
        c = s[i]
        if closer is not None and c == closer and closer in ")`":
            end_command()
            return i + 1
        if c == "\n":
            end_command()
            i += 1
            for delim, strip in heredocs:
                i = _skip_heredoc(s, i, delim, strip)
            heredocs.clear()
            continue
        if c in " \t":
            end_word()
            i += 1
            continue
        if c == "\\":
            if i + 1 < n and s[i + 1] != "\n":
                cur.append(s[i + 1])
                started = True
            i += 2
            continue
        if c == "#" and not started:
            while i < n and s[i] != "\n":
                i += 1
            continue
        if c == "'":
            j = s.find("'", i + 1)
            j = n if j < 0 else j
            cur.append(s[i + 1:j])
            started = True
            i = j + 1
            continue
        if c == '"':
            i += 1
            started = True
            while i < n and s[i] != '"':
                if s[i] == "\\" and i + 1 < n:
                    cur.append(s[i + 1])
                    i += 2
                elif s.startswith("$(", i) and not s.startswith("$((", i):
                    i = _parse(s, i + 2, ")", out)
                    subst = True
                    cur.append("$(...)")
                elif s[i] == "`":
                    i = _parse(s, i + 1, "`", out)
                    subst = True
                    cur.append("`...`")
                else:
                    cur.append(s[i])
                    i += 1
            i += 1
            continue
        if s.startswith("$((", i):
            j = s.find("))", i)
            j = n if j < 0 else j + 2
            cur.append(s[i:j])
            started = True
            i = j
            continue
        if s.startswith("$(", i):
            i = _parse(s, i + 2, ")", out)
            subst = started = True
            cur.append("$(...)")
            continue
        if c == "`":
            i = _parse(s, i + 1, "`", out)
            subst = started = True
            cur.append("`...`")
            continue
        if s.startswith("<<", i) and not s.startswith("<<<", i):
            m = re.match(r"<<(-?)\s*(?:'([^']*)'|\"([^\"]*)\"|\\?([^\s;&|()<>]+))", s[i:])
            if m:
                end_word()
                heredocs.append((m.group(2) or m.group(3) or m.group(4), bool(m.group(1))))
                i += m.end()
                continue
        if c in ";&|(){}" and not (c in "{}" and started):
            if c in "&|" and i + 1 < n and s[i + 1] == c:
                i += 1
            elif c == "&" and started and "".join(cur).endswith((">", "<")):
                cur.append(c)  # `2>&1`, `>&2`: a redirect, not a separator
                i += 1
                continue
            end_command()
            i += 1
            continue
        cur.append(c)
        started = True
        i += 1
    end_command()
    return n


def _skip_heredoc(s, i, delim, strip):
    n = len(s)
    while i < n:
        j = s.find("\n", i)
        line = s[i:] if j < 0 else s[i:j]
        i = n if j < 0 else j + 1
        if (line.lstrip("\t") if strip else line) == delim:
            break
    return i


def _emit(words, out):
    """Strip keywords, redirections and prefixes; record the command and recurse into
    `bash -c`, `eval` and `ssh host cmd`."""
    words = [w for w in words if not REDIRECT.match(w.text)] if any(
        REDIRECT.match(w.text) for w in words) else words
    assigns = {}
    i = 0
    while i < len(words):
        t = words[i].text
        base = os.path.basename(t)
        if t in KEYWORDS:
            i += 1
        elif ASSIGN.match(t):
            k, v = t.split("=", 1)
            assigns[k] = v
            i += 1
        elif base in PREFIX_VALUE_FLAGS:
            i += 1
            flags = PREFIX_VALUE_FLAGS[base]
            while i < len(words):
                w = words[i].text
                if w.startswith("-") and w != "--":
                    i += 2 if w in flags else 1
                elif base == "env" and ASSIGN.match(w):
                    k, v = w.split("=", 1)
                    assigns[k] = v
                    i += 1
                elif base == "timeout" and DURATION.match(w):
                    i += 1
                    break
                elif w == "--":
                    i += 1
                    break
                else:
                    break
        else:
            break
    rest = words[i:]
    cmd = Command(rest, assigns)
    out.append(cmd)
    if not rest:
        return
    name, args = cmd.name, cmd.args
    if name in SHELLS and "-c" in args:
        k = args.index("-c")
        if k + 1 < len(args):
            _parse(args[k + 1], 0, None, out)
    elif name == "eval" and args:
        _parse(" ".join(args), 0, None, out)
    elif name == "ssh":
        k = 0
        while k < len(args) and args[k].startswith("-"):
            k += 2 if args[k] in {"-p", "-i", "-l", "-o", "-F", "-J", "-L", "-R", "-D", "-b", "-c", "-E", "-S", "-W"} else 1
        if k + 1 < len(args):  # args[k] is the host
            _parse(" ".join(args[k + 1:]), 0, None, out)
