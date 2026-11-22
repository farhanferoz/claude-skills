#!/usr/bin/env bash
# PreToolUse(Agent, SendMessage) — a dispatch must name its tier (no silent
# inheritance) and must justify itself against doing the work inline.
#
# THE INCIDENT (first-person, 2026-08-10). Four `claude-code-guide` agents were
# dispatched in parallel to do web search and summarise. Every agent the user
# DEFINED is pinned — adjudicator/opus, task-worker/sonnet, utility-worker/haiku,
# all dr-*/sonnet — so the pinning discipline was complete for everything he
# built. `claude-code-guide` has no definition file at all: it is a BUILT-IN type,
# unpinned by construction, so it inherited the session model. In an Opus session
# every built-in type (claude-code-guide, Explore, Plan, general-purpose) is
# silently an Opus dispatch. Estimated cost of that one mistake: $10-30, against a
# stated estimate of "$8-12" that nothing ever reconciled.
#
# WHY A HOOK AND NOT A RULE. The rule already existed, verbatim, in CLAUDE.md
# ("Route via the pinned role agents … Ad-hoc model/effort only when no role
# fits"), re-injected by the orchestrator gate on EVERY prompt — it was in context
# nine times that session and did not bind. Re-injection frequency is not the
# lever. The only mechanisms in this setup with a proven record are the ones that
# exit non-zero.
#
# THE CHECK IS PURELY MECHANICAL — no judgment, so it can enforce from day one
# (the same property that let foreground_long_job_guard ship in enforce mode):
#   deny iff  subagent_type resolves to NO definition file carrying `model:`
#             AND the call passes no explicit `model`.
# A dispatch that names a pinned role agent, or states its own model, is untouched.
# The remedy is one word in the call, so a false denial costs a single retry.
#
# DELIBERATELY NOT CHECKED HERE: whether a fan-out is genuinely independent
# (disjoint write sets vs merely different questions — the other half of the same
# incident). That is judgment, it cannot be verified from a tool payload, and a
# required magic phrase would become ritual within a week. It needs a convention
# decision, not a regex.
#
# RE-RAISED AND DECLINED AGAIN 2026-08-11, this time on measurement rather than
# prediction. The register (issue 13b) asked for the brief to DECLARE each
# worker's write set. Note that is not actually in conflict with the paragraph
# above — declaring is not verifying — so the question was only ever whether the
# declaration would be worth its cost. Two numbers say no:
#   * It would not have caught the reference case. Each of the four agents in the
#     2026-08-10 incident could have named a different output file and still been
#     re-reading one corpus. The register's own bar for the tier check was "would
#     have blocked all four dispatches"; this fails that bar.
#   * A fan-out-SIZE gate, the obvious alternative, fires far too often to
#     survive. Census of 1,007 sessions: 3+ agents in one turn is 245 of 922
#     dispatching turns — 26.6%. The largest (35 agents: 22 verifiers, 7
#     extractors, 5 checkers, 1 synthesiser) is the tiered deep-research workflow
#     working as designed, and the next several are 15-19 task-workers, pinned to
#     sonnet by definition. A guard firing on a quarter of correct dispatches
#     teaches the escape hatch.
# ⇒ The TIER half of that incident is mechanized and enforcing (below). The
#   OVERLAP half is recorded as unenforceable, per the placement rule: judgment
#   with no mechanical shadow gets written down, and its failure made cheap to
#   spot — here by the `agent-cost` skill, which rolls up per-subagent spend from
#   the transcripts after the fact. Do not re-open this without new evidence;
#   both mechanical shapes have now been costed and rejected.
#
# MODES: CCLAUDE_AGENTGUARD_MODE = enforce (default) | observe | off.
# FAIL-OPEN ALWAYS: unparseable payload, missing field, unreadable agents dir ->
# allow. A guard that blocks dispatch on bad data is worse than no guard.

payload="$(cat 2>/dev/null || true)"

python3 - "$payload" <<'PY'
import fnmatch
import json
import os
import re
import sys
import time

MODE = os.environ.get("CCLAUDE_AGENTGUARD_MODE", "enforce")

# Delivered on every ALLOWED Agent dispatch. This is the whole delivery
# mechanism for the delegation procedure: it arrives at the moment of the
# decision and costs nothing on the ~99% of turns that dispatch nothing.
# A DENIAL carries the refusal text only, not this brief (verified on a real
# dispatch 2026-08-10, not a synthetic payload) — and that is correct, because
# the remedy the refusal demands is one retry, and the retry is an allowed
# dispatch that arrives here. The brief therefore always lands before any agent
# actually runs. Do not "fix" this by appending the brief to the refusal.
# The alternative considered and rejected was a skill — it would have been a
# fourth home for doctrine, and its trigger would have been the model deciding
# a description matched, which is the judgment that keeps failing.
#
# Every figure below is MEASURED from this machine's own transcripts
# (2026-08-10): 2,211 subagent runs and 867 main sessions, priced with ccage's
# maintained rate table. They replace vendor blog estimates ("4x a chat"), which
# are not a unit of anything and were rightly rejected as a basis for spending.
IS_AGENT = False

DISPATCH_BRIEF = (
    "[dispatch] Lowest rung that fits — measured on your own history, not estimates:\n"
    "  1 INLINE (default): you know where to look, or it's small/linear.\n"
    "  2 ONE agent: wide search, NARROW answer. Never for a single-fact lookup you could Grep.\n"
    "  3 PARALLEL: genuinely independent strands, each individually slow. Disjoint WRITE sets.\n"
    "  4 WORKFLOW: only on the user's explicit opt-in, in their own words.\n"
    "COST per agent run, measured (median / p90 / max): sonnet $1.33 / $4.51 / $39.87 · opus $0.74 /\n"
    "$2.10 / $20.29. The spread within a tier is ~30x, so never multiply one figure by an agent count.\n"
    "Inline alternative: carrying 200k tokens for 20 more calls costs ~$4. Delegation buys\n"
    "wall-clock + context hygiene, not dollars.\n"
    "CHEAPEST *SUFFICIENT* TIER, never cheapest. Haiku is the weakest model and its wins are real\n"
    "only where it is sufficient: bounded, mechanical, spec-checkable work — extraction,\n"
    "classification, formatting, single-file edits against an exact spec. NOT for judgment (which\n"
    "claims matter, source quality, design) and NOT for DISCOVERY (bugs, security, research): a\n"
    "weak finder's MISSES are unrecoverable — verification restores precision, never recall. Never\n"
    "certify completeness from a quiet cheap finder. Cost is the tiebreak among sufficient tiers.\n"
    "The driver is the agent's LIFETIME x context, NOT its tier — a cheap agent doing 40 tool\n"
    "calls costs more than an expensive one doing 5. Keep the task narrow and the context small.\n"
    "PARALLELISM: median 1.96x for 3+ agents, and 17% of past fan-outs got NO overlap at all.\n"
    "It does not improve with agent count. Past ~3 agents you are usually buying cost, not time.\n"
    "Explore/Plan skip CLAUDE.md; every other agent loads it, so its size is paid per agent.\n"
    "STATE agent count x tier x estimated cost BEFORE dispatching. Rationale + the router table: "
    "~/.claude/model-routing-policy.md\n"
    "INPUT CONTRACT, the two clauses that fail silently: QUOTE the plan's round-level constraints\n"
    "into the brief (a worker sees only its task block); and BREAK THE INPUT AND WATCH THE CHECK\n"
    "GO RED before trusting it — a check never seen failing is not evidence. For a comparative\n"
    "study the broken input is free: make two arms identical. Measured 2026-08-15: a study whose\n"
    "three arms were byte-identical passed every conformance check written for it, because all\n"
    "of them asked whether an output EXISTED and none asked whether the input FLOWED."
)


NAME_NOTE = ""          # set below for an unnamed dispatch; rides along on allow


def allow():
    # PreToolUse additionalContext reaches the model without blocking the call.
    if IS_AGENT:
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "additionalContext": DISPATCH_BRIEF + NAME_NOTE}}))
    sys.exit(0)


if MODE == "off":
    allow()

try:
    p = json.loads(sys.argv[1])
except Exception:
    allow()

TOOL = p.get("tool_name") or ""
if TOOL not in ("Agent", "SendMessage"):
    allow()

ti = p.get("tool_input") or {}

# ---- inline-vs-dispatch justification: ENFORCE (added 2026-10-01) ----------
# THE INCIDENT. One session, two over-dispatches within an hour: a Sonnet worker
# for SWE data prep the main session had mostly scoped itself, then a SECOND
# worker (by re-scoping the first over SendMessage) for scoring the main session
# held every path, unit and environment for. The owner stopped it: "is the second
# worker necessary and more efficient ... don't just jump to starting a worker".
# The rules already said inline-first (CLAUDE.md "never dispatch a fix you have
# already fully diagnosed"; this file's own rung 1), and 8b6a732 (2026-09-28)
# had narrowed one trigger ("an execution plan means dispatch"). The trigger that
# fired here -- "it needs discovery/judgement, so dispatch" -- was untouched, and
# the advice below only ever arrived AFTER the call was made.
# THE CHECK: an Agent dispatch, or a SendMessage that hands an existing agent
# work, must OPEN with one line comparing the two routes:
#     INLINE-VS-DISPATCH: <why a worker beats doing it here>
# A coordination message with no new work opens with `INFO:` instead. This is a
# required phrase, which this file argued against for fan-out INDEPENDENCE in
# 2026-08 ("would become ritual within a week"); the owner ruled for it here
# because the failure is the decision itself, and the only moment to force the
# comparison is before the call. Every pass is logged so the ritual risk is
# auditable: read agent_dispatch_guard.log for one-liners that say nothing.
# Exempt: the subagent types in CCLAUDE_INLINE_EXEMPT_TYPES (comma-separated
# fnmatch patterns; default `dr-*,web-fetch`). dr-* are deep-research workflow
# internals launched by a script. web-fetch stands in for the WebFetch tool in a
# session that lacks it, and the harness calls dispatching it ordinary tool use,
# so a worker-earns-its-brief line is ritual there: measured 2026-11-12/18, one
# session wrote a justification just to read a page and another was blocked.
# The model-pinning check further down still applies to it.
# TIGHTENED 2026-11-01 (owner "y"): any 40 characters passed, so a reason that
# only cited a rule ("owner rule sends implementation to Sonnet medium") sent a
# 4-file config change to a worker that took ~45 min of queue waits and handoffs
# (owner: "Every time you start a worker, it takes an age ... Isn't it a simple
# job?"). The reason must now state the worker's expected run time,
# `runtime ~N min` (or h) with N >= 30 min, or say it needs an independent
# reader. A rule citation alone carries neither, so it is refused.
MIN_RUNTIME_MIN = 30
RUNTIME_RE = re.compile(r"runtime\s*[:~=]?\s*~?\s*(\d+(?:\.\d+)?)\s*(min|minutes?|h|hrs?|hours?)\b", re.I)
READER_RE = re.compile(r"independent\s+reader", re.I)


def earned(reason):
    """(passes, label) for the text after the mark: a stated runtime >= MIN_RUNTIME_MIN or an independent reader."""
    if READER_RE.search(reason):
        return True, "independent-reader"
    m = RUNTIME_RE.search(reason)
    if not m:
        return False, "no-runtime"
    minutes = float(m.group(1)) * (60 if m.group(2).lower().startswith("h") else 1)
    return minutes >= MIN_RUNTIME_MIN, "runtime=%gmin" % minutes


OVERCLAIM = 3  # claimed runtime more than this many times the measured one


def _subagents_dir():
    tp = str(p.get("transcript_path") or "")
    return os.path.join(os.path.splitext(tp)[0], "subagents") if tp else ""


def _agents():
    """{name: (start, first turn end or None, first incoming text)} for this session's workers."""
    out, d = {}, _subagents_dir()
    if not d or not os.path.isdir(d):
        return out
    for f in os.listdir(d):
        if not f.endswith(".meta.json"):
            continue
        try:
            name = json.load(open(os.path.join(d, f))).get("name") or ""
            rows = [json.loads(l) for l in open(os.path.join(d, f[:-len(".meta.json")] + ".jsonl"))]
        except (OSError, ValueError):
            continue
        start = next((r.get("timestamp") for r in rows if r.get("timestamp")), None)
        end = next((r.get("timestamp") for r in rows if r.get("type") == "assistant"
                    and (r.get("message") or {}).get("stop_reason") == "end_turn"), None)
        c = (rows[0].get("message") or {}).get("content") if rows else ""
        text0 = c if isinstance(c, str) else " ".join(
            x.get("text", "") for x in (c or []) if isinstance(x, dict))
        out[name] = (start, end, text0)
    return out


def _minutes(a, b):
    from datetime import datetime
    f = lambda s: datetime.fromisoformat(s.replace("Z", "+00:00"))
    return (f(b) - f(a)).total_seconds() / 60


def check_facts(kind, text, ti, exempt):
    """A refusal label from the transcripts, or '' when the facts allow the call."""
    agents = _agents()
    if kind == "message":
        if exempt:
            return ""
        a = agents.get(str(ti.get("to") or "").strip())
        if a and a[1]:
            return "worker-already-reported"
        return ""
    if READER_RE.search(text.splitlines()[0] if text else ""):
        return ""
    for name, (start, end, text0) in agents.items():
        m = RUNTIME_RE.search(text0.split(MARK, 1)[1].splitlines()[0]) if MARK in text0 else None
        if not (m and start and end):
            continue
        claimed = float(m.group(1)) * (60 if m.group(2).lower().startswith("h") else 1)
        actual = _minutes(start, end)
        if claimed >= MIN_RUNTIME_MIN and actual * OVERCLAIM < claimed:
            return "overclaimed:%s claimed %g min, reported after %.0f" % (name, claimed, actual)
    return ""


INLINE_MODE = os.environ.get("CCLAUDE_INLINE_CHECK_MODE", "enforce")
INLINE_EXEMPT_TYPES = os.environ.get("CCLAUDE_INLINE_EXEMPT_TYPES", "dr-*,web-fetch")
MARK = "INLINE-VS-DISPATCH:"
report = False
if INLINE_MODE != "off":
    if TOOL == "Agent":
        text = str(ti.get("prompt") or "")
        kind = "dispatch"
        exempt = any(fnmatch.fnmatchcase(str(ti.get("subagent_type") or ""), pat.strip())
                     for pat in INLINE_EXEMPT_TYPES.split(",") if pat.strip())
    else:
        text = str(ti.get("message") if isinstance(ti.get("message"), str)
                   else json.dumps(ti.get("message")))
        kind = "message"
        exempt = text.lstrip().startswith("INFO:")
        # A worker reporting back to its orchestrator is not a dispatch.
        report = str(ti.get("to") or "").strip() in ("main", "team-lead")
        exempt = exempt or report
    first = text.lstrip().splitlines()[0] if text.strip() else ""
    marked = first.startswith(MARK)
    has_reason, why = earned(first[len(MARK):]) if marked else (False, "no-mark")
    # FACT CHECKS (2026-11-05, owner: "Does it work or not?"). The runtime above
    # is the caller's own claim; that day two workers claimed ~90 min and
    # reported after 7 and 8, and review fixes were sent back to a worker that
    # had already reported. These two checks read the session's subagent
    # transcripts instead of trusting the claim.
    fact = check_facts(kind, text, ti, exempt)
    if fact:
        has_reason, why = False, fact
        exempt = False
    ok = exempt or has_reason
    try:
        log = os.path.join(os.environ.get("CLAUDE_CONFIG_DIR")
                           or os.path.expanduser("~/.claude"),
                           "agent_dispatch_guard.log")
        prev = open(log).read().splitlines()[-499:] if os.path.exists(log) else []
        open(log, "w").write("\n".join(prev + [
            "%s INLINE-CHECK %s %s: %s" % (
                time.strftime("%Y-%m-%dT%H:%M:%S"),
                ("PASS-REPORT" if TOOL == "SendMessage" and report else "PASS")
                if ok else ("BLOCK" if INLINE_MODE == "enforce" else "OBSERVE"),
                kind, ("[exempt] " if exempt else "[%s] " % why) + first[:160])]) + "\n")
    except OSError:
        pass
    if not ok and INLINE_MODE == "enforce" and why == "worker-already-reported":
        print("Blocked (worker-already-reported): %s has already delivered its "
              "report. Follow-up fixes after a report are done in the main session: "
              "you hold the diff, the outputs and the review.\nDO INSTEAD: make the "
              "change yourself. A message with no new work opens with `INFO:`.\n"
              "If this block is wrong, say so and ask (D15)." % ti.get("to"),
              file=sys.stderr)
        sys.exit(2)
    if not ok and INLINE_MODE == "enforce" and why.startswith("overclaimed"):
        print("Blocked (%s): an earlier worker in this session ran far shorter "
              "than its stated runtime, so a stated runtime no longer earns a "
              "worker here.\nDO INSTEAD: do the work in the main session. Only a "
              "need for an independent reader still earns one (`%s needs an "
              "independent reader because ...`).\nIf this block is wrong, say so "
              "and ask (D15)." % (why, MARK), file=sys.stderr)
        sys.exit(2)
    if not ok and INLINE_MODE == "enforce":
        print(
            "Blocked (%s): this %s does not open with an inline-vs-dispatch line "
            "that earns a worker. Doing the work in the main session is the "
            "default; a worker must earn its brief by its run time or by "
            "needing an independent reader. Citing a rule is not a reason.\n"
            "FIRST ask: do I already hold the context (paths, environment, the "
            "diagnosis)? If writing the brief means TRANSCRIBING facts you "
            "measured, do it inline -- the worker adds latency and cost "
            "(sonnet median $1.33, p90 $4.51 per run), nothing else.\n"
            "DO INSTEAD, either:\n"
            "  1. Do the work inline (usual answer).\n"
            "  2. Or open the prompt/message with one line:\n"
            "       %s runtime ~N min (N >= 30) of independent wall-clock while "
            "I do X  -- or --  needs an independent reader because Y\n"
            "  3. A SendMessage that adds NO work opens with `INFO:` instead.\n"
            "If neither fits, do it inline; if you think this block is wrong, "
            "say so and ask (D15)." % (why, kind, MARK),
            file=sys.stderr)
        sys.exit(2)

if TOOL != "Agent":
    sys.exit(0)

IS_AGENT = True

# ---- unnamed dispatch: WARN, do not refuse (added 2026-08-11) --------------
# A name is how an agent is STOPPED. Without one it can only be addressed by an
# opaque id dug out of transcript files, and an un-stopped agent survives /clear
# and keeps doing real work — observed on this machine. Measured across every
# session here: 778 of 1,994 dispatches (39%) carried no name.
#
# WARN, not refuse, deliberately — the opposite of the model check right below,
# and the difference is worth stating. The model check keys on a fact with no
# remedy other than deciding (and a wrong tier costs money silently). A missing
# name is always addable and costs nothing until an agent outlives its session,
# which is rare. Refusing 39% of dispatches to fix a rare, cheap failure buys
# friction people learn to click through. So: note it, log it, and flip to
# enforce only if the log shows the note being ignored — the path poll_loop_guard
# took, and the evidence that eventually flipped resume_budget_check.
NAME_MODE = os.environ.get("CCLAUDE_AGENTNAME_MODE", "observe")
if NAME_MODE != "off" and not str(ti.get("name") or "").strip():
    try:
        log = os.path.join(os.environ.get("CLAUDE_CONFIG_DIR")
                           or os.path.expanduser("~/.claude"),
                           "agent_dispatch_guard.log")
        prev = open(log).read().splitlines()[-499:] if os.path.exists(log) else []
        open(log, "w").write("\n".join(prev + [
            "%s UNNAMED mode=%s type=%s desc=%s" % (
                time.strftime("%Y-%m-%dT%H:%M:%S"), NAME_MODE,
                ti.get("subagent_type") or "<default>",
                str(ti.get("description") or "?")[:50])]) + "\n")
    except OSError:
        pass
    if NAME_MODE == "enforce":
        print("Blocked: this dispatch passes no `name`. A name is how the agent "
              "is stopped later — without one it can only be addressed by an "
              "opaque id recovered from transcript files, and an un-stopped "
              "agent survives /clear and keeps working.\n"
              "DO INSTEAD: add `name` — a short slug describing the job.\n"
              "If a name is genuinely wrong here, say so and ask (D15).",
              file=sys.stderr)
        sys.exit(2)
    NAME_NOTE = ("\n[unnamed dispatch] This call passes no `name`, so the agent "
                 "can only be stopped by an opaque id dug out of transcript "
                 "files. Name the next one.")

# ---- foreground dispatch: OBSERVE (added 2026-08-13) -----------------------
# CLAUDE.md bans `run_in_background: false` on Agent calls, and the reason is
# that it buys nothing: a "foreground" dispatch is still asynchronous, so the
# calling turn is not blocked either way — the flag only freezes the USER's
# terminal until the agent finishes, forcing a manual Ctrl+B. The harness's own
# Agent tool description sanctions the flag ("pass false only when your very
# next action depends on the result"), which is the same tool-description-vs-
# CLAUDE.md conflict the provenance guard exists for.
#
# OBSERVE-first, per D16(5): unlike the trailer, this failure has NOT been
# measured here — no dispatch in any log carries the flag. A guard whose trigger
# may never occur gets logged, not enforced, until the log says otherwise. Flip
# with CCLAUDE_DISPATCH_BG_MODE=enforce.
#
# Placed BEFORE the explicit-model allow below on purpose: a dispatch that pins
# its model is still a foreground dispatch, and would otherwise never be seen.
BG_MODE = os.environ.get("CCLAUDE_DISPATCH_BG_MODE", "observe")
if BG_MODE != "off" and ti.get("run_in_background") is False:
    try:
        log = os.path.join(os.environ.get("CLAUDE_CONFIG_DIR")
                           or os.path.expanduser("~/.claude"),
                           "agent_dispatch_guard.log")
        prev = open(log).read().splitlines()[-499:] if os.path.exists(log) else []
        open(log, "w").write("\n".join(prev + [
            "%s FOREGROUND mode=%s type=%s" % (
                time.strftime("%Y-%m-%dT%H:%M:%S"), BG_MODE,
                ti.get("subagent_type") or "<default>")]) + "\n")
    except OSError:
        pass
    if BG_MODE == "enforce":
        print("Blocked: this dispatch passes `run_in_background: false`. That "
              "does not make the call blocking — the dispatch is asynchronous "
              "either way — it only freezes the user's terminal until the agent "
              "finishes, which then needs a manual Ctrl+B.\n"
              "DO INSTEAD: omit the flag (or pass true) and wait for the "
              "completion notification.\n"
              "If a blocking foreground dispatch is genuinely needed here, say "
              "so and ask (D15).", file=sys.stderr)
        sys.exit(2)

# An explicit model is the author making the tier decision on purpose. Done.
if ti.get("model"):
    allow()

# Absent subagent_type means the general-purpose default — built-in, unpinned.
subagent_type = (ti.get("subagent_type") or "general-purpose").strip()

config = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
# ANCHOR ON THE PROJECT, NOT THE PAYLOAD'S cwd (2026-08-14). A project's agent
# definitions live at its ROOT, but `cwd` is "the current working directory when
# the hook is invoked" and it follows Claude's own `cd` — MEASURED with a probe
# hook: payload cwd=~/dev/ccage/tests while CLAUDE_PROJECT_DIR stayed
# ~/dev/ccage. Keyed on cwd, one `cd` hid the whole project registry,
# and "no definition file" is read here as "not pinned", so the guard failed
# silently in the permissive direction. Fall back to cwd when the var is absent.
project = os.environ.get("CLAUDE_PROJECT_DIR") or p.get("cwd") or os.getcwd()

FRONTMATTER_MODEL = re.compile(r"^model:\s*\S+", re.M)


def pinned(name):
    """True iff a definition file for `name` exists AND pins a model.

    A definition with no `model:` line inherits the session model exactly like a
    built-in does, so it is NOT pinned — the file existing is not the point."""
    for base in (os.path.join(project, ".claude", "agents"),
                 os.path.join(config, "agents"),
                 os.path.join(os.path.expanduser("~"), ".claude", "agents")):
        path = os.path.join(base, name + ".md")
        if not os.path.isfile(path):
            continue
        try:
            with open(path, errors="replace") as f:
                head = f.read(4096)
        except OSError:
            return True          # unreadable -> fail open, do not block a dispatch
        return bool(FRONTMATTER_MODEL.search(head))
    return False


try:
    if pinned(subagent_type):
        allow()
except OSError:
    allow()


def cheap_roles():
    """Name the pinned roles that actually exist, so the remedy is concrete."""
    found = []
    for base in (os.path.join(config, "agents"),
                 os.path.join(os.path.expanduser("~"), ".claude", "agents")):
        for role in ("utility-worker", "task-worker", "adjudicator"):
            path = os.path.join(base, role + ".md")
            if os.path.isfile(path) and role not in found:
                found.append(role)
        if found:
            break
    return found


log = os.path.join(config, "agent_dispatch_guard.log")
label = ti.get("name") or ti.get("description") or "?"
try:
    stamp = time.strftime("%Y-%m-%dT%H:%M:%S")
    line = "%s %s type=%s label=%s" % (
        stamp, "BLOCK" if MODE == "enforce" else "OBSERVE", subagent_type,
        str(label)[:60])
    prev = open(log).read().splitlines()[-499:] if os.path.exists(log) else []
    open(log, "w").write("\n".join(prev + [line]) + "\n")
except OSError:
    pass

if MODE != "enforce":
    allow()

roles = cheap_roles()
# With NO definitions on disk — a fresh machine or cage — every type is unpinned,
# so this guard denies every dispatch while option 1 tells the author to use a
# pinned role agent that does not exist. Found by live-firing the unconfigured
# path, 2026-08-11: loud, but the remedy could not be followed and nothing said
# why. Name the real cause there instead of repeating advice that cannot work.
if roles:
    roles_line = "Pinned roles available here: %s.\n" % ", ".join(roles)
    option_1 = ("  1. Use a pinned role agent whose tier already matches the work "
                "— mechanical or bounded work does NOT need the session tier.\n")
else:
    roles_line = ("No pinned role agents exist on this machine (looked in "
                  "<project>/.claude/agents, $CLAUDE_CONFIG_DIR/agents and "
                  "~/.claude/agents), so EVERY subagent_type is unpinned here.\n")
    option_1 = ("  1. Create a role agent with a `model:` line in its frontmatter "
                "— until one exists, option 2 is the only remedy.\n")
print(
    "Blocked: this dispatch names subagent_type '%s', which has no pinned model, "
    "and passes no explicit `model`. It would therefore INHERIT THIS SESSION'S "
    "MODEL — on an expensive session that is an expensive agent, silently, and "
    "nothing in the tool call shows you the price.\n"
    "%s"
    "DO INSTEAD, either:\n"
    "%s"
    "  2. Or pass `model` explicitly on this call, having actually decided the "
    "tier is warranted.\n"
    "Search/summarise/extract/format work is the common case for a cheaper tier.\n"
    "If inheriting the session model is genuinely intended, say why and ask (D15)."
    % (subagent_type, roles_line, option_1),
    file=sys.stderr,
)
sys.exit(2)
PY
