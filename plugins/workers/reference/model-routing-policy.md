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

Aliases on Claude Code 2.1.289 (measured 2026-10-05 with `claude -p --model <alias>`): `sonnet` → `claude-sonnet-5-5`, `opus` → `claude-opus-5-5`, `fable` → `claude-fable-5-1`.

- **Haiku 4.5** — routing, classification, formatting, small summaries, and
  extraction **against an explicit schema**. NOT judgment-laden extraction (which
  claims matter, source quality) — measured in the deep-research validation:
  Haiku search/extract had invisible misses and had to be upgraded to Sonnet.
- **Sonnet 5.5** — default worker: coding, research, file analysis, scoped
  synthesis, test authoring, commits against a precise spec.
- **Opus 5.5** — planning, arbitration, architecture review, difficult/ambiguous
  debugging, final verification. As orchestrator only when it is the session model.
- **Fable 5.1** — among the STRONGEST tiers, not a weak or cheap model. When the
  session runs on Fable it is a fully capable orchestrator AND verifier; never
  auto-pin it, and never route heavy judgment *away* from it on the mistaken
  assumption it is weak. Like every tier here, the choice to use it is the user's.

### OpenCode Go routing (via `opencode-ccage-yolo` / `opencode-claude`)

When running on an OpenCode Go subscription ($10/mo flat-rate proxy tier):
- **Launch via:** `opencode-ccage-yolo` (or `opencode-claude`) which triggers the interactive model (26 options) and effort (low..max) selector, or pass direct flags `opencode-ccage-yolo --model <name> --effort <level>`.
- **Key Models**:
  - `qwen3.8-max` / `deepseek-v4-pro`: Flagship reasoning, deep code synthesis, and architectural decisions.
  - `glm-5.3` / `kimi-k3` / `minimax-m3`: Frontier reasoning, long-context comprehension, and rapid agentic iterations.
  - `deepseek-v4-flash` / `qwen3.7-plus`: High-speed coding, mechanical refactoring, and test execution.
- **Context Windows**:
  - **1M models (1,000,000 to 1,050,000 tokens):** `glm-5.3`, `glm-5.2`, `qwen3.8-max`, `qwen3.7-max`, `qwen3.7-plus`, `qwen3.6-plus`, `deepseek-v4-pro`, `deepseek-v4-flash`, `kimi-k3`, `minimax-m3`, `mimo-v2.5-pro`, `mimo-v2.5`, `mimo-v2-pro`, `gpt-5.6-luna`.
  - **500K models:** `grok-4.5`.
  - **256K–262K models:** `qwen3.5-plus`, `kimi-k2.7-code`, `kimi-k2.6`, `kimi-k2.5`, `mimo-v2-omni`, `hy3`, `hy3-preview`.
  - **~200K legacy models:** `glm-5.1`, `glm-5`, `minimax-m2.7`, `minimax-m2.5`.
  - `opencode-claude` automatically sets `CLAUDE_CODE_MAX_CONTEXT_TOKENS` and `statusline-command.sh` maps accurate token ceilings per model.
- **Latency & Context Management:**
  - OpenCode Go backends evaluate the full prompt on every turn without server-side KV prompt caching.
  - At large context (e.g. >80k tokens), prefill time takes 2–5 seconds per turn. Run `/compact` or `/clear` periodically to keep active context under 40–50k tokens for optimal responsiveness.
  - For rapid mechanical coding, prefer `deepseek-v4-flash` or `minimax-m3` with `--effort medium` or `low`.
- **Mid-session Model Switch:** Exit (`/exit` or `Ctrl+D`) and resume with `opencode-ccage-yolo -c` to pick a different model with 100% conversation & cage state preservation.

(`subagent-driven-development` carries its own cheap/standard/capable per-role
guidance — the same doctrine; this is the cross-mechanism default.)

## Effort policy

Effort moves in BOTH directions; prefer adjusting effort before switching tier or
architecture.

- Sonnet 5.5: `high` for substantive work; `low`/`medium` for mechanical fan-out.
- Opus 5.5: `high` default; `xhigh` for difficult / ambiguous / high-autonomy work.
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

**DO NOT MULTIPLY ANY NUMBER BELOW BY A NUMBER OF AGENTS.** There is no such
thing as "the cost of a Sonnet agent". The spread within a tier is ~30×, and it
is driven by lifetime × context, not by tier — so a per-tier figure predicts a
*population*, never the five agents you are about to dispatch. The only honest
answer to "what will this fan-out cost" before it runs is **"I don't know until
it lands"**; say that, dispatch, and reconcile with `agent-cost` afterwards (D4).

Written 2026-08-17, after this table caused the error it was supposed to
prevent: a session estimated $3–6 for five short research workers, "corrected"
itself to $28.50 by multiplying the Sonnet mean below by five, and the actual
came in at **$4.95**. The first instinct was right; the correction — reaching
for a population mean as a unit price — was the larger error, and the mean was
bolded in a column headed `$/agent` with the caveat in prose underneath.

**MEASURED 2026-08-17 across every subagent transcript on this machine (1,864
runs), parsed with `agent-cost`, which counts usage ONCE PER API RESPONSE:**

| tier | runs | median | p90 | max | median API calls |
|---|---|---|---|---|---|
| sonnet | 1,145 | 1.33 | 4.51 | **39.87** | 34 |
| opus | 553 | 0.74 | 2.10 | **20.29** | 9 |
| fable | 5 | 1.52 | 3.96 | 3.96 | 9 |

The `max` column is the point: one Sonnet agent has cost $39.87 and the median
one costs $1.33. Any single number here is a lie about at least one of them.

**UNRECONCILED, stated rather than quietly overwritten.** The 2026-08-10 pass
recorded means of $9.50 (sonnet, 1,425 runs), $4.66 (opus 4.x, 603) and $0.53
(haiku, 130) over a partly different population — it is 4.5× above the figures
above and is NOT superseded on the strength of one recount. Two differences are
known and neither fully closes the gap: **53.5 % of usage rows in these
transcripts are re-logs of an already-billed response** (67,001 re-logged rows
against 58,156 billed API calls), so any parser that does not dedup roughly
doubles every figure; and no haiku subagent transcripts survive on disk today,
so that row cannot be recomputed at all. Until someone reconciles them, treat
BOTH as evidence that the level is uncertain and the spread is the real finding.

- **The driver is the agent's LIFETIME × context, not its tier.** Sonnet agents
  cost 2× Opus agents here — because they run long and re-read their prefix on
  every call, while Opus agents are short adjudications. A cheap agent doing 40
  tool calls costs more than an expensive one doing 5. ⇒ narrow the task and
  keep the context small BEFORE reaching for a cheaper tier.
- **The inline alternative, costed:** carrying 200 k tokens for 20 more calls
  ≈ $4; for 50 more calls ≈ $7. A delegated agent lands in the same range for
  the same amount of work, so **delegation buys wall-clock and context hygiene,
  not dollars** — say that plainly instead of implying a saving. (This bullet
  used to name a single dollar figure for "a Sonnet agent". It no longer does,
  for the reason at the top of this section: that phrasing is what got
  multiplied.)
- **Cheapest SUFFICIENT tier, never cheapest.** Haiku's 18× advantage over
  Sonnet is real only where Haiku is sufficient: bounded, mechanical,
  spec-checkable work. Not judgment, and **not discovery** — a weak finder's
  misses are unrecoverable, and verification restores precision, never recall
  (see *verifiability asymmetry* below). Cost is the tiebreak among tiers that
  are all sufficient, never the selector.
- **Parallelism buys a median 1.96× (3+ agents), and NOTHING in 17 % of past
  fan-outs.** 335 fan-out groups measured. It does not improve with agent
  count — a 43-agent run returned 10.8×, a 50-agent run returned 2.31×. Past
  ~3 agents you are usually buying cost, not time.
- **Main-thread context is ~90 % of per-call cost at peak** (median session:
  $58, 280 calls, peak 376 k tokens ⇒ $0.19 of the $0.21 median call is
  re-reading what you are already carrying). This is why delegation is a
  context-offload tool first and a parallelism tool second.
- **CLAUDE.md is loaded by EVERY custom subagent** (only Explore and Plan skip
  it, per the Claude Code docs), so its size is multiplied by agent count, not
  paid once. Subagents do NOT receive the full Claude Code system prompt.
- State estimated cost (agent count × tier) before any large fan-out. Fan-out
  scale is the user's call, not an inference.
- Budget every Workflow; always budget a dynamic one. **Enforced** by
  `workflow_budget_guard` — a script with no `budget` reference is denied.
- Agent Teams costs significantly more than subagents (each teammate is a full
  session, and every inter-agent message is a model round trip) — route to it
  only when workers genuinely need to talk to each other.

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
- `task-worker-medium` — Sonnet, medium: executes a fully specified task (the plan fixes every file, test
  and behaviour). Measured 2026-09-28 on one project's plan step: median 6.4 min per task against 12.3 at high
  (B8, 97 tasks), no code defect found at landing in 10 tasks; its one repeated slip, a ticked plan step
  whose test covers a symbol without naming it, is caught by the repo's plan check.
- `task-worker` — Sonnet, high: any task needing investigation, debugging, research or a design choice.
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

---

## Orchestration reference (moved out of CLAUDE.md, 2026-08-10)

These are **not rules to obey** — they are facts to look up when relevant. They were sitting in the
always-loaded instruction tier, where each one competed for adherence with rules that do have to
bind (measured: instruction-following degrades with the COUNT of simultaneously live rules —
Sonnet 4.6 falls 96.4% → 60.4% going from 1 to 20). Moved here so they cost nothing until read.

- **Workers self-assign because a hook ORDERS them to — check hooks before blaming the worker.** No brief survives a hook that tells the worker to claim tasks; if workers go rogue, read the hook payloads in their transcripts first. ⚠️ A `tools:` allowlist does NOT contain this — `ToolSearch` fetches deferred tools around the frontmatter allowlist, so the binding fix is at the hook, not the toolset.
- **AGENT LIFECYCLE — name every agent; stop them yourself.** Enumerate live teammates with `TaskStop({task_id: "__enumerate_probe__"})` → it prints a `Running teammates:` line (absent = none); use it before every `/clear`, checkpoint, or compaction, and to confirm a stop took. **Stop every agent before any context boundary** — a `/clear` wipes your memory of them but does NOT stop them, orphaning agents nobody can kill. Killing a parent does NOT kill its children: find orphaned children via `<config-dir>/projects/<project>/<session-id>/subagents/*.meta.json` (each carries `parentAgentId`/`spawnDepth`/`description`), stop by **bare agent id** (from the `agent-<id>.jsonl` filename — type names fail); `.jsonl` mtime is the liveness test — **run it BEFORE any stop of a remembered/recorded id, never sweep-stop a list blind**. `TaskStop` replying `No task found` = already dead = **SUCCESS — move on, never retry**; the probe's error reply is its designed output, not a failure. Commit before stopping (a kill freezes work mid-contract). Backstop: `hooks/agent_reaper.sh` records unstopped agents into `RESUME.md` at `SessionEnd`/`PreCompact`, but `SessionEnd` cannot block — it preserves names, it does not save you. (why: hook header)
- **A named teammate's final answer arrives in its idle notification — fixed in 2.1.251, verified 2026-10-05 on 2.1.289** (a named Haiku probe's `PONG` came back as the notification's `result`). Naming is safe. Two caveats: the notification is queued until the parent's current turn ends, so a long parent turn sees nothing until it yields — do not read that silence as non-delivery (it was misread so once, the same day); and SendMessage is still how you hand a named agent more work. The root still verifies against DISK, never the claim.
- **Route by shape (mechanisms already installed — don't reinvent):** 2–5 known independent tasks → parallel subagents; a planned multi-task project → `writing-plans` → `subagent-driven-development`/`executing-plans`; workers must discuss/challenge or a multi-lens review → **Agent Teams**; large/repeatable/looping/discovered-scale → a **Workflow** with an explicit budget. Single/sequential/spec≈diff → main loop; don't over-orchestrate.
- **Verifiability asymmetry:** adjudication kills false positives but cannot recover misses. Execution-shaped work (checkable vs a spec) → worker tier barely matters. Discovery-shaped (bugs/security/research) → raise finder tier or use diverse finders; never certify completeness from a quiet finder.
- **Opus 5.5's real premium on long-context work is ~1.5x, not 2x.** Cache READS cost the same on both: $0.20/Mtok (0.05x of Opus 5.5's $4, 0.1x of Sonnet 5.5's $2; pricing page 2026-10-05). The premium sits in new input written to the 1-hour cache ($8 vs $4) and output ($20 vs $10). Arithmetic, not a measurement: a turn with 100k cached context, 2k new input and 1k output costs ~5.6c on Opus 5.5 vs ~3.8c on Sonnet 5.5. The gap narrows as context grows and widens with output, so for judgement-heavy, low-output work on a big context, cost is a weak reason to avoid Opus.
- **Sonnet 5.5 and the cache — measured 2026-10-05.** Inside ONE process it caches normally: four Sonnet 5.5 workers read ~20x what they wrote (e.g. 1.43M read / 72k written, one big write on the first request). It misses on EVERY turn only across separate `claude -p --resume` processes (seed + 4 resumed turns: read only the 12.4k system prefix, re-wrote ~94k each turn, ~$0.38/turn; Opus 5.5 in the same chain read ~106k). So dispatching Sonnet workers is unaffected; a multi-step HEADLESS job that chains `--resume` runs should stay in one process or use Opus 5.5.
- **Watch long jobs from the main thread, not a sub-agent.** Sub-agents default to the 5-minute
  prompt-cache tier; ours get 1 hour only because `ENABLE_PROMPT_CACHING_1H=1` is exported in every
  cage (it covers both buckets; measured 2026-10-05: a research sub-agent wrote 847,783 cache tokens at
  the 1-hour tier, 0 at 5-minute). Even so, a sub-agent watcher dies with its parent and costs a second
  context. Background+notify, or a single blocking wait. Never poll by re-reading a whole log file.

## Throughput: close work faster than it opens (owner 2026-09-30; dropped from the resident rules 2026-10-28, this is its record)

Everything else in this document optimises correctness; this section is the counterweight. **Measured 2026-09-30
(a product project):** a plan counter sat at 150/201 for over an hour while one gate's carry-over grew from 8 blockers to 10
plus 16 follow-ups, because every review finding became a task, every find made while landing became a dispatched
wave, a blocking live defect was investigated before any fix, and landings ran one at a time. The owner: "the speed at
which new tasks are being added is way faster than the speed at which the tasks are being closed … I've told you
repeatedly." Plans written for any project carry these rules; running orchestration obeys them:

- **A gate works only its blockers and security findings before it passes.** Every other finding is triaged: at most a
  handful ride along with the next batch's waves; the rest are deferred or dropped, each with a one-line reason.
- **Finds made mid-work are parked** as one line unless they block; they join the triage, never an immediate wave.
- **Conservative, reversible fix first** for a blocking defect (smaller batches, lower budgets, refuse instead of
  guess), verified live; investigate the exact cause only if it does not hold. Briefs carry no slow steps (live
  measurement loops, rests) unless the owner asked.
- **Order rules gate files, not batches:** a dependent task whose files do not overlap a gate's open items may start
  once those items are dispatched. A rule holding unrelated work is raised with the owner at once, not obeyed silently.
- **Batch landings:** land every finished worker, then one test run, one push per group. Local pre-push runs fast
  checks; CI is the full gate, and every push is still followed to its result.
- **Watch the owner's progress signal** (the plan counter): if it has not moved in an hour, say why and what changes.

## Long authoring (moved from main-session-doctrine.md 2026-09-30; that file was folded into CLAUDE.md 2026-10-28 and this rule dropped)

MEASURED 2026-08-12. Evidence assembly ran 08:00-08:23 and was good work. By 08:23 the
session had been told eight times by the Stop guard that it was idling, and asked twice why
it was idle. At 08:25 it wrote "the last few turns went to answering rather than writing --
drafting now", accepting a schedule debt it did not owe, and produced ~7,000 words against
an agreed 16,400 in six minutes. Budget tracking appeared for the first section and never
again. The occupancy threshold had to be raised by hand, mid-draft, at 08:31.

The lesson is not "work faster" or "ignore the guard". It is that a phase boundary is free
and removes the pressure at its source: a fresh session has room, a clean context, and no
accumulated sense of being behind. The drafting step reads from frozen registers by design,
so it needs nothing from the evidence session's context. Scope (2026-09-30): this is about
PROSE deliverables. It was misapplied to a request to plan twelve already-diagnosed UI fixes,
which is execution work — see the doctrine's "First decide whether a plan is warranted".

## Removed re-injection gate (moved from main-session-doctrine.md 2026-09-30)

The per-turn `orchestrator_check.sh` gate was REMOVED 2026-08-10. It re-injected the
orchestration section's headlines before every message — ~204 tokens × ~9/session, 1.45 M
tokens lifetime — and every rule it carried was already in the doctrine, four of them
verbatim. It did not bind: the four-unpinned-agent incident happened with it firing on every
turn. Repetition is not the lever. Do not reintroduce a re-injection hook to fix an adherence
problem.
