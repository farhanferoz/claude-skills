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
