# Maintaining the orchestration plugin

Three of the four skills here are **modified forks** of Superpowers skills. The
fourth capability set (the eight guard hooks and the routing policy) is
original. This note is for keeping the forks current against upstream.

## Provenance

| Skill | Origin | Status |
|---|---|---|
| `writing-plans` | obra/superpowers | modified fork |
| `executing-plans` | obra/superpowers | modified fork (+ `workflow-compile.md`, original) |
| `subagent-driven-development` | obra/superpowers | modified fork |
| the 8 `hooks/` guards, `reference/model-routing-policy.md` | original | — |

- **Upstream:** https://github.com/obra/superpowers (MIT, © 2025 Jesse Vincent)
- **Fork point:** 2026-03-21 — the unmodified copies as of that date are kept in
  `.upstream-base/` (one file per skill).
- **Last upstream reviewed:** commit `d884ae0`, 2026-07-02.

## What our fork changes

Every modification replaces Superpowers' sequential "walk the task list"
execution model with dependency-wave dispatch, plus the write-set discipline the
`hooks/write_set_guard.sh` backstops. The supporting prompt files
(`implementer-prompt.md`, `spec-reviewer-prompt.md`, `code-quality-reviewer-prompt.md`)
are unchanged from upstream.

## Upstream drift (measured at fork point → `d884ae0`)

| Skill | Upstream change since fork | Our divergence from upstream HEAD | Rebase priority |
|---|---|---|---|
| `executing-plans` | +3 / −3 (effectively stagnant) | +38 / −15 | low — freeze is nearly free |
| `writing-plans` | +43 / −14 | +24 / −40 | medium — worth a one-time rebase |
| `subagent-driven-development` | **+209 / −68 (heavily rewritten)** | +90 / −210 | **high — missing ~200 lines of new upstream work** |

## How to rebase a skill onto newer upstream

Do NOT auto-track upstream: an update's most likely effect is to silently revert
the wave-dispatch behaviour, which is the whole point of the fork. Rebase
deliberately, per skill:

1. `git clone --depth 1 https://github.com/obra/superpowers` (call it `UP`).
2. Three-way merge: base = `.upstream-base/<skill>.SKILL.md`, theirs =
   `UP/skills/<skill>/SKILL.md`, ours = `skills/<skill>/SKILL.md`. e.g.
   `git merge-file -p ours base theirs > merged` (ours/base/theirs in that arg
   order), or a visual 3-way tool.
3. Resolve so upstream's improvements land but the wave-dispatch sections
   (Step 2 / execution model / the "overlapping write sets" rule / the
   Orchestration tag block) keep our version.
4. Replace `.upstream-base/<skill>.SKILL.md` with the new upstream copy so the
   next rebase has a fresh base, and bump "Last upstream reviewed" above.
5. Run `claude plugin validate plugins/orchestration` and exercise a real plan.

## Not shipped here

`autonomous_ask_guard.sh` (blocks `AskUserQuestion` mid-autonomous-run) is part
of the **ccage** project — it is armed per-run by `ccage-auto` via
`CCAGE_AUTONOMOUS=1`, and ccage ships it in its own `share/hooks/`. Duplicating
it here would double-register it for ccage-auto users, so it is intentionally
absent. Install ccage to get it.
