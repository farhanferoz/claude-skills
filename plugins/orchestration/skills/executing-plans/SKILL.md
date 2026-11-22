---
name: executing-plans
description: Use when you have a written implementation plan to execute in a separate session with review checkpoints
---

# Executing Plans

## Overview

Load plan, review critically, execute all tasks, report when complete.

**Announce at start:** "I'm using the executing-plans skill to implement this plan."

**Note:** Tell your human partner that Superpowers works much better with access to subagents. The quality of its work will be significantly higher if run on a platform with subagent support (such as Claude Code or Codex). If subagents are available, use superpowers:subagent-driven-development instead of this skill.

## The Process

### Step 1: Load and Review Plan
1. Read plan file
2. Review critically - identify any questions or concerns about the plan
3. If concerns: Raise them with your human partner before starting
4. If no concerns: Create TodoWrite and proceed
5. **Autonomous run? Pin the run contract in RESUME before executing** (the
   measured-adherence recipe — the near-perfect 2026-07-23 control run had
   exactly this, the stallers didn't): (a) exactly ONE in-scope item, or an
   explicit wave list; (b) a BINDING definition of done — "this run is DONE
   only when …", concrete and checkable; (c) pre-declared deferrals — every
   user-gated or deliberately-unscheduled item named OUT of scope up front, so
   any end-of-run "open for you" claim can be audited against a declaration
   made before work started, not invented to justify stopping.

### Step 2: Execute Tasks — dispatch waves, don't walk the list

(Rewritten 2026-07-16: the old form — "for each task: follow steps" — mandated
sequential execution and was the measured cause of plans executing one task at
a time despite the orchestration doctrine.)

1. **Partition the WHOLE plan into dependency waves first.** A wave = every
   remaining task whose `deps:` (Orchestration line) are complete and whose
   write set (`Files:` Create/Modify) is disjoint from the others in the wave.
   Never evaluate tasks one at a time — that always concludes "do this one
   inline" and degenerates into sequential self-execution.
2. **Dispatch each wave concurrently in ONE message** — one subagent per task on
   its Orchestration `tier:`, brief carrying the task's full text (the input
   contract: files, spec, verify command, non-goals + the standing clauses).
   With subagent support, use superpowers:subagent-driven-development mechanics
   (implementer + two-stage review) per task. A wave of one, or genuinely
   coupled tasks, runs inline — don't over-orchestrate.
3. **The root is dispatcher + verifier, not executor**: verify each task
   against DISK (run its verify command yourself), mark it complete, refill the
   wave as deps clear. Root is the single writer for the plan checklist.
4. **Fully execution-level plan + autonomous run?** Consider compiling the plan
   into a dynamic Workflow instead (deterministic waves, budget-capped,
   crash-resumable): see ./workflow-compile.md. Prefer it when the plan has ≥5
   tasks, every task is decision-complete, and no mid-course human ratification
   is expected.

### Step 3: Complete Development

After all tasks complete and verified:
- Verify: run the project's test and lint gates and show the output — do not
  claim completion from memory (`verification-before-completion` skill).
- Present the options to the user — merge, open a PR, or leave the branch — and
  execute the choice; never merge or push without being asked.

## When to Stop and Ask for Help

Blockers: missing dependency, repeated verification failure, unclear
instruction, critical plan gap. What you do depends on who is watching:

**Attended session:** stop and ask. Ask for clarification rather than guessing.

**Autonomous run** (`CCAGE_AUTONOMOUS=1`, user stepped away, ccage-auto):
never block on a question mid-run. In order: (1) grep the ratified plan/design
doc — it usually already decides it; (2) take the reversible default, log the
decision + rationale in RESUME.md `### Decisions`, and continue; (3) batch
anything only the user can answer for end-of-run. Halt outright ONLY for
irreversible/destructive/outward-facing actions. Never end a turn "waiting"
while any unblocked task remains.

## When to Revisit Earlier Steps

**Return to Review (Step 1) when:**
- Partner updates the plan based on your feedback
- Fundamental approach needs rethinking

**Don't force through blockers** - stop and ask.

## Remember
- Review plan critically first
- Follow plan steps exactly
- Don't skip verifications
- Reference skills when plan says to
- Stop when blocked, don't guess
- Never start implementation on main/master branch without explicit user consent

## Integration

**Required workflow skills:**
- **`using-git-worktrees`** - REQUIRED: Set up isolated workspace before starting
- **`writing-plans`** - Creates the plan this skill executes
- **`verification-before-completion`** - REQUIRED: evidence before any "done" claim
