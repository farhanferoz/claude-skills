#!/usr/bin/env bash
# PreToolUse (Write) — repo-clutter guard.
#
# Denies (exit 2, stderr fed back to the model) writes of junk-named files
# into project directories: tmp_*/temp_*/scratch_*/debug_* prefixes, *.tmp,
# and bare out/output dumps. These belong in the session scratchpad (path in
# the system prompt) or a deliberate location with a descriptive name.
#
# Deliberately conservative — allowed through: anything already under /tmp,
# a scratchpad, or a directory named temp/ tmp/ scratch/ (a repo that HAS a
# designated scratch area is using it correctly). Fail-open on any parse error.

# MODES: CCLAUDE_CLUTTER_MODE = enforce (default) | observe | off. Added
# 2026-08-11: this was the ONLY blocking guard here with no escape hatch, so a
# false positive could be worked around only by renaming the file. Every other
# guard on this machine ships one, and this guard's rule is a NAME match — the
# fuzziest kind — which is exactly the case that needs an out.
payload="$(cat 2>/dev/null || true)"

python3 - "$payload" "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" <<'PY'
import json, os, re, sys, time

MODE = os.environ.get("CCLAUDE_CLUTTER_MODE", "enforce")


def allow():
    sys.exit(0)


if MODE == "off":
    allow()

try:
    fp = json.loads(sys.argv[1]).get("tool_input", {}).get("file_path", "")
except Exception:
    allow()
if not fp:
    allow()


def note(tag, path):
    """Log every decision. Added 2026-08-10: this guard ran for a month with NO
    log, so 'is it firing, or is it being stepped around?' was unanswerable —
    the same blind spot that left poll_loop_guard un-flippable until four weeks
    of data existed. A guard you cannot measure cannot be calibrated."""
    config = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
    log = os.path.join(config, "clutter_guard.log")
    try:
        line = "%s %s %s" % (time.strftime("%Y-%m-%dT%H:%M:%S"), tag, path[:160])
        prev = open(log).read().splitlines()[-499:] if os.path.exists(log) else []
        open(log, "w").write("\n".join(prev + [line]) + "\n")
    except OSError:
        pass

norm = fp.replace("\\", "/")
# Designated scratch locations are fine.
if norm.startswith("/tmp/") or "/scratchpad/" in norm:
    allow()
parts = norm.lower().split("/")
if any(d in ("tmp", "temp", "scratch", ".scratch") for d in parts[:-1]):
    allow()

base = parts[-1]

# The name rule lives in lib/junk_names.py, shared with
# scripts/end_of_work_audit.py (which finds what got past this guard).
sys.path.insert(0, os.path.join(sys.argv[2], "lib"))  # lib/ ships beside this hook
try:
    from junk_names import is_junk
except ImportError:
    allow()
if is_junk(base):
    note("BLOCK" if MODE == "enforce" else "OBSERVE", fp)
    msg = (
        "Clutter guard: '%s' looks like a temporary/one-off file being written "
        "into the project. Put it in the session scratchpad directory (path in "
        "your system prompt) or /tmp instead; if it is a real deliverable, give "
        "it a descriptive name in the proper directory. Track anything temporary "
        "you create and remove it before finishing the task.\n"
        "If this name is genuinely right, say why and ask (D15).\n" % fp)
    if MODE != "enforce":
        sys.stderr.write("NOTE (clutter, observe mode): " + msg)
        allow()
    sys.stderr.write(msg)
    sys.exit(2)

# ---------------------------------------------------------------------------
# NOTES ORGANISATION — added 2026-09-15 after the owner opened
# notes/design/rollout_model_change/ and found 63 loose files named like
# results_task14_w4s.md, across four studies, with two more added that day:
# "you need to stop creating this garbage in the first place"; "what is task 14?
# Who is supposed to understand these garbage names?". A memory rule alone had
# not held, so the rule lives here. It checks only NEW files and NEW folders, so
# existing legacy paths can still be edited until they are reorganised.
#   1. Anywhere under a notes/ directory: a new folder or file name may not carry
#      an internal code (task/stage/phase/wave/step number, W4S, D123, T5.8,
#      A4_2, arm B, weekend) and a new folder name may not carry a date. Codes
#      belong in the study's study.json under "internal_labels".
#   2. Under notes/design/: no new loose file at the root or directly in a
#      programme folder (README.md excepted); content lives in
#      notes/design/<programme>/<study>/.
#   3. A study folder must hold study.json before anything else is written into it.
CODE_PATTERNS = (
    (r"task[_-]?\d", "a task number"),
    (r"stage[_-]?\d", "a stage number"),
    (r"phase[_-]?\d", "a phase number"),
    (r"wave[_-]?\d", "a wave number"),
    (r"step[_-]?\d", "a step number"),
    (r"(^|[_.-])w\d+[a-z0-9]*($|[_.-])", "a work-item code like W4S"),
    (r"(^|[_.-])[dq]\d{2,3}($|[_.-])", "a decision/question id like D123"),
    (r"(^|[_.-])t\d+([_.]\d+)?($|[_.-])", "a task code like T5_8"),
    (r"(^|[_.-])[abceg]\d+([_.]\d+)?($|[_.-])", "an item code like A4_2, B3, G2"),
    (r"(^|[_.-])arm[_-]?[a-z]($|[_.-])", "an arm label like arm_b"),
    (r"weekend", "a weekend label"),
)
DATE = re.compile(r"20\d\d[-_]?\d\d([-_]?\d\d)?")


def refuse_notes(msg):
    note("BLOCK-NOTES" if MODE == "enforce" else "OBSERVE-NOTES", fp)
    msg += ("Layout: notes/design/<programme>/<study>/ with both names saying what is "
            "investigated; the file name says what it contains; internal codes go in "
            "<study>/study.json under \"internal_labels\".\n")
    if MODE != "enforce":
        sys.stderr.write("NOTE (notes organisation, observe mode): " + msg)
        allow()
    sys.stderr.write(msg)
    sys.exit(2)


segs = norm.split("/")
if "notes" in segs and not os.path.exists(fp):
    i = len(segs) - 1 - segs[::-1].index("notes")
    tail = segs[i + 1:]
    for k, name in enumerate(tail):
        is_file = k == len(tail) - 1
        if not is_file and os.path.isdir("/".join(segs[: i + 2 + k])):
            continue  # an existing folder is legacy, not a new name
        low = (name.rsplit(".", 1)[0] if is_file else name).lower()
        hits = [label for pattern, label in CODE_PATTERNS if re.search(pattern, low)]
        if not is_file and DATE.search(low):
            hits.append("a date")
        if hits:
            refuse_notes(
                "Notes guard: the new %s '%s' carries %s. Name it by what it is, and "
                "record the code in study.json instead.\n"
                % ("file" if is_file else "folder", name, ", ".join(hits)))
    if tail and tail[0] == "design":
        rel = tail[1:]
        base_l = rel[-1].lower() if rel else ""
        if 1 <= len(rel) <= 2 and base_l != "readme.md":
            refuse_notes(
                "Notes guard: '%s' would be a loose file %s. Put it inside the study "
                "folder it belongs to.\n"
                % (rel[-1], "at the top of notes/design/" if len(rel) == 1
                   else "directly in the programme folder '%s/'" % rel[0]))
        if len(rel) >= 3 and base_l != "study.json":
            study = "/".join(segs[: i + 4])
            if not os.path.isfile(study + "/study.json"):
                refuse_notes(
                    "Notes guard: study folder '%s' has no study.json. Write it first "
                    "(title, question, answer, status, plan, start_here, internal_labels, "
                    "decisions), then add content.\n" % study)
allow()
PY
exit $?
