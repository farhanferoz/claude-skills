# Compiling an execution-level plan into a dynamic Workflow

Referenced from SKILL.md Step 2.4. Use when ALL of these hold; otherwise stay with
wave-dispatched subagents (SKILL.md Step 2.1–2.3):

- the plan is **execution-level**: every task decision-complete (exact files, full
  spec, Orchestration line with `deps`/`tier`/`verify`), nothing left to design;
- **≥5 tasks** (below that, the compile overhead beats the drift it prevents);
- **autonomous run** — no mid-course human ratification expected between waves;
- the user has opted into workflow-scale execution (this skill telling you to call
  Workflow satisfies the opt-in, but still STATE THE ESTIMATED COST first and set
  a budget — never launch unbounded).

Why compile at all: a model-as-dispatcher enforces waves by discipline; a script
enforces them by construction. The compiled workflow cannot degenerate into
sequential inline execution, survives a crash (journal + `resumeFromRunId`), and
hard-caps spend (`budget`).

## The compilation, mechanically

1. **Extract tasks** from the plan: id, full task text, `Files:` Create/Modify
   (= write set), Orchestration `deps` / `tier` / `shape` / `verify`.
2. **Compute waves**: wave N = all tasks whose deps are in waves < N. Then split
   any wave whose members share a write path (two tasks writing one file never
   share a wave — `writes` overlap is a serialization edge exactly like `deps`).
3. **Emit the script** (template below): one `phase()` per wave; inside a wave,
   `parallel()` over its tasks; each task = implement (its `tier`) → verify
   (run the plan's `verify` command; `shape: discovery` tasks get an adversarial
   verifier on a higher tier instead of a plain check).
4. **Root stays in the loop**: for long programmes run ONE workflow per wave-batch
   and read results between batches, rather than one mega-run — you are the
   dispatcher-verifier, the workflow is your wave engine.
5. **After the run**: verify the final state against DISK yourself (workers' green
   claims are not verification), update the plan checkboxes / RESUME, commit.

## Script template

```javascript
export const meta = {
  name: 'execute-plan',
  description: 'Deterministic wave execution of a ratified execution-level plan',
  phases: [{ title: 'Wave 1' }, { title: 'Wave 2' }],  // one per computed wave
}
// TASKS: paste the extracted task objects — the plan text IS the brief.
// {id, brief, tier: 'haiku'|'sonnet'|'opus', verify: 'exact command', wave: N}
const WAVES = [ /* [[task, ...], [task, ...]] in wave order */ ]
const AGENT_TYPE = { haiku: 'utility-worker', sonnet: 'task-worker', opus: 'adjudicator' }
const done = []
for (let w = 0; w < WAVES.length; w++) {
  phase(`Wave ${w + 1}`)
  const results = await parallel(WAVES[w].map(t => () =>
    agent(
      `${t.brief}\n\nSTANDING CLAUSES: land every verified change to disk ` +
      `immediately; do ONLY what this task names. VERIFY before returning by ` +
      `running: ${t.verify} — include its real output in your report.`,
      { label: t.id, phase: `Wave ${w + 1}`, agentType: AGENT_TYPE[t.tier] || 'task-worker',
        isolation: undefined /* 'worktree' ONLY if same-wave tasks were split for write overlap you could not serialize */ }
    ).then(r => ({ id: t.id, verify: t.verify, report: r }))
  ))
  done.push(...results.filter(Boolean))
  log(`wave ${w + 1}: ${results.filter(Boolean).length}/${WAVES[w].length} tasks returned`)
}
return { completed: done.map(d => d.id), reports: done }
```

Budget it: pass the user's token target, or guard loops with
`budget.remaining()`. State the estimate before launching (tasks × tier cost);
`agent-cost` afterwards tells you what it actually was.

## What does NOT belong in a compiled workflow

- Tasks needing judgment about WHAT to build (that's planning — go back);
- mid-run user questions (autonomous protocol: reversible default + RESUME
  `### Decisions`, or halt if irreversible);
- plan-file edits by workers (root is the single writer; workers return reports);
- discovery-shaped open sweeps without a budget (loop-until-dry + budget, or
  don't).
