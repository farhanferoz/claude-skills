# Model Routing Policy

The router that sits ABOVE every orchestration mechanism and picks between them.
The compact hard-gate version lives in `~/.claude/CLAUDE.md`; this is the full
reference. It does NOT re-teach the mechanisms — each is self-documenting (see
**Mechanisms** below) — it routes to them and carries the few cross-cutting
judgments no single mechanism owns.

## Who orchestrates

The **session model** orchestrates — whatever tier the session runs on (Fable
when selected, otherwise Opus). "The orchestrator" = the main loop; never
hardcode its tier in prompts or scripts. Spend the orchestrator's expensive
judgment only at high-leverage points (planning, seam decisions, final
adjudication); push the bulk token volume to cheaper workers.

## The router — which mechanism, by shape

| Situation | Mechanism | Notes |
|---|---|---|
| 1 unit, or sequential / context-heavy / spec≈diff | **Main loop** | Don't delegate; the handoff tax exceeds the gain. |
| 2–5 independent units, report-back | **Subagents** (Agent tool / pinned roles) | Cheapest fan-out; results summarized back to the caller. |
| A planned multi-task project | **`writing-plans` → `subagent-driven-development`** (or `executing-plans`) | Orchestrator dispatches per task + two-stage review; escalates to the human when the plan itself is wrong. |
| Workers must discuss/challenge; multi-lens review; competing-hypothesis debugging | **Agent Teams** (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`) | Native plan-approval seams + `TeammateIdle`/`TaskCompleted` quality hooks + direct redirect. Costlier (each teammate a full session) — selective use only. |
| Large / repeatable / looping / discovered-scale fan-out; find→verify→synthesize | **Workflow tool** | Deterministic control flow = zero model tokens; hard `budget` cap; resume/caching. |

Two wins are separate axes: **parallelism buys wall-clock time; tier arbitrage +
context offload buy money.** Concurrency alone (same tier) costs the same total
tokens — it is only cheaper when the delegated work moves to a cheaper
*sufficient* tier, or offloads volume out of the main context.

## Static vs dynamic workflows

Once routed to a Workflow, decide whether the work-list is known up front:

- **Static** — you can enumerate the items (`parallel(DIMENSIONS.map(...))`,
  migrate N listed files). Cost is predictable.
- **Dynamic** — the work-list is discovered at runtime (scout → fan-out) or the
  loop count is unknown (loop-until-dry, loop-until-count, loop-until-budget).
  Raw cost is NOT predictable up front, so **always hand a dynamic workflow an
  explicit `budget`** — an unbounded dynamic loop runs to the agent cap. The
  budget is the strongest cost control available.

("Dynamic" here = runtime-discovered fan-out. Distinct from `/loop` dynamic mode,
which is self-paced recurrence over *time*.)

## The seam protocol (decision-making between stages)

Don't encode a whole replan-prone project as one mega-workflow — it can't
rethink. Keep the main loop as orchestrator, walking the plan stage by stage;
decide at each seam over the distilled stage result (worker output + its stated
uncertainty/blockers):

1. **Exit criteria met?** Result matches what the plan said this stage produces → proceed.
2. **If not, route:** uncertain / unverifiable → adjudicator verify pass; contradicts a plan assumption → amend the plan; new in-scope work → insert stages; **ambiguous tradeoff / scope or goal change / irreversible / outward-facing / budget blown / repeated worker failure → escalate to the human.** (In an autonomous run, "escalate to the human" converts to default + log + batch — see §Autonomous execution regime — except for irreversible/destructive/outward-facing actions, which still halt.)
3. **Budget check** before continuing.

This is not hand-rolled — the mechanisms already implement it:
`subagent-driven-development` handles implementer status (DONE /
DONE_WITH_CONCERNS / NEEDS_CONTEXT / BLOCKED) and escalates to the human when
the plan itself is wrong; Agent Teams provides native plan-approval gates plus
`TeammateIdle` (exit 2 = tasks remain, keep working — the anti-idle enforcement)
and `TaskCompleted` (exit 2 = validate against the plan before marking done).

## Autonomous execution regime (user away)

Active when the user asks for autonomous execution, announces stepping away, or
the session runs under `ccage-auto`. Three overrides on top of normal doctrine
(each corrects an observed recurring failure — 2026-07-11 feedback):

1. **The root is dispatcher + verifier, not executor.** With an execution-level
   plan in hand, partition it into dependency waves (all tasks with no unmet
   dependency = wave 1, and so on) and dispatch each wave concurrently in ONE
   message. The "single substantive task → main loop" rule applies to the
   *plan as a whole*, never step-by-step inside one — evaluating each step
   alone always concludes "do it inline" and degenerates into the root walking
   the whole plan sequentially. The root executes inline only what is genuinely
   sequential-critical, context-bound, or trivial. Sequential execution itself
   is NOT banned: a genuinely sequential chain is waves of size 1, and a short
   chain (or trivial steps) is cheapest inline — per-step dispatch of a
   sequential plan pays only when the plan is long enough that keeping the
   root's context lean across checkpoint cycles matters (the `ccage-auto`
   case). The ban is on *defaulting* to inline when independent units exist.
2. **Never block on the user mid-run.** Mid-execution `AskUserQuestion` while
   the user is away stalls the entire run. Instead: (a) grep the ratified
   plan/design doc first — the plan-adherence gate; it usually already decides
   the question; (b) otherwise take the reversible default and log the decision
   + rationale in `RESUME.md` `### Decisions` for later review; (c) batch
   genuinely user-only questions and present them at the END of the run, after
   completing all work that doesn't depend on the answers. Halt mid-run only
   for irreversible / destructive / outward-facing actions.
3. **No idle waiting — THIS BINDS THE ROOT ONLY, NEVER A WORKER.** After every
   dispatch, the *root* re-scans the task list: anything unblocked gets
   dispatched or done — in the same message where possible. Ending the turn
   while background work runs is legitimate ONLY when nothing unblocked remains
   (the harness re-invokes on completion; polling is waste). "Launched X,
   waiting for results" while unblocked tasks sit on the list is the exact
   failure the wave rule exists to prevent.
   ⛔ **A WORKER MUST NEVER RE-SCAN OR CLAIM FROM THE TASK LIST.** A worker does
   only what its own dispatch contract names; reaching outside it is a defect,
   not initiative. Read as a worker instruction, this rule turns every idle
   agent into a claim-anything agent — and **a brief does not constrain a worker
   that can see unclaimed work.** *(Observed 2026-07-15: an agent briefed
   "READ-ONLY AUDIT, do not modify any file" announced "I'll claim task #15
   since it's the only unblocked, unclaimed task remaining" — an entire new
   strategy build. It was obeying this bullet. Another read-only auditor built a
   204-page dossier the same way.)* **The root assigns; workers do not shop.**
   Prefer not exposing a browsable task list to workers at all.
4. **Start on partial inputs.** When a subset of the inputs is already
   available (data for some instruments, some files fetched, some modules
   built) and real work is unblocked by that subset, START there — never
   barrier on the full set out of convenience. "Waiting for the rest of the
   data" while buildable work sits ready is the same idle-waiting bug in a
   different costume. Waves are defined by *dependency*, not by completeness.
5. **In-scope trivial decisions are not user questions** (applies in attended
   sessions too). If a piece of work is already inside the ratified plan/scope
   and reversible, build it — do not surface "should I build X?" while sitting
   idle. Escalate only genuine tradeoffs, scope changes, or irreversible
   steps; in an autonomous run, batch even those per rule 2.

Enforcement wired 2026-07-11: `ccage-auto` blocks `AskUserQuestion` mid-run
(PR #9, per-run `--settings` hook + `CCAGE_AUTONOMOUS=1`); Agent Teams sessions
get `TeammateIdle` (exit 2 = unblocked/owned tasks remain → keep working) and
`TaskCompleted` (exit 2 = blockedBy still open → completion refused) via
`~/.claude/hooks/teammate_idle_guard.sh` / `task_completed_guard.sh`,
registered globally and seeded per cage by `~/.bashrc.d/claude-overrides.sh`.

## Model defaults

- **Haiku 4.5** — routing, classification, formatting, small summaries, and
  extraction **against an explicit schema**. NOT judgment-laden extraction (which
  claims matter, source quality) — measured in the deep-research validation:
  Haiku search/extract had invisible misses and had to be upgraded to Sonnet.
- **Sonnet 5** — default worker: coding, research, file analysis, scoped
  synthesis, test authoring, commits against a precise spec.
- **Opus 4.8** — planning, arbitration, architecture review, difficult/ambiguous
  debugging, final verification. As orchestrator only when it is the session model.
- **Fable 5** — among the STRONGEST tiers, not a weak or cheap model. When the
  session runs on Fable it is a fully capable orchestrator AND verifier; never
  auto-pin it, and never route heavy judgment *away* from it on the mistaken
  assumption it is weak. Like every tier here, the choice to use it is the user's.

(`subagent-driven-development` carries its own cheap/standard/capable per-role
guidance — the same doctrine; this is the cross-mechanism default.)

## Effort policy

Effort moves in BOTH directions; prefer adjusting effort before switching tier or
architecture.

- Sonnet 5: `high` for substantive work; `low`/`medium` for mechanical fan-out.
- Opus 4.8: `high` default; `xhigh` for difficult / ambiguous / high-autonomy work.
- In workflows AND Agent Teams, omitting the model makes agents INHERIT THE
  SESSION MODEL — pin cheap tiers explicitly (`model: 'sonnet'`, `effort: 'low'`)
  or you silently pay orchestrator rates. Pass `effort` explicitly in `agent()`
  options too (frontmatter binding on workflow subagents is unverified).

## The verifiability asymmetry (when worker tier matters)

An orchestrator/adjudicator can kill a worker's false positives but cannot recover
what the worker never found — verification restores **precision, not recall**.

- **Execution-shaped work** (checkable against a spec): worker tier barely matters
  if the spec is precise. A good execution plan CONVERTS discovery-shaped work
  into execution-shaped work — that is why planning is itself an economy lever.
- **Discovery-shaped work** (bug/security/research sweeps): tier matters a lot;
  misses are invisible. Raise the finder tier, or use multiple diverse-lens
  finders. Never treat a quiet finder as a clean bill.
- **The verifier's tier is bounded below by the executor's.** A verifier at a
  *lower* capability tier than the worker it checks cannot reliably catch that
  worker's errors, so pin the verifier at a capability tier **≥** the executor's
  (in practice Opus adjudicates Sonnet; a Sonnet worker is never certified by
  Haiku). Pin it by **role/tier** (`adjudicator`, `task-worker`) — **never by a
  hardcoded or auto-selected model id.** The session model is a variable and the
  choice of model is the user's; any trust knob that depends on orchestrator
  strength (e.g. a circuit-breaker's vouch trust) keys on the *capability tier*,
  never on a specific model string.

## Cost gates

- State estimated cost (agent count × rough per-agent tokens) before any large
  fan-out. Fan-out scale is the user's call, not an inference.
- Budget every Workflow; always budget a dynamic one.
- Agent Teams costs significantly more than subagents — route to it only when
  workers genuinely need to talk to each other.

## Input contract (what every dispatch must carry)

Most delegation failures are underspecified handoffs, not weak workers. Every
dispatch to a worker states:

1. **Files/paths** — exact absolute paths the task touches or must read first.
2. **Spec** — the precise change/deliverable; for execution-shaped work the spec
   should be decision-complete (all judgment calls already made by the planner).
3. **Doctrine** — which standing rules apply (no AI attribution, branch + draft
   PR for CI-gated repos, ci-local gate, style/idiom constraints). ALWAYS
   includes: **no guessing** — any claim about an external system, API, tool
   flag, or on-disk format is verified empirically (run the command, read the
   source) or via a focused web search before being asserted or built upon;
   if it can't be verified, report it as *unknown*, never as fact. A guess
   that ships is a defect (the 06ec2d5 slug-rule bug was a guess).
4. **Verification** — the exact command(s) the worker must run and pass before
   reporting DONE (tests, `bash tests/ci-local.sh`, build).
5. **Non-goals** — what NOT to touch, explicitly (adjacent fixes → Findings, not
   commits).

A dispatch that can't fill these five isn't ready to delegate — finish planning
or do the discovery first.

## Output contract

- **Substantive workers** (Sonnet/Opus) return: Task · Findings · Evidence (as
  `file:line` or quoted source, never paraphrase) · Uncertainty · Blockers ·
  Recommendation (keep / escalate / verify).
- **Bounded utility workers** (Haiku) return just the result — schema-enforced
  structured output where available beats prose contracts.

## Pinned role agents

Enforced routing lives in `~/.claude/agents/` — frontmatter pins beat prose:

- `utility-worker` — Haiku, low: schema extraction, classification, formatting, mechanical single-file edits.
- `task-worker` — Sonnet, high: default substantive worker.
- `adjudicator` — Opus, xhigh: verification, arbitration, final judgment.

Route via these by default; reuse them as Agent Teams teammate definitions (a
subagent type spawned as a teammate honors its `tools` + `model`).

## Mechanisms (self-documenting — route to these, don't reinvent)

- **Subagents** — the Agent tool / pinned roles above.
- **Plan → execute loop** — `~/.claude/skills/`: `writing-plans`,
  `subagent-driven-development`, `executing-plans`, `dispatching-parallel-agents`,
  `using-git-worktrees`.
- **Agent Teams** — `code.claude.com/docs/en/agent-teams` (experimental).
- **Workflow tool** — deterministic fan-out with budgets / pipelines / resume.

## Anti-patterns

- The main thread doing dispatchable work sequentially, or sitting idle while
  dispatched work runs (the primary failure the per-turn hook guards against).
  Both recur worst in autonomous runs — see §Autonomous execution regime.
- Walking an execution-level plan sequentially inline because each step
  *individually* looks like "one substantive task" (decompose over the plan's
  dependency graph, not the current step).
- Blocking an autonomous run with a mid-execution `AskUserQuestion` (plan-doc
  check → reversible default + RESUME log → batch for end-of-run instead).
- Spawning many agents for a sequential problem; encoding a replan-prone project
  as one mega-workflow.
- Multiple agents editing the same files without ownership (use worktree isolation).
- Premium models for cheap repetitive tasks; unpinned cheap stages silently
  paying orchestrator rates.
- **Cheap-worker → Opus-adjudicator on a *single* task.** You pay Sonnet to
  generate *and* Opus to read the whole thing back, for worse recall than Opus
  generating once (verification restores precision, not recall — Sonnet's misses
  survive the verify). Strictly dominated. Worker→adjudicator earns its keep only
  across *many* workers (one judge amortized over the fan-out) or when verifying
  is genuinely cheaper than generating (repro a bug, run tests, diff a spec) —
  never when verify ≈ generate.
- Delegating when spec ≈ diff; synthesizing unsupported claims to look complete.
- An unbudgeted dynamic workflow.
