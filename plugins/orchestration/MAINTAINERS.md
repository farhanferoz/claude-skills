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
- **Fork points are now per-skill** (each `.upstream-base/<skill>.SKILL.md` is the
  exact upstream ancestor it was last rebased from — each verified byte-identical
  to the commit named):
  - `writing-plans` — commit `d884ae0` (2026-07-02), **rebased 2026-07-17** (was
    `4ae1a3d`, 2026-03-25).
  - `subagent-driven-development` — commit `d884ae0` (2026-07-02), **rebased
    2026-07-17** (was `9ccce3b`, 2026-03-11).
  - `executing-plans` — commit `3bdd66e` (2026-03-08), not yet rebased.
- **Last upstream reviewed:** commit `d884ae0`, 2026-07-02 (= current HEAD / v6.1.1).

## What our fork changes

Every modification replaces Superpowers' sequential "walk the task list"
execution model with dependency-wave dispatch, plus the write-set discipline the
`hooks/write_set_guard.sh` backstops. Beyond that:

- `subagent-driven-development` tracks upstream's file set as of `d884ae0`:
  `implementer-prompt.md` + `task-reviewer-prompt.md` (upstream consolidated our
  old separate `spec-reviewer`/`code-quality-reviewer` prompts into this single
  two-verdict reviewer) + `scripts/{task-brief,review-package,sdd-workspace}`.
  One local adaptation: upstream's hard relative path
  `../requesting-code-review/code-reviewer.md` (final whole-branch review) is
  softened to a `superpowers:requesting-code-review` skill reference, since this
  plugin does not bundle that sibling skill — install the Superpowers pack
  alongside for it.

## Upstream drift (vs current HEAD `d884ae0`)

| Skill | State | Our divergence from its base | Action |
|---|---|---|---|
| `subagent-driven-development` | **rebased 2026-07-17 onto `d884ae0`** | just the 2 wave-dispatch hunks | current — re-review when upstream moves |
| `writing-plans` | **rebased 2026-07-17 onto `d884ae0`** | just the 2 additive Orchestration-tag hunks | current — re-review when upstream moves |
| `executing-plans` | at `3bdd66e` (2026-03-08) | +38 / −15 | low — upstream stagnant (+3/−3 since fork), freeze is nearly free |

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
