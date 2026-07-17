# claude-skills

A Claude Code plugin marketplace. Add it once, then install the plugins you want:

```
/plugin marketplace add farhanferoz/claude-skills
/plugin install session-continuity@claude-skills
```

## Plugins

### session-continuity

Keep a session's state alive across `/clear` and context boundaries.

- **`/checkpoint`** — writes the current state into a lean `RESUME.md` and rolls
  older detail into `CHANGELOG.md`. Both files are excluded locally via
  `.git/info/exclude`, so they never land in the repo.
- **SessionStart hook** — on every session start, including right after `/clear`,
  `RESUME.md` is read back into context automatically. The loop becomes
  `/checkpoint` → `/clear` → (state reloaded), with no copy and no paste.
- **`/keepwarm`** — schedules tiny self-wake turns so the prompt cache stays warm
  while you step away, avoiding a full cache rewrite on your return. Optionally
  uses `jq` for per-ping cost estimates; works without it (cost shown as unknown).
- **session-handoff** — produces a chat-only end-of-session handoff brief so a
  fresh agent can resume after `/clear`.

`RESUME.md` / `CHANGELOG.md` are personal continuity files. The hook honors a
`RESUME_SLOT` suffix for parallel same-directory sessions and falls back to plain
`RESUME.md` when it is unset.

`/checkpoint --final` marks the session's work as genuinely finished: it writes
a `.session-done` marker at the project root after the usual checkpoint. A
running `/keepwarm` checks for that marker on every wake and self-stops the
moment it sees one, instead of pinging a session that's already done. A plain
`/checkpoint` (no `--final`) clears the marker again, signaling "still
working" — so returning to a project and checkpointing normally puts
`/keepwarm` back to work if you resume it.

### review-suite

Match review depth to how risky the change is, then dispatch the right local
skills.

- **`tiered-review`** — classifies a branch light-to-critical (Tier 1–4) from
  commit count and whether the diff touches auth, migrations, data integrity,
  a public API, or an on-disk format. States the proposed tier and waits for
  confirmation before running anything.
  - **Tier 1 (light)** — `simplify` only, no dedicated review.
  - **Tier 2 (standard)** — `simplify` + `find-bugs` + `/second-opinion` +
    `fp-check` on the candidate findings.
  - **Tier 3 (release candidate)** — `simplify` + a parallel fan-out
    (`differential-review`, `find-bugs`, `security-review`, test-coverage,
    convention compliance) + `fp-check` + `/second-opinion` + one adversarial
    re-run.
  - **Tier 4 (critical)** — everything in Tier 3, plus property-based tests
    added before the review and a fresh-session pattern to strip conversation
    context that primed the agent on the implementation.
- **`find-bugs`**, **`fp-check`**, **`differential-review`**,
  **`security-review`** — the workers `tiered-review` dispatches; each is also
  usable standalone.
- **`second-opinion`** — shells out to an external LLM CLI for genuinely
  cold-context review. Requires at least one of `codex`, `gemini-cli`, or
  `agy` installed, plus a `~/.claude/second-opinion.config.json` declaring
  provider order and model.

```
/plugin install review-suite@claude-skills
```

### deep-research-tiered

A cost-tiered fork of deep research: decompose the question in-session, get
user approval on the search angles and cost estimate, then run the expensive
fan-out on cheaper models instead of the session model throughout.

- **`/deep-research-tiered`** — decomposes the question into 4–6
  complementary search angles itself (no agent spent on that step), presents
  angles + caps + a cost estimate, and waits for confirmation before
  launching. The fan-out then runs search → fetch → three-way verify
  (confirmed / unvalidated / refuted) with Opus appeals for refuted
  primary-source claims → synthesis, with search/fetch/verify on Sonnet and
  only the final synthesis on the session model. Measured roughly 10× cheaper
  than an all-session-model deep research run on our test runs. Writes the
  full cited report to disk before presenting it in chat.
- Bundles the six `dr-*` agents the workflow drives: `dr-searcher`,
  `dr-extractor`, `dr-verifier`, `dr-checker`, `dr-synthesizer`, and
  `dr-synthesizer-max` (for the deepest-effort synthesis pass).

```
/plugin install deep-research-tiered@claude-skills
```

### research-report

Turn working notes into a technical report a colleague with no project context
and no code access can read start to finish.

- **`research-report`** — drafts or revises the document against a genre
  contract (no code references, every named object defined inline with its
  formula, load-bearing math derived, evidence shown as tables/figures), then
  enforces it with two gates the author cannot fool: a mechanical grep guard and
  a fresh-subagent cold-read of the *rendered PDF*. Bundles the contract, the
  book-chapter LaTeX template, the guard, and the build script.
- **Requires** `pandoc` and a `pdflatex`/texlive install (the template's
  Palatino/Helvetica packages are Type1, so the engine is pdflatex, not
  xelatex). Without them the guard and cold-read loop still run; only the PDF
  build step needs the toolchain.

```
/plugin install research-report@claude-skills
```

### programme-plan

Keep one plan coherent across months, many parallel strands, and many agents
writing the same files.

- **`programme-plan`** — structures a long-lived programme as `MASTER.md` (index
  + rules only) plus one file per strand, on the principle that *a plan is a
  cache of disk state and caches go stale*. Bans dated plan files, requires
  evidence on every done row, and enforces single-writer discipline (fan out on
  compute, serialise on writes). For a single multi-step task use
  `writing-plans` instead; this is for programmes that run for weeks.

```
/plugin install programme-plan@claude-skills
```

### orchestration

Turn a written plan into an autonomous, hours-long run that works through a
stack of tasks by itself — dispatching in dependency waves instead of walking
the list one task at a time.

- **`writing-plans`** — write an execution-level plan whose tasks carry
  Orchestration tags (`parallel`/`deps`/`tier`/`scale`/`shape`/`verify` and a
  `Files:` write set) so execution can self-route.
- **`executing-plans`** — partition the whole plan into dependency waves (a wave
  = tasks whose deps are met and whose write sets are disjoint), dispatch each
  wave concurrently, and act as dispatcher + verifier rather than executor.
  Includes `workflow-compile.md` for compiling a plan into a budget-capped,
  crash-resumable Workflow.
- **`subagent-driven-development`** — the in-session variant: fresh subagent per
  task with a spec + quality review after each, dispatched by wave.
- **Eight guard hooks** (wired automatically on install) that make this safe:
  `write_set_guard` enforces single-writer discipline (no two subagents write
  the same path), `orchestrator_check` re-injects the decomposition doctrine
  every turn, `agent_reaper` records unstopped agents at session end and
  pre-compaction, plus subagent/foreground/poll-loop guards. All fail-open and
  inert outside their trigger conditions.
- **`reference/model-routing-policy.md`** — the router the doctrine points at
  (which tier for which task shape).

The three skills are **modified forks of [obra/superpowers](https://github.com/obra/superpowers)**
(MIT, © 2025 Jesse Vincent) — sequential execution was replaced with wave
dispatch. See the plugin's `NOTICE` for attribution and `MAINTAINERS.md` for the
fork point and how to rebase onto newer upstream. Pairs with **ccage** for
unattended runs: ccage-auto keeps the session alive across checkpoints and arms
its own `autonomous_ask_guard` (not shipped here, to avoid double-registration).

**Optional Superpowers companion.** `subagent-driven-development` points at a few
sibling Superpowers skills — `superpowers:requesting-code-review` for the final
whole-branch review, and `test-driven-development` / `using-git-worktrees` /
`finishing-a-development-branch` in its Integration list. This plugin does **not**
bundle them; those steps degrade to a generic review when they are absent. To get
them, install the `superpowers` plugin from
[obra/superpowers-marketplace](https://github.com/obra/superpowers-marketplace)
alongside this one. Note that `superpowers` is a monolithic pack that *also* ships
its own writing-plans/executing-plans/subagent-driven-development — so with both
installed you will have two of each: prefer the `orchestration:`-namespaced ones
(the wave-dispatch forks). A hard plugin dependency is intentionally not declared,
precisely to avoid pulling in that second, sequential copy.

**Requires `python3`** on `PATH` — the guard hooks use it for JSON parsing and
write-set tracking (they fail open if it is missing, so the skills still work,
but the guards are what make parallel wave-dispatch safe).

```
/plugin install orchestration@claude-skills
```

### playwright-agents

Listed here for one-command install; lives in its own repo
([farhanferoz/playwright-agents](https://github.com/farhanferoz/playwright-agents)).
Wraps Playwright's first-party test agents: pins model/effort, wires the Test MCP
into the project's `.mcp.json`, and verifies generated specs with a real test run.

```
/plugin install playwright-agents@claude-skills
```

## License

MIT — see [LICENSE](LICENSE).
