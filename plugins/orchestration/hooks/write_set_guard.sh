#!/usr/bin/env bash
# PreToolUse(Write|Edit) — enforce SINGLE-WRITER DISCIPLINE mechanically.
#
# THE RULE (CLAUDE.md, "the highest-leverage rule here"): workers RETURN
# findings; the ORCHESTRATOR writes the shared artifact. Fan out on COMPUTE,
# serialise on WRITES.
#
# THE FAILURE IT CATCHES: "independence" means DISJOINT WRITE SETS, not
# different topics. Eight agents on eight different strategies, all writing one
# findings ledger + one plan + one task list, is EIGHT WRITERS ON THREE FILES.
# Observed 2026-07-15: it produced a plan stale within the hour and numbers that
# disagreed between documents. Nobody noticed, because nothing checked.
#
# THE MECHANISM: PreToolUse carries `agent_id` ONLY when the call comes from
# inside a subagent (per the hooks reference, and CONFIRMED empirically on this
# build before this guard was allowed to block — the docs have been wrong twice
# in this codebase's history, so "the docs say so" is not evidence). So:
#   - no agent_id  -> the MAIN THREAD is writing. Always allowed: the root IS
#                     the legitimate single writer.
#   - agent_id set -> a worker is writing. Record it. If a DIFFERENT worker has
#                     already written this same path in this session, that is a
#                     shared write set: BLOCK and name both.
#
# MODE: ENFORCE by default. Set CCLAUDE_WRITESET_MODE=observe to downgrade to
# logging only (the escape hatch, if this ever misfires).
#
# Enforce is the right default because the guard is deliberately narrow: it fires
# ONLY when two DIFFERENT subagents write the SAME path in the SAME session --
# which is not a coincidence, it is the false-parallel failure itself. The main
# thread is never blocked, so the sanctioned path (worker returns a finding, root
# writes the file) always works. The failure it prevents is silent divergence
# nobody notices for hours; the failure it can cause is one blocked write with an
# actionable message and a one-env-var escape. Those are not close.
#
# KNOWN, ACCEPTED FALSE POSITIVE: a deliberate worker->worker handoff on one file
# (agent A drafts, agent B refines) is blocked. That is not collateral damage --
# it is against the rule this enforces. Route it through the root.
#
# CONFIRMED ON THIS BUILD 2026-07-15, not assumed: a live subagent's Write fired
# this hook carrying agent_id=awsg-probe-570f535bb5f0879a. The hooks reference
# says agent_id is subagent-only; that claim was verified with a real probe
# because two other documented claims failed on contact today.
#
# FAIL-OPEN ALWAYS. Any parse error, missing field, or unwritable state allows
# the write. A guard that wedges a session on bad data is worse than no guard.

payload="$(cat 2>/dev/null || true)"

python3 - "$payload" <<'PY'
import fnmatch
import json
import os
import sys
import time

MODE = os.environ.get("CCLAUDE_WRITESET_MODE", "enforce")


def allow():
    sys.exit(0)


try:
    p = json.loads(sys.argv[1])
except Exception:
    allow()

agent_id = p.get("agent_id") or ""
session_id = p.get("session_id") or ""
tool_input = p.get("tool_input") or {}
path = tool_input.get("file_path") or ""

config = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
log = os.path.join(config, "write_set_guard.log")


def note(msg):
    """Always leave a trail. A guard whose firing cannot be observed cannot be
    debugged -- teammate_idle_guard carried a false claim about its own event for
    weeks because nothing recorded whether it ran."""
    try:
        stamp = time.strftime("%Y-%m-%dT%H:%M:%S")
        prev = open(log).read().splitlines()[-299:] if os.path.exists(log) else []
        open(log, "w").write("\n".join(prev + ["%s %s" % (stamp, msg)]) + "\n")
    except OSError:
        pass


if not path or not session_id:
    allow()

# The main thread writing is the DESIRED state, not a violation -- the whole
# rule is that the root, not the workers, owns shared artifacts.
if not agent_id:
    allow()

# PROTECTED PATHS: the collision rule above only catches agent-vs-agent. It does
# NOT catch the failure that actually cost the most -- a SINGLE worker writing an
# unverified number straight into a shared artifact. One worker writing the
# ledger collides with nobody and sails through.
#
# Real case (2026-07-15): a worker wrote a "+0.15 Sharpe" lever directly into the
# plan. Nothing verified it. It was the programme's headline open lever for days.
# It was a window-mismatch artifact and did not exist.
#
# So a project may declare artifacts that ONLY the orchestrator may write, by
# listing fnmatch globs (one per line, '#' comments) in `.claude-single-writer`
# at the repo root. Absent file => no protection, so this is opt-in and inert by
# default rather than a surprise. Workers are blocked; the main thread is not.
def protected_globs():
    """Globs only the root may write, from <project>/.claude-single-writer.

    Anchored on CLAUDE_PROJECT_DIR, not the payload's cwd: the file lives at the
    REPO ROOT, while cwd follows Claude's own `cd` (measured 2026-08-14). Keyed
    on cwd, one `cd` into a subdirectory made the file unreadable and this guard
    returned "no protection" — failing open exactly when it should bite."""
    root = os.environ.get("CLAUDE_PROJECT_DIR") or p.get("cwd") or ""
    try:
        with open(os.path.join(root, ".claude-single-writer")) as f:
            return [ln.strip() for ln in f
                    if ln.strip() and not ln.lstrip().startswith("#")]
    except OSError:
        return []


for pattern in protected_globs():
    if fnmatch.fnmatch(path, pattern) or fnmatch.fnmatch(os.path.basename(path), pattern):
        note("PROTECTED mode=%s path=%s agent=%s pattern=%s" % (MODE, path, agent_id, pattern))
        if MODE == "enforce":
            sys.stderr.write(
                "PROTECTED ARTIFACT: '%s' matches '%s' in .claude-single-writer — only the "
                "orchestrator may write it, and you are agent '%s'.\n"
                "This is the rule that a worker-written, unverified '+0.15 Sharpe' lever "
                "broke: it led the programme for days and was a measurement artifact.\n"
                "RETURN your finding (with the artifact path that proves it) and let the "
                "orchestrator verify it and write it. Do not work around this.\n"
                % (path, pattern, agent_id))
            sys.exit(2)
        allow()

# ---------------------------------------------------------------------------
# SELF-HEALING CLAIMS (added 2026-09-15, after this guard blocked three workers
# in one session on claims held by agents that had been stopped hours earlier).
#
# The defect: a claim is recorded on first write and NEVER released. There is no
# unclaim path, so a FINISHED worker blocks the next one indefinitely, and the
# only remedy was hand-editing this registry -- during which a live worker's
# claim was stripped off a file carrying 72 uncommitted lines, because the
# human check was "is it clean?" answered from a misread command.
#
# So the machine does it, and the check that failed by hand is the gate:
#   stale owner AND file clean  -> hand the claim over, log it, allow
#   stale owner AND file DIRTY  -> still block. Uncommitted work is the exact
#                                  thing a wrong release destroys.
#   live owner                  -> still block. That is the real collision this
#                                  guard exists for, and it is unchanged.
# Anything unverifiable counts as DIRTY/LIVE: this only ever relaxes the block
# on evidence, never on the absence of it.
STALE_MIN = int(os.environ.get("CCLAUDE_WRITESET_STALE_MIN", "15") or 15)


def owner_is_stale(owner_id):
    """True when the owning agent's transcript has not been written recently.

    A live worker writes its transcript every few tool calls; a stopped one
    never does. Not found at all -> stale, since an agent that left no
    transcript cannot be mid-write."""
    import glob as _glob
    pat = os.path.join(config, "projects", "*", "*", "subagents",
                       "agent-%s.jsonl" % owner_id)
    newest = None
    for f in _glob.glob(pat):
        try:
            m = os.path.getmtime(f)
        except OSError:
            continue
        if newest is None or m > newest:
            newest = m
    if newest is None:
        return True
    return (time.time() - newest) > STALE_MIN * 60


def file_is_clean(fp):
    """True ONLY on positive evidence that the file holds no uncommitted work.

    Every failure mode -- not a repo, git missing, timeout, staged-but-uncommitted
    -- returns False and keeps the block. Releasing a claim on unsaved work is the
    one outcome worth a dozen false blocks."""
    import subprocess
    root = os.environ.get("CLAUDE_PROJECT_DIR") or p.get("cwd") or os.path.dirname(fp)
    try:
        for args in (["git", "diff", "--quiet", "HEAD", "--", fp],
                     ["git", "diff", "--quiet", "--cached", "HEAD", "--", fp]):
            r = subprocess.run(args, cwd=root, capture_output=True, timeout=5)
            if r.returncode != 0:
                return False
        return True
    except Exception:
        return False


state_dir = os.path.join(config, "write_sets")
state_path = os.path.join(state_dir, "%s.json" % session_id.replace("/", "_"))
try:
    os.makedirs(state_dir, exist_ok=True)
    state = json.load(open(state_path)) if os.path.exists(state_path) else {}
except (OSError, ValueError):
    state = {}

owner = state.get(path)

def _persist(st):
    try:
        tmp = state_path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(st, f)
        os.replace(tmp, state_path)
    except OSError:
        pass


if owner and owner != agent_id:
    stale = owner_is_stale(owner)
    clean = file_is_clean(path) if stale else False
    if stale and clean:
        state[path] = agent_id
        _persist(state)
        note("REASSIGN mode=%s path=%s from=%s to=%s (owner stale >%dmin, file clean)"
             % (MODE, path, owner, agent_id, STALE_MIN))
        allow()
    reason = ("owner is STILL LIVE" if not stale
              else "owner is stale BUT the file has UNCOMMITTED changes")
    note("COLLISION mode=%s path=%s owner=%s intruder=%s reason=%s"
         % (MODE, path, owner, agent_id, reason))
    if MODE == "enforce":
        sys.stderr.write(
            "SHARED WRITE SET: '%s' was already written by agent '%s'; you are '%s'.\n"
            "Two agents writing one file is not independence -- it is how a plan goes "
            "stale within the hour and how two documents end up disagreeing.\n"
            "Return your finding to the orchestrator and let IT write this file "
            "(single-writer discipline). If you genuinely own this file now, say so "
            "and have the orchestrator confirm the handoff.\n"
            "WHY THIS DID NOT AUTO-RELEASE: %s. A stale claim on a CLEAN file is handed "
            "over automatically; a stale claim on a file with uncommitted changes is not, "
            "because releasing it is how unsaved work gets destroyed.\n"
            % (path, owner, agent_id, reason))
        sys.exit(2)
    allow()

if not owner:
    state[path] = agent_id
    _persist(state)
    note("claim mode=%s path=%s agent=%s" % (MODE, path, agent_id))

allow()
PY
exit $?
