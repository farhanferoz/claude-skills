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
