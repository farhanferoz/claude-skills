# claude-skills

A Claude Code plugin marketplace. Add it once, then install the plugins you want:

```
/plugin marketplace add farhanferoz/claude-skills
/plugin install guards@claude-skills
```

These plugins are the shareable part of one working Claude Code setup. The map of the whole setup (which practice
lives in which repository, and one command to install everything) is
[farhanferoz/claude-code-setup](https://github.com/farhanferoz/claude-code-setup).

Plugin skills are namespaced (`/guards:...`, `/orchestration:writing-plans`), and `skillOverrides` in
`settings.json` does not apply to them: to drop a plugin's skills, disable the plugin in `/plugin`. Each plugin is
independent, so install only the ones you want.

## Plugins

### Session continuity: see ccage

`/checkpoint`, `/keepwarm` and the hooks that read `RESUME.md` back after `/clear` now ship with
[ccage](https://github.com/farhanferoz/ccage), which installs them into every project. The `session-continuity`
plugin that used to live here was an older second copy and has been retired. The chat-only `session-handoff` skill
moved to the `session-hooks` plugin below.

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
- **`agy-run`** (in `scripts/`) — a wrapper that gives the `agy` CLI an honest exit code; `second-opinion` and
  `review-panel` call it.
- **The finders and the second opinion are third-party** and are not bundled. Install them from their authors:
  `find-bugs` and `security-review` from [getsentry/skills](https://github.com/getsentry/skills) (Apache-2.0);
  `fp-check`, `differential-review` and `second-opinion` from [trailofbits/skills](https://github.com/trailofbits/skills)
  (CC-BY-SA-4.0). `second-opinion` needs at least one of `codex`, `gemini-cli` or `agy`, plus a
  `~/.claude/second-opinion.config.json` declaring provider order and model.

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

- **`ai-patterns`** — measures formulaic "AI writing" patterns in prose against a baseline you calibrate from your
  own writing (`scan.py`). It is not an authorship detector and must not be used as one.
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

### review-panel

Run a simulated review panel on your own draft funding application before you
submit it, and get back only the criticisms that hold up against the text.

- **`review-panel`** — checks the draft against the funder's format limits,
  builds review copies with unfinished items marked so they are not counted as
  weaknesses, then runs several independent reviewers section by section (no
  critical or lenient personas, no rebuttal round), a check of the draft
  against the author's own brief and rulings, and a moderator that verifies
  every quoted criticism and ranks the fixes. Funders are described by profile
  files; a UKRI distributed peer review profile is included. For your own
  drafts only: funders forbid putting other applicants' work into AI tools.
- **Requires** Python 3.11+, Poppler (`pdfinfo`, `pdftotext`), and for some
  steps MuPDF's `mutool` and `pandoc` with `pdflatex`. Reviewers on a second
  model family need Google's Antigravity CLI (`agy`); without it the panel runs
  on Claude agents alone.
- Also published, identical, in
  [alan-turing-institute/aiphys-skills](https://github.com/alan-turing-institute/aiphys-skills).

```
/plugin install review-panel@claude-skills
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
- **`agent-cost`** — rolls up per-subagent tokens and dollars from the transcripts, and harvests the answer of a
  dead or stalled worker (`agent_harvest.py`) before anyone re-dispatches it.
- **`watch-job`** — how to watch a long job from the main session without polling or blocking it.
- **Guard hooks** (wired automatically on install) that make this safe: `write_set_guard` enforces single-writer
  discipline (no two subagents write the same path), `agent_reaper` records unstopped agents at session end and
  before compaction, `teammate_idle_guard` keeps a teammate working while its tasks remain, `task_completed_guard` checks a task's completion,
  plus foreground-job, subagent-foreground and poll-loop guards. All fail open and are inert outside their trigger
  conditions. (A per-turn doctrine re-injection hook used to ship here; it was removed because repeating the
  doctrine every turn did not change behaviour.)
- The routing policy the doctrine points at is in the `workers` plugin.

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

### guards

Policy guards that refuse or rewrite risky tool calls before they run, and check code after it is written. Each one
logs every decision, allows included, to `$CLAUDE_CONFIG_DIR/<guard>.log`, and each refusal names the correct action.

- **Before a Bash call:** `timeout_kill_guard` adds `-k 5` to a bare `timeout` (a child that ignores SIGTERM otherwise
  outlives its cap); `self_match_kill_guard` stops a `pkill -f`/`pgrep -f` whose pattern also matches the shell that
  runs it; `commit_provenance_guard` keeps AI/tool provenance out of commit messages and committed files;
  `secret_print_guard` (Bash, Read, Grep) refuses to print secret files or decrypted parameters into the transcript;
  `test_scope_guard` keeps test runs narrow and refuses a re-run of tests that already passed on an unchanged tree;
  `agy_print_guard` catches `agy -p` reporting a success it did not have; `approval_prompt_guard` refuses command
  shapes that make Claude Code stop for a human approval even under `bypassPermissions`.
- **Before an Agent, SendMessage or Workflow call:** `agent_dispatch_guard` asks a worker to earn its brief (run time
  or an independent reader); `agent_fanout_cap` caps parallel fan-out; `agent_worktree_base_guard` refuses a worktree
  that would start from a stale base; `workflow_budget_guard` refuses a workflow that carries no budget.
- **Before a Write:** `clutter_guard` refuses scratch-looking file names in a repository (`lib/junk_names.py`).
- **After a Write or Edit:** `code_hygiene_check` flags copied code (`scripts/dupcheck.py`), test growth
  (`hooks/test_growth_check.py`) and model loads that skip a settings lookup.
- **On demand:** `scripts/structure_ratchet.py --check` lets ruff's code-shape rules (`PLR0913`, `PLR0915`, `PLR0912`,
  `C901`) only get better in a repository that holds a `.structure-baseline.json`; `--update` lowers the baseline.
  No hook calls it, and it exits 0 in a repository without a baseline.
- **Setting:** `LM_LOOKUP_EXEMPT_GLOBS` (asked for when you enable the plugin; default empty) lists colon-separated
  path globs the model-load check never flags.
- Every guard with a `*.selftest.sh` beside it can be checked with `bash <name>.selftest.sh`.

```
/plugin install guards@claude-skills
```

### workers

Model-pinned agents so the tier of each subagent is set by its definition, not by the session: `task-worker`
(Sonnet, high effort), `task-worker-medium` (Sonnet, medium), `utility-worker` (Haiku, low), `adjudicator` (Opus,
extra-high), plus `claude` and `general-purpose` overrides. `reference/model-routing-policy.md` says which to use for
which task shape, with measured costs.

```
/plugin install workers@claude-skills
```

### coding-standard

One coding standard (reuse before writing, one responsibility per unit, settings instead of constants, types, errors,
performance and memory, tests, style, briefs and reviews), put into every session's context by a `SessionStart`
hook. A plugin's own `CLAUDE.md` is not loaded, so the hook is how it reaches the model. If you already load your own
standard from `CLAUDE.md` or `.claude/rules/`, do not install this as well: it would load twice.

```
/plugin install coding-standard@claude-skills
```

### session-hooks

Conveniences that never block: a cost report at session start (uses [tokenol](https://github.com/farhanferoz/tokenol)
when installed), tokenol start and stop, session-end cleanup, pruning of old session scratch directories, a report of
which installed skills were ever used (`scripts/skill_usage_inventory.py`), and the chat-only **`session-handoff`**
skill.

```
/plugin install session-hooks@claude-skills
```

`scripts/statusline-command.sh` is the status line: reasoning effort, context used, the 5-hour and 7-day limits,
prompt-cache state and, in a project with a `RESUME.md`, its open plan items. It needs `jq`. Copy it to
`~/.claude/statusline-command.sh` and set `"statusLine": {"type": "command", "command": "bash
~/.claude/statusline-command.sh"}` in `~/.claude/settings.json`.

### research-method

Procedures for research work, each written from a real failure: **`figure-workflow`** (from agreeing a figure's
message to rendered, checked output), **`methodology-review`** (reviewing a research programme's set-up and rigour),
**`training-change-checks`** (minutes of checks before hours of training after a change to how a model trains), and
**`ground-before-summarizing`** (resolve claims against source notes, with
[corpus-search](https://github.com/farhanferoz/corpus-search), before writing a summary).

```
/plugin install research-method@claude-skills
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
